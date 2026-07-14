import SwiftUI

@main
struct FileNestApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        // 菜单栏常驻：点击弹出状态 + 快速入口
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .frame(width: 360, height: 460)
        } label: {
            Image(systemName: appState.statusIcon)
        }
        .menuBarExtraStyle(.window)

        // 主窗口：文件库 / 规则 / 聊天
        WindowGroup("FileNest") {
            MainView()
                .environmentObject(appState)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button("立即整理一次") { appState.organizer.runOnce() }
                    .keyboardShortcut("O", modifiers: [.command, .shift])
                Button("重新索引") { appState.indexer.reindexAll() }
                    .keyboardShortcut("R", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
