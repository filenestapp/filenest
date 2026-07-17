import XCTest
import Combine
@testable import FileNest

final class AppStateTests: XCTestCase {
    @MainActor
    func testChatActivityTracksRunningCompletionAndSeenStates() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        let previousIndexer = AppStateIndexerProxy.shared.indexer
        defer { AppStateIndexerProxy.shared.indexer = previousIndexer }
        let state = AppState(
            store: store,
            settings: settings,
            organizeRoot: temporaryDirectory.appendingPathComponent("organized"),
            startAutomatically: false
        )

        state.markChatRunning(42)
        XCTAssertEqual(state.runningChatSessionIDs, [42])
        XCTAssertTrue(state.completedChatSessionIDs.isEmpty)

        state.markChatCompleted(42)
        XCTAssertTrue(state.runningChatSessionIDs.isEmpty)
        XCTAssertEqual(state.completedChatSessionIDs, [42])

        state.markChatSeen(42)
        XCTAssertTrue(state.completedChatSessionIDs.isEmpty)
    }

    func testIndexingTaskStateDrivesAnimationsAndReindexAvailability() {
        XCTAssertTrue(IndexingTaskState.running.isActive)
        XCTAssertTrue(IndexingTaskState.running.isAnimating)
        XCTAssertTrue(IndexingTaskState.running.blocksReindexButtons)

        XCTAssertTrue(IndexingTaskState.paused.isActive)
        XCTAssertFalse(IndexingTaskState.paused.isAnimating)
        XCTAssertTrue(IndexingTaskState.paused.blocksReindexButtons)

        XCTAssertFalse(IndexingTaskState.stopped.isActive)
        XCTAssertFalse(IndexingTaskState.stopped.blocksReindexButtons)
    }

    @MainActor
    func testRefreshLoadsFilesRulesAndCountFromInjectedStore() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        let organizedDirectory = temporaryDirectory.appendingPathComponent("organized", isDirectory: true)
        try FileManager.default.createDirectory(at: organizedDirectory, withIntermediateDirectories: true)
        let previousIndexer = AppStateIndexerProxy.shared.indexer
        defer { AppStateIndexerProxy.shared.indexer = previousIndexer }
        _ = try store.upsertFile(makeFile(in: organizedDirectory, name: "first.txt"))
        _ = try store.upsertRule(Rule(
            id: nil,
            name: "Documents",
            type: RuleType.rule.rawValue,
            pattern: "txt",
            targetFolder: "Documents",
            priority: 1,
            enabled: true
        ))

        let state = AppState(store: store, settings: settings, organizeRoot: organizedDirectory,
                             startAutomatically: false)

        XCTAssertEqual(state.files.map(\.name), ["first.txt"])
        XCTAssertEqual(state.rules.map(\.name), ["Documents"])
        XCTAssertEqual(state.indexedCount, 1)
        XCTAssertFalse(state.isWatching)

        _ = try store.upsertFile(makeFile(in: organizedDirectory, name: "second.txt"))
        state.refresh()
        XCTAssertEqual(Set(state.files.map(\.name)), ["first.txt", "second.txt"])
        XCTAssertEqual(state.indexedCount, 2)
    }

    @MainActor
    func testWatchStatusUsesSuccessfullyAttachedDirectoryCount() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let accessibleDirectory = temporaryDirectory.appendingPathComponent("accessible", isDirectory: true)
        let missingDirectory = temporaryDirectory.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createDirectory(at: accessibleDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        settings.setWatchDirs([accessibleDirectory.path, missingDirectory.path])
        let previousIndexer = AppStateIndexerProxy.shared.indexer
        defer { AppStateIndexerProxy.shared.indexer = previousIndexer }
        let state = AppState(
            store: store,
            settings: settings,
            organizeRoot: temporaryDirectory.appendingPathComponent("organized"),
            startAutomatically: false
        )

        state.startWatching()
        defer { state.stopWatching() }
        for _ in 0..<50 where state.activeWatchDirectoryCount != 1 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(state.isWatching)
        XCTAssertTrue(state.hasActiveWatchDirectories)
        XCTAssertEqual(state.activeWatchDirectoryCount, 1)
        XCTAssertEqual(state.configuredWatchDirectoryCount, 2)
        XCTAssertEqual(state.watchDirectoryStatus(for: missingDirectory.path)?.accessState, .missing)
        XCTAssertEqual(state.watchStatusTitle, settings.localizedFormat("Watching %d of %d folders", 1, 2))
    }

    @MainActor
    func testForwardsNestedSettingsChangesToSwiftUIObservers() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        let previousIndexer = AppStateIndexerProxy.shared.indexer
        defer { AppStateIndexerProxy.shared.indexer = previousIndexer }
        let state = AppState(store: store, settings: settings,
                             organizeRoot: temporaryDirectory.appendingPathComponent("organized"),
                             startAutomatically: false)
        var changeCount = 0
        let cancellable = state.objectWillChange.sink { changeCount += 1 }

        settings.setLLMChoice(AppSettings.LLMChoice.cloud.rawValue)

        XCTAssertGreaterThan(changeCount, 0)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testSettingsCanOpenDirectlyOnAIModels() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        let previousIndexer = AppStateIndexerProxy.shared.indexer
        defer { AppStateIndexerProxy.shared.indexer = previousIndexer }
        let state = AppState(store: store, settings: settings,
                             organizeRoot: temporaryDirectory.appendingPathComponent("organized"),
                             startAutomatically: false)

        state.selectSettingsSection(.aiModels)

        XCTAssertEqual(state.selectedSettingsSection, .aiModels)
    }

    @MainActor
    func testNewChatIsPersistedOnlyAfterFirstQuestion() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        let previousIndexer = AppStateIndexerProxy.shared.indexer
        defer { AppStateIndexerProxy.shared.indexer = previousIndexer }
        let state = AppState(
            store: store,
            settings: settings,
            organizeRoot: temporaryDirectory.appendingPathComponent("organized"),
            startAutomatically: false
        )

        state.newChat()

        XCTAssertNil(state.selectedChatSessionID)
        XCTAssertTrue(try store.allChatSessions().isEmpty)

        let sessionID = try XCTUnwrap(state.persistChatForQuestion())
        XCTAssertEqual(state.selectedChatSessionID, sessionID)
        XCTAssertEqual(try store.allChatSessions().map(\.id), [sessionID])
    }

    @MainActor
    func testComposerDraftSurvivesViewChangesAndIsKeptPerChat() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        let previousIndexer = AppStateIndexerProxy.shared.indexer
        defer { AppStateIndexerProxy.shared.indexer = previousIndexer }
        let state = AppState(
            store: store,
            settings: settings,
            organizeRoot: temporaryDirectory.appendingPathComponent("organized"),
            startAutomatically: false
        )

        state.newChat()
        state.updateChatComposerInput("unfinished new question")
        state.refresh()
        XCTAssertEqual(state.chatComposerInput, "unfinished new question")

        let firstSessionID = try XCTUnwrap(state.persistChatForQuestion())
        state.updateChatComposerInput("follow-up draft")
        state.newChat()
        XCTAssertEqual(state.chatComposerInput, "")

        state.updateChatComposerInput("another draft")
        state.selectChat(firstSessionID)
        XCTAssertEqual(state.chatComposerInput, "follow-up draft")
    }

    @MainActor
    func testOnboardingCanBePresentedOnceAndCompletedFromSingletonWindow() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        settings.setWatchDirs([temporaryDirectory.path])
        let previousIndexer = AppStateIndexerProxy.shared.indexer
        defer { AppStateIndexerProxy.shared.indexer = previousIndexer }
        let state = AppState(
            store: store,
            settings: settings,
            organizeRoot: temporaryDirectory.appendingPathComponent("organized"),
            startAutomatically: false
        )

        state.presentOnboarding()
        state.presentOnboarding()
        XCTAssertTrue(state.isOnboardingPresented)

        state.completeOnboarding()
        XCTAssertFalse(state.isOnboardingPresented)
        XCTAssertTrue(settings.onboardingCompleted)
    }

    @MainActor
    func testIndexConfigurationSeparatesMigrationPromptAndAutomaticModelRebuild() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        let organizedDirectory = temporaryDirectory.appendingPathComponent("organized", isDirectory: true)
        try FileManager.default.createDirectory(at: organizedDirectory, withIntermediateDirectories: true)
        var legacy = makeFile(in: organizedDirectory, name: "legacy.txt")
        legacy.indexSignature = "legacy-combined-signature"
        let fileID = try store.upsertFile(legacy)
        let previousIndexer = AppStateIndexerProxy.shared.indexer
        defer { AppStateIndexerProxy.shared.indexer = previousIndexer }

        let state = AppState(
            store: store,
            settings: settings,
            organizeRoot: organizedDirectory,
            startAutomatically: false
        )

        XCTAssertEqual(try store.file(id: fileID)?.indexSignature, settings.embeddingSpaceSignature)
        XCTAssertFalse(state.hasPendingAutomaticEmbeddingRebuild)
        XCTAssertFalse(state.isIndexConfigurationPromptPresented)

        settings.setVectorChunkWords(700)
        state.refreshIndexConfigurationState(allowAutomaticRebuild: false)
        XCTAssertFalse(state.hasPendingAutomaticEmbeddingRebuild)
        XCTAssertTrue(state.isIndexConfigurationPromptPresented)
        XCTAssertEqual(state.pendingAdvancedReindexCategories, [.chunking])

        state.reindexAll()
        XCTAssertEqual(state.reindexConfirmationStep, .selection)
        XCTAssertFalse(state.canAdvanceReindexConfirmation)
        XCTAssertTrue(state.selectedAdvancedReindexCategories.isEmpty)
        state.setAdvancedReindexCategory(.chunking, selected: true)
        XCTAssertTrue(state.canAdvanceReindexConfirmation)
        state.advanceReindexConfirmation()
        XCTAssertEqual(state.reindexConfirmationStep, .finalConfirmation)
        state.returnToReindexSelection()
        XCTAssertEqual(state.reindexConfirmationStep, .selection)
        state.cancelReindexConfirmation()
        XCTAssertNil(state.reindexConfirmationStep)

        state.skipPendingConfigurationChange()
        XCTAssertFalse(state.isIndexConfigurationPromptPresented)
        state.refreshIndexConfigurationState(allowAutomaticRebuild: false)
        XCTAssertFalse(state.isIndexConfigurationPromptPresented)

        var newFile = makeFile(in: organizedDirectory, name: "new-file.txt")
        newFile.indexedAt = nil
        _ = try store.upsertFile(newFile)
        state.reindexAll()
        XCTAssertTrue(state.isEmbeddingChangeReindexSelected)
        XCTAssertTrue(state.isUnindexedFilesReindexSelected)
        XCTAssertEqual(state.unindexedFileCount, 1)
        XCTAssertTrue(state.canAdvanceReindexConfirmation)
        state.setUnindexedFilesReindexSelected(false)
        XCTAssertFalse(state.canAdvanceReindexConfirmation)
        state.cancelReindexConfirmation()

        settings.setOllamaEmbeddingModel("replacement-embedding-model")
        state.refreshIndexConfigurationState(allowAutomaticRebuild: false)
        XCTAssertTrue(state.hasPendingAutomaticEmbeddingRebuild)
        XCTAssertFalse(state.isIndexConfigurationPromptPresented)

        state.reindexAll()
        XCTAssertTrue(state.hasDefaultEmbeddingRebuildSelection)
        XCTAssertTrue(state.canAdvanceReindexConfirmation)
        XCTAssertTrue(state.selectedAdvancedReindexCategories.isEmpty)
        state.cancelReindexConfirmation()
    }

    func testLibraryFileQuerySortsByModifiedDateAndSizeInBothDirections() {
        let olderLarge = makeLibraryRecord(
            name: "older-large.pdf",
            size: 900,
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        let newerSmall = makeLibraryRecord(
            name: "newer-small.pdf",
            size: 100,
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(
            LibraryFileQuery.sorted(
                [olderLarge, newerSmall],
                field: .modified,
                direction: .descending
            ).map(\.name),
            ["newer-small.pdf", "older-large.pdf"]
        )
        XCTAssertEqual(
            LibraryFileQuery.sorted(
                [olderLarge, newerSmall],
                field: .modified,
                direction: .ascending
            ).map(\.name),
            ["older-large.pdf", "newer-small.pdf"]
        )
        XCTAssertEqual(
            LibraryFileQuery.sorted(
                [olderLarge, newerSmall],
                field: .size,
                direction: .descending
            ).map(\.name),
            ["older-large.pdf", "newer-small.pdf"]
        )
    }

    func testLibraryFileQuerySortsSearchResultsByConfidenceBeforeScore() {
        let higherScore = makeLibraryRecord(
            name: "higher-score.pdf",
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        let higherConfidence = makeLibraryRecord(
            name: "higher-confidence.pdf",
            modifiedAt: Date(timeIntervalSince1970: 200)
        )
        let matches = [
            higherScore.path: LibrarySearchResult(
                file: higherScore,
                score: 0.99,
                confidence: 0.65,
                matchKind: .title,
                snippet: nil,
                sectionPath: [],
                pageStart: nil,
                pageEnd: nil
            ),
            higherConfidence.path: LibrarySearchResult(
                file: higherConfidence,
                score: 0.50,
                confidence: 0.95,
                matchKind: .content,
                snippet: nil,
                sectionPath: [],
                pageStart: nil,
                pageEnd: nil
            ),
        ]

        XCTAssertEqual(
            LibraryFileQuery.sortedByConfidence(
                [higherScore, higherConfidence],
                matchesByPath: matches
            ).map(\.name),
            ["higher-confidence.pdf", "higher-score.pdf"]
        )
    }

    func testLibraryFileQueryFiltersCreationAndModificationDatesIndependently() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let july15 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 10))!
        let july16 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 10))!
        let createdYesterday = makeLibraryRecord(
            name: "created-yesterday.pdf",
            modifiedAt: july16
        )
        let modifiedYesterday = makeLibraryRecord(
            name: "modified-yesterday.pdf",
            modifiedAt: july15
        )
        let files = [createdYesterday, modifiedYesterday]
        let creationDates = [
            createdYesterday.path: july15,
            modifiedYesterday.path: july16
        ]

        XCTAssertEqual(
            LibraryFileQuery.filtered(
                files,
                in: LibraryDateRange(start: july15, end: july15),
                dateField: .created,
                creationDates: creationDates,
                calendar: calendar
            ).map(\.name),
            ["created-yesterday.pdf"]
        )
        XCTAssertEqual(
            LibraryFileQuery.filtered(
                files,
                in: LibraryDateRange(start: july15, end: july15),
                dateField: .modified,
                creationDates: creationDates,
                calendar: calendar
            ).map(\.name),
            ["modified-yesterday.pdf"]
        )
    }

    func testLibraryFileQueryDateRangeIncludesBothBoundaryDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let july15 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 1))!
        let july16 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 23))!
        let july17 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 1))!
        let files = [
            makeLibraryRecord(name: "range-start.pdf", modifiedAt: july15),
            makeLibraryRecord(name: "range-end.pdf", modifiedAt: july16),
            makeLibraryRecord(name: "outside.pdf", modifiedAt: july17),
        ]

        let results = LibraryFileQuery.filtered(
            files,
            in: LibraryDateRange(start: july16, end: july15),
            dateField: .modified,
            creationDates: [:],
            calendar: calendar
        )

        XCTAssertEqual(Set(results.map(\.name)), ["range-start.pdf", "range-end.pdf"])
    }

    private func makeLibraryRecord(
        name: String,
        size: Int64 = 100,
        modifiedAt: Date
    ) -> FileRecord {
        FileRecord(
            id: nil,
            path: "/tmp/\(name)",
            name: name,
            ext: "pdf",
            size: size,
            mtime: modifiedAt,
            category: FileCategory.documents.rawValue,
            sourceDir: "/tmp",
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        )
    }

    private func makeFile(in directory: URL, name: String) -> FileRecord {
        let url = directory.appendingPathComponent(name)
        try? Data(name.utf8).write(to: url)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = Int64((attributes?[.size] as? NSNumber)?.intValue ?? 0)
        let modificationDate = (attributes?[.modificationDate] as? Date) ?? Date()
        return FileRecord(
            id: nil,
            path: url.path,
            name: name,
            ext: url.pathExtension,
            size: size,
            mtime: modificationDate,
            category: FileCategory.documents.rawValue,
            sourceDir: directory.path,
            indexedAt: Date(),
            contentHash: nil,
            title: nil,
            contentText: nil
        )
    }
}
