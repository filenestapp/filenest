import SwiftUI

/// 文件库：搜索 + 分类筛选 + 列表
struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var category: FileCategory? = nil

    var filtered: [FileRecord] {
        appState.files.filter { f in
            (category == nil || f.categoryEnum == category) &&
            (searchText.isEmpty ||
             f.name.localizedCaseInsensitiveContains(searchText) ||
             (f.title ?? "").localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                TextField("搜索文件名、标题、内容…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button { runSearch() } label: { Label("搜索", systemImage: "magnifyingglass") }
            }
            .padding(12)

            // 分类筛选条
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Chip(label: "全部", selected: category == nil) { category = nil }
                    ForEach(FileCategory.allCases) { c in
                        Chip(label: c.label, systemImage: c.icon, selected: category == c) { category = c }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 8)

            Divider()

            // 列表
            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("没有匹配的文件").font(.headline)
                    Text("试试调整搜索词或分类，或把文件放到下载目录后点「立即整理」")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filtered) {
                    TableColumn("") { f in
                        Image(systemName: f.categoryEnum.icon).foregroundStyle(.tint)
                            .frame(width: 20)
                    }.width(28)
                    TableColumn("名称") { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).font(.body)
                            if let t = f.title, !t.isEmpty {
                                Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    TableColumn("类别") { f in Text(f.categoryEnum.label) }.width(70)
                    TableColumn("大小") { f in Text(formatSize(f.size)) }.width(80)
                    TableColumn("修改时间") { f in Text(f.mtime.formatted(date: .abbreviated, time: .shortened)) }.width(140)
                    TableColumn("") { f in
                        Button { reveal(f) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                            .help("在 Finder 中显示")
                    }.width(36)
                }
                .contextMenu(forSelectionType: FileRecord.self) { items in
                    if let f = items.first {
                        Button("在 Finder 中显示") { reveal(f) }
                        Button("打开") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: f.path))
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { appState.organizer.runOnce(); appState.refresh() } label: {
                    Label("立即整理", systemImage: "tray.and.arrow.down")
                }
            }
            ToolbarItem {
                Button { appState.indexer.reindexAll() } label: {
                    Label("重新索引", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
    }

    private func runSearch() {
        if !searchText.isEmpty {
            // 关键词检索（含 content_text）
            appState.files = (try? appState.store.files(matching: searchText)) ?? []
        } else {
            appState.refresh()
        }
    }

    private func reveal(_ f: FileRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)])
    }

    private func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct Chip: View {
    let label: String
    var systemImage: String? = nil
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let s = systemImage { Image(systemName: s) }
                Text(label)
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.2) : Color(nsColor: .controlBackgroundColor))
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(selected ? Color.accentColor : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
