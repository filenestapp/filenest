import XCTest
@testable import FileNest

final class IndexerServiceTests: XCTestCase {
    private final class StubEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name = "stub"
        let dimension = 2
        private let queue = DispatchQueue(label: "filenest.tests.stub-embedder")
        private let result: [Float]
        private var calls = 0

        init(result: [Float]) {
            self.result = result
        }

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
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
        store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testSuccessfulIndexSetsHashAndSkipsUnchangedContent() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("notes.txt")
        try Data("hello world".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let embedder = StubEmbedder(result: [1, 0])
        let indexer = IndexerService(store: store, settings: .shared, embedder: embedder)

        let didIndex = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(didIndex)

        let indexed = try XCTUnwrap(store.file(id: fileId))
        XCTAssertNotNil(indexed.indexedAt)
        XCTAssertEqual(indexed.contentHash,
                       "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        XCTAssertEqual(indexer.vectorStore.count, 2)
        XCTAssertEqual(embedder.callCount, 2)

        let didSkipUnchanged = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(didSkipUnchanged)
        XCTAssertEqual(embedder.callCount, 2)
        XCTAssertEqual(indexer.vectorStore.count, 2)

        try Data("changed content".utf8).write(to: fileURL)
        let didReindex = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(didReindex)
        XCTAssertEqual(embedder.callCount, 4)
        XCTAssertEqual(indexer.vectorStore.count, 2)
        let reindexed = try XCTUnwrap(store.file(id: fileId))
        XCTAssertNotEqual(reindexed.contentHash, indexed.contentHash)
        XCTAssertNotNil(reindexed.indexedAt)
    }

    func testFailedEmbeddingDoesNotMarkFileIndexed() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("notes.txt")
        try Data("hello world".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let indexer = IndexerService(
            store: store,
            settings: .shared,
            embedder: StubEmbedder(result: [])
        )

        let didIndex = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertFalse(didIndex)

        let record = try XCTUnwrap(store.file(id: fileId))
        XCTAssertNil(record.indexedAt)
        XCTAssertNotNil(record.contentHash)
        XCTAssertEqual(indexer.vectorStore.count, 0)
    }

    func testFileChangedDuringEmbeddingIsRejectedAndLatestContentCanRetry() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("changing.txt")
        try Data("old content".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let embedder = GateEmbedder()
        defer { embedder.release() }
        let indexer = IndexerService(store: store, settings: .shared, embedder: embedder)

        let indexingTask = Task {
            await indexer.indexFile(id: fileId, overridePath: fileURL)
        }
        let didStartEmbedding = await waitUntil { embedder.isWaiting }
        XCTAssertTrue(didStartEmbedding)
        try Data("latest content".utf8).write(to: fileURL)
        embedder.release()

        let acceptedStaleContent = await indexingTask.value
        XCTAssertFalse(acceptedStaleContent)
        XCTAssertNil(try store.file(id: fileId)?.indexedAt)
        XCTAssertEqual(indexer.vectorStore.count, 0)

        let didRetryLatestContent = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(didRetryLatestContent)
        let latest = try XCTUnwrap(store.file(id: fileId))
        XCTAssertEqual(latest.contentText, "latest content")
        XCTAssertEqual(latest.contentHash, try FileContentHasher.sha256(of: fileURL))
        XCTAssertNotNil(latest.indexedAt)
        XCTAssertEqual(indexer.vectorStore.count, 2)
    }

    func testChunkReturnsNoSegmentsForBlankOrInvalidInput() {
        XCTAssertEqual(IndexerService.chunk(text: "", maxWords: 200, overlap: 30), [])
        XCTAssertEqual(IndexerService.chunk(text: "  \n\t", maxWords: 200, overlap: 30), [])
        XCTAssertEqual(IndexerService.chunk(text: "content", maxWords: 0, overlap: 0), [])
    }

    func testChunkUsesOverlappingWordWindows() {
        let chunks = IndexerService.chunk(
            text: "one two three four five six seven",
            maxWords: 3,
            overlap: 1
        )

        XCTAssertEqual(chunks, ["one two three", "three four five", "five six seven"])
    }

    func testChunkSplitsLongTextWithoutWhitespaceByCharacters() {
        let text = String(repeating: "文", count: 1_000)

        let chunks = IndexerService.chunk(text: text, maxWords: 200, overlap: 30)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 800)
        XCTAssertEqual(String(chunks[0].suffix(120)), String(chunks[1].prefix(120)))
        XCTAssertEqual(chunks[1].count, 320)
    }

    private func insertFile(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try store.upsertFile(FileRecord(
            id: nil,
            path: url.path,
            name: url.lastPathComponent,
            ext: url.pathExtension,
            size: Int64((attributes[.size] as? NSNumber)?.intValue ?? 0),
            mtime: (attributes[.modificationDate] as? Date) ?? Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: temporaryDirectory.path,
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        ))
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
