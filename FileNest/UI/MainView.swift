import AppKit
import SwiftUI

/// Main window with a stable global sidebar shared by the library and chat.
struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @SceneStorage("FileNest.mainSelection") private var selectionRawValue = SidebarItem.chat.rawValue
    @SceneStorage("FileNest.sidebarCollapsed") private var isSidebarCollapsed = false
    @State private var isSidebarToggleHovered = false
    @State private var isNewChatHovered = false
    @State private var restoreSidebarAfterPreview = false

    enum SidebarItem: String, CaseIterable, Identifiable {
        case library
        case chat

        var id: String { rawValue }

        var label: String {
            switch self {
            case .library: return "Library"
            case .chat: return "Find with Chat"
            }
        }

        var icon: String {
            switch self {
            case .library: return "folder"
            case .chat: return "ellipsis.message"
            }
        }
    }

    private var selection: SidebarItem {
        get { SidebarItem(rawValue: selectionRawValue) ?? .chat }
        nonmutating set { selectionRawValue = newValue.rawValue }
    }

    private var watchPath: String {
        if FileNestEnvironment.isUIPreview { return "~/FileNestWatch" }
        guard let first = appState.settings.watchDirs.first else {
            return appState.settings.localized("No watched folder")
        }
        return URL(fileURLWithPath: first).tildeAbbreviatedPath
    }

    var body: some View {
        HStack(spacing: 0) {
            if !isSidebarCollapsed {
                FileNestSidebar(
                    selection: Binding(
                        get: { selection },
                        set: { selection = $0 }
                    ),
                    openSettings: openSettings
                )
                .frame(width: 255)
                .transition(.move(edge: .leading).combined(with: .opacity))

                Rectangle()
                    .fill(FileNestTheme.border)
                    .frame(width: 1)
                    .transition(.opacity)
            }

            Group {
                switch selection {
                case .library:
                    LibraryView(startDocumentChat: startDocumentChat)
                case .chat:
                    ChatView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FileNestTheme.surface)

            if let previewedFile = appState.previewedFile {
                Rectangle()
                    .fill(FileNestTheme.border)
                    .frame(width: 1)

                FilePreviewView(
                    file: previewedFile,
                    startDocumentChat: startDocumentChat
                )
                .id(previewedFile.id.map(String.init) ?? previewedFile.path)
                .frame(width: 334)
                .frame(maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(.ultraThinMaterial)
        .animation(.easeInOut(duration: 0.18), value: isSidebarCollapsed)
        .animation(.easeInOut(duration: 0.2), value: appState.previewedFile?.path)
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    toolbarNavigationControls
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    toolbarNavigationControls
                }
            }
        }
        .onAppear {
            appState.refresh()
            appState.refreshChatSessions()
            if appState.settings.onboardingCompleted && !appState.isWatching {
                appState.startWatching()
            }
            presentOnboardingIfNeeded()
        }
        .onChange(of: appState.isOnboardingPresented) { isPresented in
            if isPresented { presentOnboardingIfNeeded() }
        }
        .onChange(of: appState.previewedFile?.path) { previewPath in
            coordinateSidebar(withPreviewPath: previewPath)
        }
    }

    private var toolbarNavigationControls: some View {
        HStack(alignment: .center, spacing: 4) {
            sidebarToggleButton

            if isSidebarCollapsed {
                collapsedToolbarControls
            }
        }
        .frame(height: 28, alignment: .center)
    }

    private var sidebarToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if appState.previewedFile != nil {
                    restoreSidebarAfterPreview = false
                }
                isSidebarCollapsed.toggle()
            }
        } label: {
            Image(systemName: isSidebarCollapsed ? "sidebar.right" : "sidebar.left")
                .font(.system(size: 14, weight: .medium))
                .sidebarIconSurface(isHovered: isSidebarToggleHovered)
        }
        .buttonStyle(.plain)
        .onHover { isSidebarToggleHovered = $0 }
        .help(isSidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar")
        .accessibilityLabel(isSidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar")
    }

    private var collapsedToolbarControls: some View {
        HStack(alignment: .center, spacing: 4) {
            Button(action: createChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .medium))
                    .sidebarIconSurface(isHovered: isNewChatHovered)
            }
            .buttonStyle(.plain)
            .onHover { isNewChatHovered = $0 }
            .help("Create a new chat")
            .accessibilityLabel("Create a new chat")

            Divider().frame(height: 16)

            SidebarStatusBar(
                watchPath: watchPath,
                placement: .toolbar,
                openSettings: openSettings
            )
        }
        .frame(height: 28, alignment: .center)
    }

    private func createChat() {
        selection = .chat
        guard !FileNestEnvironment.isUIPreview else { return }
        appState.newChat()
    }

    private func startDocumentChat(_ file: FileRecord) {
        selection = .chat
        guard !FileNestEnvironment.isUIPreview else { return }
        appState.newChat(attachedFilePath: file.path)
    }

    private func coordinateSidebar(withPreviewPath previewPath: String?) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if previewPath != nil {
                guard !isSidebarCollapsed else { return }
                restoreSidebarAfterPreview = true
                isSidebarCollapsed = true
            } else if restoreSidebarAfterPreview {
                restoreSidebarAfterPreview = false
                isSidebarCollapsed = false
            }
        }
    }

    private func presentOnboardingIfNeeded() {
        guard appState.isOnboardingPresented else { return }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "onboarding")
    }

    private func openSettings(_ section: SettingsSection) {
        appState.selectSettingsSection(section)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }
}

private struct FileNestSidebar: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selection: MainView.SidebarItem
    let openSettings: (SettingsSection) -> Void
    @State private var previewSelectionID = UIShowcaseData.chatSessions.first?.id

    private var sessions: [ChatSession] {
        FileNestEnvironment.isUIPreview ? UIShowcaseData.chatSessions : appState.chatSessions
    }

    private var selectedSessionID: Int64? {
        FileNestEnvironment.isUIPreview ? previewSelectionID : appState.selectedChatSessionID
    }

    private var visibleSessions: ArraySlice<ChatSession> {
        sessions.prefix(25)
    }

    private var watchPath: String {
        if FileNestEnvironment.isUIPreview { return "~/FileNestWatch" }
        guard let first = appState.settings.watchDirs.first else {
            return appState.settings.localized("No watched folder")
        }
        return URL(fileURLWithPath: first).tildeAbbreviatedPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BrandMark(size: 28)
                Text("FileNest")
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 14)

            VStack(spacing: 5) {
                ForEach(MainView.SidebarItem.allCases) { item in
                    sidebarNavigationButton(item)
                }
            }
            .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Text("Recent")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: createChat) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Create a new chat")
            }
            .padding(.leading, 24)
            .padding(.trailing, 18)
            .padding(.top, 18)
            .padding(.bottom, 5)

            recentChats
                .frame(maxHeight: .infinity)

            SidebarStatusBar(
                watchPath: watchPath,
                placement: .sidebar,
                openSettings: openSettings
            )
        }
        .background(.ultraThinMaterial)
    }

    private func sidebarNavigationButton(_ item: MainView.SidebarItem) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                selection = item
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                Text(LocalizedStringKey(item.label))
                    .font(.system(size: 14, weight: selection == item ? .medium : .regular))
                Spacer()
            }
            .foregroundStyle(selection == item ? FileNestTheme.accent : Color.primary.opacity(0.86))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Rectangle())
            .background(
                selection == item ? FileNestTheme.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == item ? .isSelected : [])
        .help(LocalizedStringKey(item.label))
    }

    private var recentChats: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                if sessions.isEmpty {
                    Text("No recent chats")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                } else {
                    ForEach(visibleSessions) { session in
                        if let id = session.id {
                            Button {
                                openChat(id)
                            } label: {
                                RecentChatRow(
                                    session: session,
                                    selected: selection == .chat && id == selectedSessionID
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete Chat", role: .destructive) {
                                    guard !FileNestEnvironment.isUIPreview else { return }
                                    appState.deleteChat(id)
                                }
                            }
                        }
                    }

                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
        .accessibilityLabel("Recent chats")
    }

    private func createChat() {
        selection = .chat
        guard !FileNestEnvironment.isUIPreview else { return }
        appState.newChat()
    }

    private func openChat(_ id: Int64) {
        selection = .chat
        if FileNestEnvironment.isUIPreview {
            previewSelectionID = id
        } else {
            appState.selectChat(id)
        }
    }

}

private struct RecentChatRow: View {
    let session: ChatSession
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: session.attachedFilePath == nil ? "bubble.left" : "doc.text")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? FileNestTheme.accent : .secondary)
                .frame(width: 16)
            Text(LocalizedStringKey(session.title))
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? FileNestTheme.accent : Color.primary.opacity(0.82))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            selected ? FileNestTheme.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
    }
}

private struct SidebarStatusBar: View {
    enum Placement {
        case sidebar
        case toolbar
    }

    private enum Panel: Hashable {
        case watching
        case indexing
        case ai
    }

    @EnvironmentObject private var appState: AppState
    let watchPath: String
    let placement: Placement
    let openSettings: (SettingsSection) -> Void
    @State private var settingsHovered = false
    @State private var activePanel: Panel?
    @State private var hoveredPanel: Panel?
    @State private var isPopoverHovered = false
    @State private var dismissTask: Task<Void, Never>?

    private var isIndexing: Bool { appState.indexingState.isActive }

    private var watchIcon: String {
        if appState.hasActiveWatchDirectories { return "dot.radiowaves.left.and.right" }
        if appState.isWatching { return "folder.badge.questionmark" }
        return "pause.circle"
    }

    private var watchColor: Color {
        if appState.hasActiveWatchDirectories { return FileNestTheme.success }
        if appState.isWatching { return FileNestTheme.warning }
        return .secondary
    }

    private var indexIcon: String {
        switch appState.indexingState {
        case .running: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle.fill"
        case .stopping: return "stop.circle"
        case .stopped: return "stop.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return appState.indexedCount > 0 ? "doc.text.magnifyingglass" : "magnifyingglass"
        }
    }

    private var indexColor: Color {
        switch appState.indexingState {
        case .running, .stopping: return FileNestTheme.accentBlue
        case .paused, .stopped: return .secondary
        case .failed: return FileNestTheme.warning
        case .completed: return FileNestTheme.success
        case .idle: return appState.indexedCount > 0 ? FileNestTheme.success : .secondary
        }
    }

    private var indexTitle: String { appState.indexingStatusTitle }

    private var indexedSubtitle: String { appState.indexingStatusSubtitle }

    private var aiChoice: AppSettings.LLMChoice {
        AppSettings.LLMChoice(rawValue: appState.settings.llmChoice) ?? .ollama
    }

    private var aiIcon: String {
        switch aiChoice {
        case .ollama: return appState.ollama.state == .running ? "cpu.fill" : "cpu"
        case .cloud: return "cloud.fill"
        case .none: return "slash.circle.fill"
        }
    }

    private var aiColor: Color {
        switch aiChoice {
        case .ollama: return appState.ollama.state == .running ? FileNestTheme.accent : FileNestTheme.warning
        case .cloud: return FileNestTheme.accentBlue
        case .none: return .secondary
        }
    }

    var body: some View {
        Group {
            if placement == .toolbar {
                HStack(alignment: .center, spacing: 4) {
                    watchStatusButton
                    indexStatusButton
                    aiStatusButton
                    settingsButton
                }
                .frame(height: 28, alignment: .center)
            } else {
                HStack(spacing: 4) {
                    watchStatusButton
                    indexStatusButton
                    aiStatusButton
                    Spacer(minLength: 8)
                    settingsButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .overlay(alignment: .top) {
                    Divider()
                }
            }
        }
        .onDisappear { dismissTask?.cancel() }
    }

    private var watchStatusButton: some View {
        SidebarStatusButton(
            icon: watchIcon,
            color: watchColor,
            label: localized(appState.watchStatusTitle),
            isAnimating: false,
            popoverArrowEdge: .bottom,
            isPresented: panelBinding(for: .watching),
            onActivate: { toggle(.watching) },
            onHoverChange: { updateHover(.watching, inside: $0) },
            onPopoverHoverChange: updatePopoverHover
        ) {
            watchPopover
        }
    }

    private var indexStatusButton: some View {
        SidebarStatusButton(
            icon: indexIcon,
            color: indexColor,
            label: localized(isIndexing ? appState.indexingStatusTitle : "Index Status"),
            isAnimating: appState.indexingState.isAnimating,
            popoverArrowEdge: .bottom,
            isPresented: panelBinding(for: .indexing),
            onActivate: { toggle(.indexing) },
            onHoverChange: { updateHover(.indexing, inside: $0) },
            onPopoverHoverChange: updatePopoverHover
        ) {
            indexPopover
        }
    }

    private var aiStatusButton: some View {
        SidebarStatusButton(
            icon: aiIcon,
            color: aiColor,
            label: localized(aiStatusTitle),
            isAnimating: false,
            popoverArrowEdge: .bottom,
            isPresented: panelBinding(for: .ai),
            onActivate: { toggle(.ai) },
            onHoverChange: { updateHover(.ai, inside: $0) },
            onPopoverHoverChange: updatePopoverHover
        ) {
            aiPopover
        }
    }

    private var settingsButton: some View {
        Button {
            openSettings(.general)
        } label: {
            IndexingActivitySymbol(
                systemName: "gearshape",
                isAnimating: false,
                size: 14,
                weight: .medium
            )
                .foregroundStyle(.secondary)
                .sidebarIconSurface(isHovered: settingsHovered)
        }
        .buttonStyle(.plain)
        .onHover { settingsHovered = $0 }
        .help("Open FileNest Settings")
        .accessibilityLabel("Settings")
    }

    private var watchPopover: some View {
        StatusPopoverLayout(
            icon: watchIcon,
            color: watchColor,
            title: localized(appState.watchStatusTitle),
            subtitle: localized(appState.watchStatusSubtitle)
        ) {
            Text(watchPath)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button {
                    appState.isWatching ? appState.stopWatching() : appState.startWatching()
                } label: {
                    Label {
                        Text(localized(appState.isWatching ? "Pause Watching" : "Start Watching"))
                    } icon: {
                        Image(systemName: appState.isWatching ? "pause.fill" : "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.isWatching ? FileNestTheme.warning : FileNestTheme.accent)

                Button {
                    openSettings(.indexing)
                } label: {
                    Label {
                        Text(localized("Watch Settings"))
                    } icon: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)

            if appState.hasWatchDirectoryAccessIssue {
                HStack(spacing: 8) {
                    Button(localized("Check Again")) { appState.retryWatchDirectoryAccess() }
                    Button(localized("Restore Access…")) { appState.openWatchDirectoryPrivacySettings() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var indexPopover: some View {
        StatusPopoverLayout(
            icon: indexIcon,
            color: indexColor,
            title: localized(indexTitle),
            subtitle: localized(indexedSubtitle),
            isAnimating: appState.indexingState.isAnimating
        ) {
            IndexingStatusProgressView(
                appState: appState,
                showsHeader: false,
                showsControls: true
            )

            Text(localized("File content and vector indexes stay on this Mac."))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    appState.reindexAll()
                } label: {
                    IndexingButtonLabel(defaultTitle: "Reindex", appState: appState)
                }
                .buttonStyle(.borderedProminent)
                .tint(FileNestTheme.accent)
                .disabled(appState.reindexButtonsDisabled)

                Button {
                    openSettings(.statistics)
                } label: {
                    Label {
                        Text(localized("View Statistics"))
                    } icon: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }

    private var aiStatusTitle: String {
        switch aiChoice {
        case .ollama: return appState.ollama.state == .running ? "Local AI" : "Local AI Disconnected"
        case .cloud: return "Cloud AI"
        case .none: return "AI Disabled"
        }
    }

    private var aiSubtitle: String {
        switch aiChoice {
        case .ollama: return appState.settings.ollamaModel
        case .cloud: return appState.settings.cloudModel
        case .none: return "Local semantic search only"
        }
    }

    private var aiDetail: String {
        switch aiChoice {
        case .ollama:
            return String.localizedStringWithFormat(
                appState.settings.localized("Ollama · %@"),
                appState.settings.localized(appState.ollama.state.label)
            )
        case .cloud:
            let format = AppSettings.CloudAPIFormat(rawValue: appState.settings.cloudAPIFormat)?.label ?? "OpenAI"
            return "\(format) · \(appState.settings.cloudBaseURL)"
        case .none:
            return "Chat responses will not call a generative model."
        }
    }

    private var aiPopover: some View {
        StatusPopoverLayout(
            icon: aiIcon,
            color: aiColor,
            title: localized(aiStatusTitle),
            subtitle: localized(aiSubtitle)
        ) {
            Text(localized(aiDetail))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            Button {
                openSettings(.aiModels)
            } label: {
                Label {
                    Text(localized("Manage AI Models"))
                } icon: {
                    Image(systemName: "cpu")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(FileNestTheme.accent)
            .controlSize(.small)
        }
    }

    private func localized(_ text: String) -> String {
        appState.settings.localized(text)
    }

    private func panelBinding(for panel: Panel) -> Binding<Bool> {
        Binding(
            get: { activePanel == panel },
            set: { isPresented in
                if isPresented {
                    activePanel = panel
                } else if activePanel == panel {
                    activePanel = nil
                }
            }
        )
    }

    private func toggle(_ panel: Panel) {
        dismissTask?.cancel()
        activePanel = activePanel == panel ? nil : panel
    }

    private func updateHover(_ panel: Panel, inside: Bool) {
        if inside {
            dismissTask?.cancel()
            hoveredPanel = panel
            activePanel = panel
        } else {
            if hoveredPanel == panel { hoveredPanel = nil }
            scheduleDismiss(for: panel)
        }
    }

    private func updatePopoverHover(_ inside: Bool) {
        isPopoverHovered = inside
        if inside {
            dismissTask?.cancel()
        } else if let activePanel {
            scheduleDismiss(for: activePanel)
        }
    }

    private func scheduleDismiss(for panel: Panel) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 360_000_000)
            } catch {
                return
            }
            guard hoveredPanel == nil, !isPopoverHovered, activePanel == panel else { return }
            activePanel = nil
        }
    }
}

private struct SidebarStatusButton<PopoverContent: View>: View {
    let icon: String
    let color: Color
    let label: String
    let isAnimating: Bool
    let popoverArrowEdge: Edge
    @Binding var isPresented: Bool
    let onActivate: () -> Void
    let onHoverChange: (Bool) -> Void
    let onPopoverHoverChange: (Bool) -> Void
    @ViewBuilder let popoverContent: () -> PopoverContent

    @State private var isHovered = false

    var body: some View {
        Button(action: onActivate) {
            IndexingActivitySymbol(
                systemName: icon,
                isAnimating: isAnimating,
                size: 14,
                weight: .medium
            )
                .foregroundStyle(color)
                .sidebarIconSurface(isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey(label))
        .help(LocalizedStringKey(label))
        .onHover { inside in
            isHovered = inside
            onHoverChange(inside)
        }
        .popover(isPresented: $isPresented, arrowEdge: popoverArrowEdge) {
            popoverContent()
                .padding(14)
                .frame(width: 274, alignment: .leading)
                .onHover(perform: onPopoverHoverChange)
        }
    }
}

private struct SidebarIconSurface: ViewModifier {
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .frame(width: 16, height: 16)
            .frame(width: 28, height: 28)
            .background(
                isHovered ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
    }
}

private extension View {
    func sidebarIconSurface(isHovered: Bool) -> some View {
        modifier(SidebarIconSurface(isHovered: isHovered))
    }
}

private struct StatusPopoverLayout<Content: View>: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    var isAnimating = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IndexingActivitySymbol(
                    systemName: icon,
                    isAnimating: isAnimating,
                    size: 16,
                    weight: .semibold
                )
                    .foregroundStyle(color)
                    .frame(width: 30, height: 30)
                    .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Divider()

            content()
        }
    }
}
