import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FileNestLayout {
    static let sidebarWidth: CGFloat = 255
    static let inspectorWidth: CGFloat = 334
    static let dividerWidth: CGFloat = 1
}

enum FileNestTheme {
    /// Foreground accents are deliberately brighter in Dark Mode so links,
    /// icons, and focus indicators keep strong contrast on deep surfaces.
    static let accent = adaptiveColor(
        light: NSColor(srgbRed: 0.34, green: 0.31, blue: 0.96, alpha: 1),
        dark: NSColor(srgbRed: 0.68, green: 0.64, blue: 1.0, alpha: 1)
    )
    static let accentBlue = adaptiveColor(
        light: NSColor(srgbRed: 0.24, green: 0.48, blue: 0.98, alpha: 1),
        dark: NSColor(srgbRed: 0.46, green: 0.68, blue: 1.0, alpha: 1)
    )
    /// Prominent fills remain darker than foreground accents so white button
    /// labels retain accessible contrast in both appearances.
    static let accentFill = Color(red: 0.34, green: 0.31, blue: 0.96)
    static let accentFillBlue = Color(red: 0.22, green: 0.42, blue: 0.88)
    static let selection = adaptiveColor(
        light: NSColor(srgbRed: 0.929, green: 0.926, blue: 0.992, alpha: 1),
        dark: NSColor(srgbRed: 0.18, green: 0.17, blue: 0.28, alpha: 1)
    )
    /// Neutral content selection keeps dense rows calm in Dark Mode. Brand color
    /// remains on controls and icons instead of tinting a large reading surface.
    static let contentSelection = adaptiveColor(
        light: NSColor(srgbRed: 0.945, green: 0.945, blue: 0.970, alpha: 1),
        dark: NSColor(srgbRed: 0.150, green: 0.150, blue: 0.165, alpha: 1)
    )
    static let contentHover = adaptiveColor(
        light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.975, alpha: 1),
        dark: NSColor(srgbRed: 0.125, green: 0.125, blue: 0.135, alpha: 1)
    )
    static let inspectorSurface = adaptiveColor(
        light: NSColor(srgbRed: 0.975, green: 0.975, blue: 0.980, alpha: 1),
        dark: NSColor(srgbRed: 0.115, green: 0.115, blue: 0.125, alpha: 1)
    )
    static let sidebarSurface = adaptiveColor(
        light: NSColor(srgbRed: 0.965, green: 0.969, blue: 0.978, alpha: 1),
        dark: NSColor(srgbRed: 0.094, green: 0.106, blue: 0.133, alpha: 1)
    )
    static let sidebarSelection = adaptiveColor(
        light: NSColor(srgbRed: 0.925, green: 0.925, blue: 1.0, alpha: 1),
        dark: NSColor(srgbRed: 0.157, green: 0.176, blue: 0.227, alpha: 1)
    )
    static let sidebarSelectedText = adaptiveColor(
        light: NSColor(srgbRed: 0.275, green: 0.251, blue: 0.82, alpha: 1),
        dark: NSColor(srgbRed: 0.949, green: 0.957, blue: 1.0, alpha: 1)
    )
    static let sidebarSelectedIcon = adaptiveColor(
        light: NSColor(srgbRed: 0.34, green: 0.31, blue: 0.96, alpha: 1),
        dark: NSColor(srgbRed: 0.557, green: 0.627, blue: 1.0, alpha: 1)
    )
    static let success = Color(red: 0.10, green: 0.67, blue: 0.29)
    static let warning = Color(red: 0.83, green: 0.55, blue: 0.08)
    static let warningSurface = Color.yellow.opacity(0.12)
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let secondarySurface = Color(nsColor: .controlBackgroundColor)
    static let elevatedSurface = Color(nsColor: .textBackgroundColor)
    static let border = Color.primary.opacity(0.10)
    static let strongBorder = Color.primary.opacity(0.16)
    static let primaryGradient = LinearGradient(
        colors: [accentFillBlue, accentFill],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// SwiftUI does not expose AppKit's overlay scroller controls. This bridge applies
/// a compact, low-contrast overlay style to every scroller in its containing window.
@MainActor
final class FileNestScrollerStyleCoordinator {
    static let shared = FileNestScrollerStyleCoordinator()

    private var observerTokens = [NSObjectProtocol]()
    private var pendingWindowIDs = Set<ObjectIdentifier>()

    private init() {}

    func start() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default
        let notifications: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResizeNotification,
            // SwiftUI replaces subtrees when switching between the main workspace and
            // settings. A window update is emitted after the new NSScrollViews join
            // the hierarchy, so it covers those late-created views.
            NSWindow.didUpdateNotification,
        ]
        observerTokens = notifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let window = notification.object as? NSWindow
                Task { @MainActor [weak self, weak window] in
                    self?.schedule(window: window)
                }
            }
        }
        NSApp.windows.forEach(scheduleInitialConfiguration(for:))
    }

    func scheduleInitialConfiguration(for window: NSWindow?) {
        guard let window else { return }
        schedule(window: window)
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard let self, let window else { return }
                self.apply(to: window)
            }
        }
    }

    func schedule(window: NSWindow?) {
        guard let window else { return }
        let identifier = ObjectIdentifier(window)
        guard pendingWindowIDs.insert(identifier).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self, weak window] in
            guard let self else { return }
            self.pendingWindowIDs.remove(identifier)
            guard let window else { return }
            self.apply(to: window)
        }
    }

    func apply(to window: NSWindow) {
        guard let contentView = window.contentView else { return }
        applyRecursively(to: contentView)
    }

    func applyRecursively(to view: NSView) {
        if let scrollView = view as? NSScrollView {
            configure(scrollView)
        }
        view.subviews.forEach(applyRecursively(to:))
    }

    private func configure(_ scrollView: NSScrollView) {
        let needsLayout = scrollView.scrollerStyle != .overlay
            || scrollView.verticalScroller?.controlSize != .mini
            || scrollView.horizontalScroller?.controlSize != .mini
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.horizontalScroller?.controlSize = .mini
        scrollView.verticalScroller?.alphaValue = 0.30
        scrollView.horizontalScroller?.alphaValue = 0.30
        if needsLayout {
            scrollView.needsLayout = true
        }
    }
}

private final class FileNestScrollerStyleAnchorView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        FileNestScrollerStyleCoordinator.shared.scheduleInitialConfiguration(for: window)
    }
}

private struct FileNestOverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = FileNestScrollerStyleAnchorView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            FileNestScrollerStyleCoordinator.shared.scheduleInitialConfiguration(for: view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        FileNestScrollerStyleCoordinator.shared.scheduleInitialConfiguration(for: nsView.window)
    }
}

extension View {
    func fileNestOverlayScrollStyle() -> some View {
        background(FileNestOverlayScrollerConfigurator().frame(width: 0, height: 0))
    }

    func pointingHandOnHover(_ enabled: Bool = true) -> some View {
        onHover { hovering in
            guard enabled else { return }
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }
}

extension AppSettings {
    var selectedLocale: Locale {
        (AppLanguage(rawValue: appLanguage) ?? .system).locale
    }

    var preferredColorScheme: ColorScheme? {
        switch AppAppearance(rawValue: appearance) ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func localized(_ key: String) -> String {
        let language = (AppLanguage(rawValue: appLanguage) ?? .system).effectiveLanguage
        guard language == .simplifiedChinese,
              let path = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key), locale: selectedLocale, arguments: arguments)
    }

    /// Localizes runtime messages that may include a service-provided detail.
    func localizedRuntimeMessage(_ message: String) -> String {
        let exact = localized(message)
        if exact != message { return exact }

        let templates = [
            "Docling installation failed: %@",
            "Docling update failed: %@",
            "Ollama installation failed: %@",
            "PaddleOCR update failed: %@",
            "PaddleOCR installation failed: %@",
            "FFmpeg installation failed: %@",
            "FFmpeg update failed: %@",
            "Whisper installation failed: %@",
            "Whisper model download failed: %@",
            "Could not start Ollama: %@",
            "The service started, but FileNest could not connect to %@.",
            "Model download failed: %@",
            "Could not delete model: %@",
            "Downloading the Whisper %@ model…",
            "FFmpeg %@ is ready",
            "OpenAI Whisper %@ is ready",
        ]
        for template in templates {
            let parts = template.components(separatedBy: "%@")
            guard parts.count == 2,
                  message.hasPrefix(parts[0]),
                  message.hasSuffix(parts[1]) else { continue }
            let detailStart = message.index(message.startIndex, offsetBy: parts[0].count)
            let detailEnd = message.index(message.endIndex, offsetBy: -parts[1].count)
            let detail = String(message[detailStart..<detailEnd])
            return localizedFormat(template, localizedRuntimeMessage(detail))
        }
        return message
    }
}

/// A shared entry point for the two manual organization scopes.
/// The picker action is deliberately one-time and never mutates watched folders.
struct OrganizeNowMenu<MenuLabel: View>: View {
    @EnvironmentObject private var appState: AppState
    @ViewBuilder private let label: () -> MenuLabel

    init(@ViewBuilder label: @escaping () -> MenuLabel) {
        self.label = label
    }

    var body: some View {
        Menu {
            Button {
                appState.organizeNewFilesInWatchedDirectories()
            } label: {
                Label("Organize New Files in Watched Folders", systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(appState.settings.watchDirs.isEmpty)

            Button {
                appState.chooseDirectoriesForOneTimeOrganization()
            } label: {
                Label("Choose Folders to Organize…", systemImage: "folder.badge.plus")
            }
        } label: {
            label()
        }
        .disabled(appState.indexingState.isActive || appState.organizationState.isActive)
    }
}

extension View {
    func fileNestEnvironment(_ settings: AppSettings) -> some View {
        environment(\.locale, settings.selectedLocale)
            .preferredColorScheme(settings.preferredColorScheme)
    }
}

enum FileNestEnvironment {
    private static func debugPreview(_ value: String) -> Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["FILENEST_PREVIEW"] == value
#else
        false
#endif
    }

    static var isUIPreview: Bool {
        debugPreview("main") ||
            debugPreview("library") ||
            debugPreview("indexing") ||
            debugPreview("search") ||
            debugPreview("file-chat") ||
            debugPreview("settings-models")
    }

    static var isLibraryPreview: Bool {
        debugPreview("library")
    }

    static var isIndexingPreview: Bool {
        debugPreview("indexing")
    }

    static var isSearchPreview: Bool {
        debugPreview("search")
    }

    static var isFileChatPreview: Bool {
        debugPreview("file-chat")
    }

    static var isMenuPreview: Bool {
        debugPreview("menu")
    }

    static var isRulePreview: Bool {
        debugPreview("rule")
    }

    static var isSettingsPreview: Bool {
        debugPreview("settings")
    }

    static var isStatisticsPreview: Bool {
        debugPreview("statistics")
    }

    static var isSettingsModelsPreview: Bool {
        debugPreview("settings-models")
    }

    static var isSettingsRulesPreview: Bool {
        debugPreview("settings-rules")
    }

    static var isAIRulePreview: Bool {
        debugPreview("ai-rule")
    }
}

struct BrandMark: View {
    var size: CGFloat = 36

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .accessibilityLabel("FileNest")
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(LocalizedStringKey(subtitle))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 24)
            trailing()
        }
        .padding(.horizontal, 28)
        .frame(height: 96)
        .background(FileNestTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FileNestTheme.border).frame(height: 1)
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct LocalModeMenu: View {
    @ObservedObject var settings: AppSettings

    private var label: String {
        if FileNestEnvironment.isUIPreview { return "Local Mode" }
        switch AppSettings.LLMChoice(rawValue: settings.llmChoice) ?? .ollama {
        case .ollama: return "Local Mode"
        case .cloud: return "Cloud Mode"
        case .none: return "Search Only"
        }
    }

    var body: some View {
        Menu {
            ForEach(AppSettings.LLMChoice.allCases) { choice in
                Button {
                    settings.setLLMChoice(choice.rawValue)
                } label: {
                    if settings.llmChoice == choice.rawValue {
                        Label(LocalizedStringKey(choice.label), systemImage: "checkmark")
                    } else {
                        Text(LocalizedStringKey(choice.label))
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(FileNestTheme.success)
                Text(LocalizedStringKey(label))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(FileNestTheme.strongBorder, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct IndexingActivitySymbol: View {
    let systemName: String
    let isAnimating: Bool
    var size: CGFloat = 13
    var weight: Font.Weight = .medium

    var body: some View {
        // Service progress does not need a 10 FPS redraw. A modest cadence keeps
        // the indicator responsive without continuously invalidating its host UI.
        TimelineView(.animation(minimumInterval: 0.5, paused: !isAnimating)) { timeline in
            Image(systemName: isAnimating ? "arrow.triangle.2.circlepath" : systemName)
                .font(.system(size: size, weight: weight))
                .rotationEffect(.degrees(rotation(at: timeline.date)))
        }
    }

    private func rotation(at date: Date) -> Double {
        guard isAnimating else { return 0 }
        return date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 1.15) / 1.15 * 360
    }
}

/// Shared AI activity indicator for operations that are waiting on analysis,
/// retrieval planning, or a language model rather than file-system indexing.
struct AIThinkingActivitySymbol: View {
    var isAnimating: Bool = true
    var size: CGFloat = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.35, paused: !isAnimating)) { timeline in
            let phase = pulsePhase(at: timeline.date)
            Image(systemName: "brain.head.profile")
                .font(.system(size: size, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(FileNestTheme.accent)
                .scaleEffect(1 + (0.08 * phase))
                .opacity(0.72 + (0.28 * phase))
        }
        .frame(width: size + 3, height: size + 3)
        .accessibilityLabel("Thinking")
    }

    private func pulsePhase(at date: Date) -> CGFloat {
        guard isAnimating else { return 0 }
        let elapsed = date.timeIntervalSinceReferenceDate
        return CGFloat((sin(elapsed * .pi * 2 / 1.2) + 1) / 2)
    }
}

struct IndexingButtonLabel: View {
    let defaultTitle: String
    @ObservedObject var appState: AppState

    var body: some View {
        Label {
            Text(appState.settings.localized(displayTitle))
        } icon: {
            IndexingActivitySymbol(
                systemName: symbolName,
                isAnimating: appState.indexingState.isAnimating
            )
        }
        .id("\(displayTitle)-\(appState.indexingState)")
    }

    private var displayTitle: String {
        if appState.reindexButtonsDisabled { return appState.indexingStatusTitle }
        if appState.indexingState == .stopped { return "Restart Indexing" }
        if appState.indexingState == .completedWithErrors { return "Retry Failed Files" }
        return defaultTitle
    }

    private var symbolName: String {
        switch appState.indexingState {
        case .paused: return "pause.circle.fill"
        case .stopping: return "stop.circle"
        case .stopped: return "stop.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .completedWithErrors: return "exclamationmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .idle, .running: return "arrow.triangle.2.circlepath"
        }
    }
}

struct IndexingStatusProgressView: View {
    @ObservedObject var appState: AppState
    var showsHeader = true
    var showsControls = true

    var body: some View {
        return VStack(alignment: .leading, spacing: 9) {
            if showsHeader {
                HStack(spacing: 9) {
                    IndexingActivitySymbol(
                        systemName: statusSymbol,
                        isAnimating: appState.indexingState.isAnimating,
                        size: 14,
                        weight: .semibold
                    )
                    .foregroundStyle(statusColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(appState.indexingStatusTitle))
                            .font(.system(size: 12, weight: .semibold))
                        Text(appState.indexingStatusSubtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }

            if let progress = appState.indexingProgress, progress.total > 0 {
                ProgressView(value: progress.fraction)
                    .tint(statusColor)
                if let fileName = progress.currentFileName,
                   appState.indexingState == .running {
                    Text(fileName)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if showsControls {
                IndexingTaskControls(appState: appState)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Index Status")
    }

    private var statusSymbol: String {
        switch appState.indexingState {
        case .paused: return "pause.circle.fill"
        case .stopping: return "stop.circle"
        case .stopped: return "stop.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .completedWithErrors: return "exclamationmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return appState.indexedCount > 0 ? "doc.text.magnifyingglass" : "magnifyingglass"
        case .running: return "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch appState.indexingState {
        case .failed: return FileNestTheme.warning
        case .completedWithErrors: return FileNestTheme.warning
        case .completed: return FileNestTheme.success
        case .paused, .stopped: return .secondary
        default: return FileNestTheme.accentBlue
        }
    }
}

/// Compact status for automatic watcher work. Manual reindexing retains its own controls above.
struct AutomaticProcessingQueueView: View {
    @ObservedObject var appState: AppState
    var maximumItems = 3
    var showsHeader = true
    var onDismiss: (() -> Void)?

    private var items: [AutomaticFileProcessingItem] {
        Array(appState.automaticFileProcessingItems.prefix(maximumItems))
    }

    var body: some View {
        guard !items.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                if showsHeader {
                    HStack(spacing: 7) {
                    Text(verbatim: appState.settings.localized(
                        appState.hasActiveAutomaticFileProcessing
                            ? appState.automaticProcessingStatusTitle
                            : "Recent file activity"
                    ))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    if appState.activeAutomaticFileProcessingItems.count > 1 {
                        Text("\(appState.activeAutomaticFileProcessingItems.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let onDismiss {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(LocalizedStringKey("Dismiss Processing Status"))
                        .accessibilityLabel(LocalizedStringKey("Dismiss Processing Status"))
                    }
                    }
                }

                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(verbatim: item.fileName == "File"
                                 ? appState.settings.localized("File")
                                 : item.fileName)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        Text(verbatim: localizedStatus(for: item))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let progress = item.progress, item.isAnimating {
                            ProgressView(value: progress)
                                .tint(color(for: item.stage))
                                .controlSize(.small)
                        }
                    }
                }
            }
        )
    }

    private func localizedStatus(for item: AutomaticFileProcessingItem) -> String {
        switch item.stage {
        case let .duplicate(originalFileName):
            return appState.settings.localizedFormat("Duplicate of %@", originalFileName)
        case let .indexing(.embedding(completed, total)):
            return appState.settings.localizedFormat(
                "Generating vectors %d/%d",
                completed,
                total
            )
        case .indexing:
            return appState.settings.localized(item.subtitle)
        case let .failed(message):
            return item.detail ?? appState.settings.localized(message)
        case .queued, .waitingForOrganization, .organizing, .completed:
            return appState.settings.localized(item.title)
        }
    }

    private func color(for stage: AutomaticFileProcessingStage) -> Color {
        switch stage {
        case .completed: return FileNestTheme.success
        case .failed: return FileNestTheme.warning
        case .duplicate: return FileNestTheme.warning
        case .queued, .waitingForOrganization: return .secondary
        case .indexing, .organizing: return FileNestTheme.accentBlue
        }
    }
}

/// Compact progress and queue preview for a user-initiated organization job.
/// It deliberately keeps the Library usable while a long-running batch is active.
struct ManualOrganizationQueueView: View {
    @ObservedObject var appState: AppState
    var maximumItems = 10
    var showsControls = true
    var showsActivitySymbol = true
    @State private var isUpcomingExpanded = false

    private var progress: OrganizationJobProgress? { appState.organizationProgress }
    private var upcomingFiles: [String] {
        Array((progress?.upcomingFileNames ?? []).prefix(maximumItems))
    }

    private var pendingFilesToggleHint: String {
        appState.settings.localized(
            isUpcomingExpanded ? "Hide Pending Files" : "Show 10 Pending Files"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if showsActivitySymbol {
                        IndexingActivitySymbol(
                            systemName: phaseIcon,
                            isAnimating: appState.organizationState.isAnimating,
                            size: 14,
                            weight: .semibold
                        )
                        .foregroundStyle(phaseColor)
                    }
                    Text(LocalizedStringKey(appState.organizationStatusTitle))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 0)
                    if let progress {
                        Text("\(progress.completed)/\(progress.total)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if showsControls { controls }
                }
                Text(appState.organizationStatusSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let progress {
                HStack(spacing: 8) {
                    ProgressView(value: progress.fractionCompleted)
                        .tint(phaseColor)
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            isUpcomingExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: isUpcomingExpanded ? "chevron.up" : "chevron.down")
                            .accessibilityLabel(Text(verbatim: pendingFilesToggleHint))
                    }
                    .buttonStyle(InlineActionButtonStyle())
                    .fixedSize()
                    .help(pendingFilesToggleHint)
                }
            }

            if isUpcomingExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Up Next")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if upcomingFiles.isEmpty {
                        Text("No pending files")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(upcomingFiles.enumerated()), id: \.offset) { _, fileName in
                            Label(fileName, systemImage: "doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Organization Queue")
    }

    @ViewBuilder
    private var controls: some View {
        switch appState.organizationState {
        case .running:
            HStack(spacing: 5) {
                Button(action: appState.pauseOrganization) {
                    Image(systemName: "pause.fill")
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.bordered)
                .help("Pause Organization")
                Button(role: .destructive, action: appState.stopOrganization) {
                    Image(systemName: "stop.fill")
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.bordered)
                .help("Stop Organization")
            }
            .controlSize(.small)
        case .paused:
            HStack(spacing: 5) {
                Button(action: appState.resumeOrganization) {
                    Image(systemName: "play.fill")
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(FileNestTheme.accentFill)
                .help("Resume Organization")
                Button(role: .destructive, action: appState.stopOrganization) {
                    Image(systemName: "stop.fill")
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.bordered)
                .help("Stop Organization")
            }
            .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private var phaseIcon: String {
        switch progress?.phase {
        case .waitingForStability: return "clock.arrow.circlepath"
        case .indexing: return "doc.text.magnifyingglass"
        case .organizing: return "tray.and.arrow.down"
        case .paused: return "pause.circle.fill"
        case .stopping, .stopped: return "stop.circle"
        case .failed: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var phaseColor: Color {
        switch appState.organizationState {
        case .failed: return FileNestTheme.warning
        case .completed: return FileNestTheme.success
        case .paused, .stopped: return .secondary
        default: return FileNestTheme.accentBlue
        }
    }
}

private struct IndexingTaskControls: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 7) {
            switch appState.indexingState {
            case .running:
                taskButton("Pause Indexing", icon: "pause.fill", action: appState.pauseIndexing)
                stopButton
            case .paused:
                taskButton("Resume Indexing", icon: "play.fill", action: appState.resumeIndexing)
                stopButton
            case .stopping:
                taskButton("Stopping…", icon: "stop.fill", action: {})
                    .disabled(true)
            case .completedWithErrors:
                taskButton("Retry Failed Files", icon: "arrow.clockwise", action: appState.restartIndexing)
            case .stopped, .failed, .completed:
                taskButton("Restart Indexing", icon: "arrow.clockwise", action: appState.restartIndexing)
            case .idle:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    private var stopButton: some View {
        taskButton("Stop Indexing", icon: "stop.fill", action: appState.stopIndexing)
    }

    private func taskButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(appState.settings.localized(title))
            } icon: {
                Image(systemName: icon)
            }
        }
        .buttonStyle(.bordered)
    }
}

struct GradientButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 14 : 18)
            .frame(height: compact ? 34 : 38)
            .background(FileNestTheme.primaryGradient.opacity(configuration.isPressed ? 0.82 : 1))
            .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous))
            .shadow(color: FileNestTheme.accentFill.opacity(configuration.isPressed ? 0.08 : 0.18), radius: 8, y: 3)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var compact = false
    var foreground = Color.primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? 32 : 36)
            .background(FileNestTheme.elevatedSurface.opacity(configuration.isPressed ? 0.62 : 0.86))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(FileNestTheme.strongBorder, lineWidth: 1)
            }
    }
}

struct InlineActionButtonStyle: ButtonStyle {
    var tint = FileNestTheme.accent
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        InlineActionButtonStyleBody(
            configuration: configuration,
            tint: tint,
            fillsWidth: fillsWidth
        )
    }
}

private struct InlineActionButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let fillsWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isEnabled ? tint : Color.secondary.opacity(0.46))
            .padding(.horizontal, 6)
            .frame(height: 24)
            .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
            .background(
                isHovered && isEnabled ? FileNestTheme.selection : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.68 : 1)
            .onHover { hovering in
                isHovered = hovering
                (hovering && isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

struct FileIconView: View {
    let file: FileRecord
    var size: CGFloat = 38

    private var presentation: FileIconPresentation {
        FileIconPresentation(fileExtension: file.ext)
    }

    private var image: NSImage {
        FileIconCache.shared.image(for: file)
    }

    var body: some View {
        Group {
            switch presentation {
            case let .semantic(symbol, tint, label):
                SemanticFileIcon(symbol: symbol, tint: tint, label: label, size: size)
            case .finder:
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// FileNest uses stable semantic artwork for ubiquitous work files, while retaining
/// Finder artwork and thumbnails for media and app-specific formats. This makes
/// common files recognisable even when a Mac has no default document handler,
/// without discarding useful previews for visual or proprietary file types.
private enum FileIconPresentation {
    case semantic(symbol: String, tint: Color, label: String?)
    case finder

    init(fileExtension: String) {
        let fileExtension = fileExtension.lowercased()

        switch fileExtension {
        case "pdf":
            self = .semantic(symbol: "doc.fill", tint: Self.pdfTint, label: "PDF")
        case "doc", "docx", "docm", "odt":
            self = .semantic(symbol: "doc.fill", tint: Self.documentTint, label: "DOC")
        case "xls", "xlsx", "xlsm", "ods", "csv":
            self = .semantic(symbol: "doc.fill", tint: Self.spreadsheetTint, label: "XLS")
        case "ppt", "pptx", "ppsx", "odp":
            self = .semantic(symbol: "doc.fill", tint: Self.presentationTint, label: "PPT")
        case "txt", "rtf":
            self = .semantic(symbol: "doc.fill", tint: Self.textTint, label: "TXT")
        case "md", "markdown":
            self = .semantic(symbol: "doc.fill", tint: Self.markdownTint, label: "MD")
        case "epub":
            self = .semantic(symbol: "book.closed.fill", tint: Self.bookTint, label: nil)
        case "xml":
            self = .semantic(symbol: "doc.fill", tint: Self.codeTint, label: "XML")
        case "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "go", "rs", "c", "cpp", "h", "hpp", "cs", "rb", "php", "sh", "sql", "json", "yaml", "yml", "html", "css", "vue", "lua", "r":
            self = .semantic(
                symbol: "doc.fill",
                tint: Self.codeTint,
                label: Self.codeLabel(for: fileExtension)
            )
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            self = .semantic(symbol: "archivebox.fill", tint: Self.archiveTint, label: nil)
        // Images, audio, video, iWork, disk images, and design files keep the
        // richer Finder icon or thumbnail that communicates their source app.
        case "png", "jpg", "jpeg", "gif", "heic", "tiff", "svg", "psd", "sketch", "webp",
             "mp4", "mov", "mkv", "avi", "m4v", "webm", "mpeg", "mpg",
             "mp3", "wav", "aac", "flac", "m4a", "ogg", "opus", "aiff", "aif", "wma",
             "pages", "numbers", "key", "keynote", "dmg", "iso":
            self = .finder
        default:
            self = .finder
        }
    }

    private static let pdfTint = Color(red: 0.86, green: 0.20, blue: 0.23)
    private static let documentTint = Color(red: 0.15, green: 0.40, blue: 0.84)
    private static let spreadsheetTint = Color(red: 0.10, green: 0.56, blue: 0.30)
    private static let presentationTint = Color(red: 0.88, green: 0.40, blue: 0.12)
    private static let textTint = Color(red: 0.40, green: 0.43, blue: 0.48)
    private static let markdownTint = Color(red: 0.43, green: 0.30, blue: 0.78)
    private static let bookTint = Color(red: 0.54, green: 0.35, blue: 0.16)
    private static let codeTint = Color(red: 0.33, green: 0.31, blue: 0.90)
    private static let archiveTint = Color(red: 0.72, green: 0.42, blue: 0.10)

    private static func codeLabel(for fileExtension: String) -> String {
        switch fileExtension {
        case "cpp": return "C++"
        case "hpp": return "H++"
        case "yaml": return "YAML"
        case "html": return "HTML"
        case "json": return "JSON"
        default: return fileExtension.uppercased()
        }
    }
}

private struct SemanticFileIcon: View {
    let symbol: String
    let tint: Color
    let label: String?
    let size: CGFloat

    private var labelSize: CGFloat {
        max(4.5, min(7.5, size * 0.19))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.92, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)

            if let label {
                Text(label)
                    .font(.system(size: labelSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.bottom, max(1, size * 0.08))
            }
        }
        .frame(width: size, height: size)
    }
}

/// Finder icon lookup crosses into AppKit and may touch the file system. List rows
/// are rebuilt often while filtering or selecting, so cache the immutable icon per
/// path/type rather than performing that work in every `body` evaluation.
private final class FileIconCache {
    static let shared = FileIconCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for file: FileRecord) -> NSImage {
        let key = "\(file.path)|\(file.ext)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image: NSImage
        if FileManager.default.fileExists(atPath: file.path) {
            image = NSWorkspace.shared.icon(forFile: file.path)
        } else {
            let contentType = UTType(filenameExtension: file.ext.isEmpty ? "txt" : file.ext) ?? .data
            image = NSWorkspace.shared.icon(for: contentType)
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct CircularAvatar: View {
    enum Kind { case user, assistant }
    let kind: Kind

    var body: some View {
        Group {
            if kind == .user {
                ZStack {
                    FileNestTheme.primaryGradient
                    Text("You")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
            } else {
                BrandMark(size: 34)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }
}

extension URL {
    var tildeAbbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

extension FileRecord {
    var displayPath: String {
        URL(fileURLWithPath: path).tildeAbbreviatedPath
    }

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

enum UIShowcaseData {
    static let files: [FileRecord] = [
        file("final_contract.docx", ext: "docx", size: 128_000, daysAgo: 2, folder: "Documents/Contracts"),
        file("final_contract_v2.docx", ext: "docx", size: 96_000, daysAgo: 4, folder: "Documents/Contracts/Archive"),
        file("final_contract.pdf", ext: "pdf", size: 203_000, daysAgo: 6, folder: "Documents/Contracts")
    ]

    static let menuFiles: [FileRecord] = [
        menuFile("final_contract.docx", ext: "docx", size: 128_000, daysAgo: 0, hour: 11, minute: 26, folder: "Documents/Contracts"),
        menuFile("product_requirements.pdf", ext: "pdf", size: 203_000, daysAgo: 0, hour: 11, minute: 8, folder: "Documents/Product"),
        menuFile("app_notes.md", ext: "md", size: 18_000, daysAgo: 0, hour: 9, minute: 42, folder: "Documents/Meeting Notes"),
        menuFile("Q3_budget.xlsx", ext: "xlsx", size: 76_000, daysAgo: 1, hour: 16, minute: 35, folder: "Documents/Finance")
    ]

    static let chatSessions: [ChatSession] = {
        let titles = [
            "Find last week's final contract",
            "Chat with the product requirements document",
            "Recently modified PDFs",
            "Organize quarterly budget files",
            "Find customer meeting notes",
            "Design drafts and assets",
            "Project archive materials",
            "Find invoices and expense claims",
            "Code snippets and technical documents",
            "Team weekly report summary",
            "Vendor contracts",
            "Product launch checklist",
            "User research materials",
            "Clean up old file versions",
            "Annual planning documents",
            "Marketing campaign assets",
            "Annual audit materials",
            "Candidate materials",
            "Competitive analysis reports",
            "Sales contract summary",
            "Image asset archive",
            "Launch event presentation",
            "Customer feedback records",
            "Engineering milestone documents",
            "Legal approval files",
            "Server operations manual",
            "Travel expense materials",
            "Brand visual guidelines",
            "Project retrospective notes",
            "Purchase order files"
        ]
        return titles.enumerated().map { index, title in
            ChatSession(
                id: -Int64(index + 1),
                title: title,
                createdAt: Calendar.current.date(byAdding: .day, value: -index, to: showcaseDate) ?? showcaseDate,
                updatedAt: Calendar.current.date(byAdding: .hour, value: -(index * 4), to: showcaseDate) ?? showcaseDate,
                attachedFilePath: index == 1 ? "~/Documents/product_requirements.pdf" : nil
            )
        }
    }()

    private static let showcaseDate = Calendar.current.date(
        from: DateComponents(year: 2026, month: 7, day: 14, hour: 11, minute: 26)
    ) ?? Date()

    static let messages: [ChatMessage] = {
        let user = ChatMessage(
            id: -101,
            role: ChatRole.user.rawValue,
            content: "Find the final contract I downloaded last week",
            ts: showcaseDate,
            relatedFileIds: nil
        )
        var assistant = ChatMessage(
            id: -102,
            role: ChatRole.assistant.rawValue,
            content: "I found these best-matching files:",
            ts: showcaseDate,
            relatedFileIds: nil
        )
        assistant.relatedFiles = files
        return [user, assistant]
    }()

    static let fileChatMessages: [ChatMessage] = [
        ChatMessage(
            id: -201,
            role: ChatRole.user.rawValue,
            content: "What is the renewal term and notice period?",
            ts: showcaseDate,
            relatedFileIds: nil
        ),
        ChatMessage(
            id: -202,
            role: ChatRole.assistant.rawValue,
            content: "The renewal term is 12 months. Either party may give 30 days’ written notice before renewal.",
            ts: showcaseDate,
            relatedFileIds: nil
        )
    ]

    private static func file(_ name: String, ext: String, size: Int64, daysAgo: Int, folder: String) -> FileRecord {
        let stableID = name.utf8.reduce(Int64(17)) { partial, byte in
            (partial * 31 + Int64(byte)) % 1_000_000_000
        }
        return FileRecord(
            id: -stableID,
            path: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("FileNest Demo Workspace")
                .appendingPathComponent(folder)
                .appendingPathComponent(name).path,
            name: name,
            ext: ext,
            size: size,
            mtime: Calendar.current.date(byAdding: .day, value: -daysAgo, to: showcaseDate) ?? showcaseDate,
            category: FileCategory.documents.rawValue,
            sourceDir: "~/FileNest Demo Workspace",
            indexedAt: showcaseDate,
            contentHash: nil,
            title: nil,
            contentText: nil
        )
    }

    private static func menuFile(
        _ name: String,
        ext: String,
        size: Int64,
        daysAgo: Int,
        hour: Int,
        minute: Int,
        folder: String
    ) -> FileRecord {
        var record = file(name, ext: ext, size: size, daysAgo: daysAgo, folder: folder)
        let shifted = Calendar.current.date(byAdding: .day, value: -daysAgo, to: showcaseDate) ?? showcaseDate
        record.mtime = Calendar.current.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: shifted
        ) ?? shifted
        return record
    }
}
