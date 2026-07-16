import AppKit
import SwiftUI

final class FileNestAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            MainWindowPresenter.shared.present()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        MainWindowPresenter.shared.present()
        return false
    }
}

@MainActor
final class MainWindowPresenter {
    static let shared = MainWindowPresenter()

    private var openWindow: OpenWindowAction?
    private var hasPendingPresentation = false

    func register(openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        guard hasPendingPresentation else { return }
        hasPendingPresentation = false
        present()
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        if focusExistingMainWindow() { return }

        guard let openWindow else {
            hasPendingPresentation = true
            return
        }

        openWindow(id: "main")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            _ = self?.focusExistingMainWindow()
        }
    }

    @discardableResult
    private func focusExistingMainWindow() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.title == "FileNest" }) else {
            return false
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return true
    }
}

@main
struct FileNestApp: App {
    @NSApplicationDelegateAdaptor(FileNestAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .fileNestEnvironment(appState.settings)
                .frame(width: 380, height: 660)
        } label: {
            MenuBarStatusIcon(
                baseImage: menuBarBaseIcon(),
                showsWatchingBadge: appState.hasActiveWatchDirectories,
                showsIndexingSpinner: appState.indexingState.isAnimating,
                animationFrame: appState.indexingAnimationFrame
            )
                .accessibilityLabel("FileNest")
                .background(MainWindowPresentationBridge())
        }
        .menuBarExtraStyle(.window)

        WindowGroup("FileNest", id: "main") {
            Group {
                if FileNestEnvironment.isSettingsPreview ||
                    FileNestEnvironment.isStatisticsPreview ||
                    FileNestEnvironment.isSettingsModelsPreview ||
                    FileNestEnvironment.isSettingsRulesPreview {
                    SettingsView()
                        .environmentObject(appState)
                } else if FileNestEnvironment.isRulePreview {
                    RuleEditor(rule: Rule(
                        id: nil,
                        name: "Contract Archive",
                        type: RuleType.rule.rawValue,
                        pattern: "pdf, docx",
                        targetFolder: "Contracts",
                        priority: 80,
                        enabled: true
                    )) { _ in }
                    .environmentObject(appState)
                } else if FileNestEnvironment.isMenuPreview {
                    MenuBarView()
                        .environmentObject(appState)
                        .frame(width: 380, height: 660)
                } else {
                    MainView()
                        .environmentObject(appState)
                        .frame(minWidth: 980, minHeight: 700)
                }
            }
            .fileNestEnvironment(appState.settings)
            .alert(
                "Index Processing Settings Changed",
                isPresented: Binding(
                    get: { appState.isIndexConfigurationPromptPresented },
                    set: { _ in }
                )
            ) {
                Button("Reindex Now") {
                    appState.reindexForPendingConfigurationChange()
                }
                Button("Skip and Keep Existing Index", role: .cancel) {
                    appState.skipPendingConfigurationChange()
                }
            } message: {
                Text("Chunking, document parsing, OCR, indexing scope, or a service endpoint changed. The existing index remains usable. Reindex now, or skip and use the latest settings for new files.")
            }
            .sheet(
                isPresented: Binding(
                    get: { appState.reindexConfirmationStep != nil },
                    set: { if !$0 { appState.cancelReindexConfirmation() } }
                )
            ) {
                ReindexConfirmationView()
                    .environmentObject(appState)
                    .fileNestEnvironment(appState.settings)
            }
        }
        .defaultSize(
            width: FileNestEnvironment.isSettingsPreview || FileNestEnvironment.isStatisticsPreview || FileNestEnvironment.isSettingsModelsPreview || FileNestEnvironment.isSettingsRulesPreview ? 1040 : (FileNestEnvironment.isRulePreview ? 520 : (FileNestEnvironment.isMenuPreview ? 380 : 1180)),
            height: FileNestEnvironment.isSettingsPreview || FileNestEnvironment.isStatisticsPreview || FileNestEnvironment.isSettingsModelsPreview || FileNestEnvironment.isSettingsRulesPreview ? 760 : (FileNestEnvironment.isRulePreview ? 570 : (FileNestEnvironment.isMenuPreview ? 660 : 840))
        )
        .windowStyle(.hiddenTitleBar)
        .commands {
            FileNestSettingsCommands(appState: appState)
            CommandMenu("FileNest") {
                Button("Organize Now") { appState.organizeNow() }
                    .keyboardShortcut("O", modifiers: [.command, .shift])
                Button {
                    appState.reindexAll()
                } label: {
                    IndexingButtonLabel(defaultTitle: "Reindex", appState: appState)
                }
                .disabled(appState.reindexButtonsDisabled)
                    .keyboardShortcut("R", modifiers: [.command, .shift])
                if appState.indexingState == .running {
                    Button("Pause Indexing") { appState.pauseIndexing() }
                } else if appState.indexingState == .paused {
                    Button("Resume Indexing") { appState.resumeIndexing() }
                }
                if appState.indexingState == .running || appState.indexingState == .paused {
                    Button("Stop Indexing", role: .destructive) { appState.stopIndexing() }
                } else if appState.indexingState == .stopped {
                    Button("Restart Indexing") { appState.restartIndexing() }
                }
                Divider()
                Button("Clear Chat History") {
                    appState.clearAllChats()
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
        }

        Window("FileNest Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
                .fileNestEnvironment(appState.settings)
        }
        .defaultSize(width: 1040, height: 760)
        .windowResizability(.contentMinSize)

        Window("FileNest Setup", id: "onboarding") {
            OnboardingView()
                .environmentObject(appState)
                .fileNestEnvironment(appState.settings)
        }
        .defaultSize(width: 920, height: 700)
        .windowResizability(.contentSize)
    }

    private func menuBarBaseIcon() -> NSImage {
        let source = NSImage(named: NSImage.Name("MenuBarIconListening"))
            ?? NSImage(systemSymbolName: "archivebox", accessibilityDescription: "FileNest")
            ?? NSImage()

        let canvasSize = NSSize(width: 16, height: 16)
        let sourceCrop = NSRect(x: 16, y: 24, width: 96, height: 81)

        let visibleWidth: CGFloat = 15.5
        let visibleHeight = min(15.5, visibleWidth * sourceCrop.height / max(sourceCrop.width, 1))
        let target = NSRect(
            x: (canvasSize.width - visibleWidth) / 2,
            y: (canvasSize.height - visibleHeight) / 2,
            width: visibleWidth,
            height: visibleHeight
        )
        let icon = NSImage(size: canvasSize)
        icon.lockFocus()
        source.draw(
            in: target,
            from: sourceCrop,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        icon.unlockFocus()
        icon.isTemplate = true
        return icon
    }
}

private struct ReindexConfirmationView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.reindexConfirmationStep == .finalConfirmation {
                finalConfirmation
            } else {
                selection
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 18) {
            confirmationHeader(
                step: "First Confirmation · 1/2",
                title: "Choose Reindex Scope",
                detail: "By default, process embedding model changes and new unindexed files; Advanced mode can reprocess configuration changes."
            )

            selectionRow(
                title: "Embedding model changes",
                detail: appState.hasEmbeddingConfigurationChange
                    ? "The model or source changed; all vectors will be regenerated"
                    : "The current model and source have not changed",
                icon: "point.3.connected.trianglepath.dotted",
                isSelected: Binding(
                    get: { appState.isEmbeddingChangeReindexSelected },
                    set: { appState.setEmbeddingChangeReindexSelected($0) }
                )
            )

            selectionRow(
                title: "New unindexed files",
                detail: appState.unindexedFileCount > 0
                    ? appState.settings.localizedFormat("%d unindexed files detected", appState.unindexedFileCount)
                    : "No unindexed files detected",
                icon: "doc.badge.plus",
                isSelected: Binding(
                    get: { appState.isUnindexedFilesReindexSelected },
                    set: { appState.setUnindexedFilesReindexSelected($0) }
                )
            )

            DisclosureGroup(isExpanded: $appState.isReindexAdvancedExpanded) {
                VStack(spacing: 10) {
                    if appState.pendingAdvancedReindexCategories.isEmpty {
                        Text("No other indexing configuration changes were detected.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(IndexContentChangeCategory.allCases) { category in
                            if appState.pendingAdvancedReindexCategories.contains(category) {
                                Toggle(isOn: Binding(
                                    get: { appState.selectedAdvancedReindexCategories.contains(category) },
                                    set: { appState.setAdvancedReindexCategory(category, selected: $0) }
                                )) {
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(LocalizedStringKey(category.title))
                                                .font(.system(size: 13, weight: .medium))
                                            Text(LocalizedStringKey(category.detail))
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: category.systemImage)
                                            .foregroundStyle(FileNestTheme.accent)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    Text("Selecting any advanced category rereads source files and uses all current settings to parse, chunk, and generate vectors.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 12)
            } label: {
                Label("Advanced Mode", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
            }

            if !appState.canAdvanceReindexConfirmation {
                Label("No changes requiring reindexing were detected. Expand Advanced Mode for details.", systemImage: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            actionBar {
                Button("Cancel", role: .cancel) { appState.cancelReindexConfirmation() }
                Button("Continue") { appState.advanceReindexConfirmation() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.canAdvanceReindexConfirmation)
            }
        }
        .padding(24)
    }

    private var finalConfirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            confirmationHeader(
                step: "Final Confirmation · 2/2",
                title: "Start Reindexing?",
                detail: "You can pause or stop while it runs. Configuration baselines update only after full success."
            )

            VStack(alignment: .leading, spacing: 10) {
                if appState.hasDefaultEmbeddingRebuildSelection {
                    Label("Regenerate Embedding vectors (reuse existing chunks)", systemImage: "checkmark.circle.fill")
                }
                if appState.isUnindexedFilesReindexSelected && appState.unindexedFileCount > 0 {
                    Label {
                        Text(appState.settings.localizedFormat(
                            "Index %d new files",
                            appState.unindexedFileCount
                        ))
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
                ForEach(IndexContentChangeCategory.allCases) { category in
                    if appState.selectedAdvancedReindexCategories.contains(category) {
                        Label {
                            Text("Reprocess: ") + Text(LocalizedStringKey(category.title))
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                        }
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(FileNestTheme.accent)

            if !appState.selectedAdvancedReindexCategories.isEmpty {
                Label("Advanced rebuilding rereads all managed files. Duration depends on document count and OCR/parsing settings.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(FileNestTheme.warning)
            }

            actionBar {
                Button("Back") { appState.returnToReindexSelection() }
                Button("Confirm and Start", role: .destructive) { appState.confirmReindex() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    private func confirmationHeader(step: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(step))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FileNestTheme.accent)
            Text(LocalizedStringKey(title))
                .font(.system(size: 20, weight: .semibold))
            Text(LocalizedStringKey(detail))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func selectionRow(
        title: String,
        detail: String,
        icon: String,
        isSelected: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isSelected) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title)).font(.system(size: 13, weight: .medium))
                    Text(LocalizedStringKey(detail)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon).foregroundStyle(FileNestTheme.accent)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func actionBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Spacer()
            content()
        }
        .padding(.top, 4)
    }
}

private struct MenuBarStatusIcon: View {
    let baseImage: NSImage
    let showsWatchingBadge: Bool
    let showsIndexingSpinner: Bool
    let animationFrame: Int

    var body: some View {
        Image(nsImage: baseImage)
            .frame(width: 16, height: 16)
            .overlay(alignment: .topTrailing) {
                if showsWatchingBadge {
                    Circle()
                        .fill(Color(red: 0.12, green: 0.78, blue: 0.34))
                        .frame(width: 4.5, height: 4.5)
                        .overlay {
                            Circle().stroke(.black.opacity(0.24), lineWidth: 0.5)
                        }
                        .offset(x: 0.5, y: -0.25)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsIndexingSpinner {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.primary)
                        .rotationEffect(.degrees(Double(animationFrame) * 45))
                        .offset(x: 1, y: 0.5)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityValue(Text(LocalizedStringKey(accessibilityStatus)))
    }

    private var accessibilityStatus: String {
        switch (showsWatchingBadge, showsIndexingSpinner) {
        case (true, true): return "Watching and indexing"
        case (true, false): return "Watching"
        case (false, true): return "Indexing"
        case (false, false): return "Paused"
        }
    }
}

private struct MainWindowPresentationBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                MainWindowPresenter.shared.register(openWindow: openWindow)
            }
    }
}

private struct FileNestSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                appState.selectSettingsSection(.general)
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .appInfo) {
            Button(appState.updates.status == .checking ? "Checking for updates…" : "Check for Updates…") {
                appState.updates.checkForUpdates()
            }
            .disabled(!appState.updates.canCheckForUpdates)
        }
    }
}
