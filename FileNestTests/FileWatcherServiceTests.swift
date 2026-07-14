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

    private func makeWatcher(embedder: EmbeddingProvider,
                             pollingInterval: TimeInterval = 10) -> FileWatcherService {
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
            pollingInterval: pollingInterval
        )
    }

    private func createFile(named name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? sourceDirectory).appendingPathComponent(name)
        try Data("hello world".utf8).write(to: url)
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
