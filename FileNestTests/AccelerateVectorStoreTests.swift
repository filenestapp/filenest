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

    func testSQLiteVecSearchPreservesStructuredMetadataAndFindsNeighbors() async throws {
        let fileId = try insertFile(named: "manual.pdf")
        let vectorStore = AccelerateVectorStore(store: store)
        let replaced = await vectorStore.replace(
            fileId: fileId,
            chunks: [
                EmbeddingChunk(
                    vector: [1, 0, 0],
                    text: "Installation overview",
                    sectionPath: ["Guide", "Installation"],
                    pageStart: 4,
                    pageEnd: 4,
                    kind: .title
                ),
                EmbeddingChunk(
                    vector: [0.98, 0.02, 0],
                    text: "Run the installer",
                    sectionPath: ["Guide", "Installation"],
                    pageStart: 5,
                    pageEnd: 5,
                    kind: .text
                ),
                EmbeddingChunk(
                    vector: [0, 1, 0],
                    text: "Configuration table",
                    sectionPath: ["Guide", "Configuration"],
                    pageStart: 8,
                    pageEnd: 9,
                    kind: .table
                ),
            ],
            model: "test-model"
        )
        XCTAssertTrue(replaced)

        let version = try await store.dbPool.read { db in try String.fetchOne(db, sql: "SELECT vec_version()") }
        XCTAssertNotNil(version)
        let hits = await vectorStore.searchChunks([1, 0, 0], k: 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.fileId, fileId)
        XCTAssertEqual(hit.chunkIndex, 0)
        XCTAssertEqual(hit.sectionPath, ["Guide", "Installation"])
        XCTAssertEqual(hit.pageStart, 4)
        XCTAssertEqual(hit.kind, .title)

        let neighbors = await vectorStore.neighboringChunks(fileId: fileId, around: 1, radius: 1)
        XCTAssertEqual(neighbors.map(\.chunkIndex), [0, 1, 2])
        XCTAssertEqual(neighbors.last?.kind, .table)
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

    func testRemoveAllClearsPersistedAndInMemoryVectorSpace() async throws {
        let fileId = try insertFile(named: "notes.md")
        let vectorStore = AccelerateVectorStore(store: store)
        let replaced = await vectorStore.replace(
            fileId: fileId,
            chunks: [EmbeddingChunk(vector: [1, 0], text: "old model")],
            model: "old-model"
        )
        XCTAssertTrue(replaced)

        let removed = await vectorStore.removeAll()
        XCTAssertTrue(removed)

        XCTAssertEqual(vectorStore.count, 0)
        try assertPersistedChunks(fileId: fileId, expectedIndexes: [])
        let hits = await vectorStore.search([1, 0], k: 1)
        XCTAssertTrue(hits.isEmpty)
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

    func testOlderRevisionCannotOverwriteNewerReplacement() async throws {
        let fileId = try insertFile(named: "notes.md")
        let vectorStore = AccelerateVectorStore(store: store)

        let newerSucceeded = await vectorStore.replace(
            fileId: fileId,
            chunks: [EmbeddingChunk(vector: [0, 1], text: "newer")],
            model: "test-model",
            revision: 2
        )
        let olderSucceeded = await vectorStore.replace(
            fileId: fileId,
            chunks: [EmbeddingChunk(vector: [1, 0], text: "older")],
            model: "test-model",
            revision: 1
        )

        XCTAssertTrue(newerSucceeded)
        XCTAssertFalse(olderSucceeded)
        let hits = await vectorStore.search([0, 1], k: 1)
        XCTAssertEqual(hits.first?.fileId, fileId)
        XCTAssertEqual(try XCTUnwrap(hits.first).score, 1, accuracy: 0.0001)
    }

    func testNoteUpdateAndRemovalPreserveBodyVectors() async throws {
        let fileID = try insertFile(named: "brief.md")
        let vectorStore = AccelerateVectorStore(store: store)
        let initialReplaceSucceeded = await vectorStore.replace(
            fileId: fileID,
            chunks: [
                EmbeddingChunk(vector: [1, 0], text: "Brief", kind: .title),
                EmbeddingChunk(vector: [0, 1], text: "Original body", kind: .text),
            ],
            model: "test-model"
        )
        XCTAssertTrue(initialReplaceSucceeded)

        let noteUpdateSucceeded = await vectorStore.updateNote(
            fileId: fileID,
            chunk: EmbeddingChunk(vector: [0.7, 0.3], text: "User note: Urgent", kind: .note),
            model: "test-model"
        )
        XCTAssertTrue(noteUpdateSucceeded)
        var chunks = try store.documentChunks(fileID: fileID)
        XCTAssertEqual(chunks.filter { $0.kind == .title }.map(\.text), ["Brief"])
        XCTAssertEqual(chunks.filter { $0.kind == .text }.map(\.text), ["Original body"])
        XCTAssertEqual(chunks.filter { $0.kind == .note }.map(\.text), ["User note: Urgent"])
        XCTAssertEqual(vectorStore.count, 3)

        let noteRemovalSucceeded = await vectorStore.updateNote(
            fileId: fileID,
            chunk: nil,
            model: "test-model"
        )
        XCTAssertTrue(noteRemovalSucceeded)
        chunks = try store.documentChunks(fileID: fileID)
        XCTAssertEqual(chunks.map(\.kind), [.title, .text])
        XCTAssertEqual(vectorStore.count, 2)
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

    func testFileScopedChunkSearchNeverReturnsAnotherFilesChunks() async throws {
        let selectedID = try insertFile(named: "selected.md")
        let otherID = try insertFile(named: "other.md")
        let vectorStore = AccelerateVectorStore(store: store)
        _ = await vectorStore.replace(
            fileId: selectedID,
            chunks: [EmbeddingChunk(vector: [0.8, 0.2], text: "selected file answer")],
            model: "test-model"
        )
        _ = await vectorStore.replace(
            fileId: otherID,
            chunks: [EmbeddingChunk(vector: [1, 0], text: "globally closer but wrong file")],
            model: "test-model"
        )

        let hits = await vectorStore.searchChunks([1, 0], fileId: selectedID, k: 4)

        XCTAssertEqual(hits.map(\.fileId), [selectedID])
        XCTAssertEqual(hits.first?.chunkText, "selected file answer")
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
