import SwiftUI

/// 菜单栏弹窗：状态 + 快速操作 + 最近文件
struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 状态头
            HStack {
                Image(systemName: appState.isWatching ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(appState.isWatching ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("FileNest").font(.headline)
                    Text("\(appState.statusText) · 已索引 \(appState.indexedCount) 个文件")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)

            Divider()

            // 监听开关
            HStack {
                Toggle(isOn: Binding(
                    get: { appState.isWatching },
                    set: { $0 ? appState.startWatching() : appState.stopWatching() }
                )) { Text("自动监听整理").font(.subheadline) }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            // 快速操作
            HStack(spacing: 8) {
                Button { appState.organizer.runOnce(); appState.refresh() } label: {
                    Label("立即整理", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                Button { appState.indexer.reindexAll() } label: {
                    Label("重新索引", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            // 最近文件
            VStack(alignment: .leading, spacing: 0) {
                Text("最近整理").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 8)
                if appState.files.isEmpty {
                    Text("还没有文件被索引\n把文件放到下载目录试试")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(appState.files.prefix(8)) { f in
                                MenuBarFileRow(file: f)
                            }
                        }
                        .padding(.horizontal, 8).padding(.bottom, 8)
                    }
                }
            }

            Divider()

            // 底部
            HStack {
                Button("打开主窗口") { openMainWindow() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(10)
        }
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // 通过 WindowGroup id 激活
        if let window = NSApp.windows.first(where: { $0.title == "FileNest" }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSApp.sendAction(Selector(("showMainWindow:")), to: nil, from: nil)
        }
    }
}

struct MenuBarFileRow: View {
    let file: FileRecord
    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
        } label: {
            HStack(spacing: 8) {
                Image(systemName: file.categoryEnum.icon)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).lineLimit(1).font(.caption)
                    if let t = file.title, !t.isEmpty {
                        Text(t).lineLimit(1).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3).padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }
}
