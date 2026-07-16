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

    func testFileUpsertPreservesOrganizedTimestamp() throws {
        let path = filePath("organized.txt")
        var organized = makeFile(path: path, title: "Organized")
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        organized.organizedAt = timestamp
        let id = try store.upsertFile(organized)

        var refreshed = makeFile(path: path, title: "Refreshed")
        refreshed.id = id
        _ = try store.upsertFile(refreshed)

        XCTAssertEqual(try store.file(id: id)?.organizedAt, timestamp)
    }

    func testFileLibraryDefaultsToNewestDiscoveredTime() throws {
        var older = makeFile(path: filePath("recently-reindexed.txt"), title: "Old")
        older.discoveredAt = Date(timeIntervalSince1970: 100)
        older.indexedAt = Date(timeIntervalSince1970: 900)
        var newer = makeFile(path: filePath("newly-added.txt"), title: "New")
        newer.discoveredAt = Date(timeIntervalSince1970: 500)
        newer.indexedAt = Date(timeIntervalSince1970: 600)
        _ = try store.upsertFile(older)
        _ = try store.upsertFile(newer)

        XCTAssertEqual(try store.allFiles().map(\.name), ["newly-added.txt", "recently-reindexed.txt"])
    }

    func testFileSearchTreatsSQLWildcardsAsLiteralCharacters() throws {
        _ = try store.upsertFile(makeFile(path: filePath("budget%2026.txt"), title: "Budget"))
        _ = try store.upsertFile(makeFile(path: filePath("draft_v1.txt"), title: "Draft"))
        _ = try store.upsertFile(makeFile(path: filePath("ordinary.txt"), title: "Ordinary"))

        XCTAssertEqual(try store.files(matching: "%").map(\.name), ["budget%2026.txt"])
        XCTAssertEqual(try store.files(matching: "_").map(\.name), ["draft_v1.txt"])
    }

    func testFileNotePersistsAndParticipatesInSearch() throws {
        let id = try store.upsertFile(makeFile(path: filePath("brief.pdf"), title: "Brief"))

        try store.updateFileNote(id: id, note: "Polaris release plan")

        let file = try XCTUnwrap(store.file(id: id))
        XCTAssertEqual(file.note, "Polaris release plan")
        XCTAssertNil(file.indexedAt)
        XCTAssertEqual(try store.files(matching: "Polaris").map(\.id), [id])
    }

    func testEditingNoteDoesNotInvalidateExistingDocumentIndex() throws {
        var record = makeFile(path: filePath("indexed.pdf"), title: "Indexed")
        record.indexedAt = Date(timeIntervalSince1970: 1_000)
        record.indexSignature = "content-signature"
        let id = try store.upsertFile(record)

        try store.updateFileNote(id: id, note: "Keep the existing document chunks")

        let updated = try XCTUnwrap(store.file(id: id))
        XCTAssertEqual(updated.indexedAt, record.indexedAt)
        XCTAssertEqual(updated.indexSignature, "content-signature")
    }

    func testFilePathParticipatesInFileLevelSearch() throws {
        let path = temporaryDirectory
            .appendingPathComponent("Client-Aurora", isDirectory: true)
            .appendingPathComponent("brief.pdf")
            .path
        let id = try store.upsertFile(makeFile(path: path, title: "Generic brief"))

        XCTAssertEqual(try store.files(matching: "Aurora").map(\.id), [id])
    }

    func testDocumentChunksRoundTripPreservesStructureAndOrder() throws {
        let fileID = try store.upsertFile(makeFile(path: filePath("manual.pdf"), title: "Manual"))
        try store.dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO document_chunks(
                        file_id, chunk_idx, text, contextual_text, section_path,
                        page_start, page_end, kind
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    fileID, 2, "A result table", "Manual › Results\nA result table",
                    "[\"Manual\",\"Results\"]", 8, 9, "table",
                    fileID, 0, "Introduction", "Manual\nIntroduction",
                    "[\"Manual\"]", 1, 1, "title",
                ]
            )
        }

        let chunks = try store.documentChunks(fileID: fileID)

        XCTAssertEqual(chunks.map(\.index), [0, 2])
        XCTAssertEqual(chunks.first?.kind, .title)
        XCTAssertEqual(chunks.last?.sectionPath, ["Manual", "Results"])
        XCTAssertEqual(chunks.last?.pageStart, 8)
        XCTAssertEqual(chunks.last?.pageEnd, 9)
        XCTAssertEqual(chunks.last?.contextualText, "Manual › Results\nA result table")
    }

    func testUpsertPreservesExistingNoteAndOrganizationSubfolder() throws {
        var original = makeFile(path: filePath("preserved.txt"), title: "Original")
        original.note = "User note"
        original.organizationSubfolder = "Project Materials"
        original.indexSignature = "index-config-v2"
        let id = try store.upsertFile(original)

        var refreshed = makeFile(path: filePath("preserved.txt"), title: "Refreshed")
        refreshed.id = id
        _ = try store.upsertFile(refreshed)

        let stored = try XCTUnwrap(store.file(id: id))
        XCTAssertEqual(stored.note, "User note")
        XCTAssertEqual(stored.organizationSubfolder, "Project Materials")
        XCTAssertEqual(stored.indexSignature, "index-config-v2")
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
            targetFolder: "Documents",
            priority: 1,
            enabled: true
        ))
        var rule = try XCTUnwrap(store.allRules().first)
        rule.name = "Contracts"
        rule.targetFolder = "Contracts"
        rule.priority = 10
        rule.action = RuleAction.ignore.rawValue

        XCTAssertEqual(try store.upsertRule(rule), id)
        let updated = try XCTUnwrap(store.allRules().first)
        XCTAssertEqual(updated.name, "Contracts")
        XCTAssertEqual(updated.targetFolder, "Contracts")
        XCTAssertEqual(updated.priority, 10)
        XCTAssertEqual(updated.actionEnum, .ignore)

        try store.deleteRule(id: id)
        XCTAssertTrue(try store.allRules().isEmpty)
    }

    func testDefaultOrganizationRulesUseStableEnglishNamesAndFolders() throws {
        try store.seedDefaultRulesIfNeeded()

        let rules = try store.allRules()
        XCTAssertEqual(rules.count, 7)
        XCTAssertEqual(Set(rules.map(\.name)), Set([
            "Installers (keep in place)",
            "Documents (pdf/doc/md…)",
            "Images (png/jpg…)",
            "Videos (mp4/mov…)",
            "Audio (mp3/wav…)",
            "Code (swift/py/js…)",
            "Archives (zip/dmg…)",
        ]))
        XCTAssertEqual(Set(rules.filter { $0.actionEnum == .organize }.map(\.targetFolder)), Set([
            "Documents", "Images", "Videos", "Audio", "Code", "Archives",
        ]))
        let installerRule = try XCTUnwrap(rules.first { $0.name == "Installers (keep in place)" })
        XCTAssertEqual(installerRule.actionEnum, .ignore)
        XCTAssertEqual(installerRule.priority, 100)
        XCTAssertEqual(installerRule.pattern, "dmg,pkg,mpkg,app,iso,xip")
    }

    func testLegacyChineseDefaultRuleMigratesWithoutChangingCustomRule() throws {
        _ = try store.upsertRule(Rule(
            id: nil,
            name: "Documents (pdf/doc/md…)",
            type: RuleType.rule.rawValue,
            pattern: "pdf,doc,docx,txt,md,rtf,xls,xlsx,ppt,pptx,csv,epub",
            targetFolder: "Documents",
            priority: 6,
            enabled: true
        ))
        _ = try store.upsertRule(Rule(
            id: nil,
            name: "My Contract Rule",
            type: RuleType.rule.rawValue,
            pattern: "pdf",
            targetFolder: "Contracts",
            priority: 90,
            enabled: true
        ))

        try store.seedDefaultRulesIfNeeded()

        let rules = try store.allRules()
        XCTAssertTrue(rules.contains {
            $0.name == "Documents (pdf/doc/md…)" && $0.targetFolder == "Documents"
        })
        XCTAssertTrue(rules.contains {
            $0.name == "My Contract Rule" && $0.targetFolder == "Contracts"
        })
    }

    func testSettingRoundTripOverwritesExistingValue() {
        store.setSetting("test.key", "first")
        XCTAssertEqual(store.getSetting("test.key"), "first")

        store.setSetting("test.key", "updated")
        XCTAssertEqual(store.getSetting("test.key"), "updated")
    }

    func testDocumentChunkSchemaAndSQLiteVecExtensionAreAvailable() throws {
        let vecVersion = try store.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT vec_version()")
        }
        let chunkTableExists = try store.dbPool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'document_chunks')"
            ) ?? false
        }

        XCTAssertNotNil(vecVersion)
        XCTAssertTrue(chunkTableExists)
    }

    func testTransientFilesCanBePurgedFromExistingLibrary() throws {
        _ = try store.upsertFile(makeFile(path: filePath("~$draft.txt"), title: "Lock"))
        _ = try store.upsertFile(makeFile(path: filePath("final.txt"), title: "Final"))

        XCTAssertEqual(try store.removeTransientFiles(), 1)
        XCTAssertEqual(try store.allFiles().map(\.name), ["final.txt"])
    }

    func testTransientFilesAlreadyInsideManagedRootArePreservedForDirectoryParity() throws {
        let managedRoot = temporaryDirectory.appendingPathComponent("managed", isDirectory: true)
        let managedPath = managedRoot.appendingPathComponent("~$draft.txt").path
        _ = try store.upsertFile(makeFile(path: managedPath, title: "Lock"))

        XCTAssertEqual(try store.removeTransientFiles(preservingRoot: managedRoot), 0)
        XCTAssertNotNil(try store.file(path: managedPath))
    }

    func testStatisticsAggregateFilesIndexesStorageAndTokens() throws {
        var indexed = makeFile(path: filePath("indexed.txt"), title: "Indexed content")
        indexed.size = 1_024
        indexed.discoveredAt = Date()
        indexed.indexedAt = Date()
        _ = try store.upsertFile(indexed)

        var pending = makeFile(path: filePath("pending.txt"), title: "Pending")
        pending.size = 2_048
        pending.discoveredAt = Date()
        _ = try store.upsertFile(pending)
        try store.recordTokenUsage(TokenUsageRecord(
            id: nil,
            ts: Date(),
            provider: "ollama",
            model: "test",
            inputTokens: 120,
            outputTokens: 30,
            sessionId: nil
        ))

        let statistics = try store.statistics(days: 7)
        XCTAssertEqual(statistics.totalFiles, 2)
        XCTAssertEqual(statistics.indexedFiles, 1)
        XCTAssertEqual(statistics.todayAddedFiles, 2)
        XCTAssertEqual(statistics.totalTokens, 150)
        XCTAssertEqual(statistics.managedFileBytes, 3_072)
        XCTAssertEqual(statistics.dailyActivity.last?.tokens, 150)
    }

    func testChatResponseMetricsRoundTrip() throws {
        let session = try store.createChatSession()
        let messageID = try store.addChatMessage(ChatMessage(
            id: nil,
            role: ChatRole.assistant.rawValue,
            content: "Answer",
            ts: Date(),
            relatedFileIds: nil,
            sessionId: session.id,
            inputTokens: 120,
            outputTokens: 45,
            firstResponseDuration: 0.42,
            totalResponseDuration: 1.75,
            responseProvider: "ollama",
            responseModel: "qwen3.5:9b"
        ))

        let stored = try XCTUnwrap(store.chatMessages(sessionId: try XCTUnwrap(session.id)).first)
        XCTAssertEqual(stored.id, messageID)
        XCTAssertEqual(stored.inputTokens, 120)
        XCTAssertEqual(stored.outputTokens, 45)
        XCTAssertEqual(try XCTUnwrap(stored.firstResponseDuration), 0.42, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(stored.totalResponseDuration), 1.75, accuracy: 0.001)
        XCTAssertEqual(stored.responseProvider, "ollama")
        XCTAssertEqual(stored.responseModel, "qwen3.5:9b")
    }

    func testLegacyDatabaseLocationMigrationCheckpointsValidatesAndMovesDatabase() throws {
        let root = temporaryDirectory.appendingPathComponent("database-location", isDirectory: true)
        let legacyURL = root.appendingPathComponent("filenest.sqlite")
        let destinationURL = root
            .appendingPathComponent("FileNest", isDirectory: true)
            .appendingPathComponent("filenest.sqlite")
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: destinationURL)

        try createLegacyDatabase(at: legacyURL)

        let resolved = try SQLiteStore.migrateLegacyDatabaseIfNeeded(
            legacyURL: legacyURL,
            destinationURL: destinationURL
        )

        XCTAssertEqual(resolved, destinationURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path + "-shm"))
        let migratedQueue = try DatabaseQueue(path: destinationURL.path)
        XCTAssertEqual(
            try migratedQueue.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM migration_probe")
            },
            "preserved"
        )
    }

    func testLegacyDatabaseLocationMigrationPreservesInvalidSourceAndEmptyDestination() throws {
        let root = temporaryDirectory.appendingPathComponent("invalid-location", isDirectory: true)
        let legacyURL = root.appendingPathComponent("filenest.sqlite")
        let destinationURL = root
            .appendingPathComponent("FileNest", isDirectory: true)
            .appendingPathComponent("filenest.sqlite")
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let invalidData = Data("not a sqlite database".utf8)
        try invalidData.write(to: legacyURL)
        try Data().write(to: destinationURL)

        XCTAssertThrowsError(try SQLiteStore.migrateLegacyDatabaseIfNeeded(
            legacyURL: legacyURL,
            destinationURL: destinationURL
        ))
        XCTAssertEqual(try Data(contentsOf: legacyURL), invalidData)
        XCTAssertEqual(try Data(contentsOf: destinationURL).count, 0)
    }

    private func filePath(_ name: String) -> String {
        temporaryDirectory.appendingPathComponent(name).path
    }

    private func createLegacyDatabase(at url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "CREATE TABLE migration_probe(value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO migration_probe VALUES ('preserved')")
        }
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
