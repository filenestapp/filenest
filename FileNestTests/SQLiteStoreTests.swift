import XCTest
import GRDB
@testable import FileNest

final class SQLiteStoreTests: XCTestCase {
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

    func testFileUpsertByPathUpdatesExistingRecordWithoutDuplicate() throws {
        let path = temporaryDirectory.appendingPathComponent("notes.txt").path
        let firstId = try store.upsertFile(makeFile(path: path, title: "First"))
        let secondId = try store.upsertFile(makeFile(path: path, title: "Updated"))

        XCTAssertEqual(secondId, firstId)
        XCTAssertEqual(try store.allFiles().count, 1)
        XCTAssertEqual(try store.file(id: firstId)?.title, "Updated")
    }

    func testFileSearchTreatsSQLWildcardsAsLiteralCharacters() throws {
        _ = try store.upsertFile(makeFile(path: filePath("budget%2026.txt"), title: "Budget"))
        _ = try store.upsertFile(makeFile(path: filePath("draft_v1.txt"), title: "Draft"))
        _ = try store.upsertFile(makeFile(path: filePath("ordinary.txt"), title: "Ordinary"))

        XCTAssertEqual(try store.files(matching: "%").map(\.name), ["budget%2026.txt"])
        XCTAssertEqual(try store.files(matching: "_").map(\.name), ["draft_v1.txt"])
    }

    func testDeletingFileCascadesToEmbeddings() throws {
        let fileId = try store.upsertFile(makeFile(path: filePath("notes.txt"), title: "Notes"))
        try store.dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO embeddings(file_id, vector, dim, model, chunk_idx) VALUES(?,?,?,?,?)",
                arguments: [fileId, AccelerateVectorStore.encode([1, 0]), 2, "test", 0]
            )
        }

        try store.deleteFile(id: fileId)

        let embeddingCount = try store.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings WHERE file_id = ?",
                             arguments: [fileId]) ?? -1
        }
        XCTAssertNil(try store.file(id: fileId))
        XCTAssertEqual(embeddingCount, 0)
    }

    func testRuleCreateUpdateAndDeleteRoundTrip() throws {
        let id = try store.upsertRule(Rule(
            id: nil,
            name: "Documents",
            type: RuleType.rule.rawValue,
            pattern: "pdf",
            targetFolder: "文档",
            priority: 1,
            enabled: true
        ))
        var rule = try XCTUnwrap(store.allRules().first)
        rule.name = "Contracts"
        rule.targetFolder = "合同"
        rule.priority = 10

        XCTAssertEqual(try store.upsertRule(rule), id)
        let updated = try XCTUnwrap(store.allRules().first)
        XCTAssertEqual(updated.name, "Contracts")
        XCTAssertEqual(updated.targetFolder, "合同")
        XCTAssertEqual(updated.priority, 10)

        try store.deleteRule(id: id)
        XCTAssertTrue(try store.allRules().isEmpty)
    }

    func testSettingRoundTripOverwritesExistingValue() {
        store.setSetting("test.key", "first")
        XCTAssertEqual(store.getSetting("test.key"), "first")

        store.setSetting("test.key", "updated")
        XCTAssertEqual(store.getSetting("test.key"), "updated")
    }

    private func filePath(_ name: String) -> String {
        temporaryDirectory.appendingPathComponent(name).path
    }

    private func makeFile(path: String, title: String) -> FileRecord {
        FileRecord(
            id: nil,
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            ext: URL(fileURLWithPath: path).pathExtension,
            size: 1,
            mtime: Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: temporaryDirectory.path,
            indexedAt: nil,
            contentHash: nil,
            title: title,
            contentText: title
        )
    }
}
