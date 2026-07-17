import Foundation
import GRDB
import SQLiteVec

/// SQLite storage for metadata in files, rules, and chat plus vectors in embeddings.
final class SQLiteStore {
    static let shared = SQLiteStore()
    private static let resolvedDefaultDatabaseURL = prepareDefaultDatabaseURL()

    let dbPool: DatabasePool
    private let databasePath: String

    init(path: String? = nil) {
        do {
            let url = path.map { URL(fileURLWithPath: $0) } ?? SQLiteStore.databaseURL()
            databasePath = url.path
            var config = Configuration()
            config.prepareDatabase { db in
                guard let connection = db.sqliteConnection,
                      filenest_load_sqlite_vec(connection) == 0 else {
                    throw DatabaseError(message: "Unable to initialize sqlite-vec")
                }
                // WAL mode supports concurrent access.
                try db.execute(sql: "PRAGMA journal_mode=WAL")
                try db.execute(sql: "PRAGMA synchronous=NORMAL")
                try db.execute(sql: "PRAGMA wal_autocheckpoint=1000")
                try db.execute(sql: "PRAGMA journal_size_limit=67108864")
            }
            // The default data directory is writable under App Sandbox.
            dbPool = try DatabasePool(path: url.path, configuration: config)
            try migrate()
        } catch {
            fatalError("SQLiteStore init failed: \(error)")
        }
    }

    static func databaseURL() -> URL {
        resolvedDefaultDatabaseURL
    }

    private static func prepareDefaultDatabaseURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let legacyURL = support.appendingPathComponent("filenest.sqlite")
        let destinationURL = support
            .appendingPathComponent("FileNest", isDirectory: true)
            .appendingPathComponent("filenest.sqlite")

        // The macOS test host initializes the app lifecycle before XCTest cases run.
        // Keep that process completely isolated from the user's live database.
        if ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("XCTest") }) {
            let testDirectory = fm.temporaryDirectory.appendingPathComponent(
                "FileNestTests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            try? fm.createDirectory(at: testDirectory, withIntermediateDirectories: true)
            return testDirectory.appendingPathComponent("filenest.sqlite")
        }

        let hadLegacyDatabase = fm.fileExists(atPath: legacyURL.path)
        do {
            let resolved = try migrateLegacyDatabaseIfNeeded(
                legacyURL: legacyURL,
                destinationURL: destinationURL
            )
            if resolved == destinationURL, !fm.fileExists(atPath: legacyURL.path) {
                AppLogService.shared.write(
                    hadLegacyDatabase ? "database location migrated" : "database location ready",
                    category: .appConfiguration,
                    metadata: ["location": "FileNest/filenest.sqlite"]
                )
            }
            return resolved
        } catch {
            AppLogService.shared.write(
                "database location migration deferred: \(error.localizedDescription)",
                category: .appConfiguration,
                level: .warning
            )
            return fm.fileExists(atPath: legacyURL.path) ? legacyURL : destinationURL
        }
    }

    /// Moves the legacy root-level database only after WAL is fully checkpointed,
    /// the database passes quick_check, and no other SQLite connection remains.
    @discardableResult
    static func migrateLegacyDatabaseIfNeeded(legacyURL: URL,
                                              destinationURL: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let destinationSize = try fileSizeIfPresent(at: destinationURL)
        if let destinationSize, destinationSize > 0 { return destinationURL }
        guard fm.fileExists(atPath: legacyURL.path) else { return destinationURL }

        var legacyQueue: DatabaseQueue? = try DatabaseQueue(path: legacyURL.path)
        try legacyQueue?.writeWithoutTransaction { db in
            guard let row = try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") else {
                throw DatabaseLocationMigrationError.checkpointFailed
            }
            let busy: Int = row[0]
            guard busy == 0 else { throw DatabaseLocationMigrationError.databaseInUse }
            let check = try String.fetchOne(db, sql: "PRAGMA quick_check")
            guard check == "ok" else {
                throw DatabaseLocationMigrationError.integrityCheckFailed(check ?? "unknown")
            }
            // Leaving WAL mode requires SQLite's exclusive database lock. This is
            // the authoritative in-process/cross-process occupancy check and also
            // removes the checkpointed WAL/SHM files before the main file moves.
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode=DELETE")
            guard journalMode?.lowercased() == "delete" else {
                throw DatabaseLocationMigrationError.journalModeSwitchFailed(journalMode)
            }
        }
        legacyQueue = nil

        let legacyWAL = URL(fileURLWithPath: legacyURL.path + "-wal")
        let legacySHM = URL(fileURLWithPath: legacyURL.path + "-shm")
        guard !fm.fileExists(atPath: legacyWAL.path) else {
            throw DatabaseLocationMigrationError.companionFilesRemain(
                walSize: try fileSizeIfPresent(at: legacyWAL),
                shmSize: try fileSizeIfPresent(at: legacySHM)
            )
        }
        // SQLite may leave an empty/obsolete SHM inode after a successful
        // exclusive switch to DELETE mode. It contains no database pages and
        // is safe to remove now that WAL mode is no longer active.
        if fm.fileExists(atPath: legacySHM.path) {
            try fm.removeItem(at: legacySHM)
        }

        if destinationSize == 0 { try fm.removeItem(at: destinationURL) }
        try fm.moveItem(at: legacyURL, to: destinationURL)
        return destinationURL
    }

    private static func fileSizeIfPresent(at url: URL) throws -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Schema and Migrations
    private func migrate() throws {
        try dbPool.write { db in
            try db.create(table: "files", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull()
                t.column("name", .text).notNull()
                t.column("ext", .text).notNull()
                t.column("size", .integer).notNull()
                t.column("mtime", .datetime).notNull()
                t.column("category", .text).notNull()
                t.column("source_dir", .text).notNull()
                t.column("indexed_at", .datetime)
                t.column("content_hash", .text)
                t.column("title", .text)
                t.column("content_text", .text)
                t.column("discovered_at", .datetime)
                t.column("organized_at", .datetime)
                t.column("note", .text)
                t.column("organization_subfolder", .text)
                t.column("is_directory", .boolean).notNull().defaults(to: false)
                t.column("index_signature", .text)
            }
            try db.create(index: "idx_files_path", on: "files", columns: ["path"], unique: true, ifNotExists: true)
            try db.create(index: "idx_files_category", on: "files", columns: ["category"], ifNotExists: true)
            let fileColumns = try db.columns(in: "files").map(\.name)
            if !fileColumns.contains("discovered_at") {
                try db.execute(sql: "ALTER TABLE files ADD COLUMN discovered_at DATETIME")
            }
            if !fileColumns.contains("organized_at") {
                try db.execute(sql: "ALTER TABLE files ADD COLUMN organized_at DATETIME")
            }
            if !fileColumns.contains("note") {
                try db.execute(sql: "ALTER TABLE files ADD COLUMN note TEXT")
            }
            if !fileColumns.contains("organization_subfolder") {
                try db.execute(sql: "ALTER TABLE files ADD COLUMN organization_subfolder TEXT")
            }
            if !fileColumns.contains("is_directory") {
                try db.execute(sql: "ALTER TABLE files ADD COLUMN is_directory BOOLEAN NOT NULL DEFAULT 0")
            }
            if !fileColumns.contains("index_signature") {
                try db.execute(sql: "ALTER TABLE files ADD COLUMN index_signature TEXT")
            }
            try db.execute(sql: "UPDATE files SET discovered_at = COALESCE(discovered_at, indexed_at, mtime) WHERE discovered_at IS NULL")
            try db.create(index: "idx_files_discovered", on: "files", columns: ["discovered_at"], ifNotExists: true)
            try db.create(index: "idx_files_organized", on: "files", columns: ["organized_at"], ifNotExists: true)

            try db.create(table: "embeddings", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file_id", .integer).notNull().references("files", onDelete: .cascade)
                t.column("vector", .blob).notNull()
                t.column("dim", .integer).notNull()
                t.column("model", .text).notNull()
                t.column("chunk_idx", .integer).notNull().defaults(to: 0)
                t.column("chunk_text", .text)
            }
            try db.create(index: "idx_emb_file", on: "embeddings", columns: ["file_id"], ifNotExists: true)

            try db.create(table: "document_chunks", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file_id", .integer).notNull().references("files", onDelete: .cascade)
                t.column("chunk_idx", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("contextual_text", .text).notNull()
                t.column("section_path", .text).notNull().defaults(to: "[]")
                t.column("page_start", .integer)
                t.column("page_end", .integer)
                t.column("kind", .text).notNull().defaults(to: DocumentChunkKind.text.rawValue)
                t.uniqueKey(["file_id", "chunk_idx"])
            }
            try db.create(index: "idx_chunks_file", on: "document_chunks", columns: ["file_id", "chunk_idx"], ifNotExists: true)
            try db.execute(sql: """
                INSERT OR IGNORE INTO document_chunks(
                    file_id, chunk_idx, text, contextual_text, section_path, kind
                )
                SELECT file_id, chunk_idx, COALESCE(chunk_text, ''), COALESCE(chunk_text, ''), '[]', 'text'
                FROM embeddings
                WHERE chunk_text IS NOT NULL
                """)

            try db.create(table: "rules", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("pattern", .text).notNull()
                t.column("target_folder", .text).notNull()
                t.column("priority", .integer).notNull().defaults(to: 0)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("action", .text).notNull().defaults(to: RuleAction.organize.rawValue)
            }
            let ruleColumns = try db.columns(in: "rules").map(\.name)
            if !ruleColumns.contains("action") {
                try db.execute(sql: "ALTER TABLE rules ADD COLUMN action TEXT NOT NULL DEFAULT 'organize'")
            }

            try db.create(table: "chat_messages", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("ts", .datetime).notNull()
                t.column("related_file_ids", .text)
            }

            try db.create(table: "chat_sessions", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("attached_file_path", .text)
            }

            let chatColumns = try db.columns(in: "chat_messages").map(\.name)
            if !chatColumns.contains("session_id") {
                try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN session_id INTEGER")
            }
            if !chatColumns.contains("input_tokens") {
                try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN input_tokens INTEGER")
            }
            if !chatColumns.contains("output_tokens") {
                try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN output_tokens INTEGER")
            }
            if !chatColumns.contains("first_response_duration") {
                try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN first_response_duration DOUBLE")
            }
            if !chatColumns.contains("total_response_duration") {
                try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN total_response_duration DOUBLE")
            }
            if !chatColumns.contains("response_provider") {
                try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN response_provider TEXT")
            }
            if !chatColumns.contains("response_model") {
                try db.execute(sql: "ALTER TABLE chat_messages ADD COLUMN response_model TEXT")
            }
            try db.create(
                index: "idx_chat_messages_session",
                on: "chat_messages",
                columns: ["session_id", "ts"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_chat_sessions_updated",
                on: "chat_sessions",
                columns: ["updated_at"],
                ifNotExists: true
            )

            try db.create(table: "settings", ifNotExists: true) { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }

            // When the user keeps existing files in place, record the folder's direct children at that time.
            // Persist the baseline by path so restarts continue to process only later additions.
            try db.create(table: "watch_directory_baseline_entries", ifNotExists: true) { t in
                t.column("directory_path", .text).notNull()
                t.column("entry_path", .text).notNull()
                t.primaryKey(["directory_path", "entry_path"])
            }
            try db.create(
                index: "idx_watch_baseline_directory",
                on: "watch_directory_baseline_entries",
                columns: ["directory_path"],
                ifNotExists: true
            )

            try db.create(table: "token_usage", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .datetime).notNull()
                t.column("provider", .text).notNull()
                t.column("model", .text).notNull()
                t.column("input_tokens", .integer).notNull()
                t.column("output_tokens", .integer).notNull()
                t.column("session_id", .integer)
            }
            try db.create(index: "idx_token_usage_ts", on: "token_usage", columns: ["ts"], ifNotExists: true)
        }
    }

    // MARK: - files CRUD
    func upsertFile(_ record: FileRecord) throws -> Int64 {
        try dbPool.write { db in
            try Self.upsertFile(record, in: db)
        }
    }

    /// Applies a managed-library reconciliation in one transaction. Stable files are
    /// intentionally omitted by the caller, so large scans do not rewrite every row.
    func applyManagedFileChanges(
        upserts: [FileRecord],
        staleFileIDs: Set<Int64>
    ) throws {
        guard !upserts.isEmpty || !staleFileIDs.isEmpty else { return }
        try dbPool.write { db in
            for record in upserts {
                _ = try Self.upsertFile(record, in: db)
            }
            for id in staleFileIDs {
                try db.execute(
                    sql: "UPDATE files SET indexed_at = NULL, index_signature = NULL WHERE id = ?",
                    arguments: [id]
                )
            }
        }
    }

    private static func upsertFile(_ record: FileRecord, in db: Database) throws -> Int64 {
        // Stored records may change path after organization, so update by ID first.
        if let id = record.id,
           let existing = try FileRecord.fetchOne(db, key: id) {
            var updated = record
            updated.discoveredAt = updated.discoveredAt ?? existing.discoveredAt ?? Date()
            updated.organizedAt = updated.organizedAt ?? existing.organizedAt
            updated.note = updated.note ?? existing.note
            updated.organizationSubfolder = updated.organizationSubfolder ?? existing.organizationSubfolder
            updated.indexSignature = updated.indexSignature ?? existing.indexSignature
            try updated.update(db)
            return id
        }

        // Newly discovered files are unique by path; update an existing record.
        if let existing = try FileRecord.fetchOne(
            db,
            sql: "SELECT * FROM files WHERE path = ?",
            arguments: [record.path]
        ) {
            var updated = record
            updated.id = existing.id
            updated.discoveredAt = updated.discoveredAt ?? existing.discoveredAt ?? Date()
            updated.organizedAt = updated.organizedAt ?? existing.organizedAt
            updated.note = updated.note ?? existing.note
            updated.organizationSubfolder = updated.organizationSubfolder ?? existing.organizationSubfolder
            updated.indexSignature = updated.indexSignature ?? existing.indexSignature
            try updated.update(db)
            return updated.id!
        }

        var inserted = record
        inserted.id = nil
        inserted.discoveredAt = inserted.discoveredAt ?? Date()
        try inserted.insert(db)
        return inserted.id!
    }

    func allFiles() throws -> [FileRecord] {
        try dbPool.read { db in
            try FileRecord.fetchAll(
                db,
                sql: "SELECT * FROM files ORDER BY COALESCE(discovered_at, organized_at, indexed_at, mtime) DESC, name COLLATE NOCASE ASC"
            )
        }
    }

    func file(id: Int64) throws -> FileRecord? {
        try dbPool.read { db in
            try FileRecord.fetchOne(
                db,
                sql: "SELECT * FROM files WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func file(path: String) throws -> FileRecord? {
        try dbPool.read { db in
            if let exact = try FileRecord.fetchOne(
                db,
                sql: "SELECT * FROM files WHERE path = ?",
                arguments: [path]
            ) {
                return exact
            }
            // macOS may represent the same temporary folder as /var/... or /private/var/....
            // Fall back to normalized paths only after an exact miss, avoiding duplicates and missed existing indexes.
            let canonical = URL(fileURLWithPath: path)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            return try FileRecord.fetchAll(db).first { record in
                URL(fileURLWithPath: record.path)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL.path == canonical
            }
        }
    }

    func files(matching keyword: String) throws -> [FileRecord] {
        try dbPool.read { db in
            let escapedKeyword = keyword
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            let pattern = "%\(escapedKeyword)%"
            return try FileRecord.fetchAll(
                db,
                sql: "SELECT * FROM files WHERE name LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\' OR content_text LIKE ? ESCAPE '\\' OR note LIKE ? ESCAPE '\\' OR path LIKE ? ESCAPE '\\' ORDER BY COALESCE(discovered_at, organized_at, indexed_at, mtime) DESC, name COLLATE NOCASE ASC LIMIT 200",
                arguments: [pattern, pattern, pattern, pattern, pattern]
            )
        }
    }

    func documentChunks(fileID: Int64) throws -> [IndexedDocumentChunk] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT chunk_idx, text, contextual_text, section_path,
                           page_start, page_end, kind
                    FROM document_chunks
                    WHERE file_id = ?
                    ORDER BY chunk_idx
                    """,
                arguments: [fileID]
            )
            return rows.map { row in
                let sectionJSON = (row["section_path"] as String?) ?? "[]"
                let sectionPath = (try? JSONDecoder().decode(
                    [String].self,
                    from: Data(sectionJSON.utf8)
                )) ?? []
                let text = (row["text"] as String?) ?? ""
                return IndexedDocumentChunk(
                    index: row["chunk_idx"],
                    text: text,
                    contextualText: (row["contextual_text"] as String?) ?? text,
                    sectionPath: sectionPath,
                    pageStart: row["page_start"],
                    pageEnd: row["page_end"],
                    kind: DocumentChunkKind(rawValue: (row["kind"] as String?) ?? "") ?? .text
                )
            }
        }
    }

    func updateFileNote(id: Int64, note: String?) throws {
        try dbPool.write { db in
            try db.execute(
                // Editing a note does not invalidate extracted source content. The note vector
                // is updated independently by IndexerService without rerunning Docling/OCR.
                sql: "UPDATE files SET note = ? WHERE id = ?",
                arguments: [note, id]
            )
        }
    }

    /// Marks the file index as stale while keeping the last successful content hash
    /// available for incremental verification. The next index pass replaces its chunks
    /// and vectors atomically.
    func markFileIndexStale(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE files SET indexed_at = NULL, index_signature = NULL WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func deleteFile(id: Int64) throws {
        try dbPool.write { db in
            let embeddingIDs = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM embeddings WHERE file_id = ?",
                arguments: [id]
            )
            let hasVectorTable = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name = 'vec_embeddings')"
            ) ?? false
            if hasVectorTable {
                for embeddingID in embeddingIDs {
                    try db.execute(
                        sql: "DELETE FROM vec_embeddings WHERE rowid = ?",
                        arguments: [embeddingID]
                    )
                }
            }
            _ = try FileRecord.deleteOne(db, key: id)
        }
    }

    /// Removes Office lock files, incomplete downloads, and editor temporary files mistakenly imported by older versions.
    @discardableResult
    func removeTransientFiles(preservingRoot: URL? = nil) throws -> Int {
        try dbPool.write { db in
            let records = try FileRecord.fetchAll(db)
            let preservedPath = preservingRoot?.standardizedFileURL.path
            let ids = records.filter { record in
                guard FileEligibilityPolicy.shouldIgnoreFile(named: record.name) else { return false }
                guard let preservedPath else { return true }
                let path = URL(fileURLWithPath: record.path).standardizedFileURL.path
                return !path.hasPrefix(preservedPath + "/")
            }.compactMap(\.id)
            guard !ids.isEmpty else { return 0 }
            for id in ids { _ = try FileRecord.deleteOne(db, key: id) }
            return ids.count
        }
    }

    // MARK: - statistics

    func recordTokenUsage(_ usage: TokenUsageRecord) throws {
        try dbPool.write { db in
            var value = usage
            value.id = nil
            try value.insert(db)
        }
    }

    func statistics(days: Int = 14) throws -> AppStatistics {
        let safeDays = max(1, days)
        let files = try allFiles()
        let usages = try dbPool.read { db in
            try TokenUsageRecord.order(Column("ts")).fetchAll(db)
        }
        let vectorBytes = try dbPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(length(vector)), 0) FROM embeddings") ?? 0
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let daysList = (0..<safeDays).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        var addedByDay: [Date: Int] = [:]
        var indexedByDay: [Date: Int] = [:]
        var tokensByDay: [Date: Int] = [:]

        for file in files {
            let discovered = calendar.startOfDay(for: file.discoveredAt ?? file.indexedAt ?? file.mtime)
            addedByDay[discovered, default: 0] += 1
            if let indexedAt = file.indexedAt {
                indexedByDay[calendar.startOfDay(for: indexedAt), default: 0] += 1
            }
        }
        for usage in usages {
            let day = calendar.startOfDay(for: usage.ts)
            tokensByDay[day, default: 0] += usage.inputTokens + usage.outputTokens
        }

        let daily = daysList.map { day in
            DailyActivityStat(
                day: day,
                addedFiles: addedByDay[day, default: 0],
                indexedFiles: indexedByDay[day, default: 0],
                tokens: tokensByDay[day, default: 0]
            )
        }
        let categories = Dictionary(grouping: files, by: \.categoryEnum)
            .map { category, values in
                CategoryStorageStat(
                    category: category,
                    bytes: values.reduce(0) { $0 + max(0, $1.size) },
                    fileCount: values.count
                )
            }
            .sorted { $0.bytes > $1.bytes }

        return AppStatistics(
            totalFiles: files.count,
            indexedFiles: files.filter { $0.indexedAt != nil }.count,
            todayAddedFiles: addedByDay[today, default: 0],
            totalTokens: usages.reduce(0) { $0 + $1.inputTokens + $1.outputTokens },
            todayTokens: tokensByDay[today, default: 0],
            managedFileBytes: files.reduce(0) { $0 + max(0, $1.size) },
            databaseBytes: databaseStorageBytes(),
            vectorBytes: vectorBytes,
            extractedTextBytes: files.reduce(0) { $0 + Int64($1.contentText?.utf8.count ?? 0) },
            localModelBytes: directorySize(
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models")
            ),
            dailyActivity: daily,
            categoryStorage: categories
        )
    }

    private func databaseStorageBytes() -> Int64 {
        [databasePath, databasePath + "-wal", databasePath + "-shm"].reduce(0) { total, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            return total + size
        }
    }

    private func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    // MARK: - rules CRUD
    func allRules() throws -> [Rule] {
        try dbPool.read { db in
            try Rule.order(Column("priority").desc, Column("id")).fetchAll(db)
        }
    }

    func upsertRule(_ rule: Rule) throws -> Int64 {
        try dbPool.write { db in
            if let id = rule.id {
                let r = rule
                try r.update(db, columns: ["name", "type", "pattern", "target_folder", "priority", "enabled", "action"])
                return id
            } else {
                var r = rule
                try r.insert(db)
                return r.id!
            }
        }
    }

    func deleteRule(id: Int64) throws {
        try dbPool.write { db in
            _ = try Rule.deleteOne(db, key: id)
        }
    }

    /// Default rules inserted on first launch; legacy built-in localized rules migrate safely by exact value.
    func seedDefaultRulesIfNeeded() throws {
        let seed: [(name: String, pattern: String, folder: String)] = [
            ("Documents (pdf/doc/md…)", "pdf,doc,docx,txt,md,rtf,xls,xlsx,ppt,pptx,csv,epub", "Documents"),
            ("Images (png/jpg…)", "png,jpg,jpeg,gif,heic,tiff,bmp,svg,webp,psd,sketch", "Images"),
            ("Videos (mp4/mov…)", "mp4,mov,avi,mkv,m4v,wmv,flv,webm", "Videos"),
            ("Audio (mp3/wav…)", "mp3,wav,aac,flac,m4a,ogg,aiff", "Audio"),
            ("Code (swift/py/js…)", "swift,py,js,ts,tsx,jsx,java,kt,go,rs,c,cpp,h,cs,rb,php,sh,sql,json,yaml,yml,html,css", "Code"),
            ("Archives (zip/dmg…)", "zip,rar,7z,tar,gz,bz2,xz,dmg,iso", "Archives"),
        ]
        try dbPool.write { db in
            let legacy = [
                ("Documents (pdf/doc/md…)", "Documents"),
                ("Images (png/jpg…)", "Images"),
                ("Videos (mp4/mov…)", "Videos"),
                ("Audio (mp3/wav…)", "Audio"),
                ("Code (swift/py/js…)", "Code"),
                ("Archives (zip/dmg…)", "Archives"),
            ]
            for (index, current) in seed.enumerated() {
                try db.execute(
                    sql: """
                        UPDATE rules SET name = ?, target_folder = ?
                        WHERE name = ? AND pattern = ? AND target_folder = ?
                        """,
                    arguments: [
                        current.name, current.folder,
                        legacy[index].0, current.pattern, legacy[index].1,
                    ]
                )
            }
            try db.execute(
                sql: """
                    UPDATE rules SET pattern = ?
                    WHERE name = ? AND action = ? AND pattern = ?
                    """,
                arguments: [
                    "dmg,pkg,mpkg,app,iso,xip",
                    "Installers (keep in place)",
                    RuleAction.ignore.rawValue,
                    "dmg,pkg,mpkg,app,iso",
                ]
            )

            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rules") ?? 0
            if count == 0 {
                for (i, item) in seed.enumerated() {
                    var r = Rule(id: nil, name: item.name, type: "rule", pattern: item.pattern,
                                 targetFolder: item.folder, priority: seed.count - i, enabled: true)
                    try r.insert(db)
                }
            }

            let installerSeedKey = "rules.default.installers-ignore.seeded"
            let installerWasSeeded = try String.fetchOne(
                db,
                sql: "SELECT value FROM settings WHERE key = ?",
                arguments: [installerSeedKey]
            ) == "1"
            if !installerWasSeeded {
                let alreadyExists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM rules WHERE action = ? AND pattern = ?)",
                    arguments: [RuleAction.ignore.rawValue, "dmg,pkg,mpkg,app,iso,xip"]
                ) ?? false
                if !alreadyExists {
                    var installerRule = Rule(
                        id: nil,
                        name: "Installers (keep in place)",
                        type: RuleType.rule.rawValue,
                        pattern: "dmg,pkg,mpkg,app,iso,xip",
                        targetFolder: "Ignored",
                        priority: 100,
                        enabled: true,
                        action: RuleAction.ignore.rawValue
                    )
                    try installerRule.insert(db)
                }
                try db.execute(
                    sql: "INSERT INTO settings(key, value) VALUES(?, '1') ON CONFLICT(key) DO UPDATE SET value='1'",
                    arguments: [installerSeedKey]
                )
            }
        }
    }

    // MARK: - chat sessions / messages
    func migrateLegacyChatMessagesIfNeeded() throws {
        try dbPool.write { db in
            let legacyMessageCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM chat_messages WHERE session_id IS NULL"
            ) ?? 0
            guard legacyMessageCount > 0 else { return }

            let sessionID: Int64
            if let existing = try ChatSession.order(Column("updated_at").desc).fetchOne(db)?.id {
                sessionID = existing
            } else {
                let now = Date()
                var session = ChatSession(
                    id: nil,
                    title: "New Chat",
                    createdAt: now,
                    updatedAt: now,
                    attachedFilePath: nil
                )
                try session.insert(db)
                guard let id = session.id else { return }
                sessionID = id
            }
            try db.execute(
                sql: "UPDATE chat_messages SET session_id = ? WHERE session_id IS NULL",
                arguments: [sessionID]
            )
        }
    }

    func allChatSessions() throws -> [ChatSession] {
        try dbPool.read { db in
            try ChatSession
                .order(Column("updated_at").desc, Column("id").desc)
                .fetchAll(db)
        }
    }

    func createChatSession(attachedFilePath: String? = nil) throws -> ChatSession {
        try dbPool.write { db in
            let now = Date()
            var session = ChatSession(
                id: nil,
                title: attachedFilePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "New Chat",
                createdAt: now,
                updatedAt: now,
                attachedFilePath: attachedFilePath
            )
            try session.insert(db)
            return session
        }
    }

    func updateChatSession(_ session: ChatSession) throws {
        try dbPool.write { db in
            try session.update(db, columns: ["title", "updated_at", "attached_file_path"])
        }
    }

    func deleteChatSession(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM chat_messages WHERE session_id = ?", arguments: [id])
            _ = try ChatSession.deleteOne(db, key: id)
        }
    }

    func deleteEmptyChatSessions() throws {
        try dbPool.write { db in
            try db.execute(sql: """
                DELETE FROM chat_sessions
                WHERE NOT EXISTS (
                    SELECT 1 FROM chat_messages
                    WHERE chat_messages.session_id = chat_sessions.id
                )
                """)
        }
    }

    func allChatMessages() throws -> [ChatMessage] {
        try dbPool.read { db in
            try ChatMessage.order(Column("ts")).fetchAll(db)
        }
    }

    func chatMessages(sessionId: Int64) throws -> [ChatMessage] {
        try dbPool.read { db in
            try ChatMessage
                .filter(Column("session_id") == sessionId)
                .order(Column("ts"), Column("id"))
                .fetchAll(db)
        }
    }

    func addChatMessage(_ msg: ChatMessage) throws -> Int64 {
        try dbPool.write { db in
            var m = msg
            try m.insert(db)
            return m.id!
        }
    }

    func updateChatMessage(_ message: ChatMessage) throws {
        guard message.id != nil else { return }
        try dbPool.write { db in
            try message.update(db, columns: [
                "role", "content", "ts", "related_file_ids", "session_id",
                "input_tokens", "output_tokens", "first_response_duration",
                "total_response_duration", "response_provider", "response_model",
            ])
        }
    }

    func clearAllChats() throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM chat_messages")
            try db.execute(sql: "DELETE FROM chat_sessions")
        }
    }

    // MARK: - settings (k/v)
    func getSetting(_ key: String) -> String? {
        try? dbPool.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM settings WHERE key = ?",
                arguments: [key]
            )
        }
    }

    func setSetting(_ key: String, _ value: String) {
        _ = try? dbPool.write { db in
            try db.execute(
                sql: "INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                arguments: [key, value]
            )
        }
    }

    // MARK: - watch directory baselines

    func replaceWatchDirectoryBaseline(directoryPath: String, entryPaths: Set<String>) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM watch_directory_baseline_entries WHERE directory_path = ?",
                arguments: [directoryPath]
            )
            for entryPath in entryPaths {
                try db.execute(
                    sql: "INSERT INTO watch_directory_baseline_entries(directory_path, entry_path) VALUES(?, ?)",
                    arguments: [directoryPath, entryPath]
                )
            }
        }
    }

    func isWatchDirectoryBaselineEntry(directoryPath: String, entryPath: String) -> Bool {
        (try? dbPool.read { db in
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT EXISTS(
                        SELECT 1 FROM watch_directory_baseline_entries
                        WHERE directory_path = ? AND entry_path = ?
                    )
                    """,
                arguments: [directoryPath, entryPath]
            ) ?? false
        }) ?? false
    }

    func retainWatchDirectoryBaselineEntries(
        directoryPath: String,
        existingEntryPaths: Set<String>
    ) throws {
        try dbPool.write { db in
            let storedPaths = try String.fetchAll(
                db,
                sql: "SELECT entry_path FROM watch_directory_baseline_entries WHERE directory_path = ?",
                arguments: [directoryPath]
            )
            for path in storedPaths where !existingEntryPaths.contains(path) {
                try db.execute(
                    sql: "DELETE FROM watch_directory_baseline_entries WHERE directory_path = ? AND entry_path = ?",
                    arguments: [directoryPath, path]
                )
            }
        }
    }

    func clearWatchDirectoryBaselines(directoryPaths: [String]) throws {
        guard !directoryPaths.isEmpty else { return }
        try dbPool.write { db in
            for directoryPath in directoryPaths {
                try db.execute(
                    sql: "DELETE FROM watch_directory_baseline_entries WHERE directory_path = ?",
                    arguments: [directoryPath]
                )
            }
        }
    }

    func distinctEmbeddingModels() throws -> Set<String> {
        try dbPool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT model FROM embeddings"))
        }
    }

    func allStoredDocumentChunks() throws -> [Int64: [StructuredDocumentChunk]] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT file_id, text, contextual_text, section_path,
                           page_start, page_end, kind
                    FROM document_chunks
                    ORDER BY file_id, chunk_idx
                    """
            )
            var result = [Int64: [StructuredDocumentChunk]]()
            for row in rows {
                let sectionJSON = (row["section_path"] as String?) ?? "[]"
                let sectionPath = (try? JSONDecoder().decode(
                    [String].self,
                    from: Data(sectionJSON.utf8)
                )) ?? []
                let chunk = StructuredDocumentChunk(
                    text: (row["text"] as String?) ?? "",
                    contextualText: row["contextual_text"] as String?,
                    sectionPath: sectionPath,
                    pageStart: row["page_start"],
                    pageEnd: row["page_end"],
                    kind: DocumentChunkKind(rawValue: (row["kind"] as String?) ?? "") ?? .text
                )
                result[row["file_id"], default: []].append(chunk)
            }
            return result
        }
    }

    /// Legacy file signatures mixed chunking, OCR, and model profile data. After confirming the vector model is unchanged, migrate them in place to vector-space-only signatures.
    func migrateIndexedFileSignatures(to signature: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE files SET index_signature = ? WHERE indexed_at IS NOT NULL",
                arguments: [signature]
            )
        }
    }
}

private enum DatabaseLocationMigrationError: LocalizedError {
    case checkpointFailed
    case databaseInUse
    case journalModeSwitchFailed(String?)
    case companionFilesRemain(walSize: Int64?, shmSize: Int64?)
    case integrityCheckFailed(String)

    var errorDescription: String? {
        switch self {
        case .checkpointFailed:
            return "Unable to complete the legacy database WAL checkpoint"
        case .databaseInUse:
            return "The legacy database is still in use by another process"
        case let .journalModeSwitchFailed(mode):
            return "The legacy database could not leave WAL mode (current mode: \(mode ?? "unknown")）"
        case let .companionFilesRemain(walSize, shmSize):
            return "Legacy database shared files still exist (WAL: \(walSize ?? -1) bytes, SHM: \(shmSize ?? -1) bytes)"
        case let .integrityCheckFailed(detail):
            return "Legacy database integrity check failed: \(detail)"
        }
    }
}
