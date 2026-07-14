import Foundation
import SwiftUI
import Combine

/// 应用全局状态：持有所有服务实例，驱动 UI 响应式更新
@MainActor
final class AppState: ObservableObject {
    let store: SQLiteStore
    let settings: AppSettings
    let watcher: FileWatcherService
    let organizer: OrganizerService
    let indexer: IndexerService
    let chat: ChatService

    @Published var statusIcon = "tray"
    @Published var statusText = "就绪"
    @Published var indexedCount: Int = 0
    @Published var isWatching = false

    // 文件库 / 聊天等 UI 数据源
    @Published var files: [FileRecord] = []
    @Published var rules: [Rule] = []
    @Published var chatMessages: [ChatMessage] = []

    private var cancellables = Set<AnyCancellable>()

    init(store: SQLiteStore = .shared,
         settings: AppSettings = .shared,
         startAutomatically: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil) {
        self.store = store
        self.settings = settings
        let organizer = OrganizerService(store: store, settings: settings)
        let indexer = IndexerService(store: store, settings: settings)
        let chat = ChatService(store: store, settings: settings, vectorStore: indexer.vectorStore)
        // watcher 依赖 organizer + indexer，先创建前两者
        let watcher = FileWatcherService(
            store: store,
            organizer: organizer,
            indexer: indexer,
            settings: settings
        )
        self.organizer = organizer
        self.indexer = indexer
        self.chat = chat
        self.watcher = watcher
        self.settings.attach(store: store, organizer: organizer, indexer: indexer, chat: chat, watcher: watcher)
        // Organizer 批处理与设置页仍通过代理访问当前索引器。
        AppStateIndexerProxy.shared.indexer = indexer
        // XCTest 会启动宿主 App；测试期间默认只刷新状态，不扫描用户目录。
        guard startAutomatically else { refresh(); return }
        // 首次启动注入默认规则
        try? store.seedDefaultRulesIfNeeded()
        // 预热向量索引
        Task { await indexer.warmup() }
        refresh()
        // 启动即自动监听（菜单栏 app 可能不会立刻打开主窗口）
        startWatching()
    }

    func refresh() {
        files = (try? store.allFiles()) ?? []
        rules = (try? store.allRules()) ?? []
        indexedCount = files.count
    }

    func startWatching() {
        watcher.start()
        isWatching = true
        statusIcon = "tray.full"
        statusText = "监听中"
    }

    func stopWatching() {
        watcher.stop()
        isWatching = false
        statusIcon = "tray"
        statusText = "已暂停"
    }
}
