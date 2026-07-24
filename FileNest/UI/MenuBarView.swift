import AppKit
import SwiftUI

/// Menu bar popover for watch status, quick organization, and recent files.
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    private var recentFiles: [FileRecord] {
        if FileNestEnvironment.isUIPreview || FileNestEnvironment.isMenuPreview { return UIShowcaseData.menuFiles }
        return appState.recentlyOrganizedFiles(limit: 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    statusSection
                    Divider().padding(.horizontal, 16)
                    actions
                    Divider().padding(.horizontal, 16)
                    recentSection
                }
            }
            .scrollIndicators(.hidden)
            Divider().padding(.horizontal, 16)
            footer
        }
        .background(FileNestTheme.surface.opacity(0.97))
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandMark(size: 34)
            Text("FileNest")
                .font(.system(size: 20, weight: .semibold))
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(height: 70)
    }

    private var statusSection: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(watchStatusColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LocalizedStringKey(appState.watchStatusTitle))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(watchStatusColor)
                    Text(LocalizedStringKey(appState.watchStatusSubtitle))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(indexedFileCountText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack {
                Text("Automatic Watching")
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { appState.isWatching },
                    set: { $0 ? appState.startWatching() : appState.stopWatching() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(FileNestTheme.accent)
                .labelsHidden()
            }

            if appState.hasWatchDirectoryAccessIssue {
                HStack(spacing: 8) {
                    Button("Check Again") { appState.retryWatchDirectoryAccess() }
                    Button("Restore Access…") { appState.openWatchDirectoryPrivacySettings() }
                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if appState.organizationState.isActive ||
                appState.indexingState.isActive ||
                appState.indexingState == .stopped ||
                appState.indexingState == .failed {
                Divider()
                if appState.organizationState.isActive {
                    ManualOrganizationQueueView(appState: appState, maximumItems: 3, showsControls: false)
                } else {
                    IndexingStatusProgressView(appState: appState)
                }
            }

            if !appState.automaticFileProcessingItems.isEmpty {
                Divider()
                AutomaticProcessingQueueView(appState: appState)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private var indexedFileCountText: String {
        appState.settings.localizedFormat(
            "%d files indexed",
            FileNestEnvironment.isMenuPreview ? 68 : appState.indexedCount
        )
    }

    private var watchStatusColor: Color {
        if appState.hasActiveWatchDirectories { return FileNestTheme.success }
        if appState.isWatching { return FileNestTheme.warning }
        return .secondary
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if appState.organizationState == .running {
                HStack(spacing: 8) {
                    Button { appState.pauseOrganization() } label: {
                        Label("Pause Organization", systemImage: "pause.circle")
                            .frame(maxWidth: .infinity)
                    }
                    Button(role: .destructive) { appState.stopOrganization() } label: {
                        Label("Stop", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(QuietButtonStyle())
            } else if appState.organizationState == .paused {
                HStack(spacing: 8) {
                    Button { appState.resumeOrganization() } label: {
                        Label("Resume Organization", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    Button(role: .destructive) { appState.stopOrganization() } label: {
                        Label("Stop", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(QuietButtonStyle())
            } else {
                OrganizeNowMenu {
                    Label("Organize Now", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(GradientButtonStyle())
            }

            if !appState.organizationState.isActive {
                Button {
                    appState.reindexAll()
                } label: {
                    IndexingButtonLabel(defaultTitle: "Reindex", appState: appState)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(appState.reindexButtonsDisabled)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var recentSection: some View {
        let files = recentFiles
        return VStack(alignment: .leading, spacing: 8) {
            Text("Recently Organized")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            if files.isEmpty {
                Text("No organized files yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 94)
            } else {
                VStack(spacing: 2) {
                    ForEach(files) { file in
                        MenuBarFileRow(
                            file: file,
                            localizedCategory: appState.settings.localized(file.categoryEnum.label)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            MenuFooterButton(title: "Open Main Window", icon: "folder", showsChevron: true) {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            MenuFooterButton(title: "Settings…", icon: "gearshape", showsChevron: true) {
                appState.presentSettings(.general)
                MainWindowPresenter.shared.present()
            }
            MenuFooterButton(title: "Quit FileNest", icon: "power", showsChevron: false) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

}

private struct MenuBarFileRow: View {
    let file: FileRecord
    let localizedCategory: String

    var body: some View {
        Button {
            let url = URL(fileURLWithPath: file.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 11) {
                FileIconView(file: file, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(LocalizedStringKey(subtitle))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(recentDate, format: .dateTime.hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
            }
        }
    }

    private var recentDate: Date {
        file.organizedAt ?? file.indexedAt ?? file.discoveredAt ?? file.mtime
    }

    private var subtitle: String {
        let folder = URL(fileURLWithPath: file.path).deletingLastPathComponent().lastPathComponent
        guard !folder.isEmpty, folder != file.categoryEnum.folderName else { return localizedCategory }
        return "\(localizedCategory) / \(folder)"
    }
}

private struct MenuFooterButton: View {
    let title: String
    let icon: String
    let showsChevron: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 20)
                Text(LocalizedStringKey(title))
                    .font(.system(size: 15))
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
