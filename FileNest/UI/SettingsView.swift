import AppKit
import SwiftUI

/// Settings workspace embedded in the primary FileNest window.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    private let onBack: (() -> Void)?
    @State private var newDir = ""
    @State private var selectedSection: SettingsSection = .general
    @State private var settingsSearchText = ""
    @State private var selectedModelProfileID = OllamaModelRecommendation.defaultProfile.id
    @State private var modelPendingDeletion: OllamaModelInfo?
    @State private var isShowingDeleteRerankerConfirmation = false
    @State private var whisperModelPendingDeletion: String?
    @State private var updateFeedDraft = ""
    @State private var isShowingClearLogsConfirmation = false
    @State private var logStatusMessage: String?
    @State private var isTestingAIConnectivity = false
    @State private var aiConnectivityChecks: [AIConnectivityCheck] = []
    @State private var pendingWatchDirectories: [String] = []
    @State private var pendingWatchDirectoryInventories: [WatchDirectoryInventory] = []
    @State private var isShowingNewDirectoryChoice = false
    @State private var isShowingOrganizeExistingConfirmation = false
    @State private var existingWatchDirectoryInventories: [WatchDirectoryInventory] = []
    @StateObject private var launchAtLogin = LaunchAtLoginService()

    init(onBack: (() -> Void)? = nil) {
        self.onBack = onBack
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
                .frame(width: FileNestLayout.sidebarWidth)

            Rectangle()
                .fill(FileNestTheme.border)
                .frame(width: FileNestLayout.dividerWidth)

            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, idealWidth: 1040, minHeight: 700, idealHeight: 760)
        .onAppear {
            appState.refreshReindexJobSummary()
            selectedSection = appState.selectedSettingsSection
            updateFeedDraft = appState.updates.feedURLString
            if FileNestEnvironment.isStatisticsPreview {
                selectedSection = .statistics
            } else if FileNestEnvironment.isSettingsRulesPreview {
                selectedSection = .rules
            } else if FileNestEnvironment.isSettingsModelsPreview {
                selectedSection = .aiModels
            }
        }
        .onChange(of: appState.selectedSettingsSection) { section in
            selectedSection = section
        }
        .onChange(of: appState.hasReindexActivity) { hasActivity in
            if !hasActivity && selectedSection == .reindexActivity {
                selectedSection = .indexing
            }
        }
        .onChange(of: selectedSection) { section in
            appState.selectSettingsSection(section)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
        .task(id: selectedSection) {
            guard selectedSection == .aiModels else { return }
            await appState.refreshModelServicesIfNeeded()
        }
        .confirmationDialog(
            "Delete Local Model?",
            isPresented: Binding(
                get: { modelPendingDeletion != nil },
                set: { if !$0 { modelPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: modelPendingDeletion
        ) { model in
            Button(appState.settings.localizedFormat("Delete %@", model.name), role: .destructive) {
                Task {
                    await appState.ollama.delete(model: model.name, host: appState.settings.ollamaHost)
                    if appState.settings.ollamaModel == model.name,
                       let replacement = appState.ollama.models.first?.name {
                        appState.settings.setOllamaModel(replacement)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text(appState.settings.localizedFormat(
                "%@ will be permanently removed from this Mac. You can download it again later.",
                model.name
            ))
        }
        .confirmationDialog(
            "Delete Whisper Model?",
            isPresented: Binding(
                get: { whisperModelPendingDeletion != nil },
                set: { if !$0 { whisperModelPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: whisperModelPendingDeletion
        ) { model in
            Button(appState.settings.localizedFormat("Delete %@", model), role: .destructive) {
                appState.whisper.deleteModel(model)
                whisperModelPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text(appState.settings.localizedFormat(
                "The Whisper %@ model will be removed from this Mac. You can download it again later.",
                model
            ))
        }
        .confirmationDialog(
            "Clear All Logs?",
            isPresented: $isShowingClearLogsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Logs", role: .destructive) {
                let count = AppLogService.shared.clear()
                logStatusMessage = appState.settings.localizedFormat("Cleared %d log files", count)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all local diagnostic logs currently retained by FileNest and cannot be undone.")
        }
        .confirmationDialog(
            "Delete Local Reranker?",
            isPresented: $isShowingDeleteRerankerConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Reranker Model", role: .destructive) {
                Task { try? await appState.reranker.deleteModel() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes Qwen3-Reranker-0.6B from this Mac. FileNest will keep your reranker settings and you can download the model again later.")
        }
        .confirmationDialog(
            "How Should Existing Files in the New Folder Be Handled?",
            isPresented: $isShowingNewDirectoryChoice,
            titleVisibility: .visible
        ) {
            Button("Organize Existing Files Now") {
                commitPendingWatchDirectories(organizeExisting: true)
            }
            Button("Keep Existing Files, Process New Files Only") {
                commitPendingWatchDirectories(organizeExisting: false)
            }
            Button("Cancel", role: .cancel) {
                pendingWatchDirectories = []
                pendingWatchDirectoryInventories = []
            }
        } message: {
            Text(appState.settings.localizedFormat(
                "Adding %d folders containing %d files and %d folders. If you keep them unchanged, only items added later will be processed.",
                pendingWatchDirectories.count,
                pendingWatchDirectoryInventories.reduce(0) { $0 + $1.fileCount },
                pendingWatchDirectoryInventories.reduce(0) { $0 + $1.directoryCount }
            ))
        }
        .confirmationDialog(
            "Organize Existing Files in Watched Folders Now?",
            isPresented: $isShowingOrganizeExistingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Organizing") {
                appState.organizeExistingWatchDirectoryEntries()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(appState.settings.localizedFormat(
                "Process the current %d files and %d folders. Items may be moved according to your organization rules.",
                existingWatchDirectoryInventories.reduce(0) { $0 + $1.fileCount },
                existingWatchDirectoryInventories.reduce(0) { $0 + $1.directoryCount }
            ))
        }
    }

    private var filteredSettingsSections: [SettingsSection] {
        let query = settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let availableSections = SettingsSection.allCases.filter {
            $0 != .reindexActivity || appState.hasReindexActivity
        }
        guard !query.isEmpty else { return availableSections }
        return availableSections.filter { section in
            section.matchesSettingsSearch(query) ||
                appState.settings.localized(section.label).localizedCaseInsensitiveContains(query) ||
                appState.settings.localized(section.detail).localizedCaseInsensitiveContains(query)
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let onBack {
                Button(action: onBack) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Back to FileNest")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .help("Back to FileNest")
            } else {
                HStack(spacing: 9) {
                    BrandMark(size: 24)
                    Text("FileNest Settings")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search settings", text: $settingsSearchText)
                    .textFieldStyle(.plain)
                if !settingsSearchText.isEmpty {
                    Button {
                        settingsSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                FileNestTheme.elevatedSurface,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(FileNestTheme.border, lineWidth: 1)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            if filteredSettingsSections.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("No Settings Found")
                        .font(.system(size: 12, weight: .medium))
                    Text("Try a different search term.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(
                    selection: Binding<SettingsSection?>(
                        get: { selectedSection },
                        set: { if let section = $0 { selectedSection = section } }
                    )
                ) {
                    ForEach(SettingsSectionGroup.allCases) { group in
                        let sections = filteredSettingsSections.filter { $0.group == group }
                        if !sections.isEmpty {
                            Section(LocalizedStringKey(group.label)) {
                                ForEach(sections) { section in
                                    Label {
                                        Text(LocalizedStringKey(section.label))
                                            .lineLimit(1)
                                    } icon: {
                                        Image(systemName: section.icon)
                                            .frame(width: 16)
                                    }
                                    .tag(section)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .background(.ultraThinMaterial)
    }

    private var settingsDetail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: selectedSection.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(FileNestTheme.accent)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(selectedSection.label))
                        .font(.system(size: 20, weight: .semibold))
                    Text(LocalizedStringKey(selectedSection.detail))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label("Changes save automatically", systemImage: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(FileNestTheme.success)
            }
            .padding(.horizontal, 24)
            .frame(height: 76)
            .background(FileNestTheme.surface)
            .overlay(alignment: .bottom) {
                Rectangle().fill(FileNestTheme.border).frame(height: 1)
            }

            settingsPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(FileNestTheme.surface)
    }

    @ViewBuilder
    private var settingsPage: some View {
        switch selectedSection {
        case .general:
            DeferredSettingsPage { generalSettings }
        case .indexing:
            DeferredSettingsPage { indexSettings }
        case .reindexActivity:
            ReindexActivityView()
        case .aiModels:
            DeferredSettingsPage { aiSettings }
        case .aiSkills:
            DeferredSettingsPage { AISkillsSettingsView() }
        case .statistics:
            DeferredSettingsPage { StatisticsView(embeddedInSettings: true) }
        case .rules:
            DeferredSettingsPage { RulesView(embeddedInSettings: true) }
        }
    }

    private var generalSettings: some View {
        Form {
            Section("Runtime Status") {
                Toggle("File Watching", isOn: Binding(
                    get: { appState.isWatching },
                    set: { $0 ? appState.startWatching() : appState.stopWatching() }
                ))

                LabeledContent("Current Status") {
                    Label {
                        Text(LocalizedStringKey(appState.watchStatusTitle))
                    } icon: {
                        Image(systemName: watchStatusIcon)
                    }
                    .foregroundStyle(watchStatusColor)
                }

                if appState.hasWatchDirectoryAccessIssue {
                    LabeledContent("Folder Access") {
                        HStack(spacing: 8) {
                            Text(LocalizedStringKey(appState.watchStatusSubtitle))
                                .font(.system(size: 10))
                                .foregroundStyle(FileNestTheme.warning)
                            Button("Check Again") { appState.retryWatchDirectoryAccess() }
                            Button("Restore Access…") { appState.openWatchDirectoryPrivacySettings() }
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section("Interface") {
                Picker("Language", selection: Binding(
                    get: { appState.settings.appLanguage },
                    set: { appState.settings.setAppLanguage($0) }
                )) {
                    ForEach(AppSettings.AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.label)).tag(language.rawValue)
                    }
                }

                Picker("Appearance", selection: Binding(
                    get: { appState.settings.appearance },
                    set: { appState.settings.setAppearance($0) }
                )) {
                    ForEach(AppSettings.AppAppearance.allCases) { appearance in
                        Text(LocalizedStringKey(appearance.label)).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text("Language and appearance changes apply immediately to the main window, menu bar, and settings.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Button {
                    appState.presentOnboarding()
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "onboarding")
                } label: {
                    Label("Open Setup Assistant Again", systemImage: "wand.and.stars")
                }
            }

            Section("Startup") {
                Toggle("Launch FileNest at Login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { enabled in
                        Task { await launchAtLogin.setEnabled(enabled) }
                    }
                ))
                .disabled(
                    launchAtLogin.isUpdating ||
                    launchAtLogin.status == .requiresApproval ||
                    launchAtLogin.status == .unavailable
                )

                if launchAtLogin.isUpdating {
                    Label {
                        Text("Updating login item…")
                    } icon: {
                        ProgressView()
                            .controlSize(.small)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                } else if launchAtLogin.status == .requiresApproval {
                    HStack(spacing: 8) {
                        Label(
                            "Allow FileNest in System Settings to finish enabling this option.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(FileNestTheme.warning)

                        Spacer()

                        Button("Open Login Items Settings") {
                            openLoginItemsSettings()
                        }
                        .controlSize(.small)
                    }
                } else {
                    Text("Open FileNest automatically after you sign in to this Mac.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = launchAtLogin.errorMessage {
                    Label(LocalizedStringKey(errorMessage), systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }

            Section("Quick Search") {
                LabeledContent("Quick Search Shortcut") {
                    HStack(spacing: 8) {
                        ShortcutRecorder(
                            shortcut: QuickSearchShortcut(
                                keyCode: appState.settings.quickSearchShortcutKeyCode,
                                modifiers: appState.settings.quickSearchShortcutModifiers
                            ),
                            recordingTitle: appState.settings.localized("Press a shortcut…"),
                            accessibilityLabel: appState.settings.localized("Quick Search Shortcut"),
                            onChange: appState.settings.setQuickSearchShortcut
                        )
                        .frame(width: 132, height: 28)

                        Button("Reset to Default") {
                            appState.settings.setQuickSearchShortcut(.defaultValue)
                        }
                        .controlSize(.small)
                    }
                }

                Text("Use this shortcut from any app to open a centered FileNest search box.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if let error = appState.quickSearchShortcutRegistrationError {
                    Label(LocalizedStringKey(error), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(FileNestTheme.warning)
                }
            }

            Section("Version & Updates") {
                HStack(spacing: 12) {
                    BrandMark(size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("FileNest \(appState.updates.buildInfo.version)")
                            .font(.system(size: 14, weight: .semibold))
                        Text(appState.settings.localizedFormat(
                            "Build %@ · %@",
                            appState.updates.buildInfo.buildNumber,
                            formattedBuildDate
                        ))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    updateStatusLabel
                }

                LabeledContent("Update Source") {
                    TextField(
                        "",
                        text: $updateFeedDraft,
                        prompt: Text("https://example.com/appcast.xml")
                    )
                        .labelsHidden()
                        .accessibilityLabel("Update Source")
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 360)
                }

                HStack {
                    Text("Only HTTPS Sparkle appcast URLs are supported")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save URL") {
                        appState.updates.setFeedURL(updateFeedDraft)
                        updateFeedDraft = appState.updates.feedURLString
                    }
                    .disabled(
                        updateFeedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            == appState.updates.feedURLString
                    )
                }

                Toggle("Automatically check for updates", isOn: Binding(
                    get: { appState.settings.automaticUpdateChecks },
                    set: { appState.updates.setAutomaticChecks($0) }
                ))

                Toggle("Automatically download available updates", isOn: Binding(
                    get: { appState.settings.automaticallyDownloadsUpdates },
                    set: { appState.updates.setAutomaticallyDownloadsUpdates($0) }
                ))
                .disabled(!appState.settings.automaticUpdateChecks)

                HStack(spacing: 10) {
                    Button {
                        appState.updates.checkForUpdates()
                    } label: {
                        if appState.updates.status == .checking {
                            Label {
                                Text("Checking for updates…")
                            } icon: {
                                ProgressView().controlSize(.small)
                            }
                        } else {
                            Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(!appState.updates.canCheckForUpdates)

                    if let lastCheckedAt = appState.updates.lastCheckedAt {
                        Text(appState.settings.localizedFormat(
                            "Last checked: %@",
                            formattedDate(lastCheckedAt)
                        ))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Sparkle verifies update packages and asks before installation. Production releases require Developer ID, an EdDSA public key, and a signed appcast.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("Logs") {
                LabeledContent("Log Folder") {
                    Text(AppLogService.shared.directoryURL.tildeAbbreviatedPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text("Logs are written daily and kept for the latest 3 days by default. Expired logs are removed automatically while the app is running.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                DisclosureGroup("Log Categories & Filtering") {
                    VStack(alignment: .leading, spacing: 5) {
                        logCategoryRow("app.*", description: "App startup and configuration changes")
                        logCategoryRow("watch.*", description: "Folder watching, scans, baselines, and file discovery")
                        logCategoryRow("index.*", description: "Extraction, chunking, embeddings, and index persistence")
                        logCategoryRow("organize.*", description: "Rule matching, organization queue, and file moves")
                        logCategoryRow("vector.*", description: "Vector store lifecycle, writes, and searches")
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 11))

                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        isShowingClearLogsConfirmation = true
                    } label: {
                        Label("Clear Logs", systemImage: "trash")
                    }

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([AppLogService.shared.directoryURL])
                    } label: {
                        Label("Open Log Folder", systemImage: "folder")
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            AppLogService.unifiedLogStreamCommand,
                            forType: .string
                        )
                        logStatusMessage = appState.settings.localized("Live log filter command copied")
                    } label: {
                        Label("Copy Live Log Command", systemImage: "terminal")
                    }

                    Spacer()
                    if let logStatusMessage {
                        Label(logStatusMessage, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(FileNestTheme.success)
                    }
                }
            }

            Section("Automatic Organization") {
                Toggle("Automatically classify and move new files", isOn: Binding(
                    get: { appState.settings.autoOrganize },
                    set: { appState.settings.setAutoOrganize($0) }
                ))

                if appState.settings.autoOrganize {
                    Picker("Trigger", selection: Binding(
                        get: { appState.settings.autoOrganizeMode },
                        set: { appState.settings.setAutoOrganizeMode($0) }
                    )) {
                        ForEach(AppSettings.AutoOrganizeMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.label)).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    if appState.settings.autoOrganizeMode == AppSettings.AutoOrganizeMode.batched.rawValue {
                        Stepper(value: Binding(
                            get: { appState.settings.autoOrganizeIntervalSeconds },
                            set: { appState.settings.setAutoOrganizeIntervalSeconds($0) }
                        ), in: 30...3_600, step: 30) {
                            LabeledContent("Maximum wait") {
                                Text(appState.settings.localizedFormat(
                                    "%d sec",
                                    appState.settings.autoOrganizeIntervalSeconds
                                ))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Stepper(value: Binding(
                            get: { appState.settings.autoOrganizeBatchSize },
                            set: { appState.settings.setAutoOrganizeBatchSize($0) }
                        ), in: 2...100) {
                            LabeledContent("File threshold") {
                                Text(appState.settings.localizedFormat(
                                    "%d files",
                                    appState.settings.autoOrganizeBatchSize
                                ))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("Organize early when the file threshold is reached; otherwise organize at the maximum wait time. The minimum interval is 30 seconds.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Skip hidden files (starting with .)", isOn: Binding(
                    get: { appState.settings.excludeHidden },
                    set: { appState.settings.setExcludeHidden($0) }
                ))

                Picker("Classification Strategy", selection: Binding(
                    get: { appState.settings.classifyStrategy },
                    set: { appState.settings.setClassifyStrategy($0) }
                )) {
                    Text("Rules first, with automatic fallback").tag(ClassificationStrategy.hybrid.rawValue)
                    Text("Organization rules only").tag(ClassificationStrategy.rule.rawValue)
                }
                .pickerStyle(.radioGroup)

                Text(verbatim: appState.settings.localized(
                    appState.settings.classifyStrategy == ClassificationStrategy.rule.rawValue
                        ? "Rules Only: only matching enabled rules organize files; unmatched files stay in place."
                        : "Hybrid: matching rules take priority; unmatched files are organized by file type and AI topic."
                ))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("Organization Location") {
                LabeledContent("Destination Folder") {
                    Text(appState.organizer.organizeRoot.tildeAbbreviatedPath)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([appState.organizer.organizeRoot])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch appState.updates.status {
        case .notConfigured:
            Label("Update source not configured", systemImage: "link.badge.plus")
                .foregroundStyle(.secondary)
        case .ready:
            Label("Update service ready", systemImage: "checkmark.shield")
                .foregroundStyle(FileNestTheme.success)
        case .checking:
            Label("Checking", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(FileNestTheme.accent)
        case .upToDate:
            Label("You're up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(FileNestTheme.success)
        case let .updateAvailable(version, _):
            Label(appState.settings.localizedFormat("Version %@ available", version), systemImage: "arrow.down.circle.fill")
                .foregroundStyle(FileNestTheme.accent)
        case let .failed(message):
            Label(appState.settings.localizedRuntimeMessage(message), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(FileNestTheme.warning)
                .lineLimit(2)
        }
    }

    private func openLoginItemsSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private var formattedBuildDate: String {
        guard let date = appState.updates.buildInfo.buildDate else { return "—" }
        return formattedDate(date)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = appState.settings.selectedLocale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var indexSettings: some View {
        Form {
            Section("Watched Folders") {
                if appState.settings.watchDirs.isEmpty {
                    Label("No watched folders added", systemImage: "folder.badge.questionmark")
                        .foregroundStyle(.secondary)
                }

                ForEach(appState.settings.watchDirs, id: \.self) { directory in
                    let status = appState.watchDirectoryStatus(for: directory)
                    HStack(spacing: 10) {
                        Image(systemName: directoryStatusIcon(status))
                            .foregroundStyle(directoryStatusColor(status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: directory).tildeAbbreviatedPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(LocalizedStringKey(directoryStatusLabel(status)))
                                .font(.system(size: 9))
                                .foregroundStyle(directoryStatusColor(status))
                        }
                        Spacer()
                        if status?.accessState == .permissionDenied {
                            Button("Restore Access…") { appState.openWatchDirectoryPrivacySettings() }
                                .controlSize(.small)
                        } else if status?.accessState == .missing || status?.accessState == .unavailable {
                            Button("Check Again") { appState.retryWatchDirectoryAccess() }
                                .controlSize(.small)
                        }
                        Button {
                            removeDirectory(directory)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Remove watched folder")
                    }
                }

                Button(action: chooseDirectories) {
                    Label("Add Watched Folder…", systemImage: "plus")
                }

                DisclosureGroup("Enter Path Manually") {
                    HStack {
                        TextField("/Users/name/Folder", text: $newDir)
                        Button("Add") { addDirectory() }
                            .disabled(newDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Button {
                    existingWatchDirectoryInventories = appState.watchDirectoryInventories()
                    isShowingOrganizeExistingConfirmation = true
                } label: {
                    Label("Organize Existing Files in Watched Folders…", systemImage: "wand.and.stars")
                }
                .disabled(appState.settings.watchDirs.isEmpty || appState.organizationState.isActive)

                if appState.organizationState.isActive,
                   let progress = appState.organizationProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(LocalizedStringKey(appState.organizationStatusTitle))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            if appState.organizationState == .running {
                                Button("Pause Organization") { appState.pauseOrganization() }
                            } else if appState.organizationState == .paused {
                                Button("Resume Organization") { appState.resumeOrganization() }
                            }
                            Button("Stop Organization", role: .destructive) {
                                appState.stopOrganization()
                            }
                        }
                        ProgressView(value: progress.fractionCompleted)
                        Text(LocalizedStringKey(appState.organizationStatusSubtitle))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Process previously preserved, unorganized files at any time.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Section("Watched File Types") {
                FileTypeCheckboxSelector(
                    selectedExtensions: Binding(
                        get: { appState.settings.enabledExtensions },
                        set: { appState.settings.setEnabledExtensions($0) }
                    ),
                    customExtensions: Binding(
                        get: { appState.settings.customFileExtensions },
                        set: { appState.settings.setCustomFileExtensions($0) }
                    ),
                    availableExtensions: AppSettings.supportedExtensions,
                    title: "File types to watch"
                )
            }

            Section("Automatic Vectorization") {
                Toggle("Automatically vectorize supported files", isOn: Binding(
                    get: { appState.settings.autoVectorize },
                    set: { appState.settings.setAutoVectorize($0) }
                ))

                if appState.settings.autoVectorize {
                    FileTypeCheckboxSelector(
                        selectedExtensions: Binding(
                            get: { appState.settings.vectorizeExtensions },
                            set: { appState.settings.setVectorizeExtensions($0) }
                        ),
                        customExtensions: Binding(
                            get: { appState.settings.customFileExtensions },
                            set: { appState.settings.setCustomFileExtensions($0) }
                        ),
                        availableExtensions: AppSettings.vectorizableExtensions,
                        title: "File types to vectorize"
                    )

                    HStack(spacing: 8) {
                        Spacer()

                        Button {
                            appState.reindexAll()
                        } label: {
                            IndexingButtonLabel(defaultTitle: "Apply & Reindex", appState: appState)
                        }
                        .buttonStyle(GradientButtonStyle(compact: true))
                        .disabled(appState.reindexButtonsDisabled)
                    }

                    Stepper(value: Binding(
                        get: { appState.settings.vectorChunkWords },
                        set: { appState.settings.setVectorChunkWords($0) }
                    ), in: 600...1_000, step: 50) {
                        LabeledContent("Parent chunk maximum") {
                            Text(appState.settings.localizedFormat(
                                "%d tokens",
                                appState.settings.vectorChunkWords
                            ))
                            .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(value: Binding(
                        get: { appState.settings.vectorRetrievalChunkTokens },
                        set: { appState.settings.setVectorRetrievalChunkTokens($0) }
                    ), in: 120...appState.settings.vectorChunkWords, step: 20) {
                        LabeledContent("Retrieval chunk target") {
                            Text(appState.settings.localizedFormat(
                                "%d tokens",
                                appState.settings.vectorRetrievalChunkTokens
                            ))
                            .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(value: Binding(
                        get: { appState.settings.vectorChunkOverlap },
                        set: { appState.settings.setVectorChunkOverlap($0) }
                    ), in: 0...max(0, appState.settings.vectorRetrievalChunkTokens - 1), step: 10) {
                        LabeledContent("Maximum semantic overlap") {
                            Text(appState.settings.localizedFormat(
                                "%d tokens",
                                appState.settings.vectorChunkOverlap
                            ))
                            .foregroundStyle(.secondary)
                        }
                    }

                    Stepper(value: Binding(
                        get: { appState.settings.ragResultLimit },
                        set: { appState.settings.setRAGResultLimit($0) }
                    ), in: 1...30) {
                        LabeledContent("Chat retrieval files") {
                            Text(appState.settings.localizedFormat(
                                "%d files",
                                appState.settings.ragResultLimit
                            ))
                            .foregroundStyle(.secondary)
                        }
                    }

                    Text("The maximum number of related files returned and analyzed by AI per question. The default is 10; higher values increase recall and context usage.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Text("Paragraphs stay intact whenever possible. Oversized paragraphs split only between complete sentences, and overlap repeats complete semantic units without cutting words.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    DisclosureGroup("Local Document Parsing") {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Full text: PDF, DOCX, XLSX, PPTX, EPUB, OpenDocument, RTF, and plain text", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                            Label("Best-effort: legacy DOC/XLS/PPT and iWork (uses local macOS text metadata)", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                            if appState.settings.embeddingSource == AppSettings.EmbeddingSource.cloud.rawValue
                                || appState.settings.ocrSource == AppSettings.OCRSource.cloud.rawValue {
                                Label("Cloud processing is enabled: chunks or page images are sent to the configured services; vector storage remains local", systemImage: "exclamationmark.shield")
                                    .foregroundStyle(FileNestTheme.warning)
                            } else {
                                Label("Parsing, chunking, embeddings, OCR, and vector storage all stay on this Mac", systemImage: "lock.shield")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 10))
                        .padding(.top, 4)
                    }
                    .font(.system(size: 11, weight: .medium))
                }
            }

            Section("Index Maintenance") {
                LabeledContent("Indexed Files") {
                    Text("\(appState.indexedCount) ") + Text("items")
                }

                LabeledContent("Database Location") {
                    Text(SQLiteStore.databaseURL().tildeAbbreviatedPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 10) {
                    Button {
                        appState.reindexAll()
                    } label: {
                        IndexingButtonLabel(defaultTitle: "Reindex All Files", appState: appState)
                    }
                    .disabled(appState.reindexButtonsDisabled)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([SQLiteStore.databaseURL()])
                    } label: {
                        Label("Show Database", systemImage: "externaldrive")
                    }
                }

                if appState.indexingState != .idle {
                    IndexingStatusProgressView(appState: appState)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var aiSettings: some View {
        Form {
            Section("Chat Model") {
                Picker("Source", selection: Binding(
                    get: { appState.settings.llmChoice },
                    set: {
                        appState.settings.setLLMChoice($0)
                        appState.processPendingRAGFeedbackIfPossible()
                    }
                )) {
                    ForEach(AppSettings.LLMChoice.allCases) { choice in
                        Text(LocalizedStringKey(choice.label)).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Thinking Mode", isOn: Binding(
                    get: { appState.settings.thinkingMode },
                    set: { appState.settings.setThinkingMode($0) }
                ))
                Text("Requests deeper reasoning from the model when the selected model and API support it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if appState.settings.llmChoice == AppSettings.LLMChoice.none.rawValue {
                    Label("Chat summaries are off; semantic file search remains available.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }

                if appState.settings.llmChoice == AppSettings.LLMChoice.ollama.rawValue {
                    TextField("Ollama Address", text: Binding(
                        get: { appState.settings.ollamaHost },
                        set: { appState.settings.setOllamaHost($0) }
                    ))
                }

                if appState.settings.llmChoice == AppSettings.LLMChoice.cloud.rawValue {
                    Toggle("Detect Context Window Automatically", isOn: Binding(
                        get: { appState.settings.cloudContextWindowTokens == 0 },
                        set: { enabled in
                            appState.settings.setCloudContextWindowTokens(enabled ? 0 : 612_000)
                        }
                    ))
                    if appState.settings.cloudContextWindowTokens == 0 {
                        Text("Reads the selected model context window automatically; unknown cloud-compatible models default to 612K tokens.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Context Size") {
                            HStack(spacing: 6) {
                                TextField("612000", value: Binding(
                                    get: { appState.settings.cloudContextWindowTokens },
                                    set: { appState.settings.setCloudContextWindowTokens($0) }
                                ), format: .number.grouping(.never))
                                .multilineTextAlignment(.trailing)
                                .frame(width: 110)
                                Text("tokens")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("This manual value applies only to the selected cloud model and endpoint.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Picker("API Format", selection: Binding(
                        get: { appState.settings.cloudAPIFormat },
                        set: { appState.settings.setCloudAPIFormat($0) }
                    )) {
                        ForEach(AppSettings.CloudAPIFormat.allCases) { format in
                            Text(LocalizedStringKey(format.label)).tag(format.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    SecureField("API Key", text: Binding(
                        get: { appState.settings.cloudAPIKey },
                        set: { appState.settings.setCloudKey($0) }
                    ), prompt: Text("sk-…"))
                    TextField("Base URL", text: Binding(
                        get: { appState.settings.cloudBaseURL },
                        set: { appState.settings.setCloudBaseURL($0) }
                    ), prompt: Text(cloudBaseURLPlaceholder))
                    TextField("Model", text: Binding(
                        get: { appState.settings.cloudModel },
                        set: { appState.settings.setCloudModel($0) }
                    ))
                    Label("File excerpts will be sent to the configured cloud service. Review its privacy policy.", systemImage: "exclamationmark.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(FileNestTheme.warning)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Button {
                                Task { await testAIConnectivity() }
                            } label: {
                                Label("Test AI Connectivity", systemImage: "network")
                            }
                            .disabled(isTestingAIConnectivity)

                            if isTestingAIConnectivity {
                                ProgressView().controlSize(.small)
                                Text("Testing cloud services…")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(aiConnectivityChecks) { check in
                            aiConnectivityRow(check)
                        }

                        Text("Tests the chat model and any currently selected cloud Embedding and OCR services.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if usesOllama {
                ollamaServiceSettings
            }
            if appState.settings.llmChoice == AppSettings.LLMChoice.ollama.rawValue {
                localModelSettings
            }

            Section("Embedding Model") {
                Picker("Source", selection: Binding(
                    get: { appState.settings.embeddingSource },
                    set: { appState.settings.setEmbeddingSource($0) }
                )) {
                    ForEach(AppSettings.EmbeddingSource.allCases) { source in
                        Text(LocalizedStringKey(source.label)).tag(source.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if appState.settings.embeddingSource == AppSettings.EmbeddingSource.ollama.rawValue {
                    LabeledContent("Ollama Model") {
                        TextField("qwen3-embedding:0.6b", text: Binding(
                            get: { appState.settings.ollamaEmbeddingModel },
                            set: { appState.settings.setOllamaEmbeddingModel($0) }
                        ))
                    }
                    HStack {
                        Label("Prefer qwen3-embedding; download the model in Ollama first.", systemImage: "externaldrive")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if appState.ollama.isModelInstalled(appState.settings.ollamaEmbeddingModel) {
                            InstalledModelLabel()
                        } else {
                            Button {
                                Task {
                                    await appState.ollama.pull(
                                        model: appState.settings.ollamaEmbeddingModel,
                                        host: appState.settings.ollamaHost
                                    )
                                }
                            } label: {
                                Label("Download Embedding Model", systemImage: "arrow.down.circle")
                            }
                            .disabled(appState.ollama.state != .running || appState.ollama.pullingModel != nil)
                        }
                    }
                    if appState.ollama.pullingModel == appState.settings.ollamaEmbeddingModel {
                        SettingsOperationProgress(
                            status: appState.ollama.pullStatus,
                            progress: appState.ollama.pullProgress
                        )
                    }
                } else if appState.settings.embeddingSource == AppSettings.EmbeddingSource.cloud.rawValue {
                    Toggle("Reuse chat model API Key and Base URL", isOn: Binding(
                        get: { appState.settings.cloudEmbeddingReuseChatCredentials },
                        set: { appState.settings.setCloudEmbeddingReuseChatCredentials($0) }
                    ))
                    .toggleStyle(.checkbox)
                    if appState.settings.cloudEmbeddingReuseChatCredentials {
                        reusedCloudCredentialsSummary(
                            baseURL: appState.settings.effectiveCloudEmbeddingBaseURL
                        )
                    } else {
                        SecureField("Embedding API Key", text: Binding(
                            get: { appState.settings.cloudEmbeddingAPIKey },
                            set: { appState.settings.setCloudEmbeddingAPIKey($0) }
                        ), prompt: Text("sk-…"))
                        TextField("Embedding Base URL", text: Binding(
                            get: { appState.settings.cloudEmbeddingBaseURL },
                            set: { appState.settings.setCloudEmbeddingBaseURL($0) }
                        ), prompt: Text("https://api.openai.com/v1"))
                    }
                    TextField("Embedding Model", text: Binding(
                        get: { appState.settings.cloudEmbeddingModel },
                        set: { appState.settings.setCloudEmbeddingModel($0) }
                    ))
                    Label("Uses an OpenAI-compatible /embeddings endpoint. Document chunks are sent to this service.", systemImage: "exclamationmark.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(FileNestTheme.warning)
                } else {
                    Label("Uses the built-in macOS NLEmbedding model with no download required.", systemImage: "apple.logo")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Button {
                    appState.rebuildVectorIndex()
                } label: {
                    IndexingButtonLabel(defaultTitle: "Apply & Rebuild Vector Index", appState: appState)
                }
                .disabled(appState.reindexButtonsDisabled)

                if appState.indexingKind == .vectorRebuild,
                   let progress = appState.vectorIndexRebuildProgress {
                    VectorIndexRebuildProgressView(progress: progress)
                }

                LabeledContent("Loaded Vectors") {
                    Text("\(AppStateIndexerProxy.shared.indexer?.vectorStore.count ?? 0)")
                }
            }

            rerankerServiceSettings

            Section("OCR Model") {
                Picker("Source", selection: Binding(
                    get: { appState.settings.ocrSource },
                    set: { appState.settings.setOCRSource($0) }
                )) {
                    ForEach(AppSettings.OCRSource.allCases) { source in
                        Text(LocalizedStringKey(source.label)).tag(source.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if appState.settings.ocrSource == AppSettings.OCRSource.local.rawValue {
                    LabeledContent("Recognition Engine") {
                        HStack(spacing: 7) {
                            if appState.paddleOCR.isInstalling {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: paddleOCRReady ? "checkmark.circle.fill" : "circle.dashed")
                                    .foregroundStyle(paddleOCRReady ? FileNestTheme.success : .secondary)
                            }
                            Text(LocalizedStringKey(paddleOCRStatusText))
                        }
                    }
                    if paddleOCRReady {
                        ManagedServiceUpdateControls(
                            installedVersion: appState.paddleOCR.installedVersion,
                            status: appState.paddleOCR.updateStatus,
                            isInstalling: appState.paddleOCR.isInstalling,
                            onCheck: { Task { await appState.refreshModelServicesIfNeeded(force: true) } },
                            onUpdate: { Task { await appState.paddleOCR.update() } }
                        )
                    }
                    if !paddleOCRReady {
                        Button {
                            Task { await appState.paddleOCR.install() }
                        } label: {
                            Label("Install PaddleOCR", systemImage: "arrow.down.circle")
                        }
                        .disabled(appState.paddleOCR.isInstalling)
                    }
                    if appState.paddleOCR.isInstalling {
                        SettingsOperationProgress(
                            status: appState.paddleOCR.installStatus,
                            progress: appState.paddleOCR.installProgress
                        )
                    } else if let error = appState.paddleOCR.lastError {
                        Label(LocalizedStringKey(error), systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(FileNestTheme.warning)
                    }
                    LabeledContent("Fallback Model") {
                        TextField("glm-ocr", text: Binding(
                            get: { appState.settings.ollamaOCRModel },
                            set: { appState.settings.setOllamaOCRModel($0) }
                        ))
                    }
                    HStack {
                        Label("Use this local model automatically when PaddleOCR is unavailable.", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if appState.ollama.isModelInstalled(appState.settings.ollamaOCRModel) {
                            InstalledModelLabel()
                        } else {
                            Button {
                                Task {
                                    await appState.ollama.pull(
                                        model: appState.settings.ollamaOCRModel,
                                        host: appState.settings.ollamaHost
                                    )
                                }
                            } label: {
                                Label("Download Fallback OCR Model", systemImage: "arrow.down.circle")
                            }
                            .disabled(appState.ollama.state != .running || appState.ollama.pullingModel != nil)
                        }
                    }
                    if appState.ollama.pullingModel == appState.settings.ollamaOCRModel {
                        SettingsOperationProgress(
                            status: appState.ollama.pullStatus,
                            progress: appState.ollama.pullProgress
                        )
                    }
                    Label("Use PaddleOCR locally first; fall back to GLM-OCR when it is unavailable or recognition fails.", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if appState.settings.ocrSource == AppSettings.OCRSource.cloud.rawValue {
                    Picker("API Format", selection: Binding(
                        get: { appState.settings.cloudOCRFormat },
                        set: { appState.settings.setCloudOCRFormat($0) }
                    )) {
                        ForEach(AppSettings.CloudAPIFormat.allCases) { format in
                            Text(LocalizedStringKey(format.label)).tag(format.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Reuse chat model API Key and Base URL", isOn: Binding(
                        get: { appState.settings.cloudOCRReuseChatCredentials },
                        set: { appState.settings.setCloudOCRReuseChatCredentials($0) }
                    ))
                    .toggleStyle(.checkbox)
                    if appState.settings.cloudOCRReuseChatCredentials {
                        reusedCloudCredentialsSummary(baseURL: appState.settings.effectiveCloudOCRBaseURL)
                    } else {
                        SecureField("OCR API Key", text: Binding(
                            get: { appState.settings.cloudOCRAPIKey },
                            set: { appState.settings.setCloudOCRAPIKey($0) }
                        ), prompt: Text("sk-…"))
                        TextField("OCR Base URL", text: Binding(
                            get: { appState.settings.cloudOCRBaseURL },
                            set: { appState.settings.setCloudOCRBaseURL($0) }
                        ), prompt: Text(cloudOCRBaseURLPlaceholder))
                    }
                    TextField("OCR Model", text: Binding(
                        get: { appState.settings.cloudOCRModel },
                        set: { appState.settings.setCloudOCRModel($0) }
                    ))
                    Label("Images or scanned PDF pages are sent to the configured OCR service.", systemImage: "exclamationmark.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(FileNestTheme.warning)
                } else {
                    Text("OCR is disabled; text PDFs and regular documents can still be parsed.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            mediaTranscriptionSettings

            Section("Service Updates") {
                HStack(spacing: 8) {
                    Label("Automatic Version Detection", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text(lastAIModelVersionCheckText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text("Checks Ollama, PaddleOCR, and Docling for updates, and refreshes FFmpeg and Whisper status when this page opens.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            doclingServiceSettings
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var lastAIModelVersionCheckText: String {
        guard let checkedAt = appState.settings.lastAIModelVersionCheckAt else {
            return appState.settings.localized("Not checked yet")
        }
        let formatter = DateFormatter()
        let language = AppSettings.AppLanguage(rawValue: appState.settings.appLanguage) ?? .system
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return appState.settings.localizedFormat("Last checked: %@", formatter.string(from: checkedAt))
    }

    private var mediaTranscriptionSettings: some View {
        Section("Audio & Video Transcription") {
            Toggle("Transcribe audio and video for search and chat", isOn: Binding(
                get: { appState.settings.mediaTranscriptionEnabled },
                set: { appState.settings.setMediaTranscriptionEnabled($0) }
            ))

            Text("When enabled, FileNest transcribes supported media locally with OpenAI Whisper, creates time-coded chunks, and sends those chunks through the configured Embedding pipeline.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            LabeledContent("FFmpeg") {
                HStack(spacing: 8) {
                    Image(systemName: appState.ffmpeg.executablePath == nil
                          ? "circle.dashed"
                          : "checkmark.circle.fill")
                        .foregroundStyle(appState.ffmpeg.executablePath == nil
                                         ? Color.secondary
                                         : FileNestTheme.success)
                    Text(appState.ffmpeg.executablePath == nil
                         ? "Not installed"
                         : (appState.ffmpeg.version.map { "FFmpeg \($0)" } ?? "Ready"))
                    if appState.ffmpeg.executablePath == nil, !appState.ffmpeg.isInstalling {
                        Button("Install") { Task { await appState.ffmpeg.install() } }
                    }
                }
            }

            if appState.ffmpeg.isInstalling {
                SettingsOperationProgress(
                    status: appState.ffmpeg.installStatus,
                    progress: appState.ffmpeg.installProgress
                )
            } else if let error = appState.ffmpeg.lastError {
                Label(appState.settings.localizedRuntimeMessage(error), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(FileNestTheme.warning)
            }

            LabeledContent("Whisper Runtime") {
                HStack(spacing: 8) {
                    Image(systemName: appState.whisper.installedVersion == nil
                          ? "circle.dashed"
                          : "checkmark.circle.fill")
                        .foregroundStyle(appState.whisper.installedVersion == nil
                                         ? Color.secondary
                                         : FileNestTheme.success)
                    Text(appState.whisper.installedVersion.map { "Whisper \($0)" } ?? "Not installed")
                    if appState.whisper.installedVersion == nil, !appState.whisper.isInstalling {
                        Button("Install") { Task { await appState.whisper.installRuntime() } }
                    }
                }
            }

            Picker("Transcription Model", selection: Binding(
                get: { appState.settings.whisperModel },
                set: { appState.settings.setWhisperModel($0) }
            )) {
                ForEach(WhisperModelCatalog.models) { model in
                    Text("\(model.id) · \(model.parameters) · \(model.approximateSize)")
                        .tag(model.id)
                }
            }

            let selectedModel = WhisperModelCatalog.option(appState.settings.whisperModel)
            HStack(spacing: 10) {
                Text(LocalizedStringKey(selectedModel.detail))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if appState.whisper.isModelInstalled(selectedModel.id) {
                    InstalledModelLabel()
                    Button(role: .destructive) {
                        whisperModelPendingDeletion = selectedModel.id
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } else if !appState.whisper.isInstalling {
                    Button {
                        Task { await appState.whisper.downloadModel(selectedModel.id) }
                    } label: {
                        Label("Download Model", systemImage: "arrow.down.circle")
                    }
                }
            }

            if appState.whisper.isInstalling {
                SettingsOperationProgress(
                    status: appState.whisper.installStatus,
                    progress: appState.whisper.installProgress
                )
            } else if let error = appState.whisper.lastError {
                Label(appState.settings.localizedRuntimeMessage(error), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(FileNestTheme.warning)
            }

            Label("Audio and video stay on this Mac during transcription. FFmpeg is used only for media decoding.",
                  systemImage: "lock.shield")
                .font(.system(size: 10))
                .foregroundStyle(FileNestTheme.success)
        }
    }

    private var rerankerServiceSettings: some View {
        Section("Retrieval Reranker") {
            Picker("Source", selection: Binding(
                get: { appState.settings.rerankerSource },
                set: { source in
                    appState.settings.setRerankerSource(source)
                    guard source == AppSettings.RerankerSource.local.rawValue,
                          RerankerServiceManager.isModelInstalled else { return }
                    Task { await appState.reranker.start() }
                }
            )) {
                ForEach(AppSettings.RerankerSource.allCases) { source in
                    Text(LocalizedStringKey(source.label)).tag(source.rawValue)
                }
            }
            .pickerStyle(.segmented)

            if appState.settings.rerankerSource == AppSettings.RerankerSource.local.rawValue {
                LabeledContent("Model") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Qwen3-Reranker-0.6B")
                        Text("0.6B parameters · 32K context")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Local Status") {
                    HStack(spacing: 7) {
                        if appState.reranker.isInstalling || appState.reranker.state == .starting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: rerankerStatusIcon)
                                .foregroundStyle(rerankerStatusColor)
                        }
                        Text(LocalizedStringKey(rerankerStatusText))
                    }
                }

                if appState.reranker.isInstalling {
                    SettingsOperationProgress(
                        status: appState.reranker.installStatus,
                        progress: appState.reranker.installProgress
                    )
                } else if !RerankerServiceManager.isModelInstalled {
                    HStack {
                        Label("About 1.25 GB download; stored only on this Mac.", systemImage: "internaldrive")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await appState.reranker.install() }
                        } label: {
                            Label("Download Reranker", systemImage: "arrow.down.circle")
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        InstalledModelLabel()
                        Text(rerankerDiskSizeText)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if appState.reranker.isRunning {
                            Button("Stop Service") {
                                Task { await appState.reranker.stop() }
                            }
                        } else {
                            Button("Start Service") {
                                Task { await appState.reranker.start() }
                            }
                        }
                        Button(role: .destructive) {
                            isShowingDeleteRerankerConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }

                if let error = appState.reranker.lastError {
                    Label(appState.settings.localizedRuntimeMessage(error), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(FileNestTheme.warning)
                }

                DisclosureGroup("Advanced Local Service") {
                    TextField("Reranker Base URL", text: Binding(
                        get: { appState.settings.rerankerBaseURL },
                        set: { appState.settings.setRerankerBaseURL($0) }
                    ), prompt: Text("http://127.0.0.1:11435/v1"))
                    .padding(.top, 6)
                    Text("The managed service uses 127.0.0.1:11435. Change this only when connecting to another compatible local reranker.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else if appState.settings.rerankerSource == AppSettings.RerankerSource.cloud.rawValue {
                Toggle("Reuse chat API credentials", isOn: Binding(
                    get: { appState.settings.rerankerReuseChatCredentials },
                    set: { appState.settings.setRerankerReuseChatCredentials($0) }
                ))
                .toggleStyle(.checkbox)

                if !appState.settings.rerankerReuseChatCredentials {
                    TextField("Reranker Base URL", text: Binding(
                        get: { appState.settings.rerankerBaseURL },
                        set: { appState.settings.setRerankerBaseURL($0) }
                    ), prompt: Text("https://api.example.com/v1"))
                    SecureField("Reranker API Key", text: Binding(
                        get: { appState.settings.rerankerAPIKey },
                        set: { appState.settings.setRerankerAPIKey($0) }
                    ), prompt: Text("API key"))
                }
                TextField("Reranker Model", text: Binding(
                    get: { appState.settings.rerankerModel },
                    set: { appState.settings.setRerankerModel($0) }
                ), prompt: Text("Qwen/Qwen3-Reranker-0.6B"))
                Label("Search candidates are sent to the configured reranking service.", systemImage: "exclamationmark.shield")
                    .font(.system(size: 10))
                    .foregroundStyle(FileNestTheme.warning)
            } else {
                Text("Reranking is disabled. FileNest keeps the fused keyword and vector retrieval order.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text("Reranking refines the final candidate order after hybrid retrieval. If the service is unavailable, search continues with the original order.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var rerankerStatusText: String {
        switch appState.reranker.state {
        case .unavailable: return "Not downloaded"
        case .installed: return "Installed · service stopped"
        case .starting: return "Starting local service…"
        case .running: return "Ready"
        case .failed: return "Service unavailable"
        }
    }

    private var rerankerStatusIcon: String {
        switch appState.reranker.state {
        case .running: return "checkmark.circle.fill"
        case .installed: return "stop.circle"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "circle.dashed"
        }
    }

    private var rerankerStatusColor: Color {
        switch appState.reranker.state {
        case .running: return FileNestTheme.success
        case .failed: return FileNestTheme.warning
        default: return .secondary
        }
    }

    private var rerankerDiskSizeText: String {
        ByteCountFormatter.string(
            fromByteCount: appState.reranker.modelDiskBytes,
            countStyle: .file
        )
    }

    private var doclingServiceSettings: some View {
        Section("Docling Document Parsing") {
            Toggle("Prefer Docling for parsing and chunking", isOn: Binding(
                get: { appState.settings.doclingEnabled },
                set: { appState.settings.setDoclingEnabled($0) }
            ))

            LabeledContent("Docling Status") {
                HStack(spacing: 7) {
                    if appState.docling.isInstalling {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: appState.docling.executablePath == nil
                              ? "circle.dashed"
                              : "checkmark.circle.fill")
                            .foregroundStyle(appState.docling.executablePath == nil
                                             ? Color.secondary
                                             : FileNestTheme.success)
                    }
                    Text(appState.settings.localizedRuntimeMessage(doclingStatusText))
                }
            }

            LabeledContent("Executable") {
                Text(appState.docling.executablePath.map {
                    URL(fileURLWithPath: $0).tildeAbbreviatedPath
                } ?? "Docling not detected")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if appState.docling.installedVersion != nil {
                ManagedServiceUpdateControls(
                    installedVersion: appState.docling.installedVersion,
                    status: appState.docling.updateStatus,
                    isInstalling: appState.docling.isInstalling,
                    onCheck: { Task { await appState.refreshModelServicesIfNeeded(force: true) } },
                    onUpdate: { Task { await appState.docling.update() } }
                )
            }

            if appState.docling.executablePath == nil {
                Button {
                    Task { await appState.docling.install() }
                } label: {
                    Label("Install Docling", systemImage: "arrow.down.circle")
                }
                .disabled(appState.docling.isInstalling)
            }

            if appState.docling.isInstalling {
                SettingsOperationProgress(
                    status: appState.docling.installStatus,
                    progress: appState.docling.installProgress
                )
            } else if let error = appState.docling.lastError {
                Label(appState.settings.localizedRuntimeMessage(error), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(FileNestTheme.warning)
            }

            Text("Docling is installed in an isolated Python environment under FileNest’s user data. Its Hybrid Chunker is preferred when available; failures fall back automatically without blocking indexing.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private var doclingStatusText: String {
        switch appState.docling.state {
        case let .ready(version): return version
        case .installing: return "Installing Docling…"
        case .unavailable: return "Not installed"
        case let .failed(message): return message
        }
    }

    private var cloudBaseURLPlaceholder: String {
        appState.settings.cloudAPIFormat == AppSettings.CloudAPIFormat.anthropic.rawValue
            ? "https://api.anthropic.com/v1"
            : "https://api.openai.com/v1"
    }

    private var paddleOCRReady: Bool {
        if case .ready = appState.paddleOCR.state { return true }
        return false
    }

    private var paddleOCRStatusText: String {
        switch appState.paddleOCR.state {
        case .ready(let version): return version
        case .installing: return "Installing PaddleOCR…"
        case .unavailable: return "Not installed"
        case .failed(let message): return message
        }
    }

    private var cloudOCRBaseURLPlaceholder: String {
        appState.settings.cloudOCRFormat == AppSettings.CloudAPIFormat.anthropic.rawValue
            ? "https://api.anthropic.com/v1"
            : "https://api.openai.com/v1"
    }

    @ViewBuilder
    private func reusedCloudCredentialsSummary(baseURL: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Using chat model credentials", systemImage: "link")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(FileNestTheme.success)
            Text(baseURL.isEmpty ? appState.settings.localized("The chat model Base URL is not configured") : baseURL)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func aiConnectivityRow(_ check: AIConnectivityCheck) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: check.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(check.succeeded ? FileNestTheme.success : Color.red)
            Text(LocalizedStringKey(aiConnectivityLabel(for: check.kind)))
                .font(.system(size: 11, weight: .medium))
            Text(LocalizedStringKey(check.succeeded ? "Connected" : "Connection failed"))
                .font(.system(size: 10))
                .foregroundStyle(check.succeeded ? FileNestTheme.success : Color.red)
            if let detail = check.detail, !detail.isEmpty {
                Text(appState.settings.localizedRuntimeMessage(detail))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private func aiConnectivityLabel(for kind: AIConnectivityCheck.Kind) -> String {
        switch kind {
        case .chat: return "Chat Model"
        case .embedding: return "Embedding Model"
        case .ocr: return "OCR Model"
        }
    }

    @MainActor
    private func testAIConnectivity() async {
        guard !isTestingAIConnectivity else { return }
        isTestingAIConnectivity = true
        aiConnectivityChecks = []
        let embedding = appState.settings.embeddingSource == AppSettings.EmbeddingSource.cloud.rawValue
            ? appState.settings.makeEmbeddingProvider()
            : nil
        let ocr = appState.settings.ocrSource == AppSettings.OCRSource.cloud.rawValue
            ? appState.settings.makeOCRProvider()
            : nil
        aiConnectivityChecks = await AIConnectivityTester.run(
            llm: appState.settings.makeLLMProvider(),
            embedding: embedding,
            ocr: ocr
        )
        isTestingAIConnectivity = false
    }

    private var ollamaServiceSettings: some View {
        Section("Ollama Service") {
            LabeledContent("Status") {
                HStack(spacing: 7) {
                    if appState.ollama.state == .starting || appState.ollama.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Circle()
                            .fill(appState.ollama.state == .running ? FileNestTheme.success : Color.secondary)
                            .frame(width: 7, height: 7)
                    }
                    Text(LocalizedStringKey(appState.ollama.state.label))
                        .foregroundStyle(appState.ollama.state == .running ? FileNestTheme.success : .secondary)
                }
            }

            LabeledContent("Executable") {
                Text(appState.ollama.executablePath.map { URL(fileURLWithPath: $0).tildeAbbreviatedPath }
                     ?? "Ollama Not Detected")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if appState.ollama.isManagedInstall {
                ManagedServiceUpdateControls(
                    installedVersion: appState.ollama.installedVersion,
                    status: appState.ollama.updateStatus,
                    isInstalling: appState.ollama.isInstalling,
                    onCheck: { Task { await appState.refreshModelServicesIfNeeded(force: true) } },
                    onUpdate: {
                        Task {
                            await appState.updateConfiguredOllama()
                        }
                    }
                )
            }

            Toggle("Enable Flash Attention", isOn: Binding(
                get: { appState.settings.ollamaFlashAttentionEnabled },
                set: { appState.settings.setOllamaFlashAttentionEnabled($0) }
            ))
            .toggleStyle(.checkbox)

            Text("Enabled by default. Restart the Ollama service after changing this setting.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if appState.ollama.executablePath == nil {
                    Button {
                        Task {
                            await appState.startConfiguredOllama(installIfNeeded: true)
                        }
                    } label: {
                        Label("Download, Install & Start", systemImage: "arrow.down.app.fill")
                    }
                    .disabled(appState.ollama.isInstalling)
                } else {
                    Button {
                        Task {
                            await appState.startConfiguredOllama()
                        }
                    } label: {
                        Label("Start Service", systemImage: "play.fill")
                    }
                    .disabled(
                        (appState.ollama.state == .running && appState.ollama.canStopManagedService) ||
                        appState.ollama.state == .starting ||
                        appState.ollama.isInstalling
                    )
                }

                Button {
                    Task { await appState.ollama.stop(host: appState.settings.ollamaHost) }
                } label: {
                    Label("Stop Service", systemImage: "stop.fill")
                }
                .disabled(!appState.ollama.canStopManagedService)

                Button {
                    Task { await appState.ollama.refresh(host: appState.settings.ollamaHost) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(appState.ollama.isRefreshing)
            }

            if appState.ollama.isInstalling {
                SettingsOperationProgress(
                    status: appState.ollama.installStatus,
                    progress: appState.ollama.installProgress
                )
            } else if !appState.ollama.installStatus.isEmpty {
                Text(LocalizedStringKey(appState.ollama.installStatus))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if appState.ollama.executablePath == nil {
                Text("Downloads from Ollama's official site and installs in FileNest's user folder; no administrator access required.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if appState.ollama.state == .running && !appState.ollama.canStopManagedService {
                Text("The service was started elsewhere. FileNest can use it but will not force it to stop.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if let error = appState.ollama.lastError {
                Label(appState.settings.localizedRuntimeMessage(error), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(FileNestTheme.warning)
            }
        }
    }

    private var localModelSettings: some View {
        Section("Local Models") {
            HStack(spacing: 10) {
                Picker("Model Profile", selection: $selectedModelProfileID) {
                    ForEach(recommendedModelProfiles) { profile in
                        if profile.id == recommendedModelProfile.id {
                            (Text("Recommended · ") + Text(LocalizedStringKey(profile.memoryLabel))
                                + Text(" — \(profile.generationModel)"))
                                .tag(profile.id)
                        } else {
                            (Text(LocalizedStringKey(profile.memoryLabel))
                                + Text(" — \(profile.generationModel)"))
                                .tag(profile.id)
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)

                Button {
                    Task {
                        await appState.ollama.pull(
                            model: selectedModelProfile.generationModel,
                            host: appState.settings.ollamaHost
                        )
                    }
                } label: {
                    Label("Download Model", systemImage: "arrow.down.circle")
                }
                .disabled(
                    appState.ollama.state != .running ||
                    appState.ollama.pullingModel != nil
                )
            }

            HStack(spacing: 14) {
                Label {
                    (Text("This Mac") + Text(" \(OllamaModelRecommendation.currentMemoryGB)GB"))
                } icon: {
                    Image(systemName: "memorychip")
                }
                    .foregroundStyle(FileNestTheme.accent)
                Divider().frame(height: 14)
                (Text("Generation") + Text(" \(selectedModelProfile.generationModel)"))
                Divider().frame(height: 14)
                Text("Embedding \(selectedModelProfile.embeddingSize)")
                Divider().frame(height: 14)
                (Text("Suggested Context") + Text(" \(selectedModelProfile.contextRange)"))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)

            if selectedModelProfile.id == recommendedModelProfile.id {
                Label("Recommended for this Mac's memory and placed first in the menu.", systemImage: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(FileNestTheme.success)
            }

            if let pulling = appState.ollama.pullingModel {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        (Text("Downloading") + Text(" \(pulling)"))
                        Spacer()
                        Text(LocalizedStringKey(appState.ollama.pullStatus))
                            .foregroundStyle(.secondary)
                        if let progress = appState.ollama.pullProgress {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .fontDesign(.monospaced)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 10))
                    if let progress = appState.ollama.pullProgress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                }
            }

            if appState.ollama.models.isEmpty {
                Text(LocalizedStringKey(
                    appState.ollama.state == .running
                        ? "No models installed"
                        : "Start the service to download and manage models"
                ))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.ollama.models) { model in
                    HStack(spacing: 10) {
                        Button {
                            appState.settings.setOllamaModel(model.name)
                        } label: {
                            Image(systemName: appState.settings.ollamaModel == model.name
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(appState.settings.ollamaModel == model.name
                                                 ? FileNestTheme.accent : .secondary)
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.name)
                                .font(.system(size: 11, weight: .medium))
                            Text(localModelSummary(model))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if appState.settings.ollamaModel == model.name {
                            Text("Current Model")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(FileNestTheme.accent)
                        }
                        Button {
                            modelPendingDeletion = model
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .help("Delete Model")
                    }
                }
            }
        }
    }

    private var recommendedModelProfile: OllamaModelProfile {
        OllamaModelRecommendation.recommendedForCurrentDevice
    }

    private func localModelSummary(_ model: OllamaModelInfo) -> String {
        var items = [ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)]
        if let parameterSize = model.details?.parameterSize {
            items.append(appState.settings.localizedFormat("Parameters %@", parameterSize))
        }
        if let contextLength = model.details?.contextLength {
            items.append(appState.settings.localizedFormat("Context %@", compactTokenCount(contextLength)))
        }
        if let architecture = model.details?.architecture ?? model.details?.family {
            items.append(architecture)
        }
        if let quantization = model.details?.quantizationLevel {
            items.append(quantization)
        }
        if let embeddingLength = model.details?.embeddingLength {
            items.append(appState.settings.localizedFormat("Embedding dimensions %d", embeddingLength))
        }
        return items.joined(separator: " · ")
    }

    private func compactTokenCount(_ value: Int) -> String {
        if value >= 1_048_576, value.isMultiple(of: 1_048_576) {
            return "\(value / 1_048_576)M"
        }
        if value >= 1_024, value.isMultiple(of: 1_024) {
            return "\(value / 1_024)K"
        }
        return value.formatted()
    }

    private var recommendedModelProfiles: [OllamaModelProfile] {
        OllamaModelRecommendation.orderedProfiles(
            forMemoryGB: OllamaModelRecommendation.currentMemoryGB
        )
    }

    private var selectedModelProfile: OllamaModelProfile {
        recommendedModelProfiles.first(where: { $0.id == selectedModelProfileID })
            ?? recommendedModelProfile
    }

    private var usesOllama: Bool {
        appState.settings.llmChoice == AppSettings.LLMChoice.ollama.rawValue
            || appState.settings.embeddingSource == AppSettings.EmbeddingSource.ollama.rawValue
            || appState.settings.ocrSource == AppSettings.OCRSource.local.rawValue
    }

    private func chooseDirectories() {
        let panel = NSOpenPanel()
        panel.title = appState.settings.localized("Choose Folders to Watch")
        panel.prompt = appState.settings.localized("Add")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true

        panel.begin { response in
            guard response == .OK else { return }
            let paths = panel.urls.map(\.path)
            Task { @MainActor in
                addDirectories(paths)
            }
        }
    }

    private func addDirectory() {
        let directory = NSString(
            string: newDir.trimmingCharacters(in: .whitespacesAndNewlines)
        ).expandingTildeInPath
        guard !directory.isEmpty else { return }
        addDirectories([directory])
        newDir = ""
    }

    private func addDirectories(_ directories: [String]) {
        let existing = Set(appState.settings.watchDirs.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        let normalized = directories.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        pendingWatchDirectories = Array(Set(normalized).subtracting(existing)).sorted()
        guard !pendingWatchDirectories.isEmpty else { return }
        pendingWatchDirectoryInventories = appState.watchDirectoryInventories(
            for: pendingWatchDirectories
        )
        isShowingNewDirectoryChoice = true
    }

    private func commitPendingWatchDirectories(organizeExisting: Bool) {
        let directories = pendingWatchDirectories
        guard !directories.isEmpty else { return }
        if organizeExisting {
            appState.clearPreservedWatchDirectoryEntries(in: directories)
        } else {
            // Record the baseline before adding the folder to watcher configuration so the first scan cannot process existing files early.
            appState.preserveExistingWatchDirectoryEntries(in: directories)
        }
        let merged = Array(Set(appState.settings.watchDirs + directories)).sorted()
        appState.settings.setWatchDirs(merged)
        restartWatcher()
        if organizeExisting {
            appState.organizeExistingWatchDirectoryEntries(in: directories)
        }
        pendingWatchDirectories = []
        pendingWatchDirectoryInventories = []
    }

    private func removeDirectory(_ directory: String) {
        appState.clearPreservedWatchDirectoryEntries(in: [directory])
        appState.settings.setWatchDirs(appState.settings.watchDirs.filter { $0 != directory })
        restartWatcher()
    }

    private func restartWatcher() {
        appState.stopWatching()
        appState.startWatching()
    }

    private var watchStatusIcon: String {
        if appState.hasActiveWatchDirectories { return "checkmark.circle.fill" }
        if appState.isWatching { return "exclamationmark.triangle.fill" }
        return "pause.circle.fill"
    }

    private var watchStatusColor: Color {
        if appState.hasActiveWatchDirectories { return FileNestTheme.success }
        if appState.isWatching { return FileNestTheme.warning }
        return .secondary
    }

    private func directoryStatusLabel(_ status: WatchDirectoryStatus?) -> String {
        guard let status else { return "Checking folder access" }
        switch status.accessState {
        case .accessible:
            return status.isWatching ? "Watching" : (appState.isWatching ? "Connecting to watched folders…" : "Accessible")
        case .permissionDenied: return "Access Denied"
        case .missing: return "Folder Missing"
        case .unavailable: return "Temporarily Unavailable"
        }
    }

    private func directoryStatusIcon(_ status: WatchDirectoryStatus?) -> String {
        guard let status else { return "folder.badge.questionmark" }
        switch status.accessState {
        case .accessible: return status.isWatching ? "folder.badge.checkmark" : "folder.fill"
        case .permissionDenied: return "folder.badge.questionmark"
        case .missing: return "folder.badge.minus"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    private func directoryStatusColor(_ status: WatchDirectoryStatus?) -> Color {
        guard let status else { return .secondary }
        switch status.accessState {
        case .accessible: return status.isWatching ? FileNestTheme.success : FileNestTheme.accent
        case .permissionDenied, .missing, .unavailable: return FileNestTheme.warning
        }
    }

    private func logCategoryRow(_ category: String, description: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(category)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 72, alignment: .leading)
            Text(description)
                .foregroundStyle(.secondary)
        }
    }

}

/// Keeps inactive settings tabs cheap to construct. Native `TabView` can retain
/// every child hierarchy even though only one page is visible.
/// Reusable category selector for every setting that accepts a file-extension set.
/// It avoids free-form comma lists, while preserving the underlying configuration
/// as a normalized list of extensions.
private struct FileTypeCheckboxSelector: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedExtensions: [String]
    @Binding var customExtensions: [String]
    let availableExtensions: [String]
    let title: String

    @State private var expandedCategories = Set<String>()
    @State private var isAddingExtension = false
    @State private var extensionDraft = ""

    private var available: Set<String> { Set(availableExtensions).union(customExtensions) }
    private var selected: Set<String> { Set(selectedExtensions).intersection(available) }
    private var allSelected: Bool { !available.isEmpty && selected == available }
    private var categories: [(name: String, systemImage: String, extensions: [String])] {
        let builtIn = AppSettings.supportedFileExtensionCategories.compactMap { category -> (String, String, [String])? in
            let extensions = category.extensions.filter { available.contains($0) }
            guard !extensions.isEmpty else { return nil }
            return (category.name, categoryIcon(for: category.name), extensions)
        }
        let custom = customExtensions.filter { available.contains($0) }
        if custom.isEmpty { return builtIn }
        return builtIn + [("Custom", "plus.circle", custom)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(appState.settings.localizedFormat("%d types selected", selected.count))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button {
                    isAddingExtension.toggle()
                    if !isAddingExtension { extensionDraft = "" }
                } label: {
                    Label(isAddingExtension ? "Cancel" : "Add Type", systemImage: isAddingExtension ? "xmark" : "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isAddingExtension {
                HStack(spacing: 8) {
                    TextField("Extension, e.g. log", text: $extensionDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addCustomExtension)
                    Button("Add", action: addCustomExtension)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(normalizedDraft == nil)
                }
            }

            Toggle(appState.settings.localized("All file types"), isOn: Binding(
                get: { allSelected },
                set: { enabled in replaceSelection(with: enabled ? available : []) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(FileNestTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 8))

            VStack(spacing: 5) {
                ForEach(categories, id: \.name) { category in
                    categoryRow(category)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func categoryRow(_ category: (name: String, systemImage: String, extensions: [String])) -> some View {
        let categoryExtensions = Set(category.extensions)
        let selectedCount = categoryExtensions.intersection(selected).count
        let isExpanded = expandedCategories.contains(category.name)

        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if isExpanded { expandedCategories.remove(category.name) }
                        else { expandedCategories.insert(category.name) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: category.systemImage)
                            .frame(width: 15)
                            .foregroundStyle(FileNestTheme.accent)
                        Text(appState.settings.localized(category.name))
                            .font(.system(size: 11, weight: .medium))
                        Text("\(selectedCount)/\(category.extensions.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Toggle("", isOn: Binding(
                    get: { categoryExtensions.isSubset(of: selected) },
                    set: { enabled in toggle(categoryExtensions, enabled: enabled) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(FileNestTheme.elevatedSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))

            if isExpanded {
                FlowLayout(spacing: 6) {
                    ForEach(category.extensions, id: \.self) { fileExtension in
                        extensionChip(fileExtension)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
        }
    }

    private func extensionChip(_ fileExtension: String) -> some View {
        let isSelected = selected.contains(fileExtension)
        return Button {
            toggle([fileExtension], enabled: !isSelected)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark" : "plus")
                    .font(.system(size: 8, weight: .bold))
                Text(".\(fileExtension)")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isSelected ? FileNestTheme.accent : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                isSelected ? FileNestTheme.accent.opacity(0.13) : FileNestTheme.elevatedSurface,
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(
                    isSelected ? FileNestTheme.accent.opacity(0.28) : .secondary.opacity(0.16),
                    lineWidth: 1
                )
            }
        }
        .buttonStyle(.plain)
    }

    private var normalizedDraft: String? {
        let value = extensionDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard value.range(of: "^[a-z0-9][a-z0-9+_-]{0,31}$", options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private func addCustomExtension() {
        guard let fileExtension = normalizedDraft else { return }
        if !customExtensions.contains(fileExtension), !AppSettings.supportedExtensions.contains(fileExtension) {
            customExtensions.append(fileExtension)
            customExtensions.sort()
        }
        if !selectedExtensions.contains(fileExtension) {
            selectedExtensions.append(fileExtension)
            selectedExtensions.sort()
        }
        expandedCategories.insert("Custom")
        extensionDraft = ""
        isAddingExtension = false
    }

    private func categoryIcon(for name: String) -> String {
        switch name {
        case "Documents": return "doc.text"
        case "Images": return "photo"
        case "Videos": return "film"
        case "Audio": return "waveform"
        case "Code": return "chevron.left.forwardslash.chevron.right"
        case "Archives": return "archivebox"
        default: return "folder"
        }
    }

    private func replaceSelection(with newSelection: Set<String>) {
        let unrelated = Set(selectedExtensions).subtracting(available)
        selectedExtensions = Array(unrelated.union(newSelection)).sorted()
    }

    private func toggle(_ extensions: Set<String>, enabled: Bool) {
        var next = selected
        if enabled { next.formUnion(extensions) } else { next.subtract(extensions) }
        replaceSelection(with: next)
    }
}

private struct FlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let rows = arrangedRows(subviews: subviews, maximumWidth: width)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrangedRows(subviews: subviews, maximumWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.view.place(
                    at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrangedRows(subviews: Subviews, maximumWidth: CGFloat) -> [FlowRow] {
        var rows = [FlowRow]()
        var current = FlowRow()
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            let candidateWidth = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, candidateWidth > maximumWidth {
                rows.append(current)
                current = FlowRow()
            }
            current.items.append(FlowItem(view: view, size: size))
            current.width = current.items.count == 1 ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }

    private struct FlowItem {
        let view: LayoutSubview
        let size: CGSize
    }

    private struct FlowRow {
        var items = [FlowItem]()
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}

private struct DeferredSettingsPage<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
    }
}

private struct ManagedServiceUpdateControls: View {
    @EnvironmentObject private var appState: AppState

    let installedVersion: String?
    let status: ManagedServiceUpdateStatus
    let isInstalling: Bool
    let onCheck: () -> Void
    let onUpdate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let installedVersion {
                Text("Current Version")
                    .foregroundStyle(.secondary)
                Text(installedVersion)
                    .fontDesign(.monospaced)
                    .textSelection(.enabled)
            }

            statusView
            Spacer(minLength: 8)

            Button {
                onCheck()
            } label: {
                Label("Check for Updates", systemImage: "arrow.clockwise")
            }
            .disabled(status.isBusy || isInstalling)

            if case .updateAvailable = status {
                Button {
                    onUpdate()
                } label: {
                    Label("Update Service", systemImage: "arrow.down.app")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling)
            }
        }
        .font(.system(size: 10))
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            Label {
                Text("Checking for updates…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
        case .upToDate:
            Label("You're up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(FileNestTheme.success)
        case let .updateAvailable(version):
            HStack(spacing: 3) {
                Image(systemName: "arrow.down.circle.fill")
                Text("Update available:")
                Text(version).fontDesign(.monospaced)
            }
            .foregroundStyle(FileNestTheme.accent)
        case .updating:
            Label {
                Text("Updating…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(FileNestTheme.accent)
        case let .failed(message):
            Label {
                Text(appState.settings.localizedRuntimeMessage(message))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
                .foregroundStyle(FileNestTheme.warning)
                .lineLimit(2)
        }
    }
}

private struct SettingsOperationProgress: View {
    @EnvironmentObject private var appState: AppState
    let status: String
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if progress == nil {
                    ProgressView().controlSize(.small)
                }
                Text(verbatim: appState.settings.localizedRuntimeMessage(status))
                    .lineLimit(1)
                Spacer()
                if let progress {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .fontDesign(.monospaced)
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)

            if let progress {
                ProgressView(value: progress)
                    .tint(FileNestTheme.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Download progress")
    }
}

private struct InstalledModelLabel: View {
    var body: some View {
        Label("Installed", systemImage: "checkmark.circle.fill")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(FileNestTheme.success)
            .accessibilityLabel("Model installed")
    }
}

private struct VectorIndexRebuildProgressView: View {
    let progress: VectorIndexRebuildProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if progress.phase == .completed || progress.phase == .failed ||
                    progress.phase == .paused || progress.phase == .stopped {
                    Image(systemName: phaseSymbol)
                        .foregroundStyle(phaseColor)
                } else {
                    ProgressView().controlSize(.small)
                }

                Text(LocalizedStringKey(statusText))
                    .lineLimit(1)
                if let stage = progress.stage {
                    Text(stageText(stage))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let fileName = progress.currentFileName, progress.phase == .indexing {
                    Text(fileName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("\(progress.completed)/\(progress.total)")
                    .fontDesign(.monospaced)
            }
            .font(.system(size: 10, weight: .medium))

            ProgressView(value: progress.fraction)
                .tint(phaseColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Indexing progress")
    }

    private var statusText: String {
        switch progress.phase {
        case .preparing: return "Preparing to rebuild vector index"
        case .clearing: return "Clearing old vectors"
        case .indexing: return "Indexing files"
        case .paused: return "Vector Index Rebuild Paused"
        case .stopping: return "Stopping Vector Index Rebuild"
        case .stopped: return "Vector Index Rebuild Stopped"
        case .completed:
            return progress.failed == 0 ? "Vector index rebuild complete" : "Vector index rebuilt with some failed files"
        case .failed: return "Vector index rebuild failed"
        }
    }

    private var phaseSymbol: String {
        switch progress.phase {
        case .completed: return progress.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private func stageText(_ stage: IndexingStage) -> String {
        if case let .embedding(completed, total) = stage {
            return String(
                format: NSLocalizedString("Generating vectors %d/%d", comment: ""),
                completed,
                total
            )
        }
        return NSLocalizedString(stage.statusText, comment: "")
    }

    private var phaseColor: Color {
        switch progress.phase {
        case .completed: return progress.failed == 0 ? FileNestTheme.success : FileNestTheme.warning
        case .failed: return FileNestTheme.warning
        case .paused, .stopped: return .secondary
        default: return FileNestTheme.accent
        }
    }
}
