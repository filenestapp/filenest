import XCTest
import GRDB
@testable import FileNest

final class AccelerateVectorStoreTests: XCTestCase {
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

    func testReplacePersistsAllChunksWithoutDuplicatesAcrossReload() async throws {
        let fileId = try insertFile(named: "notes.md")
        let vectorStore = AccelerateVectorStore(store: store)
        let chunks = [
            EmbeddingChunk(vector: [1, 0, 0], text: "first"),
            EmbeddingChunk(vector: [0, 1, 0], text: "second"),
        ]

        await vectorStore.replace(fileId: fileId, chunks: chunks, model: "test-model")
        XCTAssertEqual(vectorStore.count, 2)
        try assertPersistedChunks(fileId: fileId, expectedIndexes: [0, 1])

        await vectorStore.replace(fileId: fileId, chunks: chunks, model: "test-model")
        XCTAssertEqual(vectorStore.count, 2)
        try assertPersistedChunks(fileId: fileId, expectedIndexes: [0, 1])

        let reloaded = AccelerateVectorStore(store: store)
        await reloaded.loadAll()
        XCTAssertEqual(reloaded.count, 2)
        let hits = await reloaded.search([1, 0, 0], k: 1)
        XCTAssertEqual(hits.first?.fileId, fileId)
        XCTAssertEqual(hits.first?.score ?? 0, 1, accuracy: 0.0001)
    }

    func testReplacingOneFileKeepsOtherFilesInMemoryAndSQLite() async throws {
        let firstId = try insertFile(named: "first.md")
        let secondId = try insertFile(named: "second.md")
        let vectorStore = AccelerateVectorStore(store: store)

        await vectorStore.replace(
            fileId: firstId,
            chunks: [
                EmbeddingChunk(vector: [1, 0], text: "one"),
                EmbeddingChunk(vector: [0.8, 0.2], text: "two"),
            ],
            model: "test-model"
        )
        await vectorStore.replace(
            fileId: secondId,
            chunks: [EmbeddingChunk(vector: [0, 1], text: "other")],
            model: "test-model"
        )
        await vectorStore.replace(
            fileId: firstId,
            chunks: [EmbeddingChunk(vector: [1, 0], text: "replacement")],
            model: "test-model"
        )

        XCTAssertEqual(vectorStore.count, 2)
        try assertPersistedChunks(fileId: firstId, expectedIndexes: [0])
        try assertPersistedChunks(fileId: secondId, expectedIndexes: [0])
    }

    func testVectorEncodingRoundTripsAndRejectsMalformedData() {
        let vector: [Float] = [0, -1.25, 3.5, Float.leastNonzeroMagnitude]

        XCTAssertEqual(AccelerateVectorStore.decode(AccelerateVectorStore.encode(vector)), vector)
        XCTAssertEqual(AccelerateVectorStore.decode(Data([0, 1, 2])), [])
    }

    func testInvalidReplacementPreservesExistingChunks() async throws {
        let fileId = try insertFile(named: "notes.md")
        let vectorStore = AccelerateVectorStore(store: store)
        let initialReplaceSucceeded = await vectorStore.replace(
            fileId: fileId,
            chunks: [EmbeddingChunk(vector: [1, 0], text: "valid")],
            model: "test-model"
        )
        XCTAssertTrue(initialReplaceSucceeded)

        let invalidReplaceSucceeded = await vectorStore.replace(
            fileId: fileId,
            chunks: [EmbeddingChunk(vector: [.nan, 0], text: "invalid")],
            model: "test-model"
        )
        XCTAssertFalse(invalidReplaceSucceeded)

        XCTAssertEqual(vectorStore.count, 1)
        try assertPersistedChunks(fileId: fileId, expectedIndexes: [0])
        let hits = await vectorStore.search([1, 0], k: 1)
        XCTAssertEqual(hits.first?.fileId, fileId)
    }

    func testSearchRejectsInvalidLimitAndQuery() async throws {
        let fileId = try insertFile(named: "notes.md")
        let vectorStore = AccelerateVectorStore(store: store)
        let replaceSucceeded = await vectorStore.replace(
            fileId: fileId,
            chunks: [EmbeddingChunk(vector: [1, 0], text: "valid")],
            model: "test-model"
        )
        XCTAssertTrue(replaceSucceeded)

        let zeroLimitHits = await vectorStore.search([1, 0], k: 0)
        let negativeLimitHits = await vectorStore.search([1, 0], k: -1)
        let invalidQueryHits = await vectorStore.search([.infinity, 0], k: 1)
        XCTAssertEqual(zeroLimitHits.count, 0)
        XCTAssertEqual(negativeLimitHits.count, 0)
        XCTAssertEqual(invalidQueryHits.count, 0)
    }

    func testSearchReturnsEachFileOnceUsingItsHighestChunkScore() async throws {
        let firstId = try insertFile(named: "first.md")
        let secondId = try insertFile(named: "second.md")
        let vectorStore = AccelerateVectorStore(store: store)
        _ = await vectorStore.replace(
            fileId: firstId,
            chunks: [
                EmbeddingChunk(vector: [1, 0], text: "best"),
                EmbeddingChunk(vector: [0.8, 0.2], text: "also relevant"),
            ],
            model: "test-model"
        )
        _ = await vectorStore.replace(
            fileId: secondId,
            chunks: [EmbeddingChunk(vector: [0, 1], text: "other")],
            model: "test-model"
        )

        let hits = await vectorStore.search([1, 0], k: 5)

        XCTAssertEqual(hits.map(\.fileId), [firstId, secondId])
        XCTAssertEqual(hits.first?.score ?? 0, 1, accuracy: 0.0001)
    }

    private func insertFile(named name: String) throws -> Int64 {
        try store.upsertFile(FileRecord(
            id: nil,
            path: temporaryDirectory.appendingPathComponent(name).path,
            name: name,
            ext: "md",
            size: 1,
            mtime: Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: temporaryDirectory.path,
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        ))
    }

    private func assertPersistedChunks(fileId: Int64, expectedIndexes: [Int]) throws {
        let rows = try store.dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT chunk_idx, model FROM embeddings WHERE file_id = ? ORDER BY chunk_idx",
                arguments: [fileId]
            )
        }
        XCTAssertEqual(rows.map { $0["chunk_idx"] as Int }, expectedIndexes)
        XCTAssertTrue(rows.allSatisfy { ($0["model"] as String) == "test-model" })
    }
}
