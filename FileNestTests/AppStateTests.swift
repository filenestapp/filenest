import XCTest
@testable import FileNest

final class AppStateTests: XCTestCase {
    @MainActor
    func testRefreshLoadsFilesRulesAndCountFromInjectedStore() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
        let settings = AppSettings(store: store)
        let previousIndexer = AppStateIndexerProxy.shared.indexer
        defer { AppStateIndexerProxy.shared.indexer = previousIndexer }
        _ = try store.upsertFile(makeFile(in: temporaryDirectory, name: "first.txt"))
        _ = try store.upsertRule(Rule(
            id: nil,
            name: "Documents",
            type: RuleType.rule.rawValue,
            pattern: "txt",
            targetFolder: "文档",
            priority: 1,
            enabled: true
        ))

        let state = AppState(store: store, settings: settings, startAutomatically: false)

        XCTAssertEqual(state.files.map(\.name), ["first.txt"])
        XCTAssertEqual(state.rules.map(\.name), ["Documents"])
        XCTAssertEqual(state.indexedCount, 1)
        XCTAssertFalse(state.isWatching)

        _ = try store.upsertFile(makeFile(in: temporaryDirectory, name: "second.txt"))
        state.refresh()
        XCTAssertEqual(Set(state.files.map(\.name)), ["first.txt", "second.txt"])
        XCTAssertEqual(state.indexedCount, 2)
    }

    private func makeFile(in directory: URL, name: String) -> FileRecord {
        let url = directory.appendingPathComponent(name)
        return FileRecord(
            id: nil,
            path: url.path,
            name: name,
            ext: url.pathExtension,
            size: 1,
            mtime: Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: directory.path,
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        )
    }
}
