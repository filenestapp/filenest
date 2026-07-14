import Foundation
import Combine
import NaturalLanguage

/// 设置：所有可配置项集中管理，持久化于 SQLite settings 表。
/// 贯彻「合理默认 + 可配置」。
/// 注意：@Published 属性不能用 didSet，因此持久化逻辑放在独立的 set() 里，
/// UI 通过 SettingBinding 适配器间接调用 set()。
final class AppSettings: ObservableObject {
    static let shared = AppSettings(store: .shared)

    private let store: SQLiteStore
    private weak var organizer: OrganizerService?
    private weak var indexer: IndexerService?
    private weak var chat: ChatService?
    private weak var watcher: FileWatcherService?

    // MARK: 可配置项
    @Published var watchDirs: [String] = []
    @Published var enabledExtensions: [String] = []
    @Published var excludeHidden: Bool = true
    @Published var classifyStrategy: String = "hybrid"
    @Published var llmChoice: String = LLMChoice.ollama.rawValue
    @Published var ollamaHost: String = "http://127.0.0.1:11434"
    @Published var ollamaModel: String = "qwen2.5:7b"
    @Published var cloudAPIKey: String = ""
    @Published var cloudBaseURL: String = "https://api.openai.com/v1"
    @Published var cloudModel: String = "gpt-4o-mini"
    @Published var autoOrganize: Bool = true

    enum LLMChoice: String, CaseIterable, Identifiable { case ollama, cloud, none
        var id: String { rawValue }
        var label: String { self == .ollama ? "本地 Ollama" : self == .cloud ? "云端 API" : "禁用" }
    }

    init(store: SQLiteStore) {
        self.store = store
        watchDirs = loadStrArr(.watchDirs, sep: "\n") ?? [defaultDownloads().path]
        enabledExtensions = loadStrArr(.enabledExts, sep: ",") ?? defaultExts
        excludeHidden = load(.excludeHidden) != "0"
        classifyStrategy = ClassificationStrategy(
            storedValue: load(.classifyStrategy) ?? ClassificationStrategy.hybrid.rawValue
        ).rawValue
        llmChoice = LLMChoice(rawValue: load(.llmChoice) ?? "")?.rawValue
            ?? LLMChoice.ollama.rawValue
        ollamaHost = load(.ollamaHost) ?? "http://127.0.0.1:11434"
        ollamaModel = load(.ollamaModel) ?? "qwen2.5:7b"
        cloudAPIKey = load(.cloudKey) ?? ""
        cloudBaseURL = load(.cloudBaseURL) ?? "https://api.openai.com/v1"
        cloudModel = load(.cloudModel) ?? "gpt-4o-mini"
        autoOrganize = load(.autoOrganize) != "0"
    }

    func attach(store: SQLiteStore, organizer: OrganizerService, indexer: IndexerService,
                chat: ChatService, watcher: FileWatcherService) {
        self.organizer = organizer
        self.indexer = indexer
        self.chat = chat
        self.watcher = watcher
    }

    // MARK: - 显式 setter（持久化）
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
    func setCloudKey(_ v: String) { cloudAPIKey = v; save(.cloudKey, v) }
    func setCloudBaseURL(_ v: String) { cloudBaseURL = v; save(.cloudBaseURL, v) }
    func setCloudModel(_ v: String) { cloudModel = v; save(.cloudModel, v) }
    func setAutoOrganize(_ v: Bool) { autoOrganize = v; save(.autoOrganize, v ? "1" : "0") }

    // MARK: 键与读写
    private enum Key: String {
        case watchDirs = "watch_dirs"
        case enabledExts = "enabled_exts"
        case excludeHidden = "exclude_hidden"
        case classifyStrategy = "classify_strategy"
        case llmChoice = "llm_choice"
        case ollamaHost = "ollama_host"
        case ollamaModel = "ollama_model"
        case cloudKey = "cloud_key"
        case cloudBaseURL = "cloud_base_url"
        case cloudModel = "cloud_model"
        case autoOrganize = "auto_organize"
    }
    private func load(_ k: Key) -> String? { store.getSetting(k.rawValue) }
    private func save(_ k: Key, _ v: String) { store.setSetting(k.rawValue, v) }
    private func loadStrArr(_ k: Key, sep: Character) -> [String]? {
        guard let raw = load(k) else { return nil }
        let arr = raw.split(separator: sep).map { $0.trimmingCharacters(in: .whitespaces) }
        return arr.filter { !$0.isEmpty }
    }

    private let defaultExts = ["pdf","doc","docx","txt","md","rtf","xls","xlsx","ppt","pptx","csv","epub",
                               "png","jpg","jpeg","gif","heic","tiff","svg","psd","sketch","webp",
                               "mp4","mov","mkv","avi","m4v","mp3","wav","aac","flac","m4a",
                               "swift","py","js","ts","tsx","jsx","java","kt","go","rs","c","cpp","h",
                               "json","yaml","yml","html","css","sql","zip","rar","7z","tar","gz","dmg"]

    private func defaultDownloads() -> URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// 当前生效的 LLM Provider（根据设置）
    func makeLLMProvider() -> LLMProvider {
        switch LLMChoice(rawValue: llmChoice) ?? .ollama {
        case .ollama: return OllamaLLMProvider(host: ollamaHost, model: ollamaModel)
        case .cloud:  return OpenAICompatibleLLMProvider(baseURL: cloudBaseURL, apiKey: cloudAPIKey, model: cloudModel)
        case .none:   return NoopLLMProvider()
        }
    }

    /// 默认 Embedding Provider：Apple NLEmbedding（离线、隐私、零配置）
    func makeEmbeddingProvider() -> EmbeddingProvider {
        if let p = NLEmbeddingProvider() { return p }
        return OllamaEmbeddingProvider(host: ollamaHost, model: "nomic-embed-text")
    }
}
