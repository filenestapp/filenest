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

    init() {
        let store = SQLiteStore.shared
        self.store = store
        self.settings = AppSettings.shared
        self.organizer = OrganizerService(store: store, settings: AppSettings.shared)
        self.indexer = IndexerService(store: store, settings: AppSettings.shared)
        self.chat = ChatService(store: store, settings: AppSettings.shared)
        // watcher 依赖 organizer + indexer，先创建前两者
        self.watcher = FileWatcherService(
            store: store,
            organizer: self.organizer,
            indexer: self.indexer
        )
        self.settings.attach(store: store, organizer: organizer, indexer: indexer, chat: chat, watcher: watcher)
        // 让 ChatService 能访问向量库
        AppStateIndexerProxy.shared.indexer = indexer
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
        Task { await watcher.start() }
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
