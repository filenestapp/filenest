import Foundation
import Combine
import CryptoKit
import NaturalLanguage

enum IndexContentChangeCategory: String, CaseIterable, Identifiable, Sendable {
    case chunking
    case documentParsing
    case ocr
    case indexingScope
    case serviceEndpoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chunking: return "Chunk tokens + overlap"
        case .documentParsing: return "Document Parsing"
        case .ocr: return "OCR engine"
        case .indexingScope: return "Indexing Scope"
        case .serviceEndpoint: return "Service Endpoints"
        }
    }

    var detail: String {
        switch self {
        case .chunking: return "Chunk tokens or overlap changed"
        case .documentParsing: return "The Docling setting or parser version changed"
        case .ocr: return "The OCR engine, source, format, or model changed"
        case .indexingScope: return "Automatic vectorization or indexed file types changed"
        case .serviceEndpoint: return "An Embedding or OCR service endpoint changed"
        }
    }

    var systemImage: String {
        switch self {
        case .chunking: return "square.split.2x1"
        case .documentParsing: return "doc.text.magnifyingglass"
        case .ocr: return "text.viewfinder"
        case .indexingScope: return "line.3.horizontal.decrease.circle"
        case .serviceEndpoint: return "network"
        }
    }
}

/// Centralized application settings persisted in the SQLite settings table.
/// Provides sensible, configurable defaults.
/// @Published properties cannot use didSet, so persistence lives in explicit setter methods,
/// which the UI calls through the SettingBinding adapter.
final class AppSettings: ObservableObject {
    static let shared = AppSettings(store: .shared)

    private let store: SQLiteStore
    private weak var organizer: OrganizerService?
    private weak var indexer: IndexerService?
    private weak var chat: ChatService?
    private weak var watcher: FileWatcherService?

    // MARK: - Configurable Properties
    @Published var watchDirs: [String] = []
    @Published var enabledExtensions: [String] = []
    @Published var excludeHidden: Bool = true
    @Published var classifyStrategy: String = "hybrid"
    @Published var llmChoice: String = LLMChoice.ollama.rawValue
    @Published var ollamaHost: String = "http://127.0.0.1:11434"
    @Published var ollamaModel: String = OllamaModelRecommendation.recommendedForCurrentDevice.generationModel
    @Published var ollamaFlashAttentionEnabled: Bool = true
    @Published var cloudAPIFormat: String = CloudAPIFormat.openAI.rawValue
    @Published var cloudAPIKey: String = ""
    @Published var cloudBaseURL: String = "https://api.openai.com/v1"
    @Published var cloudModel: String = "gpt-4o-mini"
    /// Cloud models only: zero enables automatic detection, while a positive value is a user override.
    @Published var cloudContextWindowTokens: Int = 0
    @Published var autoOrganize: Bool = true
    @Published var autoOrganizeMode: String = AutoOrganizeMode.batched.rawValue
    @Published var autoOrganizeIntervalSeconds: Int = 30
    @Published var autoOrganizeBatchSize: Int = 5
    @Published var autoVectorize: Bool = true
    @Published var vectorizeExtensions: [String] = []
    @Published var vectorChunkWords: Int = 600
    @Published var vectorChunkOverlap: Int = 80
    @Published var ragResultLimit: Int = 10
    @Published var doclingEnabled: Bool = true
    @Published var embeddingSource: String = EmbeddingSource.ollama.rawValue
    @Published var ollamaEmbeddingModel: String = OllamaModelRecommendation.defaultEmbeddingModel
    @Published var cloudEmbeddingBaseURL: String = "https://api.openai.com/v1"
    @Published var cloudEmbeddingAPIKey: String = ""
    @Published var cloudEmbeddingModel: String = "text-embedding-3-small"
    @Published var cloudEmbeddingReuseChatCredentials: Bool = false
    @Published var ocrSource: String = OCRSource.local.rawValue
    @Published var ollamaOCRModel: String = "glm-ocr"
    @Published var cloudOCRFormat: String = CloudAPIFormat.openAI.rawValue
    @Published var cloudOCRBaseURL: String = "https://api.openai.com/v1"
    @Published var cloudOCRAPIKey: String = ""
    @Published var cloudOCRModel: String = "gpt-4.1-mini"
    @Published var cloudOCRReuseChatCredentials: Bool = false
    @Published var thinkingMode: Bool = false
    @Published var appLanguage: String = AppLanguage.system.rawValue
    @Published var appearance: String = AppAppearance.system.rawValue
    @Published var onboardingCompleted: Bool = false
    @Published var updateFeedURL: String = ""
    @Published var automaticUpdateChecks: Bool = true
    @Published var automaticallyDownloadsUpdates: Bool = false

    enum LLMChoice: String, CaseIterable, Identifiable { case ollama, cloud, none
        var id: String { rawValue }
        var label: String { self == .ollama ? "Local Ollama" : self == .cloud ? "Cloud API" : "Disabled" }
    }

    enum CloudAPIFormat: String, CaseIterable, Identifiable {
        case openAI = "openai"
        case anthropic = "anthropic"

        var id: String { rawValue }
        var label: String { self == .openAI ? "OpenAI" : "Anthropic" }
    }

    enum EmbeddingSource: String, CaseIterable, Identifiable {
        case ollama, cloud, apple
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ollama: return "Local Ollama"
            case .cloud: return "Cloud API"
            case .apple: return "Apple NLEmbedding"
            }
        }
    }

    enum OCRSource: String, CaseIterable, Identifiable {
        case local, cloud, disabled
        var id: String { rawValue }
        var label: String {
            switch self {
            case .local: return "Local Models"
            case .cloud: return "Cloud API"
            case .disabled: return "Disabled"
            }
        }
    }

    enum AutoOrganizeMode: String, CaseIterable, Identifiable {
        case immediate
        case batched

        var id: String { rawValue }
        var label: String { self == .immediate ? "Organize immediately after indexing" : "Organize on timer or file threshold" }
    }

    enum AppLanguage: String, CaseIterable, Identifiable {
        case system
        case simplifiedChinese = "zh-Hans"
        case english = "en"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .simplifiedChinese: return "Simplified Chinese"
            case .english: return "English"
            }
        }

        static func resolvedSystemLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
            guard let identifier = preferredLanguages.first else { return .english }
            let languageCode = identifier
                .replacingOccurrences(of: "_", with: "-")
                .split(separator: "-", maxSplits: 1)
                .first?
                .lowercased()

            switch languageCode {
            case "zh": return .simplifiedChinese
            case "en": return .english
            default: return .english
            }
        }

        var effectiveLanguage: Self {
            self == .system ? Self.resolvedSystemLanguage() : self
        }

        var locale: Locale {
            switch effectiveLanguage {
            case .system: return Locale(identifier: "en")
            case .simplifiedChinese: return Locale(identifier: "zh-Hans")
            case .english: return Locale(identifier: "en")
            }
        }
    }

    enum AppAppearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    init(store: SQLiteStore) {
        self.store = store
        watchDirs = loadStrArr(.watchDirs, sep: "\n") ?? Self.defaultWatchDirectories()
        enabledExtensions = loadStrArr(.enabledExts, sep: ",") ?? defaultExts
        excludeHidden = load(.excludeHidden) != "0"
        classifyStrategy = ClassificationStrategy(
            storedValue: load(.classifyStrategy) ?? ClassificationStrategy.hybrid.rawValue
        ).rawValue
        llmChoice = LLMChoice(rawValue: load(.llmChoice) ?? "")?.rawValue
            ?? LLMChoice.ollama.rawValue
        ollamaHost = load(.ollamaHost) ?? "http://127.0.0.1:11434"
        ollamaModel = load(.ollamaModel)
            ?? OllamaModelRecommendation.recommendedForCurrentDevice.generationModel
        ollamaFlashAttentionEnabled = load(.ollamaFlashAttentionEnabled) != "0"
        cloudAPIFormat = CloudAPIFormat(rawValue: load(.cloudAPIFormat) ?? "")?.rawValue
            ?? CloudAPIFormat.openAI.rawValue
        cloudAPIKey = load(.cloudKey) ?? ""
        cloudBaseURL = load(.cloudBaseURL) ?? "https://api.openai.com/v1"
        cloudModel = load(.cloudModel) ?? "gpt-4o-mini"
        cloudContextWindowTokens = Self.normalizedChatContextWindow(
            load(.cloudContextWindowTokens) ?? load(.legacyChatContextWindowTokens)
        )
        autoOrganize = load(.autoOrganize) != "0"
        autoOrganizeMode = AutoOrganizeMode(rawValue: load(.autoOrganizeMode) ?? "")?.rawValue
            ?? AutoOrganizeMode.batched.rawValue
        autoOrganizeIntervalSeconds = Self.normalizedInterval(load(.autoOrganizeIntervalSeconds))
        autoOrganizeBatchSize = Self.normalizedBatchSize(load(.autoOrganizeBatchSize))
        autoVectorize = load(.autoVectorize) != "0"
        vectorizeExtensions = Self.normalizedExtensions(
            loadStrArr(.vectorizeExtensions, sep: ",") ?? Self.defaultVectorizeExtensions
        )
        if load(.chunkDefaults600Migration) == nil {
            if load(.vectorChunkWords) == "800", load(.vectorChunkOverlap) == "100" {
                save(.vectorChunkWords, "600")
                save(.vectorChunkOverlap, "80")
            }
            save(.chunkDefaults600Migration, "1")
        }
        vectorChunkWords = Self.normalizedChunkWords(load(.vectorChunkWords))
        vectorChunkOverlap = Self.normalizedChunkOverlap(
            load(.vectorChunkOverlap),
            chunkWords: vectorChunkWords
        )
        ragResultLimit = Self.normalizedRAGResultLimit(load(.ragResultLimit))
        doclingEnabled = load(.doclingEnabled) != "0"
        embeddingSource = EmbeddingSource(rawValue: load(.embeddingSource) ?? "")?.rawValue
            ?? EmbeddingSource.ollama.rawValue
        ollamaEmbeddingModel = load(.ollamaEmbeddingModel)
            ?? OllamaModelRecommendation.defaultEmbeddingModel
        cloudEmbeddingBaseURL = load(.cloudEmbeddingBaseURL) ?? "https://api.openai.com/v1"
        cloudEmbeddingAPIKey = load(.cloudEmbeddingAPIKey) ?? ""
        cloudEmbeddingModel = load(.cloudEmbeddingModel) ?? "text-embedding-3-small"
        cloudEmbeddingReuseChatCredentials = load(.cloudEmbeddingReuseChatCredentials) == "1"
        let storedOCRSource = load(.ocrSource)
        switch storedOCRSource {
        case OCRSource.cloud.rawValue:
            ocrSource = OCRSource.cloud.rawValue
        case OCRSource.disabled.rawValue:
            ocrSource = OCRSource.disabled.rawValue
        default:
            // Legacy `paddle` and `ollama` values now share one local OCR pipeline.
            ocrSource = OCRSource.local.rawValue
        }
        if storedOCRSource != nil, storedOCRSource != ocrSource {
            save(.ocrSource, ocrSource)
        }
        ollamaOCRModel = load(.ollamaOCRModel) ?? "glm-ocr"
        if load(.paddleOCRDefaultMigration) != "1" {
            save(.paddleOCRDefaultMigration, "1")
        }
        cloudOCRFormat = CloudAPIFormat(rawValue: load(.cloudOCRFormat) ?? "")?.rawValue
            ?? CloudAPIFormat.openAI.rawValue
        cloudOCRBaseURL = load(.cloudOCRBaseURL) ?? "https://api.openai.com/v1"
        cloudOCRAPIKey = load(.cloudOCRAPIKey) ?? ""
        cloudOCRModel = load(.cloudOCRModel) ?? "gpt-4.1-mini"
        cloudOCRReuseChatCredentials = load(.cloudOCRReuseChatCredentials) == "1"
        thinkingMode = load(.thinkingMode) == "1"
        appLanguage = AppLanguage(rawValue: load(.appLanguage) ?? "")?.rawValue
            ?? AppLanguage.system.rawValue
        appearance = AppAppearance(rawValue: load(.appearance) ?? "")?.rawValue
            ?? AppAppearance.system.rawValue
        onboardingCompleted = load(.onboardingCompleted) == "1"
        updateFeedURL = load(.updateFeedURL) ?? ""
        automaticUpdateChecks = load(.automaticUpdateChecks) != "0"
        automaticallyDownloadsUpdates = load(.automaticallyDownloadsUpdates) == "1"
    }

    func attach(store: SQLiteStore, organizer: OrganizerService, indexer: IndexerService,
                chat: ChatService, watcher: FileWatcherService) {
        self.organizer = organizer
        self.indexer = indexer
        self.chat = chat
        self.watcher = watcher
    }

    // MARK: - Explicit Persistent Setters
    func setWatchDirs(_ v: [String]) { watchDirs = v; save(.watchDirs, v.joined(separator: "\n")) }
    func setEnabledExtensions(_ v: [String]) { enabledExtensions = v; save(.enabledExts, v.joined(separator: ",")) }
    func setExcludeHidden(_ v: Bool) { excludeHidden = v; save(.excludeHidden, v ? "1" : "0") }
    func setClassifyStrategy(_ v: String) {
        let normalized = ClassificationStrategy(storedValue: v).rawValue
        classifyStrategy = normalized
        save(.classifyStrategy, normalized)
    }
    func setLLMChoice(_ v: String) {
        let normalized = LLMChoice(rawValue: v)?.rawValue ?? LLMChoice.ollama.rawValue
        llmChoice = normalized
        save(.llmChoice, normalized)
    }
    func setOllamaHost(_ v: String) { ollamaHost = v; save(.ollamaHost, v) }
    func setOllamaModel(_ v: String) { ollamaModel = v; save(.ollamaModel, v) }
    func setOllamaFlashAttentionEnabled(_ value: Bool) {
        ollamaFlashAttentionEnabled = value
        save(.ollamaFlashAttentionEnabled, value ? "1" : "0")
    }
    func setCloudAPIFormat(_ v: String) {
        let oldFormat = CloudAPIFormat(rawValue: cloudAPIFormat) ?? .openAI
        let format = CloudAPIFormat(rawValue: v) ?? .openAI
        cloudAPIFormat = format.rawValue
        save(.cloudAPIFormat, format.rawValue)

        // Replace only FileNest defaults; never overwrite a user-supplied compatible gateway or model.
        if oldFormat != format, format == .anthropic {
            if cloudBaseURL == "https://api.openai.com/v1" {
                setCloudBaseURL("https://api.anthropic.com/v1")
            }
            if cloudModel == "gpt-4o-mini" { setCloudModel("claude-sonnet-5") }
        } else if oldFormat != format, format == .openAI {
            if cloudBaseURL == "https://api.anthropic.com/v1" {
                setCloudBaseURL("https://api.openai.com/v1")
            }
            if cloudModel == "claude-sonnet-5" { setCloudModel("gpt-4o-mini") }
        }
    }
    func setCloudKey(_ v: String) { cloudAPIKey = v; save(.cloudKey, v) }
    func setCloudBaseURL(_ v: String) { cloudBaseURL = v; save(.cloudBaseURL, v) }
    func setCloudModel(_ v: String) { cloudModel = v; save(.cloudModel, v) }
    func setCloudContextWindowTokens(_ value: Int) {
        let normalized = Self.normalizedChatContextWindow(String(value))
        cloudContextWindowTokens = normalized
        save(.cloudContextWindowTokens, String(normalized))
    }
    func setAutoOrganize(_ v: Bool) {
        autoOrganize = v
        save(.autoOrganize, v ? "1" : "0")
        organizer?.reschedulePending()
    }
    func setAutoOrganizeMode(_ v: String) {
        let normalized = AutoOrganizeMode(rawValue: v)?.rawValue ?? AutoOrganizeMode.batched.rawValue
        autoOrganizeMode = normalized
        save(.autoOrganizeMode, normalized)
        organizer?.reschedulePending()
    }
    func setAutoOrganizeIntervalSeconds(_ v: Int) {
        let normalized = max(30, min(v, 3_600))
        autoOrganizeIntervalSeconds = normalized
        save(.autoOrganizeIntervalSeconds, String(normalized))
        organizer?.reschedulePending()
    }
    func setAutoOrganizeBatchSize(_ v: Int) {
        let normalized = max(2, min(v, 100))
        autoOrganizeBatchSize = normalized
        save(.autoOrganizeBatchSize, String(normalized))
        organizer?.reschedulePending()
    }
    func setAutoVectorize(_ v: Bool) {
        autoVectorize = v
        save(.autoVectorize, v ? "1" : "0")
    }
    func setVectorizeExtensions(_ values: [String]) {
        let normalized = Self.normalizedExtensions(values)
        vectorizeExtensions = normalized
        save(.vectorizeExtensions, normalized.joined(separator: ","))
    }
    func setVectorChunkWords(_ value: Int) {
        let normalized = max(600, min(value, 1_000))
        vectorChunkWords = normalized
        save(.vectorChunkWords, String(normalized))
        if vectorChunkOverlap >= normalized {
            setVectorChunkOverlap(max(0, normalized / 5))
        }
    }
    func setVectorChunkOverlap(_ value: Int) {
        let normalized = max(0, min(value, max(0, vectorChunkWords - 1)))
        vectorChunkOverlap = normalized
        save(.vectorChunkOverlap, String(normalized))
    }
    func setRAGResultLimit(_ value: Int) {
        let normalized = max(1, min(value, 30))
        ragResultLimit = normalized
        save(.ragResultLimit, String(normalized))
    }
    func setThinkingMode(_ value: Bool) {
        thinkingMode = value
        save(.thinkingMode, value ? "1" : "0")
    }
    func setDoclingEnabled(_ value: Bool) {
        doclingEnabled = value
        save(.doclingEnabled, value ? "1" : "0")
    }
    func setEmbeddingSource(_ value: String) {
        let normalized = EmbeddingSource(rawValue: value)?.rawValue ?? EmbeddingSource.ollama.rawValue
        embeddingSource = normalized
        save(.embeddingSource, normalized)
    }
    func setOllamaEmbeddingModel(_ value: String) {
        ollamaEmbeddingModel = value.trimmingCharacters(in: .whitespacesAndNewlines)
        save(.ollamaEmbeddingModel, ollamaEmbeddingModel)
    }
    func setCloudEmbeddingBaseURL(_ value: String) {
        cloudEmbeddingBaseURL = value
        save(.cloudEmbeddingBaseURL, value)
    }
    func setCloudEmbeddingAPIKey(_ value: String) {
        cloudEmbeddingAPIKey = value
        save(.cloudEmbeddingAPIKey, value)
    }
    func setCloudEmbeddingModel(_ value: String) {
        cloudEmbeddingModel = value
        save(.cloudEmbeddingModel, value)
    }
    func setCloudEmbeddingReuseChatCredentials(_ value: Bool) {
        cloudEmbeddingReuseChatCredentials = value
        save(.cloudEmbeddingReuseChatCredentials, value ? "1" : "0")
    }
    func setOCRSource(_ value: String) {
        let normalized = OCRSource(rawValue: value)?.rawValue ?? OCRSource.local.rawValue
        ocrSource = normalized
        save(.ocrSource, normalized)
    }
    func setOllamaOCRModel(_ value: String) {
        ollamaOCRModel = value.trimmingCharacters(in: .whitespacesAndNewlines)
        save(.ollamaOCRModel, ollamaOCRModel)
    }
    func setCloudOCRFormat(_ value: String) {
        let normalized = CloudAPIFormat(rawValue: value)?.rawValue ?? CloudAPIFormat.openAI.rawValue
        cloudOCRFormat = normalized
        save(.cloudOCRFormat, normalized)
    }
    func setCloudOCRBaseURL(_ value: String) {
        cloudOCRBaseURL = value
        save(.cloudOCRBaseURL, value)
    }
    func setCloudOCRAPIKey(_ value: String) {
        cloudOCRAPIKey = value
        save(.cloudOCRAPIKey, value)
    }
    func setCloudOCRModel(_ value: String) {
        cloudOCRModel = value
        save(.cloudOCRModel, value)
    }
    func setCloudOCRReuseChatCredentials(_ value: Bool) {
        cloudOCRReuseChatCredentials = value
        save(.cloudOCRReuseChatCredentials, value ? "1" : "0")
    }

    func shouldVectorize(extension fileExtension: String) -> Bool {
        autoVectorize && vectorizeExtensions.contains(fileExtension.lowercased())
    }
    func setAppLanguage(_ v: String) {
        let normalized = AppLanguage(rawValue: v)?.rawValue ?? AppLanguage.system.rawValue
        appLanguage = normalized
        save(.appLanguage, normalized)
    }
    func setAppearance(_ v: String) {
        let normalized = AppAppearance(rawValue: v)?.rawValue ?? AppAppearance.system.rawValue
        appearance = normalized
        save(.appearance, normalized)
    }
    func setOnboardingCompleted(_ value: Bool) {
        onboardingCompleted = value
        save(.onboardingCompleted, value ? "1" : "0")
    }
    func setUpdateFeedURL(_ value: String) {
        updateFeedURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        save(.updateFeedURL, updateFeedURL)
    }
    func setAutomaticUpdateChecks(_ value: Bool) {
        automaticUpdateChecks = value
        save(.automaticUpdateChecks, value ? "1" : "0")
    }
    func setAutomaticallyDownloadsUpdates(_ value: Bool) {
        automaticallyDownloadsUpdates = value
        save(.automaticallyDownloadsUpdates, value ? "1" : "0")
    }

    // MARK: - Keys and Persistence
    private enum Key: String {
        case watchDirs = "watch_dirs"
        case enabledExts = "enabled_exts"
        case excludeHidden = "exclude_hidden"
        case classifyStrategy = "classify_strategy"
        case llmChoice = "llm_choice"
        case ollamaHost = "ollama_host"
        case ollamaModel = "ollama_model"
        case ollamaFlashAttentionEnabled = "ollama_flash_attention_enabled"
        case cloudAPIFormat = "cloud_api_format"
        case cloudKey = "cloud_key"
        case cloudBaseURL = "cloud_base_url"
        case cloudModel = "cloud_model"
        case cloudContextWindowTokens = "cloud_context_window_tokens"
        case legacyChatContextWindowTokens = "chat_context_window_tokens"
        case autoOrganize = "auto_organize"
        case autoOrganizeMode = "auto_organize_mode"
        case autoOrganizeIntervalSeconds = "auto_organize_interval_seconds"
        case autoOrganizeBatchSize = "auto_organize_batch_size"
        case autoVectorize = "auto_vectorize"
        case vectorizeExtensions = "vectorize_extensions"
        case vectorChunkWords = "vector_chunk_words"
        case vectorChunkOverlap = "vector_chunk_overlap"
        case ragResultLimit = "rag_result_limit"
        case chunkDefaults600Migration = "chunk_defaults_600_80_migration_v1"
        case doclingEnabled = "docling_enabled"
        case embeddingSource = "embedding_source"
        case ollamaEmbeddingModel = "ollama_embedding_model"
        case cloudEmbeddingBaseURL = "cloud_embedding_base_url"
        case cloudEmbeddingAPIKey = "cloud_embedding_api_key"
        case cloudEmbeddingModel = "cloud_embedding_model"
        case cloudEmbeddingReuseChatCredentials = "cloud_embedding_reuse_chat_credentials"
        case ocrSource = "ocr_source"
        case ollamaOCRModel = "ollama_ocr_model"
        case cloudOCRFormat = "cloud_ocr_format"
        case cloudOCRBaseURL = "cloud_ocr_base_url"
        case cloudOCRAPIKey = "cloud_ocr_api_key"
        case cloudOCRModel = "cloud_ocr_model"
        case cloudOCRReuseChatCredentials = "cloud_ocr_reuse_chat_credentials"
        case paddleOCRDefaultMigration = "paddle_ocr_default_migration_v1"
        case thinkingMode = "thinking_mode"
        case appLanguage = "app_language"
        case appearance = "appearance"
        case onboardingCompleted = "onboarding_completed"
        case updateFeedURL = "update_feed_url"
        case automaticUpdateChecks = "automatic_update_checks"
        case automaticallyDownloadsUpdates = "automatically_downloads_updates"
    }
    private func load(_ k: Key) -> String? { store.getSetting(k.rawValue) }
    private func save(_ k: Key, _ v: String) { store.setSetting(k.rawValue, v) }
    private static func normalizedInterval(_ raw: String?) -> Int {
        max(30, min(Int(raw ?? "") ?? 30, 3_600))
    }
    private static func normalizedBatchSize(_ raw: String?) -> Int {
        max(2, min(Int(raw ?? "") ?? 5, 100))
    }
    private static func normalizedChatContextWindow(_ raw: String?) -> Int {
        guard let value = Int(raw ?? ""), value > 0 else { return 0 }
        return max(2_048, min(value, 4_000_000))
    }
    private static func normalizedChunkWords(_ raw: String?) -> Int {
        max(600, min(Int(raw ?? "") ?? 600, 1_000))
    }
    private static func normalizedChunkOverlap(_ raw: String?, chunkWords: Int) -> Int {
        max(0, min(Int(raw ?? "") ?? 80, max(0, chunkWords - 1)))
    }
    private static func normalizedRAGResultLimit(_ raw: String?) -> Int {
        max(1, min(Int(raw ?? "") ?? 10, 30))
    }
    private static func normalizedExtensions(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value
                .trimmingCharacters(in: CharacterSet(charactersIn: " .\t\n"))
                .lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
    private func loadStrArr(_ k: Key, sep: Character) -> [String]? {
        guard let raw = load(k) else { return nil }
        let arr = raw.split(separator: sep).map { $0.trimmingCharacters(in: .whitespaces) }
        return arr.filter { !$0.isEmpty }
    }

    private let defaultExts = ["pdf","doc","docx","docm","txt","md","rtf","xls","xlsx","xlsm","ppt","pptx","ppsx","csv","epub","odt","ods","odp","pages","numbers","key",
                               "png","jpg","jpeg","gif","heic","tiff","svg","psd","sketch","webp",
                               "mp4","mov","mkv","avi","m4v","mp3","wav","aac","flac","m4a",
                               "swift","py","js","ts","tsx","jsx","java","kt","go","rs","c","cpp","h",
                               "json","yaml","yml","html","css","sql","zip","rar","7z","tar","gz","dmg"]

    static let documentVectorizeExtensions = [
        "pdf", "doc", "docx", "docm", "xls", "xlsx", "xlsm", "ppt", "pptx", "ppsx",
        "epub", "odt", "ods", "odp", "pages", "numbers", "key", "keynote",
        "txt", "md", "markdown", "rtf", "csv", "json", "yaml", "yml", "xml", "html"
    ]

    static let defaultVectorizeExtensions = documentVectorizeExtensions + [
        "png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"
    ]

    static func defaultWatchDirectories(fileManager: FileManager = .default) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser
        let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Desktop", isDirectory: true)
        let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Downloads", isDirectory: true)
        var seen = Set<String>()
        return [desktop, downloads].compactMap { url in
            let path = url.standardizedFileURL.path
            return seen.insert(path).inserted ? path : nil
        }
    }

    /// Active LLM provider selected by settings.
    func makeLLMProvider(modelOverride: String? = nil) -> LLMProvider {
        switch LLMChoice(rawValue: llmChoice) ?? .ollama {
        case .ollama:
            return OllamaLLMProvider(
                host: ollamaHost,
                model: modelOverride ?? ollamaModel,
                thinkingEnabled: thinkingMode
            )
        case .cloud:
            switch CloudAPIFormat(rawValue: cloudAPIFormat) ?? .openAI {
            case .openAI:
                return OpenAICompatibleLLMProvider(
                    baseURL: cloudBaseURL,
                    apiKey: cloudAPIKey,
                    model: modelOverride ?? cloudModel,
                    thinkingEnabled: thinkingMode
                )
            case .anthropic:
                return AnthropicLLMProvider(
                    baseURL: cloudBaseURL,
                    apiKey: cloudAPIKey,
                    model: modelOverride ?? cloudModel,
                    thinkingEnabled: thinkingMode
                )
            }
        case .none:
            return NoopLLMProvider(
                questionFormat: localized("Chat is disabled.\nYour question: %@"),
                disabledMessage: localized("Chat is disabled. Enable local Ollama or a cloud API in Settings.")
            )
        }
    }

    func makeLocalLLMProvider(modelOverride: String? = nil) -> LLMProvider {
        OllamaLLMProvider(
            host: ollamaHost,
            model: modelOverride ?? ollamaModel,
            thinkingEnabled: thinkingMode
        )
    }

    var effectiveCloudEmbeddingBaseURL: String {
        cloudEmbeddingReuseChatCredentials ? cloudBaseURL : cloudEmbeddingBaseURL
    }

    var effectiveCloudEmbeddingAPIKey: String {
        cloudEmbeddingReuseChatCredentials ? cloudAPIKey : cloudEmbeddingAPIKey
    }

    var effectiveCloudOCRBaseURL: String {
        cloudOCRReuseChatCredentials ? cloudBaseURL : cloudOCRBaseURL
    }

    var effectiveCloudOCRAPIKey: String {
        cloudOCRReuseChatCredentials ? cloudAPIKey : cloudOCRAPIKey
    }

    var embeddingConfigurationSignature: String {
        [embeddingSource, ollamaHost, ollamaEmbeddingModel, effectiveCloudEmbeddingBaseURL,
         cloudEmbeddingModel, effectiveCloudEmbeddingAPIKey].joined(separator: "|")
    }

    var ocrConfigurationSignature: String {
        [
            ocrSource,
            ollamaHost,
            ollamaOCRModel,
            cloudOCRFormat,
            effectiveCloudOCRBaseURL,
            effectiveCloudOCRAPIKey,
            cloudOCRModel,
            PaddleOCRServiceManager.hasManagedEnvironment
                ? (PaddleOCRServiceManager.installedPackageVersion
                   ?? PaddleOCRServiceManager.paddleOCRVersion)
                : "unavailable",
        ].joined(separator: "|")
    }

    /// The provider type and model define the vector space. Changes require an automatic rebuild because old and new vectors cannot be mixed.
    var embeddingSpaceSignature: String {
        let model: String
        switch EmbeddingSource(rawValue: embeddingSource) ?? .ollama {
        case .ollama:
            model = ollamaEmbeddingModel
        case .cloud:
            model = cloudEmbeddingModel
        case .apple:
            model = "nlembedding:english"
        }
        return Self.signatureDigest([
            "embedding-space-v1",
            embeddingSource,
            model,
        ])
    }

    /// These settings change extraction, chunking, or indexing scope without changing the vector space; the user decides whether to rebuild.
    /// Records only stable configuration and excludes transient Docling or PaddleOCR availability from the signature.
    var contentProcessingSignature: String {
        let categorySignatures = indexContentCategorySignatures
        return Self.signatureDigest(
            ["content-processing-v2"] + IndexContentChangeCategory.allCases.flatMap {
                [$0.rawValue, categorySignatures[$0] ?? ""]
            }
        )
    }

    var indexContentCategorySignatures: [IndexContentChangeCategory: String] {
        let doclingVersion = DoclingServiceManager.installedPackageVersion
            ?? DoclingServiceManager.pinnedVersion
        let doclingConfiguration = doclingEnabled
            ? "docling:\(doclingVersion)"
            : "disabled"
        let embeddingEndpointConfiguration: String
        switch EmbeddingSource(rawValue: embeddingSource) ?? .ollama {
        case .ollama:
            embeddingEndpointConfiguration = ollamaHost
        case .cloud:
            embeddingEndpointConfiguration = effectiveCloudEmbeddingBaseURL
        case .apple:
            embeddingEndpointConfiguration = "local"
        }
        let ocrProviderConfiguration: [String]
        switch OCRSource(rawValue: ocrSource) ?? .local {
        case .local:
            let paddleOCRVersion = PaddleOCRServiceManager.installedPackageVersion
                ?? PaddleOCRServiceManager.paddleOCRVersion
            ocrProviderConfiguration = [
                "paddleocr:\(paddleOCRVersion)",
                ollamaOCRModel,
            ]
        case .cloud:
            ocrProviderConfiguration = [
                cloudOCRFormat,
                cloudOCRModel,
            ]
        case .disabled:
            ocrProviderConfiguration = ["disabled"]
        }
        let ocrEndpointConfiguration: String
        switch OCRSource(rawValue: ocrSource) ?? .local {
        case .local: ocrEndpointConfiguration = ollamaHost
        case .cloud: ocrEndpointConfiguration = effectiveCloudOCRBaseURL
        case .disabled: ocrEndpointConfiguration = "disabled"
        }
        return [
            .chunking: Self.signatureDigest([
                "chunking-v3", String(vectorChunkWords), String(vectorChunkOverlap),
            ]),
            .documentParsing: Self.signatureDigest([
                "document-parsing-v1", doclingConfiguration,
            ]),
            .ocr: Self.signatureDigest([
                // v2: raster images always use the dedicated OCR pipeline and never Docling's
                // native OpenCV image path.
                "ocr-v2", ocrSource, ocrProviderConfiguration.joined(separator: ":"),
            ]),
            .indexingScope: Self.signatureDigest([
                "indexing-scope-v1",
                autoVectorize ? "1" : "0",
                vectorizeExtensions.sorted().joined(separator: ","),
            ]),
            .serviceEndpoint: Self.signatureDigest([
                "service-endpoint-v1",
                embeddingEndpointConfiguration,
                ocrEndpointConfiguration,
            ]),
        ]
    }

    /// The file-level signature represents only vector-space compatibility; content-processing changes no longer invalidate files automatically.
    var indexConfigurationSignature: String { embeddingSpaceSignature }

    private static func signatureDigest(_ fields: [String]) -> String {
        let digest = SHA256.hash(data: Data(fields.joined(separator: "|").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Local defaults prefer Ollama qwen3-embedding; the Apple model remains an explicit compatibility option.
    func makeEmbeddingProvider() -> EmbeddingProvider {
        switch EmbeddingSource(rawValue: embeddingSource) ?? .ollama {
        case .ollama:
            return OllamaEmbeddingProvider(host: ollamaHost, model: ollamaEmbeddingModel)
        case .cloud:
            return OpenAICompatibleEmbeddingProvider(
                baseURL: effectiveCloudEmbeddingBaseURL,
                apiKey: effectiveCloudEmbeddingAPIKey,
                model: cloudEmbeddingModel
            )
        case .apple:
            return NLEmbeddingProvider() ?? OllamaEmbeddingProvider(
                host: ollamaHost,
                model: ollamaEmbeddingModel
            )
        }
    }

    func makeOCRProvider() -> OCRProvider? {
        switch OCRSource(rawValue: ocrSource) ?? .local {
        case .local:
            return FallbackOCRProvider(
                primary: PaddleOCRProvider(),
                fallback: OllamaOCRProvider(host: ollamaHost, model: ollamaOCRModel)
            )
        case .cloud:
            let format = CloudAPIFormat(rawValue: cloudOCRFormat) ?? .openAI
            return CloudOCRProvider(
                format: format,
                baseURL: effectiveCloudOCRBaseURL,
                apiKey: effectiveCloudOCRAPIKey,
                model: cloudOCRModel
            )
        case .disabled:
            return nil
        }
    }
}
