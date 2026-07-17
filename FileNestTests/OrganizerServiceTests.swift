import XCTest
import GRDB
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
            name: "Contracts",
            type: RuleType.rule.rawValue,
            pattern: "pdf",
            targetFolder: "Contracts",
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
            .appendingPathComponent(FileCategory.documents.folderName, isDirectory: true)
            .appendingPathComponent("Contracts", isDirectory: true)
            .appendingPathComponent("agreement.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let record = try XCTUnwrap(store.file(id: fileId))
        XCTAssertEqual(record.path, destination.path)
        XCTAssertEqual(record.categoryEnum, .documents)
        XCTAssertNotNil(record.organizedAt)
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

    func testIgnoreRuleKeepsInstallerInPlace() throws {
        _ = try store.upsertRule(Rule(
            id: nil,
            name: "Installers (keep in place)",
            type: RuleType.rule.rawValue,
            pattern: "dmg,pkg,mpkg,app,iso,xip",
            targetFolder: "Ignored",
            priority: 100,
            enabled: true,
            action: RuleAction.ignore.rawValue
        ))
        let source = try createFile(named: "FileNest.dmg")
        let fileId = try insertFile(at: source)
        let organizer = OrganizerService(
            store: store,
            settings: AppSettings(store: store),
            organizeRoot: organizedDirectory,
            strategy: .hybrid
        )

        try organizer.organize(fileId: fileId)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: organizedDirectory.path))
        XCTAssertEqual(try store.file(id: fileId)?.path, source.path)
    }

    func testDatabaseUpdateFailureRollsBackPhysicalMove() throws {
        let source = try createFile(named: "rollback.txt")
        let fileId = try insertFile(at: source)
        let destination = organizedDirectory
            .appendingPathComponent(FileCategory.documents.folderName, isDirectory: true)
            .appendingPathComponent("Uncategorized", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
        _ = try insertFile(at: destination)
        let organizer = OrganizerService(
            store: store,
            settings: AppSettings(store: store),
            organizeRoot: organizedDirectory,
            strategy: .hybrid
        )

        XCTAssertThrowsError(try organizer.organize(fileId: fileId)) { error in
            guard let organizerError = error as? OrganizerError,
                  case .databaseUpdateFailed(_, _) = organizerError else {
                return XCTFail("Expected databaseUpdateFailed, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try store.file(id: fileId)?.path, source.path)
    }

    func testPhysicalMoveFailureIsReportedWithoutChangingDatabase() throws {
        let source = try createFile(named: "move-failure.txt")
        let fileId = try insertFile(at: source)
        let destination = organizedDirectory
            .appendingPathComponent(FileCategory.documents.folderName, isDirectory: true)
            .appendingPathComponent("Uncategorized", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
        let organizer = OrganizerService(
            store: store,
            settings: AppSettings(store: store),
            organizeRoot: organizedDirectory,
            strategy: .hybrid,
            moveItem: { _, _ in throw TestError.forcedMoveFailure }
        )

        XCTAssertThrowsError(try organizer.organize(fileId: fileId)) { error in
            guard let organizerError = error as? OrganizerError,
                  case .moveFailed(_, _) = organizerError else {
                return XCTFail("Expected moveFailed, got \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try store.file(id: fileId)?.path, source.path)
    }

    func testRollbackFailureIsReportedSeparately() throws {
        let source = try createFile(named: "rollback-failure.txt")
        let fileId = try insertFile(at: source)
        let destination = organizedDirectory
            .appendingPathComponent(FileCategory.documents.folderName, isDirectory: true)
            .appendingPathComponent("Uncategorized", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
        _ = try insertFile(at: destination)
        var moveCount = 0
        let organizer = OrganizerService(
            store: store,
            settings: AppSettings(store: store),
            organizeRoot: organizedDirectory,
            strategy: .hybrid,
            moveItem: { source, destination in
                moveCount += 1
                guard moveCount == 1 else { throw TestError.forcedMoveFailure }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        )

        XCTAssertThrowsError(try organizer.organize(fileId: fileId)) { error in
            guard let organizerError = error as? OrganizerError,
                  case .rollbackFailed(_, _, _) = organizerError else {
                return XCTFail("Expected rollbackFailed, got \(error)")
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try store.file(id: fileId)?.path, source.path)
    }

    func testAIClassificationCreatesTypeThenTopicHierarchy() async throws {
        let source = try createFile(named: "roadmap.txt")
        let fileId = try insertFile(at: source)
        let organizer = OrganizerService(
            store: store,
            settings: AppSettings(store: store),
            organizeRoot: organizedDirectory,
            strategy: .hybrid,
            subfolderResolver: { _ in "Project Materials" }
        )

        try await organizer.organizeUsingAI(fileId: fileId)

        let destination = organizedDirectory
            .appendingPathComponent(FileCategory.documents.folderName, isDirectory: true)
            .appendingPathComponent("Project Materials", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let record = try XCTUnwrap(store.file(id: fileId))
        XCTAssertEqual(record.path, destination.path)
        XCTAssertEqual(record.organizationSubfolder, "Project Materials")
    }

    func testLegacyCategoryRuleStillAllowsAISubfolderClassification() async throws {
        _ = try store.upsertRule(Rule(
            id: nil,
            name: "Documents",
            type: RuleType.rule.rawValue,
            pattern: "txt",
            targetFolder: FileCategory.documents.folderName,
            priority: 10,
            enabled: true
        ))
        let source = try createFile(named: "minutes.txt")
        let fileId = try insertFile(at: source)
        let organizer = OrganizerService(
            store: store,
            settings: AppSettings(store: store),
            organizeRoot: organizedDirectory,
            strategy: .hybrid,
            subfolderResolver: { _ in "Meeting Notes" }
        )

        try await organizer.organizeUsingAI(fileId: fileId)

        XCTAssertEqual(
            try store.file(id: fileId)?.path,
            organizedDirectory
                .appendingPathComponent(FileCategory.documents.folderName)
                .appendingPathComponent("Meeting Notes")
                .appendingPathComponent("minutes.txt").path
        )
    }

    func testDirectoryChangedAfterIndexingIsNotMoved() throws {
        let directory = sourceDirectory.appendingPathComponent("active-clone", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let readme = directory.appendingPathComponent("README.md")
        try Data("initial".utf8).write(to: readme)
        let indexedSnapshot = try XCTUnwrap(DirectoryInspector.inspect(directory)?.snapshot)
        var record = FileRecord(
            id: nil,
            path: directory.path,
            name: directory.lastPathComponent,
            ext: "",
            size: indexedSnapshot.totalSize,
            mtime: indexedSnapshot.latestModificationDate,
            category: FileCategory.code.rawValue,
            sourceDir: sourceDirectory.path,
            indexedAt: Date(),
            contentHash: indexedSnapshot.signature,
            title: "Active Clone",
            contentText: "initial"
        )
        record.isDirectory = true
        let id = try store.upsertFile(record)
        try Data("clone changed after indexing".utf8).write(to: readme)
        let organizer = OrganizerService(
            store: store,
            settings: AppSettings(store: store),
            organizeRoot: organizedDirectory,
            strategy: .hybrid
        )

        try organizer.organize(fileId: id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try store.file(id: id)?.path, directory.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: organizedDirectory.path))
    }

    func testReconcileManagedFilesMirrorsRecursiveDirectoryAndRemovesStaleManagedRows() throws {
        let topicDirectory = organizedDirectory
            .appendingPathComponent(FileCategory.documents.folderName, isDirectory: true)
            .appendingPathComponent("Contracts", isDirectory: true)
        try FileManager.default.createDirectory(at: topicDirectory, withIntermediateDirectories: true)
        let managedURL = topicDirectory.appendingPathComponent("signed.txt")
        try Data("signed".utf8).write(to: managedURL)
        let staleURL = topicDirectory.appendingPathComponent("missing.txt")
        _ = try insertFile(at: staleURL)
        let sourceURL = try createFile(named: "outside.txt")
        let outsideID = try insertFile(at: sourceURL)
        let organizer = OrganizerService(
            store: store,
            settings: AppSettings(store: store),
            organizeRoot: organizedDirectory,
            strategy: .hybrid
        )

        let managed = organizer.reconcileManagedFiles()

        XCTAssertEqual(managed.map(\.path), [managedURL.path])
        XCTAssertEqual(managed.first?.organizationSubfolder, "Contracts")
        XCTAssertNil(try store.file(path: staleURL.path))
        XCTAssertNotNil(try store.file(id: outsideID))
    }

    func testReconcileManagedFilesDoesNotRewriteStableRows() throws {
        let topicDirectory = organizedDirectory
            .appendingPathComponent(FileCategory.documents.folderName, isDirectory: true)
            .appendingPathComponent("Stable", isDirectory: true)
        try FileManager.default.createDirectory(at: topicDirectory, withIntermediateDirectories: true)
        let managedURL = topicDirectory.appendingPathComponent("unchanged.txt")
        try Data("stable".utf8).write(to: managedURL)
        let organizer = OrganizerService(
            store: store,
            settings: AppSettings(store: store),
            organizeRoot: organizedDirectory,
            strategy: .hybrid
        )
        _ = organizer.reconcileManagedFiles()

        try store.dbPool.write { db in
            try db.create(table: "file_update_audit") { table in
                table.autoIncrementedPrimaryKey("id")
            }
            try db.execute(sql: """
                CREATE TRIGGER audit_stable_file_update
                AFTER UPDATE ON files
                BEGIN
                    INSERT INTO file_update_audit (id) VALUES (NULL);
                END
                """)
        }

        let managed = organizer.reconcileManagedFiles()
        let updateCount = try store.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_update_audit") ?? 0
        }

        XCTAssertEqual(managed.map(\.path), [managedURL.path])
        XCTAssertEqual(updateCount, 0)
    }

    func testReconcileManagedFilesInvalidatesIndexWhenMetadataChangedOffline() throws {
        let topicDirectory = organizedDirectory
            .appendingPathComponent(FileCategory.documents.folderName, isDirectory: true)
            .appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: topicDirectory, withIntermediateDirectories: true)
        let managedURL = topicDirectory.appendingPathComponent("status.txt")
        try Data("before".utf8).write(to: managedURL)
        let values = try managedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let id = try store.upsertFile(FileRecord(
            id: nil,
            path: managedURL.path,
            name: managedURL.lastPathComponent,
            ext: managedURL.pathExtension,
            size: Int64(values.fileSize ?? 0),
            mtime: values.contentModificationDate ?? Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: sourceDirectory.path,
            indexedAt: Date(),
            contentHash: try FileContentHasher.sha256(of: managedURL),
            title: "Status",
            contentText: "before",
            note: "keep this note",
            indexSignature: "embedding-space"
        ))
        try Data("after content is longer".utf8).write(to: managedURL)
        let organizer = OrganizerService(
            store: store,
            settings: AppSettings(store: store),
            organizeRoot: organizedDirectory,
            strategy: .hybrid
        )

        _ = organizer.reconcileManagedFiles()

        let updated = try XCTUnwrap(store.file(id: id))
        XCTAssertNil(updated.indexedAt)
        XCTAssertNil(updated.indexSignature)
        XCTAssertEqual(updated.note, "keep this note")
        XCTAssertEqual(updated.contentText, "before")
    }

    func testManagedContentAuditDetectsOverwriteWithPreservedMetadata() async throws {
        let topicDirectory = organizedDirectory
            .appendingPathComponent(FileCategory.documents.folderName, isDirectory: true)
            .appendingPathComponent("Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: topicDirectory, withIntermediateDirectories: true)
        let managedURL = topicDirectory.appendingPathComponent("status.txt")
        try Data("alpha".utf8).write(to: managedURL)
        let values = try managedURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let originalMTime = values.contentModificationDate ?? Date()
        let originalHash = try FileContentHasher.sha256(of: managedURL)
        let id = try store.upsertFile(FileRecord(
            id: nil,
            path: managedURL.path,
            name: managedURL.lastPathComponent,
            ext: managedURL.pathExtension,
            size: Int64(values.fileSize ?? 0),
            mtime: originalMTime,
            category: FileCategory.documents.rawValue,
            sourceDir: sourceDirectory.path,
            indexedAt: Date(),
            contentHash: originalHash,
            title: "Status",
            contentText: "alpha",
            indexSignature: "embedding-space"
        ))
        try Data("bravo".utf8).write(to: managedURL)
        try FileManager.default.setAttributes(
            [.modificationDate: originalMTime],
            ofItemAtPath: managedURL.path
        )
        let organizer = OrganizerService(
            store: store,
            settings: AppSettings(store: store),
            organizeRoot: organizedDirectory,
            strategy: .hybrid
        )

        let invalidated = await organizer.invalidateChangedManagedFileIndexes()

        let updated = try XCTUnwrap(store.file(id: id))
        XCTAssertEqual(invalidated, 1)
        XCTAssertNil(updated.indexedAt)
        XCTAssertNil(updated.indexSignature)
        XCTAssertEqual(updated.contentHash, originalHash)
    }

    func testBatchedAutoOrganizeRunsWhenFileThresholdIsReached() async throws {
        let settings = AppSettings(store: store)
        settings.setAutoOrganize(true)
        settings.setAutoOrganizeMode(AppSettings.AutoOrganizeMode.batched.rawValue)
        settings.setAutoOrganizeIntervalSeconds(30)
        settings.setAutoOrganizeBatchSize(2)
        let first = try createFile(named: "first.txt")
        let second = try createFile(named: "second.txt")
        let firstID = try insertFile(at: first)
        let secondID = try insertFile(at: second)
        let organizer = OrganizerService(
            store: store,
            settings: settings,
            organizeRoot: organizedDirectory,
            strategy: .hybrid,
            subfolderResolver: { _ in "Batch Processing" }
        )

        organizer.enqueue(fileId: firstID)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        organizer.enqueue(fileId: secondID)

        let completed = await waitUntil {
            !FileManager.default.fileExists(atPath: first.path) &&
            !FileManager.default.fileExists(atPath: second.path)
        }
        XCTAssertTrue(completed)
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

    private func waitUntil(timeout: TimeInterval = 3,
                           condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private enum TestError: Error {
        case forcedMoveFailure
    }
}
