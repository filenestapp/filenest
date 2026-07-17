import Foundation
import GRDB
import SQLiteVec

/// SQLite storage for metadata in files, rules, and chat plus vectors in embeddings.
final class SQLiteStore: @unchecked Sendable {
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

            try db.create(table: "library_revision", ifNotExists: true) { t in
                t.primaryKey("id", .integer)
                t.column("revision", .integer).notNull().defaults(to: 0)
            }
            try db.execute(sql: "INSERT OR IGNORE INTO library_revision(id, revision) VALUES(1, 0)")
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS library_revision_insert AFTER INSERT ON files BEGIN
                    UPDATE library_revision SET revision = revision + 1 WHERE id = 1;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS library_revision_update AFTER UPDATE ON files BEGIN
                    UPDATE library_revision SET revision = revision + 1 WHERE id = 1;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS library_revision_delete AFTER DELETE ON files BEGIN
                    UPDATE library_revision SET revision = revision + 1 WHERE id = 1;
                END
                """)

            try db.create(table: "library_search_history", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("query", .text).notNull()
                t.column("normalized_query", .text).notNull()
                t.column("search_mode", .text).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("result_count", .integer).notNull()
                t.column("library_revision", .integer).notNull()
                t.column("payload", .blob).notNull()
                t.column("is_history", .boolean).notNull().defaults(to: true)
                t.uniqueKey(["normalized_query", "search_mode"])
            }
            let searchHistoryColumns = try db.columns(in: "library_search_history").map(\.name)
            if !searchHistoryColumns.contains("is_history") {
                try db.execute(sql: "ALTER TABLE library_search_history ADD COLUMN is_history BOOLEAN NOT NULL DEFAULT 1")
            }
            try db.create(
                index: "idx_library_search_history_updated",
                on: "library_search_history",
                columns: ["updated_at"],
                ifNotExists: true
            )

            try db.create(table: "rag_search_traces", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("created_at", .datetime).notNull()
                t.column("query", .text).notNull()
                t.column("semantic_query", .text).notNull()
                t.column("lexical_candidates", .integer).notNull()
                t.column("semantic_candidates", .integer).notNull()
                t.column("entity_candidates", .integer).notNull()
                t.column("fused_candidates", .integer).notNull()
                t.column("returned_results", .integer).notNull()
                t.column("semantic_threshold", .double)
                t.column("reranker", .text)
                t.column("duration_ms", .double).notNull()
            }
            try db.create(index: "idx_rag_traces_created", on: "rag_search_traces", columns: ["created_at"], ifNotExists: true)

            let shouldBuildSearchIndex = try !db.tableExists("files_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
                    name,
                    title,
                    content_text,
                    note,
                    path,
                    content='files',
                    content_rowid='id',
                    tokenize='trigram'
                )
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS files_fts_insert AFTER INSERT ON files BEGIN
                    INSERT INTO files_fts(rowid, name, title, content_text, note, path)
                    VALUES (new.id, new.name, new.title, new.content_text, new.note, new.path);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS files_fts_delete AFTER DELETE ON files BEGIN
                    INSERT INTO files_fts(files_fts, rowid, name, title, content_text, note, path)
                    VALUES ('delete', old.id, old.name, old.title, old.content_text, old.note, old.path);
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS files_fts_update AFTER UPDATE ON files BEGIN
                    INSERT INTO files_fts(files_fts, rowid, name, title, content_text, note, path)
                    VALUES ('delete', old.id, old.name, old.title, old.content_text, old.note, old.path);
                    INSERT INTO files_fts(rowid, name, title, content_text, note, path)
                    VALUES (new.id, new.name, new.title, new.content_text, new.note, new.path);
                END
                """)
            if shouldBuildSearchIndex {
                try db.execute(sql: "INSERT INTO files_fts(files_fts) VALUES('rebuild')")
            }

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
                t.column("parent_idx", .integer)
                t.column("token_count", .integer).notNull().defaults(to: 0)
                t.column("tokenizer_profile", .text).notNull().defaults(to: TokenCounter.canonicalProfile)
                t.column("tokenizer_version", .text).notNull().defaults(to: TokenCounter.canonicalVersion)
                t.column("token_count_accuracy", .text).notNull().defaults(to: TokenCountAccuracy.estimated.rawValue)
                t.column("entity_terms", .text).notNull().defaults(to: "[]")
                t.uniqueKey(["file_id", "chunk_idx"])
            }
            let chunkColumns = try db.columns(in: "document_chunks").map(\.name)
            if !chunkColumns.contains("parent_idx") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN parent_idx INTEGER")
            }
            if !chunkColumns.contains("token_count") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN token_count INTEGER NOT NULL DEFAULT 0")
            }
            if !chunkColumns.contains("tokenizer_profile") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN tokenizer_profile TEXT NOT NULL DEFAULT '\(TokenCounter.canonicalProfile)'")
            }
            if !chunkColumns.contains("tokenizer_version") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN tokenizer_version TEXT NOT NULL DEFAULT '\(TokenCounter.canonicalVersion)'")
            }
            if !chunkColumns.contains("token_count_accuracy") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN token_count_accuracy TEXT NOT NULL DEFAULT 'estimated'")
            }
            if !chunkColumns.contains("entity_terms") {
                try db.execute(sql: "ALTER TABLE document_chunks ADD COLUMN entity_terms TEXT NOT NULL DEFAULT '[]'")
            }
            try db.create(index: "idx_chunks_file", on: "document_chunks", columns: ["file_id", "chunk_idx"], ifNotExists: true)
            try db.create(index: "idx_chunks_parent", on: "document_chunks", columns: ["file_id", "parent_idx"], ifNotExists: true)
            try db.execute(sql: """
                INSERT OR IGNORE INTO document_chunks(
                    file_id, chunk_idx, text, contextual_text, section_path, kind
                )
                SELECT file_id, chunk_idx, COALESCE(chunk_text, ''), COALESCE(chunk_text, ''), '[]', 'text'
                FROM embeddings
                WHERE chunk_text IS NOT NULL
                """)
            try db.execute(sql: "UPDATE document_chunks SET parent_idx = chunk_idx WHERE parent_idx IS NULL")

            let hadDocumentParents = try db.tableExists("document_parents")
            try db.create(table: "document_parents", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("file_id", .integer).notNull().references("files", onDelete: .cascade)
                t.column("parent_idx", .integer).notNull()
                t.column("text", .text).notNull()
                t.column("contextual_text", .text).notNull()
                t.column("section_path", .text).notNull().defaults(to: "[]")
                t.column("page_start", .integer)
                t.column("page_end", .integer)
                t.column("kind", .text).notNull().defaults(to: DocumentChunkKind.text.rawValue)
                t.column("token_count", .integer).notNull().defaults(to: 0)
                t.column("tokenizer_profile", .text).notNull().defaults(to: TokenCounter.canonicalProfile)
                t.column("tokenizer_version", .text).notNull().defaults(to: TokenCounter.canonicalVersion)
                t.column("token_count_accuracy", .text).notNull().defaults(to: TokenCountAccuracy.estimated.rawValue)
                t.uniqueKey(["file_id", "parent_idx"])
            }
            let parentColumns = try db.columns(in: "document_parents").map(\.name)
            if !parentColumns.contains("tokenizer_profile") {
                try db.execute(sql: "ALTER TABLE document_parents ADD COLUMN tokenizer_profile TEXT NOT NULL DEFAULT '\(TokenCounter.canonicalProfile)'")
            }
            if !parentColumns.contains("tokenizer_version") {
                try db.execute(sql: "ALTER TABLE document_parents ADD COLUMN tokenizer_version TEXT NOT NULL DEFAULT '\(TokenCounter.canonicalVersion)'")
            }
            if !parentColumns.contains("token_count_accuracy") {
                try db.execute(sql: "ALTER TABLE document_parents ADD COLUMN token_count_accuracy TEXT NOT NULL DEFAULT 'estimated'")
            }
            try db.create(index: "idx_parents_file", on: "document_parents", columns: ["file_id", "parent_idx"], ifNotExists: true)
            if !hadDocumentParents {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO document_parents(
                        file_id, parent_idx, text, contextual_text, section_path,
                        page_start, page_end, kind, token_count
                    )
                    SELECT file_id, chunk_idx, text, contextual_text, section_path,
                           page_start, page_end, kind, token_count
                    FROM document_chunks
                    """)
            }
            try db.execute(sql: """
                DELETE FROM document_parents
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM document_chunks
                    WHERE document_chunks.file_id = document_parents.file_id
                      AND document_chunks.parent_idx = document_parents.parent_idx
                )
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
                t.column("tokenizer_profile", .text).notNull().defaults(to: TokenCounter.generationFallbackProfile)
                t.column("token_count_accuracy", .text).notNull().defaults(to: TokenCountAccuracy.estimated.rawValue)
            }
            let tokenUsageColumns = try db.columns(in: "token_usage").map(\.name)
            if !tokenUsageColumns.contains("tokenizer_profile") {
                try db.execute(sql: "ALTER TABLE token_usage ADD COLUMN tokenizer_profile TEXT NOT NULL DEFAULT '\(TokenCounter.generationFallbackProfile)'")
            }
            if !tokenUsageColumns.contains("token_count_accuracy") {
                try db.execute(sql: "ALTER TABLE token_usage ADD COLUMN token_count_accuracy TEXT NOT NULL DEFAULT 'estimated'")
            }
            try db.create(index: "idx_token_usage_ts", on: "token_usage", columns: ["ts"], ifNotExists: true)

            // Existing rows used a different CJK/character heuristic. Recalculate once with
            // the shared canonical estimator without changing chunk boundaries or vectors.
            let legacyChunks = try Row.fetchAll(
                db,
                sql: "SELECT id, contextual_text FROM document_chunks WHERE token_count = 0 OR (token_count_accuracy = 'estimated' AND tokenizer_version != ?)",
                arguments: [TokenCounter.canonicalVersion]
            )
            for row in legacyChunks {
                let measurement = TokenCounter.estimate((row["contextual_text"] as String?) ?? "")
                try db.execute(
                    sql: "UPDATE document_chunks SET token_count = ?, tokenizer_profile = ?, tokenizer_version = ?, token_count_accuracy = ? WHERE id = ?",
                    arguments: [measurement.count, measurement.tokenizerProfile, measurement.tokenizerVersion,
                                measurement.accuracy.rawValue, row["id"] as Int64]
                )
            }
            let legacyParents = try Row.fetchAll(
                db,
                sql: "SELECT id, contextual_text FROM document_parents WHERE token_count = 0 OR (token_count_accuracy = 'estimated' AND tokenizer_version != ?)",
                arguments: [TokenCounter.canonicalVersion]
            )
            for row in legacyParents {
                let measurement = TokenCounter.estimate((row["contextual_text"] as String?) ?? "")
                try db.execute(
                    sql: "UPDATE document_parents SET token_count = ?, tokenizer_profile = ?, tokenizer_version = ?, token_count_accuracy = ? WHERE id = ?",
                    arguments: [measurement.count, measurement.tokenizerProfile, measurement.tokenizerVersion,
                                measurement.accuracy.rawValue, row["id"] as Int64]
                )
            }
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

    /// Returns reindex planning counts without materializing every file record on the UI thread.
    func fileIndexCounts() throws -> (total: Int, indexed: Int, unindexed: Int) {
        try dbPool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS total,
                           SUM(CASE WHEN indexed_at IS NOT NULL THEN 1 ELSE 0 END) AS indexed,
                           SUM(CASE WHEN indexed_at IS NULL THEN 1 ELSE 0 END) AS unindexed
                    FROM files
                    """
            )
            return (
                total: row?["total"] ?? 0,
                indexed: row?["indexed"] ?? 0,
                unindexed: row?["unindexed"] ?? 0
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

    /// Loads watched entries in batches so a directory scan does not issue one query per item.
    /// The returned dictionary is keyed by the caller's original path representation.
    func files(atPaths paths: Set<String>) throws -> [String: FileRecord] {
        guard !paths.isEmpty else { return [:] }
        return try dbPool.read { db in
            let requestedPaths = Array(paths)
            let lookupPaths = Set(requestedPaths.flatMap { path in
                [path, Self.alternateMacOSPathRepresentation(path)].compactMap { $0 }
            })
            let lookupPathList = Array(lookupPaths)
            var recordsByStoredPath = [String: FileRecord]()
            for chunkStart in stride(from: 0, to: lookupPathList.count, by: 400) {
                let chunk = Array(lookupPathList[chunkStart..<min(chunkStart + 400, lookupPathList.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let records = try FileRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM files WHERE path IN (\(placeholders))",
                    arguments: StatementArguments(chunk)
                )
                for record in records { recordsByStoredPath[record.path] = record }
            }

            var recordsByRequestedPath = [String: FileRecord]()
            for path in requestedPaths {
                if let record = recordsByStoredPath[path] {
                    recordsByRequestedPath[path] = record
                } else if let alternatePath = Self.alternateMacOSPathRepresentation(path),
                          let record = recordsByStoredPath[alternatePath] {
                    recordsByRequestedPath[path] = record
                }
            }
            return recordsByRequestedPath
        }
    }

    func files(matching keyword: String) throws -> [FileRecord] {
        try dbPool.read { db in
            if keyword.unicodeScalars.count >= 3 {
                let quotedKeyword = "\"\(keyword.replacingOccurrences(of: "\"", with: "\"\""))\""
                if let records = try? FileRecord.fetchAll(
                    db,
                    sql: """
                        SELECT files.*
                        FROM files_fts
                        JOIN files ON files.id = files_fts.rowid
                        WHERE files_fts MATCH ?
                        ORDER BY COALESCE(files.discovered_at, files.organized_at, files.indexed_at, files.mtime) DESC,
                                 files.name COLLATE NOCASE ASC
                        LIMIT 200
                        """,
                    arguments: [quotedKeyword]
                ), !records.isEmpty {
                    return records
                }
            }

            // Short tokens and punctuation are not indexed by the trigram tokenizer.
            // Preserve literal substring behavior as a bounded fallback for those queries and FTS misses.
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
                    SELECT c.chunk_idx, c.text, c.contextual_text, c.section_path,
                           c.page_start, c.page_end, c.kind, c.parent_idx,
                           p.text AS parent_text, c.token_count,
                           c.tokenizer_profile, c.tokenizer_version, c.token_count_accuracy
                    FROM document_chunks c
                    LEFT JOIN document_parents p
                      ON p.file_id = c.file_id AND p.parent_idx = c.parent_idx
                    WHERE c.file_id = ?
                    ORDER BY c.chunk_idx
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
                    kind: DocumentChunkKind(rawValue: (row["kind"] as String?) ?? "") ?? .text,
                    parentIndex: row["parent_idx"],
                    parentText: row["parent_text"],
                    tokenCount: row["token_count"],
                    tokenizerProfile: (row["tokenizer_profile"] as String?) ?? TokenCounter.canonicalProfile,
                    tokenizerVersion: (row["tokenizer_version"] as String?) ?? TokenCounter.canonicalVersion,
                    tokenCountAccuracy: TokenCountAccuracy(
                        rawValue: (row["token_count_accuracy"] as String?) ?? ""
                    ) ?? .estimated
                )
            }
        }
    }

    /// Returns high-precision chunk matches for identifiers extracted during indexing.
    /// This lane complements semantic similarity for invoice numbers, emails, dates, and IDs.
    func entityChunkMatches(terms: [String], limit: Int) throws -> [VectorSearchHit] {
        let normalizedTerms = Array(Set(terms.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { $0.count >= 3 })).sorted().prefix(12)
        guard !normalizedTerms.isEmpty, limit > 0 else { return [] }
        let scoreExpression = normalizedTerms.map { _ in
            "CASE WHEN instr(lower(c.entity_terms), ?) > 0 THEN 1 ELSE 0 END"
        }.joined(separator: " + ")
        var arguments = StatementArguments(normalizedTerms)
        arguments += [limit]
        return try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    WITH ranked AS (
                        SELECT c.file_id, c.chunk_idx, c.contextual_text AS chunk_text,
                               c.section_path, c.page_start, c.page_end, c.kind,
                               c.parent_idx, p.text AS parent_text, c.entity_terms,
                               (\(scoreExpression)) AS entity_score
                        FROM document_chunks c
                        LEFT JOIN document_parents p
                          ON p.file_id = c.file_id AND p.parent_idx = c.parent_idx
                    )
                    SELECT * FROM ranked
                    WHERE entity_score > 0
                    ORDER BY entity_score DESC, file_id, chunk_idx
                    LIMIT ?
                    """,
                arguments: arguments
            )
            return rows.map { row in
                let sectionJSON = (row["section_path"] as String?) ?? "[]"
                let sectionPath = (try? JSONDecoder().decode(
                    [String].self,
                    from: Data(sectionJSON.utf8)
                )) ?? []
                let entityJSON = (row["entity_terms"] as String?) ?? "[]"
                let entityTerms = (try? JSONDecoder().decode(
                    [String].self,
                    from: Data(entityJSON.utf8)
                )) ?? []
                let matchCount = (row["entity_score"] as Int?) ?? 1
                return VectorSearchHit(
                    fileId: row["file_id"],
                    score: min(1, 0.92 + Float(matchCount - 1) * 0.02),
                    chunkText: row["chunk_text"],
                    chunkIndex: row["chunk_idx"],
                    sectionPath: sectionPath,
                    pageStart: row["page_start"],
                    pageEnd: row["page_end"],
                    kind: DocumentChunkKind(rawValue: (row["kind"] as String?) ?? "") ?? .text,
                    parentIndex: row["parent_idx"],
                    parentText: row["parent_text"],
                    entityTerms: entityTerms
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

    // MARK: - library search history and cache

    func libraryRevision() throws -> Int64 {
        try dbPool.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT revision FROM library_revision WHERE id = 1"
            ) ?? 0
        }
    }

    func librarySearchHistory(limit: Int = 20) throws -> [LibrarySearchHistoryEntry] {
        let safeLimit = max(1, min(limit, 100))
        return try dbPool.read { db in
            let revision = try Int64.fetchOne(
                db,
                sql: "SELECT revision FROM library_revision WHERE id = 1"
            ) ?? 0
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, query, search_mode, updated_at, result_count, library_revision
                    FROM library_search_history
                    WHERE is_history = 1
                    ORDER BY updated_at DESC
                    LIMIT ?
                    """,
                arguments: [safeLimit]
            )
            return rows.map { row in
                LibrarySearchHistoryEntry(
                    id: row["id"],
                    query: row["query"],
                    isSmartSearch: (row["search_mode"] as String) == "smart",
                    updatedAt: row["updated_at"],
                    resultCount: row["result_count"],
                    hasValidCache: (row["library_revision"] as Int64) == revision
                )
            }
        }
    }

    func cachedLibrarySearch(query: String, isSmartSearch: Bool) throws -> LibrarySearchCacheRecord? {
        let normalizedQuery = Self.normalizedSearchQuery(query)
        guard !normalizedQuery.isEmpty else { return nil }
        return try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT library_revision, payload
                    FROM library_search_history
                    WHERE normalized_query = ? AND search_mode = ?
                    """,
                arguments: [normalizedQuery, isSmartSearch ? "smart" : "standard"]
            ) else { return nil }
            return LibrarySearchCacheRecord(
                revision: row["library_revision"],
                payload: row["payload"]
            )
        }
    }

    func saveLibrarySearch(
        query: String,
        isSmartSearch: Bool,
        resultCount: Int,
        revision: Int64,
        payload: Data,
        recordHistory: Bool
    ) throws {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedQuery = Self.normalizedSearchQuery(trimmedQuery)
        guard !normalizedQuery.isEmpty else { return }
        let now = Date()
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO library_search_history(
                        query, normalized_query, search_mode, created_at, updated_at,
                        result_count, library_revision, payload, is_history
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(normalized_query, search_mode) DO UPDATE SET
                        query = excluded.query,
                        updated_at = excluded.updated_at,
                        result_count = excluded.result_count,
                        library_revision = excluded.library_revision,
                        payload = excluded.payload,
                        is_history = CASE
                            WHEN excluded.is_history = 1 THEN 1
                            ELSE library_search_history.is_history
                        END
                    """,
                arguments: [
                    trimmedQuery,
                    normalizedQuery,
                    isSmartSearch ? "smart" : "standard",
                    now,
                    now,
                    resultCount,
                    revision,
                    payload,
                    recordHistory,
                ]
            )
            try db.execute(sql: """
                DELETE FROM library_search_history
                WHERE id NOT IN (
                    SELECT id FROM library_search_history ORDER BY updated_at DESC LIMIT 50
                )
                """)
        }
    }

    func deleteLibrarySearchHistory(id: Int64) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM library_search_history WHERE id = ?", arguments: [id])
        }
    }

    func clearLibrarySearchHistory() throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM library_search_history")
        }
    }

    func recordRAGSearchTrace(query: String,
                              semanticQuery: String,
                              lexicalCandidates: Int,
                              semanticCandidates: Int,
                              entityCandidates: Int,
                              fusedCandidates: Int,
                              returnedResults: Int,
                              semanticThreshold: Float?,
                              reranker: String?,
                              duration: TimeInterval) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO rag_search_traces(
                        created_at, query, semantic_query, lexical_candidates,
                        semantic_candidates, entity_candidates, fused_candidates,
                        returned_results, semantic_threshold, reranker, duration_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [Date(), query, semanticQuery, lexicalCandidates,
                            semanticCandidates, entityCandidates, fusedCandidates,
                            returnedResults, semanticThreshold, reranker,
                            duration * 1_000]
            )
            try db.execute(sql: """
                DELETE FROM rag_search_traces
                WHERE id NOT IN (
                    SELECT id FROM rag_search_traces ORDER BY created_at DESC LIMIT 1000
                )
                """)
        }
    }

    private static func normalizedSearchQuery(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
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
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let daysList = (0..<safeDays).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let aggregate = try dbPool.read { db -> (
            totalFiles: Int,
            indexedFiles: Int,
            managedFileBytes: Int64,
            extractedTextBytes: Int64,
            totalTokens: Int,
            vectorBytes: Int64,
            addedByDay: [String: Int],
            indexedByDay: [String: Int],
            tokensByDay: [String: Int],
            categories: [CategoryStorageStat]
        ) in
            let fileSummary = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total_files,
                       COALESCE(SUM(CASE WHEN indexed_at IS NOT NULL THEN 1 ELSE 0 END), 0) AS indexed_files,
                       COALESCE(SUM(MAX(size, 0)), 0) AS managed_bytes,
                       COALESCE(SUM(LENGTH(COALESCE(content_text, ''))), 0) AS extracted_text_bytes
                FROM files
                """)
            let totalFiles = (fileSummary?["total_files"] as Int?) ?? 0
            let indexedFiles = (fileSummary?["indexed_files"] as Int?) ?? 0
            let managedFileBytes = (fileSummary?["managed_bytes"] as Int64?) ?? 0
            let extractedTextBytes = (fileSummary?["extracted_text_bytes"] as Int64?) ?? 0

            let totalTokens = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(input_tokens + output_tokens), 0) FROM token_usage"
            ) ?? 0
            let vectorBytes = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(LENGTH(vector)), 0) FROM embeddings"
            ) ?? 0

            let addedRows = try Row.fetchAll(db, sql: """
                SELECT DATE(COALESCE(discovered_at, indexed_at, mtime), 'localtime') AS day,
                       COUNT(*) AS value
                FROM files
                GROUP BY day
                """)
            let indexedRows = try Row.fetchAll(db, sql: """
                SELECT DATE(indexed_at, 'localtime') AS day, COUNT(*) AS value
                FROM files
                WHERE indexed_at IS NOT NULL
                GROUP BY day
                """)
            let tokenRows = try Row.fetchAll(db, sql: """
                SELECT DATE(ts, 'localtime') AS day, SUM(input_tokens + output_tokens) AS value
                FROM token_usage
                GROUP BY day
                """)
            func valuesByDay(_ rows: [Row]) -> [String: Int] {
                Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                    guard let day = row["day"] as String? else { return nil }
                    return (day, (row["value"] as Int?) ?? 0)
                })
            }

            let categoryRows = try Row.fetchAll(db, sql: """
                SELECT category, COALESCE(SUM(MAX(size, 0)), 0) AS bytes, COUNT(*) AS file_count
                FROM files
                GROUP BY category
                ORDER BY bytes DESC
                """)
            let categories = categoryRows.compactMap { row -> CategoryStorageStat? in
                guard let rawCategory = row["category"] as String?,
                      let category = FileCategory(rawValue: rawCategory) else { return nil }
                return CategoryStorageStat(
                    category: category,
                    bytes: (row["bytes"] as Int64?) ?? 0,
                    fileCount: (row["file_count"] as Int?) ?? 0
                )
            }
            return (
                totalFiles,
                indexedFiles,
                managedFileBytes,
                extractedTextBytes,
                totalTokens,
                vectorBytes,
                valuesByDay(addedRows),
                valuesByDay(indexedRows),
                valuesByDay(tokenRows),
                categories
            )
        }

        let daily = daysList.map { day in
            let key = dayFormatter.string(from: day)
            return DailyActivityStat(
                day: day,
                addedFiles: aggregate.addedByDay[key, default: 0],
                indexedFiles: aggregate.indexedByDay[key, default: 0],
                tokens: aggregate.tokensByDay[key, default: 0]
            )
        }
        let todayKey = dayFormatter.string(from: today)

        return AppStatistics(
            totalFiles: aggregate.totalFiles,
            indexedFiles: aggregate.indexedFiles,
            todayAddedFiles: aggregate.addedByDay[todayKey, default: 0],
            totalTokens: aggregate.totalTokens,
            todayTokens: aggregate.tokensByDay[todayKey, default: 0],
            managedFileBytes: aggregate.managedFileBytes,
            databaseBytes: databaseStorageBytes(),
            vectorBytes: aggregate.vectorBytes,
            extractedTextBytes: aggregate.extractedTextBytes,
            localModelBytes: directorySize(
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models")
            ),
            dailyActivity: daily,
            categoryStorage: aggregate.categories
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

    func watchDirectoryBaselineEntries(directoryPath: String) throws -> Set<String> {
        try dbPool.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT entry_path FROM watch_directory_baseline_entries WHERE directory_path = ?",
                arguments: [directoryPath]
            ))
        }
    }

    private static func alternateMacOSPathRepresentation(_ path: String) -> String? {
        if path == "/var" || path.hasPrefix("/var/") || path == "/tmp" || path.hasPrefix("/tmp/") {
            return "/private\(path)"
        }
        if path == "/private/var" || path.hasPrefix("/private/var/")
            || path == "/private/tmp" || path.hasPrefix("/private/tmp/") {
            return String(path.dropFirst("/private".count))
        }
        return nil
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
                           page_start, page_end, kind, token_count,
                           tokenizer_profile, tokenizer_version, token_count_accuracy
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
                    kind: DocumentChunkKind(rawValue: (row["kind"] as String?) ?? "") ?? .text,
                    tokenCount: row["token_count"],
                    tokenizerProfile: row["tokenizer_profile"],
                    tokenizerVersion: row["tokenizer_version"],
                    tokenCountAccuracy: TokenCountAccuracy(
                        rawValue: (row["token_count_accuracy"] as String?) ?? ""
                    ) ?? .estimated
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
