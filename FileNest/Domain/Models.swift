import Foundation
import GRDB

/// Top-level file category.
enum FileCategory: String, Codable, CaseIterable, Identifiable {
    case documents, images, videos, audio, code, archives, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .documents: return "Documents"
        case .images: return "Images"
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .code: return "Code"
        case .archives: return "Archives"
        case .other: return "Other"
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
    /// Stable English folder name used for default on-disk organization, independent of the interface language.
    var folderName: String {
        switch self {
        case .documents: return "Documents"
        case .images: return "Images"
        case .videos: return "Videos"
        case .audio: return "Audio"
        case .code: return "Code"
        case .archives: return "Archives"
        case .other: return "Other"
        }
    }

    /// Infers the top-level category from the extension, forming the core of rule classification.
    static func from(extension ext: String) -> FileCategory {
        let e = ext.lowercased()
        if ["pdf", "doc", "docx", "docm", "txt", "md", "rtf", "pages", "xls", "xlsx", "xlsm",
            "ppt", "pptx", "ppsx", "csv", "key", "keynote", "numbers", "epub", "odt", "ods", "odp"]
            .contains(e) { return .documents }
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

/// File record corresponding to the files table.
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
    var title: String?       // Extracted title or summary.
    var contentText: String? // Extracted plain text used for keyword search and summaries.
    var discoveredAt: Date? = nil // First discovery time in FileNest, used for new-file statistics.
    var organizedAt: Date? = nil // Time the item was physically moved into the organized folder.
    var note: String? = nil // User note, included with the title and body in keyword and vector search.
    var organizationSubfolder: String? = nil // Secondary folder derived by AI or rules.
    var isDirectory: Bool = false // Index and organize a folder as a whole while preserving its internal hierarchy.
    var indexSignature: String? = nil // Vector-space signature; global confirmation state manages content-processing configuration.
    /// The indexed original with identical bytes. Duplicate files deliberately do not own chunks or vectors.
    var duplicateOfFileID: Int64? = nil
    var duplicateDetectedAt: Date? = nil

    var categoryEnum: FileCategory { FileCategory(rawValue: category) ?? .other }

    /// Default FileNest library sort time. Reindexing does not change the first discovery time.
    var addedAt: Date { discoveredAt ?? organizedAt ?? indexedAt ?? mtime }

    var supportsPreview: Bool {
        [.documents, .images, .videos, .audio].contains(categoryEnum)
    }

    var supportsDocumentChat: Bool {
        categoryEnum == .documents && !isDirectory
    }

    /// Media becomes eligible for file-scoped chat only when local transcription is enabled.
    func supportsFileChat(with settings: AppSettings) -> Bool {
        supportsDocumentChat
            || (!isDirectory
                && [.videos, .audio].contains(categoryEnum)
                && settings.shouldTranscribeMedia(extension: ext))
    }

    static func sortedByNewestAdded(_ files: [FileRecord]) -> [FileRecord] {
        files.sorted {
            if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// A group of files with the same SHA-256 content hash. The first file is kept
/// as the original; the remaining files are safe candidates for the Trash only
/// after explicit user confirmation.
struct DuplicateFileGroup: Identifiable, Equatable {
    let contentHash: String
    let files: [FileRecord]

    var id: String { contentHash }

    var retainedFile: FileRecord {
        files[0]
    }

    var duplicateFiles: [FileRecord] {
        Array(files.dropFirst())
    }

    var reclaimableBytes: Int64 {
        duplicateFiles.reduce(0) { $0 + $1.size }
    }

    static func groups(from files: [FileRecord]) -> [DuplicateFileGroup] {
        let groups = Dictionary(grouping: files.compactMap { file -> (String, FileRecord)? in
            guard let hash = file.contentHash, !hash.isEmpty else { return nil }
            return (hash, file)
        }, by: \.0)

        return groups.compactMap { hash, entries in
            var ordered = entries.map(\.1).sorted { lhs, rhs in
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
                if lhs.mtime != rhs.mtime { return lhs.mtime < rhs.mtime }
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            let linkedOriginalIDs = Set(ordered.compactMap(\.duplicateOfFileID))
            if let linkedOriginalIndex = ordered.firstIndex(where: { file in
                guard let id = file.id else { return false }
                return linkedOriginalIDs.contains(id)
            }) {
                let original = ordered.remove(at: linkedOriginalIndex)
                ordered.insert(original, at: 0)
            }
            guard ordered.count > 1 else { return nil }
            return DuplicateFileGroup(contentHash: hash, files: ordered)
        }
        .sorted { lhs, rhs in
            if lhs.reclaimableBytes != rhs.reclaimableBytes {
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
            return lhs.retainedFile.name.localizedStandardCompare(rhs.retainedFile.name) == .orderedAscending
        }
    }
}

struct DuplicateScanProgress: Equatable {
    let scannedCount: Int
    let totalCount: Int

    var fractionCompleted: Double {
        guard totalCount > 0 else { return 1 }
        return min(1, Double(scannedCount) / Double(totalCount))
    }
}

struct DuplicateTrashResult: Equatable {
    let movedCount: Int
    let failedFileNames: [String]
}

struct DuplicateTrashProgress: Equatable {
    let completedCount: Int
    let totalCount: Int
    let currentFileName: String?

    var fractionCompleted: Double {
        guard totalCount > 0 else { return 1 }
        return min(1, Double(completedCount) / Double(totalCount))
    }
}

struct IndexedDocumentChunk: Identifiable, Equatable, Sendable {
    var id: Int { index }
    let index: Int
    let text: String
    let contextualText: String
    let sectionPath: [String]
    let pageStart: Int?
    let pageEnd: Int?
    let kind: DocumentChunkKind
    let parentIndex: Int?
    let parentText: String?
    let tokenCount: Int
    let tokenizerProfile: String
    let tokenizerVersion: String
    let tokenCountAccuracy: TokenCountAccuracy
}

extension FileRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "files"

    enum CodingKeys: String, CodingKey {
        case id, path, name, ext, size, mtime, category, title
        case sourceDir = "source_dir"
        case indexedAt = "indexed_at"
        case contentHash = "content_hash"
        case contentText = "content_text"
        case discoveredAt = "discovered_at"
        case organizedAt = "organized_at"
        case note
        case organizationSubfolder = "organization_subfolder"
        case isDirectory = "is_directory"
        case indexSignature = "index_signature"
        case duplicateOfFileID = "duplicate_of_file_id"
        case duplicateDetectedAt = "duplicate_detected_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Token usage for one model call, using a reproducible local estimate to avoid missing reports from different providers.
struct TokenUsageRecord: Identifiable, Codable, Equatable {
    var id: Int64?
    var ts: Date
    var provider: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var sessionId: Int64?
    var tokenizerProfile: String = TokenCounter.generationFallbackProfile
    var tokenCountAccuracy: TokenCountAccuracy = .estimated
}

extension TokenUsageRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "token_usage"
    enum CodingKeys: String, CodingKey {
        case id, ts, provider, model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case sessionId = "session_id"
        case tokenizerProfile = "tokenizer_profile"
        case tokenCountAccuracy = "token_count_accuracy"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct DailyActivityStat: Identifiable, Equatable {
    let day: Date
    let addedFiles: Int
    let indexedFiles: Int
    let tokens: Int
    var id: Date { day }
}

struct CategoryStorageStat: Identifiable, Equatable {
    let category: FileCategory
    let bytes: Int64
    let fileCount: Int
    var id: String { category.rawValue }
}

struct AppStatistics: Equatable {
    var totalFiles: Int
    var indexedFiles: Int
    var todayAddedFiles: Int
    var totalTokens: Int
    var todayTokens: Int
    var managedFileBytes: Int64
    var databaseBytes: Int64
    var vectorBytes: Int64
    var extractedTextBytes: Int64
    var localModelBytes: Int64
    var dailyActivity: [DailyActivityStat]
    var categoryStorage: [CategoryStorageStat]

    static let empty = AppStatistics(
        totalFiles: 0,
        indexedFiles: 0,
        todayAddedFiles: 0,
        totalTokens: 0,
        todayTokens: 0,
        managedFileBytes: 0,
        databaseBytes: 0,
        vectorBytes: 0,
        extractedTextBytes: 0,
        localModelBytes: 0,
        dailyActivity: [],
        categoryStorage: []
    )
}

/// Organization rule.
enum RuleType: String, Codable { case rule, ai }
enum RuleAction: String, Codable { case organize, ignore }

struct Rule: Identifiable, Codable, Equatable {
    var id: Int64?
    var name: String
    var type: String           // rule | ai
    var pattern: String        // Rule pattern: extension, wildcard, or AI prompt.
    var targetFolder: String   // Destination subfolder.
    var priority: Int
    var enabled: Bool
    var action: String = RuleAction.organize.rawValue

    var typeEnum: RuleType { RuleType(rawValue: type) ?? .rule }
    var actionEnum: RuleAction { RuleAction(rawValue: action) ?? .organize }
}

extension Rule: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "rules"
    enum CodingKeys: String, CodingKey {
        case id, name, type, pattern, priority, enabled, action
        case targetFolder = "target_folder"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Chat message.
enum ChatRole: String, Codable { case system, user, assistant }

/// Local chat session. Attachment paths are stored only in the user's on-device database.
struct ChatSession: Identifiable, Codable, Equatable, Hashable {
    var id: Int64?
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var attachedFilePath: String?
}

extension ChatSession: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chat_sessions"
    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case attachedFilePath = "attached_file_path"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Retrieval confidence persisted with an assistant response for historical chat results.
struct ChatRelatedFileMatch: Codable, Equatable, Hashable {
    let fileID: Int64
    let confidence: Double
}

struct ChatMessage: Identifiable, Codable, Equatable {
    var id: Int64?
    var role: String
    var content: String
    var ts: Date
    var relatedFileIds: String? // JSON-encoded [Int64].
    var relatedFiles: [FileRecord] = [] // Runtime-only relationship, not persisted.
    var relatedFileMatchesJSON: String? = nil // JSON-encoded [ChatRelatedFileMatch].
    var relatedFileMatches: [ChatRelatedFileMatch] = [] // Runtime-only relationship, not persisted.
    var sessionId: Int64? = nil
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var firstResponseDuration: TimeInterval? = nil
    var totalResponseDuration: TimeInterval? = nil
    var responseProvider: String? = nil
    var responseModel: String? = nil
}

extension ChatMessage: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "chat_messages"
    enum CodingKeys: String, CodingKey {
        case id, role, content, ts
        case relatedFileIds = "related_file_ids"
        case relatedFileMatchesJSON = "related_file_matches"
        case sessionId = "session_id"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case firstResponseDuration = "first_response_duration"
        case totalResponseDuration = "total_response_duration"
        case responseProvider = "response_provider"
        case responseModel = "response_model"
    }
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
