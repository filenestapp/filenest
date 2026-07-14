import Foundation
import GRDB

/// 文件大类
enum FileCategory: String, Codable, CaseIterable, Identifiable {
    case documents, images, videos, audio, code, archives, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .documents: return "文档"
        case .images: return "图片"
        case .videos: return "视频"
        case .audio: return "音频"
        case .code: return "代码"
        case .archives: return "压缩包"
        case .other: return "其他"
        }
    }
    var icon: String {
        switch self {
        case .documents: return "doc.text"
        case .images: return "photo"
        case .videos: return "film"
        case .audio: return "music.note"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archives: return "archivebox"
        case .other: return "questionmark.folder"
        }
    }
    /// 默认归类的目标子文件夹名
    var folderName: String { label }

    /// 根据扩展名推断大类（规则分类核心）
    static func from(extension ext: String) -> FileCategory {
        let e = ext.lowercased()
        if ["pdf", "doc", "docx", "txt", "md", "rtf", "pages", "xls", "xlsx",
            "ppt", "pptx", "csv", "key", "numbers", "epub"].contains(e) { return .documents }
        if ["png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp", "svg", "webp", "psd", "sketch"].contains(e) { return .images }
        if ["mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm"].contains(e) { return .videos }
        if ["mp3", "wav", "aac", "flac", "m4a", "ogg", "aiff"].contains(e) { return .audio }
        if ["swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "go", "rs", "c",
            "cpp", "h", "hpp", "cs", "rb", "php", "sh", "sql", "json", "yaml", "yml",
            "html", "css", "vue", "lua", "r"].contains(e) { return .code }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso"].contains(e) { return .archives }
        return .other
    }
}

/// 文件记录：对应 files 表
struct FileRecord: Identifiable, Codable, Equatable, Hashable {
    var id: Int64?
    var path: String
    var name: String
    var ext: String
    var size: Int64
    var mtime: Date
    var category: String
    var sourceDir: String
    var indexedAt: Date?
    var contentHash: String?
    var title: String?       // 抽取出的标题/摘要
    var contentText: String? // 抽取出的纯文本（用于关键词检索 / 摘要）

    var categoryEnum: FileCategory { FileCategory(rawValue: category) ?? .other }
}

extension FileRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "files"

    enum CodingKeys: String, CodingKey {
        case id, path, name, ext, size, mtime, category, title
        case sourceDir = "source_dir"
        case indexedAt = "indexed_at"
        case contentHash = "content_hash"
        case contentText = "content_text"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 规则
enum RuleType: String, Codable { case rule, ai }

struct Rule: Identifiable, Codable, Equatable {
    var id: Int64?
    var name: String
    var type: String           // rule | ai
    var pattern: String        // 规则模式（扩展名/通配/AI 提示词）
    var targetFolder: String   // 目标子文件夹
    var priority: Int
    var enabled: Bool

    var typeEnum: RuleType { RuleType(rawValue: type) ?? .rule }
}

extension Rule: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "rules"
    enum CodingKeys: String, CodingKey {
        case id, name, type, pattern, priority, enabled
        case targetFolder = "target_folder"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// 聊天消息
enum ChatRole: String, Codable { case system, user, assistant }

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: Int64?
    var role: String
    var content: String
    var ts: Date
    var relatedFileIds: String? // JSON 编码的 [Int64]
    var relatedFiles: [FileRecord] = [] // 运行时附带，不入库
}

extension ChatMessage: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chat_messages"
    enum CodingKeys: String, CodingKey {
        case id, role, content, ts
        case relatedFileIds = "related_file_ids"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
