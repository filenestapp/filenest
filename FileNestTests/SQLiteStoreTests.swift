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

    func testContentHashUpdatePreservesExistingFileMetadata() throws {
        let id = try store.upsertFile(makeFile(path: filePath("report.pdf"), title: "Quarterly report"))

        try store.updateFileContentHash(id: id, contentHash: "verified-hash")

        let file = try XCTUnwrap(store.file(id: id))
        XCTAssertEqual(file.contentHash, "verified-hash")
        XCTAssertEqual(file.title, "Quarterly report")
        XCTAssertNil(file.indexedAt)
    }

    func testDuplicateGroupsRetainOldestFileAndCountReclaimableBytes() {
        var retained = makeFile(path: filePath("original.pdf"), title: "Original")
        retained.id = 1
        retained.size = 20
        retained.contentHash = "same"
        retained.discoveredAt = Date(timeIntervalSince1970: 100)
        var duplicate = makeFile(path: filePath("copy.pdf"), title: "Copy")
        duplicate.id = 2
        duplicate.size = 20
        duplicate.contentHash = "same"
        duplicate.discoveredAt = Date(timeIntervalSince1970: 200)
        var unique = makeFile(path: filePath("unique.pdf"), title: "Unique")
        unique.contentHash = "different"

        let groups = DuplicateFileGroup.groups(from: [duplicate, unique, retained])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].retainedFile.path, retained.path)
        XCTAssertEqual(groups[0].duplicateFiles.map(\.path), [duplicate.path])
        XCTAssertEqual(groups[0].reclaimableBytes, duplicate.size)
    }

    func testDuplicateLinkUsesAnIndexedOriginalAndKeepsDuplicateUnindexed() throws {
        var original = makeFile(path: filePath("original.pdf"), title: "Original")
        original.contentHash = "same-content"
        original.indexedAt = Date()
        let originalID = try store.upsertFile(original)
        var duplicate = makeFile(path: filePath("duplicate.pdf"), title: "Duplicate")
        duplicate.contentHash = "same-content"
        let duplicateID = try store.upsertFile(duplicate)

        let resolvedOriginal = try store.indexedOriginal(
            matchingContentHash: "same-content",
            excludingFileID: duplicateID
        )
        XCTAssertEqual(resolvedOriginal?.id, originalID)

        try store.markFileAsDuplicate(
            id: duplicateID,
            originalFileID: originalID,
            contentHash: "same-content"
        )

        let linkedDuplicate = try XCTUnwrap(store.file(id: duplicateID))
        XCTAssertEqual(linkedDuplicate.duplicateOfFileID, originalID)
        XCTAssertNotNil(linkedDuplicate.duplicateDetectedAt)
        XCTAssertNil(linkedDuplicate.indexedAt)
        XCTAssertEqual(linkedDuplicate.contentHash, "same-content")
    }

    func testStoreStartupRemovesUnreferencedParentRows() throws {
        let databasePath = temporaryDirectory.appendingPathComponent("test.sqlite").path
        let fileID = try store.upsertFile(makeFile(path: filePath("parents.txt"), title: "Parents"))
        try store.dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO document_parents(file_id, parent_idx, text, contextual_text)
                    VALUES (?, 0, 'referenced parent', 'referenced parent'),
                           (?, 99, 'orphan parent', 'orphan parent')
                    """,
                arguments: [fileID, fileID]
            )
            try db.execute(
                sql: """
                    INSERT INTO document_chunks(
                        file_id, chunk_idx, text, contextual_text, parent_idx
                    ) VALUES (?, 0, 'child', 'child', 0)
                    """,
                arguments: [fileID]
            )
            try db.execute(
                sql: "DELETE FROM schema_migrations WHERE name = ?",
                arguments: ["document_parents.orphan_cleanup.v1"]
            )
        }

        store = SQLiteStore(path: databasePath)

        let parentIndexes = try store.dbPool.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT parent_idx FROM document_parents WHERE file_id = ? ORDER BY parent_idx",
                arguments: [fileID]
            )
        }
        XCTAssertEqual(parentIndexes, [0])
    }

    func testBatchFileLookupHandlesMacOSTemporaryPathAliases() throws {
        let storedPath = "/private/var/folders/example/report.txt"
        let requestedPath = "/var/folders/example/report.txt"
        let id = try store.upsertFile(makeFile(path: storedPath, title: "Report"))

        let recordsByPath = try store.files(atPaths: [requestedPath])

        XCTAssertEqual(recordsByPath[requestedPath]?.id, id)
        XCTAssertEqual(try store.file(path: requestedPath)?.id, id)
    }

    func testSourceDirectoryLookupHandlesMacOSTemporaryPathAliases() throws {
        let storedDirectory = "/private/var/folders/example/source"
        var file = makeFile(path: "\(storedDirectory)/report.txt", title: "Report")
        file.sourceDir = storedDirectory
        let id = try store.upsertFile(file)

        let records = try store.libraryFiles(inSourceDirectory: "/var/folders/example/source")

        XCTAssertEqual(records.map(\.id), [id])
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

    func testFileIndexCountsPlansReindexWithoutLoadingFileRows() throws {
        var indexed = makeFile(path: filePath("indexed.txt"), title: "Indexed")
        indexed.indexedAt = Date(timeIntervalSince1970: 100)
        _ = try store.upsertFile(indexed)
        _ = try store.upsertFile(makeFile(path: filePath("pending.txt"), title: "Pending"))

        let counts = try store.fileIndexCounts()

        XCTAssertEqual(counts.total, 2)
        XCTAssertEqual(counts.indexed, 1)
        XCTAssertEqual(counts.unindexed, 1)
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

    func testShortNoteTokenUsesMetadataIndex() throws {
        let id = try store.upsertFile(makeFile(path: filePath("brief.pdf"), title: "Brief"))
        try store.updateFileNote(id: id, note: "AI roadmap")

        XCTAssertEqual(try store.files(matching: "AI").map(\.id), [id])
    }

    func testCreationDateBackfillIsBoundedAndPersistent() throws {
        let firstID = try store.upsertFile(makeFile(path: filePath("first.txt"), title: "First"))
        _ = try store.upsertFile(makeFile(path: filePath("second.txt"), title: "Second"))
        _ = try store.upsertFile(makeFile(path: filePath("third.txt"), title: "Third"))

        let candidates = try store.fileCreationDateBackfillCandidates(limit: 2)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertFalse(candidates.contains(where: { $0.fileID == firstID }))

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try store.saveFileCreationDates([try XCTUnwrap(candidates.first?.fileID): timestamp])
        XCTAssertEqual(try store.fileCreationDates()[candidates[0].path], timestamp)
        XCTAssertFalse(try store.fileCreationDateBackfillCandidates(limit: 3).contains {
            $0.fileID == candidates[0].fileID
        })
    }

    func testStructuredLibraryFilterHonorsCandidateLimit() throws {
        for index in 0..<5 {
            _ = try store.upsertFile(makeFile(
                path: filePath("candidate-\(index).pdf"),
                title: "Candidate \(index)"
            ))
        }

        var filter = LibraryFileMetadataFilter()
        filter.fileExtensions = ["pdf"]
        XCTAssertEqual(try store.libraryFiles(matching: filter, limit: 2).count, 2)
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

    func testLibrarySearchCachePersistsHistoryAndInvalidatesAfterLibraryChange() throws {
        let fileID = try store.upsertFile(makeFile(path: filePath("invoice.pdf"), title: "Invoice"))
        let revision = try store.libraryRevision()
        let payload = Data("cached-results".utf8)

        try store.saveLibrarySearch(
            query: "latest invoice",
            isSmartSearch: false,
            resultCount: 3,
            revision: revision,
            payload: payload,
            recordHistory: true
        )

        let entry = try XCTUnwrap(store.librarySearchHistory().first)
        XCTAssertEqual(entry.query, "latest invoice")
        XCTAssertEqual(entry.resultCount, 3)
        XCTAssertTrue(entry.hasValidCache)
        XCTAssertEqual(
            try store.cachedLibrarySearch(query: "LATEST INVOICE", isSmartSearch: false)?.payload,
            payload
        )

        try store.updateFileNote(id: fileID, note: "Updated note")

        XCTAssertFalse(try XCTUnwrap(store.librarySearchHistory().first).hasValidCache)
    }

    func testAutomaticSearchCacheIsHiddenUntilExplicitlySearched() throws {
        let revision = try store.libraryRevision()
        let payload = Data("cached-results".utf8)
        try store.saveLibrarySearch(
            query: "invoice",
            isSmartSearch: false,
            resultCount: 1,
            revision: revision,
            payload: payload,
            recordHistory: false
        )
        XCTAssertTrue(try store.librarySearchHistory().isEmpty)

        try store.saveLibrarySearch(
            query: "invoice",
            isSmartSearch: false,
            resultCount: 1,
            revision: revision,
            payload: payload,
            recordHistory: true
        )
        XCTAssertEqual(try store.librarySearchHistory().map(\.query), ["invoice"])
    }

    func testFilePathParticipatesInFileLevelSearch() throws {
        let path = temporaryDirectory
            .appendingPathComponent("Client-Aurora", isDirectory: true)
            .appendingPathComponent("brief.pdf")
            .path
        let id = try store.upsertFile(makeFile(path: path, title: "Generic brief"))

        XCTAssertEqual(try store.files(matching: "Aurora").map(\.id), [id])
    }

    func testCombinedFileSearchPreservesShortTermRecallAlongsideFTSMatches() throws {
        var invoice = makeFile(path: filePath("invoice.txt"), title: "Invoice")
        invoice.contentText = "Quarterly invoice reconciliation"
        let invoiceID = try store.upsertFile(invoice)
        let quarterID = try store.upsertFile(makeFile(
            path: filePath("q4-summary.txt"),
            title: "Q4 summary"
        ))

        let matches = try store.files(matchingAny: ["invoice", "Q4"], limit: 20)

        XCTAssertEqual(Set(matches.compactMap(\.id)), Set([invoiceID, quarterID]))
    }

    func testRecentlyOrganizedFilesUsesRootLimitAndMetadataProjection() throws {
        let managedRoot = temporaryDirectory.appendingPathComponent("managed", isDirectory: true)
        var older = makeFile(
            path: managedRoot.appendingPathComponent("older.txt").path,
            title: "Older"
        )
        older.organizedAt = Date(timeIntervalSince1970: 100)
        var newer = makeFile(
            path: managedRoot.appendingPathComponent("newer.txt").path,
            title: "Newer"
        )
        newer.organizedAt = Date(timeIntervalSince1970: 200)
        var outside = makeFile(path: filePath("outside.txt"), title: "Outside")
        outside.organizedAt = Date(timeIntervalSince1970: 300)
        _ = try store.upsertFile(older)
        _ = try store.upsertFile(newer)
        _ = try store.upsertFile(outside)

        let recent = try store.recentlyOrganizedFiles(rootPath: managedRoot.path, limit: 1)

        XCTAssertEqual(recent.map(\.name), ["newer.txt"])
        XCTAssertNil(recent.first?.contentText)
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

        let secondPage = try store.documentChunks(fileID: fileID, limit: 1, offset: 1)
        XCTAssertEqual(secondPage.map(\.index), [2])
        XCTAssertEqual(secondPage.first?.text, "A result table")
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

    func testChatHistoryPagesLoadNewestMessagesFirstWithoutReadingWholeSession() throws {
        let session = try store.createChatSession()
        let sessionID = try XCTUnwrap(session.id)
        for index in 0..<95 {
            _ = try store.addChatMessage(ChatMessage(
                id: nil,
                role: ChatRole.user.rawValue,
                content: "Message \(index)",
                ts: Date(timeIntervalSince1970: TimeInterval(index)),
                relatedFileIds: nil,
                sessionId: sessionID
            ))
        }

        let latest = try store.chatMessagePage(sessionId: sessionID, limit: 40)
        XCTAssertEqual(latest.messages.first?.content, "Message 55")
        XCTAssertEqual(latest.messages.last?.content, "Message 94")
        XCTAssertTrue(latest.hasEarlier)

        let earlier = try store.chatMessagePage(
            sessionId: sessionID,
            beforeID: try XCTUnwrap(latest.messages.first?.id),
            limit: 40
        )
        XCTAssertEqual(earlier.messages.first?.content, "Message 15")
        XCTAssertEqual(earlier.messages.last?.content, "Message 54")
        XCTAssertTrue(earlier.hasEarlier)
    }

    func testOneTimeDataMigrationsDoNotRescanOnEveryStoreOpen() throws {
        let databasePath = temporaryDirectory.appendingPathComponent("test.sqlite").path
        try store.dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO files(
                        path, name, ext, size, mtime, category, source_dir, discovered_at
                    ) VALUES (?, 'late.txt', 'txt', 1, ?, 'Documents', ?, NULL)
                    """,
                arguments: [filePath("late.txt"), Date(), temporaryDirectory.path]
            )
        }

        store = SQLiteStore(path: databasePath)

        let discoveredAt = try store.dbPool.read { db in
            try Date.fetchOne(db, sql: "SELECT discovered_at FROM files WHERE name = 'late.txt'")
        }
        XCTAssertNil(discoveredAt)
        XCTAssertEqual(try store.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM schema_migrations WHERE name = 'files.discovered_at.v1'")
        }, 1)
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
