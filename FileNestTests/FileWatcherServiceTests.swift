import XCTest
@testable import FileNest

final class FileWatcherServiceTests: XCTestCase {
    private final class CountingEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name = "counting"
        let dimension = 2
        private let result: [Float]
        private let queue = DispatchQueue(label: "filenest.tests.watcher-embedder")
        private var calls = 0

        init(result: [Float]) { self.result = result }

        var callCount: Int { queue.sync { calls } }

        func embed(_ text: String) async throws -> [Float] {
            queue.sync { calls += 1 }
            return result
        }
    }

    private final class GateEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name = "gate"
        let dimension = 2
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        var isWaiting: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation != nil
        }

        func embed(_ text: String) async throws -> [Float] {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
            return [1, 0]
        }

        func release() {
            lock.lock()
            released = true
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    private final class DirectoryStatusRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedStatuses: [WatchDirectoryStatus] = []

        var statuses: [WatchDirectoryStatus] {
            lock.lock()
            defer { lock.unlock() }
            return storedStatuses
        }

        func record(_ statuses: [WatchDirectoryStatus]) {
            lock.lock()
            storedStatuses = statuses
            lock.unlock()
        }
    }

    private var temporaryDirectory: URL!
    private var sourceDirectory: URL!
    private var organizedDirectory: URL!
    private var store: SQLiteStore!
    private var settings: AppSettings!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        sourceDirectory = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        organizedDirectory = temporaryDirectory.appendingPathComponent("organized", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        settings = AppSettings(store: store)
        settings.setWatchDirs([sourceDirectory.path])
        settings.setEnabledExtensions(["txt"])
        settings.setExcludeHidden(true)
    }

    override func tearDownWithError() throws {
        settings = nil
        store = nil
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testRepeatedScansIndexStableFileOnlyOnce() async throws {
        _ = try createFile(named: "notes.txt")
        let embedder = CountingEmbedder(result: [1, 0])
        settings.setAutoOrganize(false)
        let watcher = makeWatcher(embedder: embedder)
        watcher.start()
        defer { watcher.stop() }
        XCTAssertTrue(watcher.isRunning)

        watcher.scanNow()
        let indexed = await waitUntil {
            guard let records = try? self.store.allFiles() else { return false }
            return records.first?.indexedAt != nil
        }
        XCTAssertTrue(indexed)
        let completedCallCount = embedder.callCount

        watcher.scanNow()
        watcher.scanNow()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(completedCallCount, 2)
        XCTAssertEqual(embedder.callCount, completedCallCount)
        XCTAssertEqual(try store.allFiles().count, 1)
    }

    func testOfficeLockFilesAreIgnoredBeforeIndexing() async throws {
        let lockFile = try createFile(named: "~$notes.txt")
        let embedder = CountingEmbedder(result: [1, 0])
        settings.setAutoOrganize(false)
        let watcher = makeWatcher(embedder: embedder, pollingInterval: 0.05)
        watcher.start()
        defer { watcher.stop() }

        watcher.scanNow()
        try await Task.sleep(nanoseconds: 160_000_000)

        XCTAssertTrue(FileManager.default.fileExists(atPath: lockFile.path))
        XCTAssertNil(try store.file(path: lockFile.path))
        XCTAssertEqual(embedder.callCount, 0)
    }

    func testTransientFilePolicyCoversEditorAndDownloadIntermediateStates() {
        ["~$contract.docx", "._resource.pdf", "draft.txt~", "movie.part", "archive.crdownload",
         "notes.swp", "report.tmp", ".DS_Store"].forEach {
            XCTAssertTrue(FileEligibilityPolicy.shouldIgnoreFile(named: $0), $0)
        }
        ["contract.docx", "report.final.pdf", "notes.txt"].forEach {
            XCTAssertFalse(FileEligibilityPolicy.shouldIgnoreFile(named: $0), $0)
        }
    }

    func testFailedIndexingIsRetriedOnLaterScans() async throws {
        let file = try createFile(named: "retry.txt")
        let embedder = CountingEmbedder(result: [])
        settings.setAutoOrganize(false)
        let watcher = makeWatcher(embedder: embedder)
        watcher.start()
        defer { watcher.stop() }
        XCTAssertTrue(watcher.isRunning)

        watcher.scanNow()
        let firstAttemptFinished = await waitUntil { embedder.callCount >= 2 }
        XCTAssertTrue(firstAttemptFinished)

        for _ in 0..<10 where embedder.callCount < 4 {
            try await Task.sleep(nanoseconds: 30_000_000)
            watcher.scanNow()
        }

        XCTAssertGreaterThanOrEqual(embedder.callCount, 4)
        XCTAssertNil(try store.file(path: file.path)?.indexedAt)
    }

    func testStoppingDuringIndexPreventsLaterFileMove() async throws {
        let file = try createFile(named: "delayed.txt")
        let embedder = GateEmbedder()
        settings.setAutoOrganize(true)
        let watcher = makeWatcher(embedder: embedder)
        watcher.start()
        XCTAssertTrue(watcher.isRunning)
        watcher.scanNow()

        let didStartIndexing = await waitUntil { embedder.isWaiting }
        XCTAssertTrue(didStartIndexing)
        watcher.stop()
        embedder.release()

        let didFinishIndexing = await waitUntil {
            guard let records = try? self.store.allFiles() else { return false }
            return records.first?.indexedAt != nil
        }
        XCTAssertTrue(didFinishIndexing)
        try await Task.sleep(nanoseconds: 100_000_000)

        let destination = organizedDirectory
            .appendingPathComponent(FileCategory.documents.folderName, isDirectory: true)
            .appendingPathComponent("Uncategorized", isDirectory: true)
            .appendingPathComponent(file.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDeletedWatchDirectoryIsDetachedAndReattachedWhenRecreated() async throws {
        settings.setAutoOrganize(false)
        let watcher = makeWatcher(
            embedder: CountingEmbedder(result: [1, 0]),
            pollingInterval: 0.05
        )
        watcher.start()
        defer { watcher.stop() }
        XCTAssertEqual(watcher.watchedDirectoryCount, 1)

        try FileManager.default.removeItem(at: sourceDirectory)
        let detached = await waitUntil { watcher.watchedDirectoryCount == 0 }
        XCTAssertTrue(detached)

        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let reattached = await waitUntil { watcher.watchedDirectoryCount == 1 }
        XCTAssertTrue(reattached)
        _ = try createFile(named: "recreated.txt")

        let indexed = await waitUntil {
            guard let records = try? self.store.allFiles() else { return false }
            return records.first?.name == "recreated.txt" && records.first?.indexedAt != nil
        }
        XCTAssertTrue(indexed)
    }

    func testRestartProcessesOnlyFilesAddedAfterStop() async throws {
        let embedder = CountingEmbedder(result: [1, 0])
        settings.setAutoOrganize(false)
        _ = try createFile(named: "before-stop.txt")
        let watcher = makeWatcher(embedder: embedder)

        watcher.start()
        watcher.scanNow()
        let firstIndexed = await waitUntil { embedder.callCount == 2 }
        XCTAssertTrue(firstIndexed)
        watcher.stop()
        XCTAssertFalse(watcher.isRunning)
        XCTAssertEqual(watcher.watchedDirectoryCount, 0)

        _ = try createFile(named: "after-restart.txt")
        watcher.start()
        defer { watcher.stop() }
        watcher.scanNow()
        let bothIndexed = await waitUntil {
            guard let records = try? self.store.allFiles() else { return false }
            return records.count == 2 && records.allSatisfy { $0.indexedAt != nil }
        }

        XCTAssertTrue(bothIndexed)
        XCTAssertEqual(embedder.callCount, 4)
    }

    func testRestartReindexesOfflineOverwriteWithPreservedSizeAndModificationDate() async throws {
        let file = try createFile(named: "offline-overwrite.txt", content: "hello world")
        let embedder = CountingEmbedder(result: [1, 0])
        settings.setAutoOrganize(false)
        let watcher = makeWatcher(embedder: embedder)

        watcher.start()
        watcher.scanNow()
        let firstIndexed = await waitUntil {
            (try? self.store.allFiles().first { $0.name == file.lastPathComponent })?.indexedAt != nil
        }
        XCTAssertTrue(firstIndexed)
        let original = try XCTUnwrap(store.allFiles().first { $0.name == file.lastPathComponent })
        let fileID = try XCTUnwrap(original.id)
        let originalHash = try XCTUnwrap(original.contentHash)
        XCTAssertEqual(embedder.callCount, 2)
        watcher.stop()

        try Data("HELLO WORLD".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: original.mtime],
            ofItemAtPath: file.path
        )

        watcher.start()
        defer { watcher.stop() }
        watcher.scanNow()
        let reindexed = await waitUntil {
            guard let updated = try? self.store.file(id: fileID) else { return false }
            return updated.indexedAt != nil &&
                updated.contentHash != originalHash &&
                updated.contentText?.contains("HELLO WORLD") == true
        }

        XCTAssertTrue(reindexed)
        XCTAssertEqual(embedder.callCount, 4)
    }

    func testRestartRemovesFileDeletedWhileWatcherWasStopped() async throws {
        let file = try createFile(named: "deleted-offline.txt")
        let embedder = CountingEmbedder(result: [1, 0])
        settings.setAutoOrganize(false)
        let watcher = makeWatcher(embedder: embedder)

        watcher.start()
        watcher.scanNow()
        let firstIndexed = await waitUntil {
            (try? self.store.allFiles().first { $0.name == file.lastPathComponent })?.indexedAt != nil
        }
        XCTAssertTrue(firstIndexed)
        watcher.stop()

        try FileManager.default.removeItem(at: file)
        watcher.start()
        defer { watcher.stop() }
        watcher.scanNow()

        let removed = await waitUntil {
            (try? self.store.allFiles().contains { $0.name == file.lastPathComponent }) == false
        }
        XCTAssertTrue(removed)
    }

    func testPreservedExistingEntriesStayUntouchedWhileNewFilesAreIndexed() async throws {
        let existing = try createFile(named: "existing.txt")
        let embedder = CountingEmbedder(result: [1, 0])
        settings.setAutoOrganize(false)
        let watcher = makeWatcher(embedder: embedder, pollingInterval: 10)

        watcher.preserveExistingEntries(in: [sourceDirectory.path])
        watcher.start()
        defer { watcher.stop() }
        watcher.scanNow()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(try store.file(path: existing.path))
        XCTAssertEqual(embedder.callCount, 0)

        let addedLater = try createFile(named: "added-later.txt")
        watcher.scanNow()
        let indexedNewFile = await waitUntil {
            (try? self.store.allFiles())?.contains {
                $0.name == addedLater.lastPathComponent && $0.indexedAt != nil
            } == true
        }

        XCTAssertTrue(indexedNewFile)
        XCTAssertNil(try store.file(path: existing.path))
        XCTAssertEqual(embedder.callCount, 2)
    }

    func testUnavailableDirectoryDefersBaselineUntilAccessReturns() async throws {
        _ = try createFile(named: "originally-present.txt")
        let embedder = CountingEmbedder(result: [1, 0])
        settings.setAutoOrganize(false)
        let watcher = makeWatcher(embedder: embedder, pollingInterval: 10)

        watcher.preserveExistingEntries(in: [sourceDirectory.path])
        let storedEntryPath = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: sourceDirectory,
                includingPropertiesForKeys: nil
            ).first?.path
        )
        XCTAssertTrue(store.isWatchDirectoryBaselineEntry(
            directoryPath: sourceDirectory.path,
            entryPath: storedEntryPath
        ))

        try FileManager.default.removeItem(at: sourceDirectory)
        watcher.preserveExistingEntries(in: [sourceDirectory.path])
        XCTAssertTrue(store.isWatchDirectoryBaselineEntry(
            directoryPath: sourceDirectory.path,
            entryPath: storedEntryPath
        ))

        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let presentWhenAccessReturns = try createFile(named: "present-when-access-returns.txt")
        watcher.start()
        defer { watcher.stop() }
        watcher.scanNow()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(try store.file(path: presentWhenAccessReturns.path))
        XCTAssertEqual(embedder.callCount, 0)

        let addedAfterRecovery = try createFile(named: "added-after-recovery.txt")
        watcher.scanNow()
        let indexedNewFile = await waitUntil {
            (try? self.store.file(path: addedAfterRecovery.path))?.indexedAt != nil
        }
        XCTAssertTrue(indexedNewFile)
        XCTAssertEqual(embedder.callCount, 2)
    }

    func testDirectoryStatusReportsMissingThenWatchingAfterFolderReturns() async throws {
        try FileManager.default.removeItem(at: sourceDirectory)
        let recorder = DirectoryStatusRecorder()
        let watcher = makeWatcher(
            embedder: CountingEmbedder(result: [1, 0]),
            pollingInterval: 0.05
        )
        watcher.onDirectoryStatusChange = { recorder.record($0) }
        watcher.start()
        defer { watcher.stop() }

        let reportedMissing = await waitUntil {
            recorder.statuses.first?.accessState == .missing &&
                recorder.statuses.first?.isWatching == false
        }
        XCTAssertTrue(reportedMissing)

        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let reportedWatching = await waitUntil {
            recorder.statuses.first?.accessState == .accessible &&
                recorder.statuses.first?.isWatching == true
        }
        XCTAssertTrue(reportedWatching)
    }

    func testManualOrganizationClearsPreservedBaselineAndForcesExistingProcessing() async throws {
        _ = try createFile(named: "preserved.txt")
        let embedder = CountingEmbedder(result: [1, 0])
        settings.setAutoOrganize(false)
        let watcher = makeWatcher(embedder: embedder, pollingInterval: 10)

        watcher.preserveExistingEntries(in: [sourceDirectory.path])
        watcher.start()
        defer { watcher.stop() }
        watcher.scanNow()
        XCTAssertTrue(try store.allFiles().isEmpty)

        watcher.organizeExistingEntries(in: [sourceDirectory.path])
        watcher.scanNow()
        let didProcessExistingFile = await waitUntil {
            guard let records = try? self.store.allFiles() else { return false }
            return records.count == 1 && records[0].indexedAt != nil
        }

        XCTAssertTrue(didProcessExistingFile)
        XCTAssertEqual(embedder.callCount, 2)
    }

    func testRunningWatcherReconcilesAddedAndRemovedDirectories() async throws {
        let secondDirectory = temporaryDirectory.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let embedder = CountingEmbedder(result: [1, 0])
        settings.setAutoOrganize(false)
        let watcher = makeWatcher(embedder: embedder, pollingInterval: 0.05)
        watcher.start()
        defer { watcher.stop() }
        XCTAssertEqual(watcher.watchedDirectoryCount, 1)

        settings.setWatchDirs([sourceDirectory.path, secondDirectory.path])
        let attachedSecondDirectory = await waitUntil { watcher.watchedDirectoryCount == 2 }
        XCTAssertTrue(attachedSecondDirectory)
        _ = try createFile(named: "first.txt", in: sourceDirectory)
        _ = try createFile(named: "second.txt", in: secondDirectory)

        let indexedBothDirectories = await waitUntil {
            guard let records = try? self.store.allFiles() else { return false }
            return records.count == 2 && records.allSatisfy { $0.indexedAt != nil }
        }
        XCTAssertTrue(indexedBothDirectories)

        settings.setWatchDirs([secondDirectory.path])
        let detachedFirstDirectory = await waitUntil { watcher.watchedDirectoryCount == 1 }
        XCTAssertTrue(detachedFirstDirectory)
        let ignored = try createFile(named: "ignored.txt", in: sourceDirectory)
        _ = try createFile(named: "active.txt", in: secondDirectory)

        let activeFileIndexed = await waitUntil {
            guard let records = try? self.store.allFiles() else { return false }
            return records.contains { $0.name == "active.txt" && $0.indexedAt != nil }
        }
        XCTAssertTrue(activeFileIndexed)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertNil(try store.file(path: ignored.path))
        XCTAssertEqual(try store.allFiles().count, 3)
        XCTAssertEqual(embedder.callCount, 6)
    }

    func testRapidWatchDirectoryChangesUseFinalConfiguration() async throws {
        let secondDirectory = temporaryDirectory.appendingPathComponent("second", isDirectory: true)
        let finalDirectory = temporaryDirectory.appendingPathComponent("final", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
        settings.setAutoOrganize(false)
        let watcher = makeWatcher(
            embedder: CountingEmbedder(result: [1, 0]),
            pollingInterval: 0.05
        )
        watcher.start()
        defer { watcher.stop() }

        settings.setWatchDirs([secondDirectory.path])
        settings.setWatchDirs([sourceDirectory.path, secondDirectory.path])
        settings.setWatchDirs([finalDirectory.path])
        watcher.scanNow()
        XCTAssertEqual(watcher.watchedDirectoryCount, 1)

        let ignoredSource = try createFile(named: "ignored-source.txt", in: sourceDirectory)
        let ignoredSecond = try createFile(named: "ignored-second.txt", in: secondDirectory)
        _ = try createFile(named: "accepted.txt", in: finalDirectory)
        let finalFileIndexed = await waitUntil {
            guard let records = try? self.store.allFiles() else { return false }
            return records.contains { $0.name == "accepted.txt" && $0.indexedAt != nil }
        }
        XCTAssertTrue(finalFileIndexed)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertNil(try store.file(path: ignoredSource.path))
        XCTAssertNil(try store.file(path: ignoredSecond.path))
        XCTAssertEqual(try store.allFiles().map(\.name), ["accepted.txt"])
    }

    func testChangingDirectoryIsNotIndexedUntilTreeStaysStable() async throws {
        settings.setAutoOrganize(false)
        let repository = sourceDirectory.appendingPathComponent("cloning-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let readme = repository.appendingPathComponent("README.md")
        try Data("first clone state".utf8).write(to: readme)
        let watcher = makeWatcher(
            embedder: CountingEmbedder(result: [1, 0]),
            pollingInterval: 10,
            directoryMinimumStableDuration: 0.12
        )
        watcher.start()
        defer { watcher.stop() }
        XCTAssertTrue(watcher.isRunning)

        watcher.scanNow()
        try Data("clone is still receiving objects".utf8).write(to: readme)
        watcher.scanNow()
        try await Task.sleep(nanoseconds: 80_000_000)
        watcher.scanNow()
        XCTAssertFalse(try store.allFiles().contains { $0.name == "cloning-repo" })

        try await Task.sleep(nanoseconds: 70_000_000)
        watcher.scanNow()
        let indexed = await waitUntil {
            guard let records = try? self.store.allFiles() else { return false }
            return records.contains { $0.name == "cloning-repo" && $0.indexedAt != nil }
        }
        XCTAssertTrue(indexed)
    }

    func testStableProjectDirectoryUsesReadmeAndMovesAsOneUnit() async throws {
        settings.setAutoOrganize(false)
        let repository = sourceDirectory.appendingPathComponent("sample-repo", isDirectory: true)
        let sources = repository.appendingPathComponent("Sources", isDirectory: true)
        let gitObjects = repository.appendingPathComponent(".git/objects", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitObjects, withIntermediateDirectories: true)
        try Data("# Sample Project\nA local semantic search engine.".utf8)
            .write(to: repository.appendingPathComponent("README.md"))
        try Data("print(\"hello\")".utf8)
            .write(to: sources.appendingPathComponent("main.swift"))

        let embedder = CountingEmbedder(result: [1, 0])
        let organizer = OrganizerService(
            store: store,
            settings: settings,
            organizeRoot: organizedDirectory,
            strategy: .hybrid,
            subfolderResolver: { _ in "Project Materials" }
        )
        let indexer = IndexerService(store: store, settings: settings, embedder: embedder)
        let watcher = FileWatcherService(
            store: store,
            organizer: organizer,
            indexer: indexer,
            settings: settings,
            minimumStableDuration: 0,
            directoryMinimumStableDuration: 0,
            pollingInterval: 10
        )
        watcher.start()
        defer { watcher.stop() }
        XCTAssertTrue(watcher.isRunning)
        watcher.scanNow()

        let indexed = await waitUntil {
            guard let records = try? self.store.allFiles() else { return false }
            return records.contains { $0.name == "sample-repo" && $0.indexedAt != nil }
        }
        XCTAssertTrue(indexed)
        let record = try XCTUnwrap(store.allFiles().first { $0.name == "sample-repo" })
        XCTAssertTrue(record.isDirectory)
        XCTAssertEqual(record.categoryEnum, .code)
        XCTAssertTrue(record.contentText?.contains("A local semantic search engine") == true)
        XCTAssertTrue(record.contentText?.contains("Reference file: README.md") == true)

        try await organizer.organizeUsingAI(fileId: try XCTUnwrap(record.id))

        let destination = organizedDirectory
            .appendingPathComponent(FileCategory.code.folderName, isDirectory: true)
            .appendingPathComponent("Project Materials", isDirectory: true)
            .appendingPathComponent("sample-repo", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("README.md").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("Sources/main.swift").path
        ))
        XCTAssertEqual(try store.file(id: record.id!)?.path, destination.path)

        let reconciled = organizer.reconcileManagedFiles()
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled.first?.name, "sample-repo")
        XCTAssertTrue(reconciled.first?.isDirectory == true)
        XCTAssertEqual(try store.allFiles().count, 1)
    }

    func testManualOrganizationProcessesOnlyEligibleNonBaselineEntries() async throws {
        settings.setAutoOrganize(false)
        let preserved = try createFile(named: "preserved.txt")
        let embedder = CountingEmbedder(result: [1, 0])
        let organizer = OrganizerService(
            store: store,
            settings: settings,
            organizeRoot: organizedDirectory,
            strategy: .hybrid,
            subfolderResolver: { _ in "Manual" }
        )
        let indexer = IndexerService(store: store, settings: settings, embedder: embedder)
        let watcher = FileWatcherService(
            store: store,
            organizer: organizer,
            indexer: indexer,
            settings: settings,
            minimumStableDuration: 0,
            directoryMinimumStableDuration: 0,
            pollingInterval: 10
        )
        watcher.preserveExistingEntries(in: [sourceDirectory.path])

        let candidate = try createFile(named: "candidate.txt")
        let transient = try createFile(named: "~$candidate.txt")
        let result = await watcher.organizePendingEntries(
            checkpoint: { true },
            progress: { _ in }
        )

        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transient.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: organizedDirectory
                .appendingPathComponent(FileCategory.documents.folderName, isDirectory: true)
                .appendingPathComponent("Manual", isDirectory: true)
                .appendingPathComponent(candidate.lastPathComponent)
                .path
        ))
    }

    func testOrganizationExecutionGateSupportsPauseResumeAndStop() async {
        let gate = OrganizationExecutionGate()
        await gate.pause()
        let resumedCheckpoint = Task { await gate.waitUntilRunnable() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await gate.resume()
        let didResume = await resumedCheckpoint.value
        XCTAssertTrue(didResume)

        await gate.pause()
        let stoppedCheckpoint = Task { await gate.waitUntilRunnable() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await gate.stop()
        let didContinueAfterStop = await stoppedCheckpoint.value
        XCTAssertFalse(didContinueAfterStop)
    }

    private func makeWatcher(embedder: EmbeddingProvider,
                             pollingInterval: TimeInterval = 10,
                             directoryMinimumStableDuration: TimeInterval = 0) -> FileWatcherService {
        let organizer = OrganizerService(
            store: store,
            settings: settings,
            organizeRoot: organizedDirectory,
            strategy: .hybrid
        )
        let indexer = IndexerService(store: store, settings: settings, embedder: embedder)
        return FileWatcherService(
            store: store,
            organizer: organizer,
            indexer: indexer,
            settings: settings,
            minimumStableDuration: 0,
            directoryMinimumStableDuration: directoryMinimumStableDuration,
            pollingInterval: pollingInterval
        )
    }

    private func createFile(
        named name: String,
        in directory: URL? = nil,
        content: String? = nil
    ) throws -> URL {
        let url = (directory ?? sourceDirectory).appendingPathComponent(name)
        try Data((content ?? name).utf8).write(to: url)
        return url
    }

    private func waitUntil(timeout: TimeInterval = 5,
                           condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
