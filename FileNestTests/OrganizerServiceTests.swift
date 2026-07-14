import XCTest
@testable import FileNest

final class OrganizerServiceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var sourceDirectory: URL!
    private var organizedDirectory: URL!
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        sourceDirectory = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        organizedDirectory = temporaryDirectory.appendingPathComponent("organized", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testCustomRuleMovesFileToExactFolderAndKeepsCategory() throws {
        _ = try store.upsertRule(Rule(
            id: nil,
            name: "合同",
            type: RuleType.rule.rawValue,
            pattern: "pdf",
            targetFolder: "合同",
            priority: 10,
            enabled: true
        ))
        let source = try createFile(named: "agreement.pdf")
        let fileId = try insertFile(at: source)
        let organizer = OrganizerService(
            store: store,
            settings: .shared,
            organizeRoot: organizedDirectory,
            strategy: .hybrid
        )

        try organizer.organize(fileId: fileId)

        let destination = organizedDirectory
            .appendingPathComponent("合同", isDirectory: true)
            .appendingPathComponent("agreement.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let record = try XCTUnwrap(store.file(id: fileId))
        XCTAssertEqual(record.path, destination.path)
        XCTAssertEqual(record.categoryEnum, .documents)
    }

    func testRuleOnlyKeepsUnmatchedFileInPlace() throws {
        let source = try createFile(named: "photo.jpg")
        let fileId = try insertFile(at: source)
        let organizer = OrganizerService(
            store: store,
            settings: .shared,
            organizeRoot: organizedDirectory,
            strategy: .rule
        )

        try organizer.organize(fileId: fileId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: organizedDirectory.path))
        XCTAssertEqual(try store.file(id: fileId)?.path, source.path)
    }

    private func createFile(named name: String) throws -> URL {
        let url = sourceDirectory.appendingPathComponent(name)
        try Data("test".utf8).write(to: url)
        return url
    }

    private func insertFile(at url: URL) throws -> Int64 {
        try store.upsertFile(FileRecord(
            id: nil,
            path: url.path,
            name: url.lastPathComponent,
            ext: url.pathExtension,
            size: 4,
            mtime: Date(),
            category: FileCategory.from(extension: url.pathExtension).rawValue,
            sourceDir: sourceDirectory.path,
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        ))
    }
}
