import Foundation
import GRDB

/// SQLite 数据存储：元数据(files/rules/chat) + 向量(embeddings)
final class SQLiteStore {
    static let shared = SQLiteStore()

    let dbPool: DatabasePool

    init(path: String? = nil) {
        do {
            let url = path.map { URL(fileURLWithPath: $0) } ?? SQLiteStore.databaseURL()
            var config = Configuration()
            config.prepareDatabase { db in
                // WAL 模式，并发友好
                try db.execute(sql: "PRAGMA journal_mode=WAL")
                try db.execute(sql: "PRAGMA synchronous=NORMAL")
            }
            // App Sandbox 下默认数据目录可写
            dbPool = try DatabasePool(path: url.path, configuration: config)
            try migrate()
        } catch {
            fatalError("SQLiteStore init failed: \(error)")
        }
    }

    static func databaseURL() -> URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("FileNest")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("filenest.sqlite")
    }

    // MARK: - 建表 / 迁移
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
            }
            try db.create(index: "idx_files_path", on: "files", columns: ["path"], unique: true, ifNotExists: true)
            try db.create(index: "idx_files_category", on: "files", columns: ["category"], ifNotExists: true)

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

            try db.create(table: "rules", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
                t.column("pattern", .text).notNull()
                t.column("target_folder", .text).notNull()
                t.column("priority", .integer).notNull().defaults(to: 0)
                t.column("enabled", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "chat_messages", ifNotExists: true) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("ts", .datetime).notNull()
                t.column("related_file_ids", .text)
            }

            try db.create(table: "settings", ifNotExists: true) { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
    }

    // MARK: - files CRUD
    func upsertFile(_ record: FileRecord) throws -> Int64 {
        try dbPool.write { db in
            // 按 path 唯一：若已存在则更新
            if let existing = try FileRecord.fetchOne(
                db,
                sql: "SELECT * FROM files WHERE path = ?",
                arguments: [record.path]
            ) {
                var updated = record
                updated.id = existing.id
                try updated.update(db)
                return updated.id!
            } else {
                var inserted = record
                try inserted.insert(db)
                return inserted.id!
            }
        }
    }

    func allFiles() throws -> [FileRecord] {
        try dbPool.read { db in
            try FileRecord
                .order(Column("indexed_at").desc, Column("mtime").desc)
                .fetchAll(db)
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

    func files(matching keyword: String) throws -> [FileRecord] {
        try dbPool.read { db in
            let pattern = "%\(keyword)%"
            return try FileRecord.fetchAll(
                db,
                sql: "SELECT * FROM files WHERE name LIKE ? OR title LIKE ? OR content_text LIKE ? ORDER BY mtime DESC LIMIT 200",
                arguments: [pattern, pattern, pattern]
            )
        }
    }

    func deleteFile(id: Int64) throws {
        try dbPool.write { db in
            _ = try FileRecord.deleteOne(db, key: id)
        }
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
                try r.update(db, columns: ["name", "type", "pattern", "target_folder", "priority", "enabled"])
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

    /// 默认规则（首次启动时注入）
    func seedDefaultRulesIfNeeded() throws {
        let count = try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rules") ?? 0
        }
        guard count == 0 else { return }
        // 默认规则：各扩展名大类对应文件夹（与 FileCategory 一致）
        let seed: [(String, String, String)] = [
            ("文档 (pdf/doc/md…)", "pdf,doc,docx,txt,md,rtf,xls,xlsx,ppt,pptx,csv,epub", "文档"),
            ("图片 (png/jpg…)", "png,jpg,jpeg,gif,heic,tiff,bmp,svg,webp,psd,sketch", "图片"),
            ("视频 (mp4/mov…)", "mp4,mov,avi,mkv,m4v,wmv,flv,webm", "视频"),
            ("音频 (mp3/wav…)", "mp3,wav,aac,flac,m4a,ogg,aiff", "音频"),
            ("代码 (swift/py/js…)", "swift,py,js,ts,tsx,jsx,java,kt,go,rs,c,cpp,h,cs,rb,php,sh,sql,json,yaml,yml,html,css", "代码"),
            ("压缩包 (zip/dmg…)", "zip,rar,7z,tar,gz,bz2,xz,dmg,iso", "压缩包"),
        ]
        try dbPool.write { db in
            for (i, (name, pattern, folder)) in seed.enumerated() {
                var r = Rule(id: nil, name: name, type: "rule", pattern: pattern,
                             targetFolder: folder, priority: seed.count - i, enabled: true)
                try r.insert(db)
            }
        }
    }

    // MARK: - chat messages
    func allChatMessages() throws -> [ChatMessage] {
        try dbPool.read { db in
            try ChatMessage.order(Column("ts")).fetchAll(db)
        }
    }

    func addChatMessage(_ msg: ChatMessage) throws -> Int64 {
        try dbPool.write { db in
            var m = msg
            try m.insert(db)
            return m.id!
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
}
