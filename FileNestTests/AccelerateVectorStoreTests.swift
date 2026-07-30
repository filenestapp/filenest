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

    func testFilteredVectorSearchOnlyScoresAllowedFiles() async throws {
        let strongestFileID = try insertFile(named: "strongest.txt")
        let allowedFileID = try insertFile(named: "allowed.pdf")
        let vectorStore = AccelerateVectorStore(store: store)
        let insertedStrongest = await vectorStore.replace(
            fileId: strongestFileID,
            chunks: [EmbeddingChunk(vector: [1, 0], text: "Globally strongest")],
            model: "test-model"
        )
        let insertedAllowed = await vectorStore.replace(
            fileId: allowedFileID,
            chunks: [EmbeddingChunk(vector: [0.8, 0.2], text: "Allowed candidate")],
            model: "test-model"
        )
        XCTAssertTrue(insertedStrongest)
        XCTAssertTrue(insertedAllowed)

        let hits = await vectorStore.searchChunks(
            [1, 0],
            allowedFileIDs: [allowedFileID],
            k: 10
        )

        XCTAssertEqual(hits.map(\.fileId), [allowedFileID])
    }

    func testExactChunkTokenMetadataSurvivesVectorPersistence() async throws {
        let fileId = try insertFile(named: "tokenized.pdf")
        let vectorStore = AccelerateVectorStore(store: store)
        let replaced = await vectorStore.replace(
            fileId: fileId,
            chunks: [EmbeddingChunk(
                vector: [1, 0],
                text: "Invoice total SGD 500",
                contextualText: "Document: Invoice\n\nInvoice total SGD 500",
                tokenCount: 11,
                tokenizerProfile: TokenCounter.canonicalProfile,
                tokenizerVersion: "huggingface-tokenizer-v1",
                tokenCountAccuracy: .exact
            )],
            model: "test-model"
        )
        XCTAssertTrue(replaced)

        let chunk = try XCTUnwrap(store.documentChunks(fileID: fileId).first)
        XCTAssertEqual(chunk.tokenCount, 11)
        XCTAssertEqual(chunk.tokenizerProfile, TokenCounter.canonicalProfile)
        XCTAssertEqual(chunk.tokenizerVersion, "huggingface-tokenizer-v1")
        XCTAssertEqual(chunk.tokenCountAccuracy, .exact)
    }

    func testParentSectionAndEntityTermsSurviveVectorPersistence() async throws {
        let fileId = try insertFile(named: "invoice.pdf")
        let vectorStore = AccelerateVectorStore(store: store)
        let replaced = await vectorStore.replace(
            fileId: fileId,
            chunks: [EmbeddingChunk(
                vector: [1, 0],
                text: "INV-20250377",
                contextualText: "Invoice INV-20250377",
                sectionPath: ["Invoices"],
                kind: .text,
                parentIndex: 4,
                parentText: "Invoice INV-20250377 was issued to Waterdrop Inc.",
                entityTerms: ["inv-20250377"]
            )],
            model: "test-model"
        )
        XCTAssertTrue(replaced)

        let hits = await vectorStore.searchChunks([1, 0], k: 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.parentIndex, 4)
        XCTAssertEqual(hit.parentText, "Invoice INV-20250377 was issued to Waterdrop Inc.")
        XCTAssertEqual(hit.entityTerms, ["inv-20250377"])

        let entityHit = try XCTUnwrap(store.entityChunkMatches(
            terms: ["INV-20250377"],
            limit: 10
        ).first)
        XCTAssertEqual(entityHit.fileId, fileId)
        XCTAssertEqual(entityHit.parentIndex, 4)
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

    func testRebuildRetrievalIndexPreservesChunksAndStoredEmbeddings() async throws {
        let fileId = try insertFile(named: "retrieval.md")
        let vectorStore = AccelerateVectorStore(store: store)
        let replaced = await vectorStore.replace(
            fileId: fileId,
            chunks: [
                EmbeddingChunk(vector: [1, 0], text: "primary retrieval chunk"),
                EmbeddingChunk(vector: [0, 1], text: "secondary retrieval chunk"),
            ],
            model: "test-model"
        )
        XCTAssertTrue(replaced)

        try await store.dbPool.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS vec_embeddings")
        }

        let rebuilt = await vectorStore.rebuildRetrievalIndex()

        XCTAssertTrue(rebuilt)
        XCTAssertEqual(vectorStore.count, 2)
        try assertPersistedChunks(fileId: fileId, expectedIndexes: [0, 1])
        let hits = await vectorStore.searchChunks([1, 0], k: 1)
        XCTAssertEqual(hits.first?.fileId, fileId)
        XCTAssertEqual(hits.first?.chunkText, "primary retrieval chunk")
    }

    func testShadowRebuildKeepsActiveIndexUntilAtomicCommit() async throws {
        let fileId = try insertFile(named: "shadow.md")
        let vectorStore = AccelerateVectorStore(store: store)
        let initialReplaceSucceeded = await vectorStore.replace(
            fileId: fileId,
            chunks: [EmbeddingChunk(vector: [1, 0], text: "active generation")],
            model: "old-model"
        )
        XCTAssertTrue(initialReplaceSucceeded)
        var stagedFile = try XCTUnwrap(store.file(id: fileId))
        stagedFile.title = "Shadow title"
        stagedFile.contentText = "Shadow content"
        stagedFile.contentHash = "shadow-hash"
        stagedFile.indexedAt = Date(timeIntervalSince1970: 2_000)
        stagedFile.indexSignature = "shadow-signature"

        let shadowStarted = await vectorStore.beginShadowRebuild()
        XCTAssertTrue(shadowStarted)
        let shadowReplaceSucceeded = await vectorStore.replaceShadow(
            fileId: fileId,
            chunks: [EmbeddingChunk(vector: [0, 1], text: "shadow generation")],
            model: "new-model"
        )
        XCTAssertTrue(shadowReplaceSucceeded)
        let metadataStaged = await vectorStore.stageShadowMetadata(stagedFile)
        XCTAssertTrue(metadataStaged)

        let hitsBeforeCommit = await vectorStore.searchChunks([1, 0], k: 1)
        let activeBeforeCommit = try XCTUnwrap(hitsBeforeCommit.first)
        XCTAssertEqual(activeBeforeCommit.chunkText, "active generation")
        XCTAssertNil(try store.file(id: fileId)?.title)

        let committed = await vectorStore.commitShadowRebuild(expectedFileCount: 1)
        XCTAssertTrue(committed)

        let hitsAfterCommit = await vectorStore.searchChunks([0, 1], k: 1)
        let activeAfterCommit = try XCTUnwrap(hitsAfterCommit.first)
        XCTAssertEqual(activeAfterCommit.chunkText, "shadow generation")
        let committedFile = try XCTUnwrap(store.file(id: fileId))
        XCTAssertEqual(committedFile.title, "Shadow title")
        XCTAssertEqual(committedFile.contentText, "Shadow content")
        XCTAssertEqual(committedFile.contentHash, "shadow-hash")
        XCTAssertEqual(committedFile.indexSignature, "shadow-signature")
    }

    func testShadowCommitPreservesCompatibleFileIndexedAfterSnapshot() async throws {
        let rebuiltFileId = try insertFile(named: "snapshot.md")
        let vectorStore = AccelerateVectorStore(store: store)
        let initialReplaceSucceeded = await vectorStore.replace(
            fileId: rebuiltFileId,
            chunks: [EmbeddingChunk(vector: [1, 0], text: "active snapshot")],
            model: "shared-model"
        )
        XCTAssertTrue(initialReplaceSucceeded)

        let shadowStarted = await vectorStore.beginShadowRebuild()
        XCTAssertTrue(shadowStarted)
        let shadowReplaceSucceeded = await vectorStore.replaceShadow(
            fileId: rebuiltFileId,
            chunks: [EmbeddingChunk(vector: [0, 1], text: "rebuilt snapshot")],
            model: "shared-model"
        )
        XCTAssertTrue(shadowReplaceSucceeded)
        var stagedFile = try XCTUnwrap(store.file(id: rebuiltFileId))
        stagedFile.indexedAt = Date(timeIntervalSince1970: 3_000)
        stagedFile.indexSignature = "rebuilt-signature"
        let metadataStaged = await vectorStore.stageShadowMetadata(stagedFile)
        XCTAssertTrue(metadataStaged)

        let concurrentFileId = try insertFile(named: "arrived-during-rebuild.md")
        let concurrentReplaceSucceeded = await vectorStore.replace(
            fileId: concurrentFileId,
            chunks: [EmbeddingChunk(vector: [0.5, 0.5], text: "concurrent generation")],
            model: "shared-model"
        )
        XCTAssertTrue(concurrentReplaceSucceeded)

        let committed = await vectorStore.commitShadowRebuild(expectedFileCount: 1)
        XCTAssertTrue(committed)
        let concurrentHits = await vectorStore.searchChunks([0.5, 0.5], k: 2)
        XCTAssertTrue(concurrentHits.contains { $0.fileId == concurrentFileId })
        XCTAssertEqual(vectorStore.count, 2)
    }

    func testShadowRebuildSurvivesWarmupAndResumesAfterRelaunch() async throws {
        let fileID = try insertFile(named: "resume-shadow.md")
        let vectorStore = AccelerateVectorStore(store: store)
        let activeStored = await vectorStore.replace(
            fileId: fileID,
            chunks: [EmbeddingChunk(vector: [1, 0], text: "active generation")],
            model: "shared-model"
        )
        XCTAssertTrue(activeStored)
        let shadowStarted = await vectorStore.beginShadowRebuild()
        XCTAssertTrue(shadowStarted)
        let shadowStored = await vectorStore.replaceShadow(
            fileId: fileID,
            chunks: [EmbeddingChunk(vector: [0, 1], text: "resumed generation")],
            model: "shared-model"
        )
        XCTAssertTrue(shadowStored)
        var metadata = try XCTUnwrap(store.file(id: fileID))
        metadata.indexedAt = Date(timeIntervalSince1970: 4_000)
        metadata.indexSignature = "resumed-signature"
        let metadataStored = await vectorStore.stageShadowMetadata(metadata)
        XCTAssertTrue(metadataStored)

        let relaunchedStore = AccelerateVectorStore(store: store)
        await relaunchedStore.loadAll()

        let stagedFileIDs = await relaunchedStore.shadowStagedFileIDs()
        XCTAssertEqual(stagedFileIDs, Set([fileID]))
        let resumed = await relaunchedStore.beginShadowRebuild(resumeIfAvailable: true)
        XCTAssertTrue(resumed)
        let committed = await relaunchedStore.commitShadowRebuild(expectedFileCount: 1)
        XCTAssertTrue(committed)
        let hits = await relaunchedStore.searchChunks([0, 1], k: 1)
        XCTAssertEqual(hits.first?.chunkText, "resumed generation")
        XCTAssertEqual(try store.file(id: fileID)?.indexSignature, "resumed-signature")
    }

    func testDiscardedOrIncompleteShadowRebuildPreservesActiveIndex() async throws {
        let fileId = try insertFile(named: "preserved.md")
        let vectorStore = AccelerateVectorStore(store: store)
        let initialReplaceSucceeded = await vectorStore.replace(
            fileId: fileId,
            chunks: [EmbeddingChunk(vector: [1, 0], text: "preserved generation")],
            model: "old-model"
        )
        XCTAssertTrue(initialReplaceSucceeded)

        let shadowStarted = await vectorStore.beginShadowRebuild()
        XCTAssertTrue(shadowStarted)
        let shadowReplaceSucceeded = await vectorStore.replaceShadow(
            fileId: fileId,
            chunks: [EmbeddingChunk(vector: [0, 1], text: "incomplete generation")],
            model: "new-model"
        )
        XCTAssertTrue(shadowReplaceSucceeded)
        let committed = await vectorStore.commitShadowRebuild(expectedFileCount: 1)
        XCTAssertFalse(committed)
        await vectorStore.discardShadowRebuild()

        let activeHits = await vectorStore.searchChunks([1, 0], k: 1)
        let active = try XCTUnwrap(activeHits.first)
        XCTAssertEqual(active.chunkText, "preserved generation")
        XCTAssertEqual(vectorStore.count, 1)
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
