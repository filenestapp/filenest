import XCTest
@testable import FileNest

final class AppLogServiceTests: XCTestCase {
    func testDailyLogsKeepLatestThreeDaysAndCanBeCleared() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for name in [
            "filenest-2026-07-12.log",
            "filenest-2026-07-13.log",
            "filenest-2026-07-14.log",
            "indexer.log",
            "watcher.log",
        ] {
            try Data("old".utf8).write(to: directory.appendingPathComponent(name))
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-15T08:00:00Z"))
        let service = AppLogService(
            directoryURL: directory,
            retentionDays: 3,
            calendar: calendar,
            now: { now }
        )

        service.write("started", category: "Test")
        service.flush()

        XCTAssertEqual(service.logFiles().map(\.lastPathComponent), [
            "filenest-2026-07-13.log",
            "filenest-2026-07-14.log",
            "filenest-2026-07-15.log",
        ])
        let current = try String(
            contentsOf: directory.appendingPathComponent("filenest-2026-07-15.log"),
            encoding: .utf8
        )
        XCTAssertTrue(current.contains("[Test] started"))

        XCTAssertEqual(service.clear(), 3)
        XCTAssertTrue(service.logFiles().isEmpty)
    }

    func testStructuredLogIncludesLevelCategorySessionAndSanitizedMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-16T08:00:00Z"))
        let service = AppLogService(
            directoryURL: directory,
            calendar: calendar,
            now: { now }
        )

        service.write(
            "scan\nfinished",
            category: .watchScan,
            level: .notice,
            metadata: ["processed": "2", "directory": "My Files"]
        )
        service.flush()

        let contents = try String(
            contentsOf: directory.appendingPathComponent("filenest-2026-07-16.log"),
            encoding: .utf8
        )
        XCTAssertTrue(contents.contains("[NOTICE] [watch.scan] scan finished"))
        XCTAssertNotNil(contents.range(of: #"session=[0-9a-f]{8}"#, options: .regularExpression))
        XCTAssertTrue(contents.contains(#"directory="My Files" processed=2"#))
        XCTAssertEqual(contents.split(separator: "\n").count, 1)
    }

    func testCategoriesAndUnifiedLogCommandAreStableAndFilterable() {
        XCTAssertEqual(AppLogCategory.indexEmbedding.rawValue, "index.embedding")
        XCTAssertEqual(AppLogCategory.organizeMove.rawValue, "organize.move")
        XCTAssertTrue(AppLogService.unifiedLogStreamCommand.contains(AppLogService.subsystem))
        XCTAssertTrue(AppLogService.unifiedLogStreamCommand.contains("subsystem =="))
    }
}
