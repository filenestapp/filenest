import XCTest
import Combine
@testable import FileNest

private final class ThreadObservationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var observedOffMainThread = false

    func recordCurrentThread() {
        guard !Thread.isMainThread else { return }
        lock.lock()
        observedOffMainThread = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedOffMainThread
    }
}

final class AppStateTests: XCTestCase {
    private struct ImmediateEmbeddingProvider: EmbeddingProvider {
        let name = "immediate-test-embedding"
        let dimension = 2

        func embed(_ text: String) async throws -> [Float] {
            [1, 0]
        }
    }

    func testSingleFileFeedbackDefaultsToAccurateForStrongTopTenResult() {
        XCTAssertEqual(
            RAGFeedbackPolicy.defaultRating(selectedFileRank: 10, confidence: 0.70),
            .accurate
        )
    }

    func testSingleFileFeedbackDefaultsToInaccurateBelowTopTen() {
        XCTAssertEqual(
            RAGFeedbackPolicy.defaultRating(selectedFileRank: 11, confidence: 0.95),
            .inaccurate
        )
    }

    func testSingleFileFeedbackDefaultsToInaccurateBelowConfidenceThreshold() {
        XCTAssertEqual(
            RAGFeedbackPolicy.defaultRating(selectedFileRank: 1, confidence: 0.699),
            .inaccurate
        )
        XCTAssertEqual(
            RAGFeedbackPolicy.defaultRating(selectedFileRank: nil, confidence: nil),
            .inaccurate
        )
    }

    @MainActor
    func testFileDetailsCanOpenForAFileWithoutInlinePreviewSupport() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        let state = AppState(
            store: store,
            settings: settings,
            organizeRoot: temporaryDirectory.appendingPathComponent("organized"),
            startAutomatically: false
        )
        let file = FileRecord(
            id: nil,
            path: temporaryDirectory.appendingPathComponent("archive.bin").path,
            name: "archive.bin",
            ext: "bin",
            size: 64,
            mtime: Date(),
            category: FileCategory.other.rawValue,
            sourceDir: temporaryDirectory.path,
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        )

        XCTAssertFalse(file.supportsPreview)
        state.presentFilePreview(file)
        XCTAssertEqual(state.previewedFile, file)
    }

    @MainActor
    func testReindexFileDetailsToggleByStoredFileIDAndCloseWithSettings() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        let state = AppState(
            store: store,
            settings: settings,
            organizeRoot: temporaryDirectory.appendingPathComponent("organized"),
            startAutomatically: false
        )
        let storedFileID = try store.upsertFile(FileRecord(
            id: nil,
            path: temporaryDirectory.appendingPathComponent("report.pdf").path,
            name: "report.pdf",
            ext: "pdf",
            size: 128,
            mtime: Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: temporaryDirectory.path,
            indexedAt: Date(),
            contentHash: nil,
            title: "Report",
            contentText: nil
        ))

        state.presentSettings(.reindexActivity)
        state.toggleFilePreview(fileID: storedFileID)
        XCTAssertEqual(state.previewedFile?.id, storedFileID)

        state.toggleFilePreview(fileID: storedFileID)
        XCTAssertNil(state.previewedFile)

        state.toggleFilePreview(fileID: storedFileID)
        state.dismissSettings()
        XCTAssertNil(state.previewedFile)
    }

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

    @MainActor
    func testChatExecutionPresentationIsIsolatedBySessionAndSurvivesSelectionChanges() throws {
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
        let sessionID: Int64 = 42
        let user = ChatMessage(
            id: -1,
            role: ChatRole.user.rawValue,
            content: "Find the latest invoice",
            ts: Date(),
            relatedFileIds: nil,
            sessionId: sessionID
        )
        let assistant = ChatMessage(
            id: -2,
            role: ChatRole.assistant.rawValue,
            content: "",
            ts: Date(),
            relatedFileIds: nil,
            sessionId: sessionID
        )

        state.beginChatExecution(
            sessionID: sessionID,
            userMessage: user,
            assistantMessage: assistant,
            progress: ChatProgress(phase: .queryingIndex)
        )
        state.newChat()

        XCTAssertNil(state.selectedChatSessionID)
        XCTAssertEqual(state.runningChatSessionIDs, [sessionID])
        XCTAssertEqual(
            state.presentedChatMessages(sessionID: sessionID, persistedMessages: []).map(\.content),
            ["Find the latest invoice", ""]
        )
        XCTAssertEqual(state.chatExecutionPresentations[sessionID]?.progress?.phase, .queryingIndex)

        state.appendChatExecutionDelta(sessionID: sessionID, delta: "Invoice found")
        XCTAssertEqual(
            state.presentedChatMessages(sessionID: sessionID, persistedMessages: []).last?.content,
            "Invoice found"
        )
        XCTAssertNil(state.chatExecutionPresentations[sessionID]?.progress)
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

    func testIndexingCompletionOutcomeDistinguishesPartialAndTaskFailure() {
        XCTAssertEqual(
            IndexingCompletionOutcome(
                stopped: false,
                operationSucceeded: true,
                successfulFiles: 10,
                failedFiles: 0
            ),
            .completed
        )
        XCTAssertEqual(
            IndexingCompletionOutcome(
                stopped: false,
                operationSucceeded: false,
                successfulFiles: 9,
                failedFiles: 1
            ),
            .completedWithErrors
        )
        XCTAssertEqual(
            IndexingCompletionOutcome(
                stopped: false,
                operationSucceeded: false,
                successfulFiles: 0,
                failedFiles: 0
            ),
            .failed
        )
        XCTAssertEqual(
            IndexingCompletionOutcome(
                stopped: true,
                operationSucceeded: false,
                successfulFiles: 5,
                failedFiles: 1
            ),
            .stopped
        )
    }

    @MainActor
    func testQuickSearchRequestTrimsInputAndCanBeConsumed() throws {
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

        state.requestLibrarySearch("  quarterly invoice  ")

        let request = try XCTUnwrap(state.librarySearchRequest)
        XCTAssertEqual(request.query, "quarterly invoice")

        state.consumeLibrarySearchRequest(request.id)
        XCTAssertNil(state.librarySearchRequest)
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

        let visibleMessage = try XCTUnwrap(state.saveUserQuestionForImmediateDisplay(
            "Summarize this file",
            sessionID: sessionID
        ))
        XCTAssertEqual(state.chatMessages.map(\.id), [visibleMessage.id])
        XCTAssertEqual(state.chatMessages.map(\.content), ["Summarize this file"])
        XCTAssertEqual(try store.chatMessages(sessionId: sessionID).map(\.content), ["Summarize this file"])

        state.newChat()
        state.refreshChatSessions()

        XCTAssertNil(state.selectedChatSessionID)
        XCTAssertTrue(state.chatMessages.isEmpty)
        XCTAssertEqual(try store.allChatSessions().map(\.id), [sessionID])
    }

    @MainActor
    func testInitialMainViewStartsWithAnUnpersistedBlankChatOnlyOnce() throws {
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

        let existingSessionID = try XCTUnwrap(state.persistChatForQuestion())
        state.refreshChatSessions(selecting: existingSessionID)
        XCTAssertEqual(state.selectedChatSessionID, existingSessionID)

        XCTAssertTrue(state.prepareInitialMainViewChatIfNeeded())
        XCTAssertNil(state.selectedChatSessionID)
        XCTAssertTrue(state.chatMessages.isEmpty)
        XCTAssertEqual(try store.allChatSessions().map(\.id), [existingSessionID])

        state.selectChat(existingSessionID)
        XCTAssertFalse(state.prepareInitialMainViewChatIfNeeded())
        XCTAssertEqual(state.selectedChatSessionID, existingSessionID)
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

    @MainActor
    func testRAGStageSelectionExpandsDependenciesAndSupportsFullReset() throws {
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

        state.reindexAll()
        state.setRAGReindexStage(.structuredChunking, selected: true)
        XCTAssertEqual(state.selectedRAGReindexStages, [
            .structuredChunking, .embeddings, .retrievalIndex,
        ])

        state.setRAGReindexStage(.embeddings, selected: false)
        XCTAssertEqual(state.selectedRAGReindexStages, [.retrievalIndex])

        state.setFullPipelineReindexSelected(true)
        XCTAssertTrue(state.isFullPipelineReindexSelected)
        XCTAssertTrue(state.selectedRAGReindexStages.contains(.parsingAndOCR))
        XCTAssertTrue(state.selectedRAGReindexStages.contains(.structuredChunking))
        XCTAssertTrue(state.selectedRAGReindexStages.contains(.embeddings))
        XCTAssertTrue(state.selectedRAGReindexStages.contains(.retrievalIndex))
        state.cancelReindexConfirmation()
    }

    @MainActor
    func testOrganizerActivityResolvesTheRealFileNameInsteadOfAPlaceholder() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        let organizedDirectory = temporaryDirectory.appendingPathComponent("organized", isDirectory: true)
        try FileManager.default.createDirectory(at: organizedDirectory, withIntermediateDirectories: true)
        let fileID = try store.upsertFile(makeFile(in: organizedDirectory, name: "quarterly-report.pdf"))
        let previousIndexer = AppStateIndexerProxy.shared.indexer
        defer { AppStateIndexerProxy.shared.indexer = previousIndexer }
        let state = AppState(
            store: store,
            settings: settings,
            organizeRoot: organizedDirectory,
            startAutomatically: false
        )

        state.organizer.onAutomaticOrganizationUpdate?(fileID, .completed, nil)
        await Task.yield()

        XCTAssertEqual(state.automaticFileProcessingItems.first?.fileName, "quarterly-report.pdf")
        XCTAssertEqual(state.automaticFileProcessingItems.first?.stage, .completed)
    }

    @MainActor
    func testDrawerFileReindexAppearsInProcessingQueue() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        let organizedDirectory = temporaryDirectory.appendingPathComponent("organized", isDirectory: true)
        try FileManager.default.createDirectory(at: organizedDirectory, withIntermediateDirectories: true)
        let fileID = try store.upsertFile(makeFile(in: organizedDirectory, name: "archive.bin"))
        let file = try XCTUnwrap(store.file(id: fileID))
        let indexer = IndexerService(
            store: store,
            settings: settings,
            embedder: ImmediateEmbeddingProvider()
        )
        let previousIndexer = AppStateIndexerProxy.shared.indexer
        defer { AppStateIndexerProxy.shared.indexer = previousIndexer }
        let state = AppState(
            store: store,
            settings: settings,
            organizeRoot: organizedDirectory,
            indexer: indexer,
            startAutomatically: false
        )

        let succeeded = await state.reindexFile(file)

        XCTAssertTrue(succeeded)
        let queueItem = try XCTUnwrap(state.automaticFileProcessingItems.first { $0.id == fileID })
        XCTAssertEqual(queueItem.fileName, "archive.bin")
        XCTAssertEqual(queueItem.stage, .completed)
        XCTAssertFalse(queueItem.isActive)
    }

    func testLibraryFileQuerySortsByAddedModifiedAndSizeInBothDirections() {
        let olderLarge = makeLibraryRecord(
            name: "older-large.pdf",
            size: 900,
            modifiedAt: Date(timeIntervalSince1970: 100),
            discoveredAt: Date(timeIntervalSince1970: 300)
        )
        let newerSmall = makeLibraryRecord(
            name: "newer-small.pdf",
            size: 100,
            modifiedAt: Date(timeIntervalSince1970: 200),
            discoveredAt: Date(timeIntervalSince1970: 250)
        )

        XCTAssertEqual(
            LibraryFileQuery.sorted(
                [olderLarge, newerSmall],
                field: .added,
                direction: .descending
            ).map(\.name),
            ["older-large.pdf", "newer-small.pdf"]
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

    @MainActor
    func testLibrarySearchContinuesAfterLibraryViewBecomesHidden() async throws {
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
        state.saveLibrarySearch(
            query: "cached invoice",
            results: [],
            recordHistory: false
        )

        state.setLibrarySearchViewVisible(true)
        state.startLibrarySearch(
            matching: "cached invoice",
            mode: .standard,
            recordHistory: false,
            debounceNanoseconds: 120_000_000
        )
        let searchID = try XCTUnwrap(state.librarySearchActivity?.id)
        XCTAssertTrue(state.librarySearchActivity?.isActive == true)

        state.setLibrarySearchViewVisible(false)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(state.librarySearchActivity?.id, searchID)
        XCTAssertFalse(state.librarySearchActivity?.isActive == true)
        XCTAssertFalse(state.librarySearchActivity?.wasCancelled == true)
        XCTAssertEqual(state.librarySearchActivity?.results, [])
        XCTAssertTrue(state.hasUnreadCompletedLibrarySearch)
    }

    @MainActor
    func testLibrarySearchPublishesStateOnlyFromMainThread() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        settings.llmChoice = AppSettings.LLMChoice.none.rawValue
        let state = AppState(
            store: store,
            settings: settings,
            organizeRoot: temporaryDirectory.appendingPathComponent("organized"),
            startAutomatically: false
        )
        let observation = ThreadObservationFlag()
        let cancellable = state.$librarySearchActivity
            .dropFirst()
            .sink { _ in observation.recordCurrentThread() }
        defer { cancellable.cancel() }

        state.startLibrarySearch(
            matching: "invoice",
            mode: .smart,
            recordHistory: false
        )
        for _ in 0..<100 where state.librarySearchActivity?.isActive == true {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(state.librarySearchActivity?.isActive == true)
        XCTAssertFalse(observation.value)
    }

    private func makeLibraryRecord(
        name: String,
        size: Int64 = 100,
        modifiedAt: Date,
        discoveredAt: Date? = nil
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
            contentText: nil,
            discoveredAt: discoveredAt
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
