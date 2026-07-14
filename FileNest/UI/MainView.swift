import SwiftUI

/// 主窗口：左侧导航 + 右侧内容（文件库 / 规则 / 聊天）
struct MainView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: SidebarItem? = .library

    enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
        case library, chat, rules
        var id: String { rawValue }
        var label: String {
            switch self {
            case .library: return "文件库"
            case .chat: return "聊天找文件"
            case .rules: return "整理规则"
            }
        }
        var icon: String {
            switch self {
            case .library: return "folder"
            case .chat: return "bubble.left.and.bubble.right"
            case .rules: return "list.bullet.rectangle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("FileNest") {
                    ForEach(SidebarItem.allCases) { item in
                        NavigationLink(value: item) {
                            Label(item.label, systemImage: item.icon)
                        }
                    }
                }
                Section("状态") {
                    HStack {
                        Image(systemName: appState.isWatching ? "checkmark.circle.fill" : "pause.circle")
                            .foregroundStyle(appState.isWatching ? .green : .secondary)
                        Text(appState.statusText).font(.caption)
                    }
                    Text("已索引 \(appState.indexedCount)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("FileNest")
            .frame(minWidth: 200)
        } detail: {
            switch selection {
            case .chat: ChatView()
            case .rules: RulesView()
            default: LibraryView()
            }
        }
        .onAppear {
            appState.refresh()
            if !appState.isWatching { appState.startWatching() }
        }
    }
}
