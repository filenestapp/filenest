import AppKit
import SwiftUI
import UserNotifications

/// Delivers native macOS banners for terminal background events. SwiftUI and AppState remain
/// the source of truth for live progress; system notifications are only an out-of-app summary.
final class SystemNotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = SystemNotificationService()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    func configure() {
        center.delegate = self
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self?.center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    AppLogService.shared.write(
                        "system notification authorization failed: \(error)",
                        category: .appLifecycle,
                        level: .warning
                    )
                } else {
                    AppLogService.shared.write(
                        granted
                            ? "system notification authorization granted"
                            : "system notification authorization denied",
                        category: .appLifecycle,
                        level: granted ? .notice : .warning
                    )
                }
            }
        }
    }

    func post(title: String, body: String, identifier: String) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self.deliver(title: title, body: body, identifier: identifier)
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    self.deliver(title: title, body: body, identifier: identifier)
                }
            case .denied, .ephemeral:
                break
            @unknown default:
                break
            }
        }
    }

    private func deliver(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            guard let error else { return }
            AppLogService.shared.write(
                "system notification delivery failed: \(error)",
                category: .appLifecycle,
                level: .warning,
                metadata: ["identifier": identifier]
            )
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            MainWindowPresenter.shared.present()
            if response.notification.request.identifier == "filenest.search.complete" {
                AppLifecycleCoordinator.shared.appState?.presentCompletedLibrarySearch()
            }
        }
    }
}

@MainActor
final class FileNestAppDelegate: NSObject, NSApplicationDelegate {
    private var isTerminating = false
    private var previewWindow: NSWindow?
    private var previewAppState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if FileNestEnvironment.isUIPreview {
            presentPreviewWindow()
            return
        }
        FileNestScrollerStyleCoordinator.shared.start()
        DispatchQueue.main.async {
            MainWindowPresenter.shared.present()
        }
    }

    private func presentPreviewWindow() {
        let appState = AppLifecycleCoordinator.shared.appState ?? previewAppState ?? AppState(startAutomatically: false)
        previewAppState = appState

        let rootView: AnyView
        if FileNestEnvironment.isSettingsModelsPreview {
            rootView = AnyView(
                SettingsView()
                    .environmentObject(appState)
                    .fileNestEnvironment(appState.settings)
                    .fileNestOverlayScrollStyle()
            )
        } else {
            rootView = AnyView(
                MainView()
                    .environmentObject(appState)
                    .fileNestEnvironment(appState.settings)
                    .fileNestOverlayScrollStyle()
                    .frame(minWidth: 980, minHeight: 700)
            )
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = FileNestInstallation.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: rootView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        MainWindowPresenter.shared.present()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task { @MainActor in
            await AppLifecycleCoordinator.shared.shutdownManagedServices()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class AppLifecycleCoordinator {
    static let shared = AppLifecycleCoordinator()
    weak var appState: AppState?

    func register(_ appState: AppState) {
        self.appState = appState
    }

    func shutdownManagedServices() async {
        await appState?.shutdownManagedServices()
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
        guard let window = NSApp.windows.first(where: { $0.title == FileNestInstallation.displayName }) else {
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
    @StateObject private var appState = AppState(
        startAutomatically: !FileNestEnvironment.isUIPreview
    )

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .fileNestEnvironment(appState.settings)
                .fileNestOverlayScrollStyle()
                .frame(width: 380, height: 660)
        } label: {
            Image(nsImage: Self.menuBarIcon)
                .frame(width: 16, height: 16)
                .accessibilityLabel(FileNestInstallation.displayName)
                .background(MainWindowPresentationBridge())
        }
        .menuBarExtraStyle(.window)

        WindowGroup(FileNestInstallation.displayName, id: "main") {
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
            .fileNestOverlayScrollStyle()
            .alert(
                appState.settings.localized("Index Processing Settings Changed"),
                isPresented: Binding(
                    get: { appState.isIndexConfigurationPromptPresented },
                    set: { _ in }
                )
            ) {
                Button {
                    appState.reindexForPendingConfigurationChange()
                } label: {
                    Text(verbatim: appState.settings.localized("Reindex Now"))
                }
                Button(role: .cancel) {
                    appState.skipPendingConfigurationChange()
                } label: {
                    Text(verbatim: appState.settings.localized("Skip and Keep Existing Index"))
                }
            } message: {
                Text(verbatim: appState.settings.localized(
                    "Chunking, document parsing, OCR, indexing scope, or a service endpoint changed. The existing index remains usable. Reindex now, or skip and use the latest settings for new files."
                ))
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
            .sheet(
                isPresented: Binding(
                    get: { appState.isOnboardingPresented },
                    set: { isPresented in
                        // Initial setup must remain in front until it is explicitly finished.
                        // Reopened setup may be dismissed normally after first-run completion.
                        if !isPresented, !appState.settings.onboardingCompleted {
                            appState.presentOnboarding()
                        }
                    }
                )
            ) {
                OnboardingView()
                    .environmentObject(appState)
                    .fileNestEnvironment(appState.settings)
                    .fileNestOverlayScrollStyle()
                    .interactiveDismissDisabled(!appState.settings.onboardingCompleted)
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
                Button("Open Quick Search") {
                    appState.toggleQuickSearchPanel()
                }
                Divider()
                if appState.organizationState == .running {
                    Button("Pause Organization") { appState.pauseOrganization() }
                    Button("Stop Organization", role: .destructive) { appState.stopOrganization() }
                } else if appState.organizationState == .paused {
                    Button("Resume Organization") { appState.resumeOrganization() }
                    Button("Stop Organization", role: .destructive) { appState.stopOrganization() }
                } else {
                    Menu("Organize Now") {
                        Button("Organize New Files in Watched Folders") {
                            appState.organizeNewFilesInWatchedDirectories()
                        }
                        .disabled(appState.settings.watchDirs.isEmpty)
                        Button("Choose Folders to Organize…") {
                            appState.chooseDirectoriesForOneTimeOrganization()
                        }
                    }
                        .keyboardShortcut("O", modifiers: [.command, .shift])
                        .disabled(appState.indexingState.isActive)
                }
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

        Window("Duplicate Files", id: "duplicates") {
            DuplicateFilesWindow()
                .environmentObject(appState)
                .fileNestEnvironment(appState.settings)
                .fileNestOverlayScrollStyle()
        }
        .defaultSize(width: 760, height: 600)
        .windowResizability(.contentMinSize)
    }

    private static let menuBarIcon = makeMenuBarIcon()

    private static func makeMenuBarIcon() -> NSImage {
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
            if appState.reindexConfirmationStep == .selection {
                selection
            } else {
                // Keep the final step mounted while the sheet dismissal animation runs.
                finalConfirmation
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 18) {
            confirmationHeader(
                step: "First Confirmation · 1/2",
                title: "Reset RAG Pipeline Stages",
                detail: "Reset only the stages you need. Selecting an upstream stage automatically includes every persisted downstream stage."
            )

            Toggle(isOn: Binding(
                get: { appState.isFullPipelineReindexSelected },
                set: { appState.setFullPipelineReindexSelected($0) }
            )) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reset the full RAG pipeline")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Reparse sources, rebuild chunks and vectors, recreate sqlite-vec, and restart the local reranker")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .foregroundStyle(FileNestTheme.accent)
                }
            }
            .toggleStyle(.checkbox)
            .padding(12)
            .background(FileNestTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 0) {
                ForEach(RAGReindexStage.allCases) { stage in
                    ragStageRow(stage)
                    if stage != RAGReindexStage.allCases.last {
                        Divider().padding(.leading, 36)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))

            if appState.hasPendingMediaTranscriptionReindex {
                selectionRow(
                    title: "Only reindex audio and video affected by transcription changes",
                    detail: "Reprocess supported audio and video files only. Existing document and image indexes stay unchanged.",
                    icon: "waveform",
                    isSelected: Binding(
                        get: { appState.isAffectedMediaOnlyReindexSelected },
                        set: { appState.setAffectedMediaOnlyReindexSelected($0) }
                    )
                )
                .padding(12)
                .background(FileNestTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Limit Reindex to File Types")
                    .font(.system(size: 13, weight: .semibold))
                Text(appState.canLimitReindexFileTypes
                    ? "Optional. Select one or more types; audio and video can be rebuilt independently. Leave every type unchecked to process all files."
                    : "Turn off the global embedding model rebuild before limiting file types.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(FileCategory.allCases) { category in
                        Toggle(isOn: Binding(
                            get: { appState.selectedReindexFileCategories.contains(category) },
                            set: { appState.setReindexFileCategory(category, selected: $0) }
                        )) {
                            Label(LocalizedStringKey(category.label), systemImage: category.icon)
                                .font(.system(size: 12))
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .padding(12)
            .background(.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .disabled(!appState.canLimitReindexFileTypes)

            selectionRow(
                title: "Include new unindexed files",
                detail: appState.unindexedFileCount > 0
                    ? appState.settings.localizedFormat("%d unindexed files detected", appState.unindexedFileCount)
                    : "No unindexed files detected",
                icon: "doc.badge.plus",
                isSelected: Binding(
                    get: { appState.isUnindexedFilesReindexSelected },
                    set: { appState.setUnindexedFilesReindexSelected($0) }
                )
            )
            .disabled(appState.unindexedFileCount == 0)

            if !appState.canAdvanceReindexConfirmation {
                Label("No reset stage is selected and no new files require indexing.", systemImage: "checkmark.circle")
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
                detail: "Review the effective pipeline below. You can pause or stop document processing while it runs."
            )

            VStack(alignment: .leading, spacing: 10) {
                ForEach(RAGReindexStage.allCases) { stage in
                    if appState.selectedRAGReindexStages.contains(stage) {
                        Label(LocalizedStringKey(stage.title), systemImage: "checkmark.circle.fill")
                    }
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
                if appState.willReindexAffectedMediaOnly {
                    Label("Only supported audio and video files will be reprocessed", systemImage: "waveform")
                }
                if !appState.selectedReindexFileCategories.isEmpty {
                    Label {
                        Text(appState.settings.localizedFormat(
                            "Limit to: %@",
                            appState.reindexFileTypeScopeDescription
                        ))
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(FileNestTheme.accent)

            if appState.willReindexAffectedMediaOnly {
                Label("Only audio and video files affected by transcription changes will be reread. Other indexed files remain unchanged.", systemImage: "checkmark.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(FileNestTheme.accent)
            } else if appState.selectedRAGReindexStages.contains(.parsingAndOCR)
                || appState.selectedRAGReindexStages.contains(.structuredChunking) {
                Label("The selected stages reread every managed source file. OCR and Docling may make this significantly slower.", systemImage: "exclamationmark.triangle")
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

    private func ragStageRow(_ stage: RAGReindexStage) -> some View {
        let unavailable = stage == .rerankerRuntime
            && (appState.settings.rerankerSource != AppSettings.RerankerSource.local.rawValue
                || !RerankerServiceManager.isModelInstalled)
        return Toggle(isOn: Binding(
            get: { appState.selectedRAGReindexStages.contains(stage) },
            set: { appState.setRAGReindexStage(stage, selected: $0) }
        )) {
            HStack(spacing: 10) {
                Image(systemName: stage.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(FileNestTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(LocalizedStringKey(stage.title))
                            .font(.system(size: 13, weight: .medium))
                        if appState.hasDetectedChange(for: stage) {
                            Text("Change detected")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(FileNestTheme.warning)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(FileNestTheme.warning.opacity(0.12), in: Capsule())
                        } else {
                            Text(unavailable ? "Unavailable" : "Up to date")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(LocalizedStringKey(stage.detail))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 9)
        }
        .toggleStyle(.checkbox)
        .disabled(unavailable)
    }

    private func actionBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Spacer()
            content()
        }
        .padding(.top, 4)
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
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                appState.presentSettings(.general)
                MainWindowPresenter.shared.present()
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
