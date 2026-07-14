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

    private func makeWatcher(embedder: EmbeddingProvider) -> FileWatcherService {
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
            minimumStableDuration: 0
        )
    }

    private func createFile(named name: String) throws -> URL {
        let url = sourceDirectory.appendingPathComponent(name)
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
