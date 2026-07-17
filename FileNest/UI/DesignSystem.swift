import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum FileNestTheme {
    static let accent = Color(red: 0.34, green: 0.31, blue: 0.96)
    static let accentBlue = Color(red: 0.24, green: 0.48, blue: 0.98)
    static let selection = Color(red: 0.45, green: 0.43, blue: 0.94).opacity(0.13)
    static let success = Color(red: 0.10, green: 0.67, blue: 0.29)
    static let warning = Color(red: 0.83, green: 0.55, blue: 0.08)
    static let warningSurface = Color.yellow.opacity(0.12)
    static let surface = Color(nsColor: .windowBackgroundColor)
    static let secondarySurface = Color(nsColor: .controlBackgroundColor)
    static let elevatedSurface = Color(nsColor: .textBackgroundColor)
    static let border = Color.primary.opacity(0.10)
    static let strongBorder = Color.primary.opacity(0.16)
    static let primaryGradient = LinearGradient(
        colors: [accentBlue, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// SwiftUI does not expose AppKit's overlay scroller controls. This bridge applies
/// a compact, low-contrast overlay style to every scroller in its containing window.
private struct FileNestOverlayScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureEnclosingScrollView(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configureEnclosingScrollView(from: nsView)
    }

    private func configureEnclosingScrollView(from view: NSView) {
        let applyStyle = { [weak view] in
            guard let view else { return }
            if let contentView = view.window?.contentView {
                configureScrollViews(in: contentView)
                return
            }

            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? NSScrollView {
                    configure(scrollView)
                    return
                }
                ancestor = current.superview
            }
        }

        // SwiftUI often creates an NSScrollView after its surrounding view hierarchy.
        // Reapplying after layout covers lazy panels such as the file preview inspector.
        DispatchQueue.main.async(execute: applyStyle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: applyStyle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: applyStyle)
    }

    private func configureScrollViews(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            configure(scrollView)
        }
        view.subviews.forEach(configureScrollViews(in:))
    }

    private func configure(_ scrollView: NSScrollView) {
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.controlSize = .mini
        scrollView.horizontalScroller?.controlSize = .mini
        // The reduced alpha prevents the overlay thumb from competing with content.
        scrollView.verticalScroller?.alphaValue = 0.42
        scrollView.horizontalScroller?.alphaValue = 0.42
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
            "Could not start Ollama: %@",
            "The service started, but FileNest could not connect to %@.",
            "Model download failed: %@",
            "Could not delete model: %@",
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
        debugPreview("main")
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
        TimelineView(.animation(minimumInterval: 0.1, paused: !isAnimating)) { timeline in
            Image(systemName: systemName)
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
        return defaultTitle
    }

    private var symbolName: String {
        switch appState.indexingState {
        case .paused: return "pause.circle.fill"
        case .stopping: return "stop.circle"
        case .stopped: return "stop.circle.fill"
        case .completed: return "checkmark.circle.fill"
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
        VStack(alignment: .leading, spacing: 9) {
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
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return appState.indexedCount > 0 ? "doc.text.magnifyingglass" : "magnifyingglass"
        case .running: return "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch appState.indexingState {
        case .failed: return FileNestTheme.warning
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

    private var items: [AutomaticFileProcessingItem] {
        Array(appState.automaticFileProcessingItems.prefix(maximumItems))
    }

    var body: some View {
        guard !items.isEmpty else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: appState.hasActiveAutomaticFileProcessing ? "tray.full.fill" : "checkmark.circle.fill")
                        .foregroundStyle(appState.hasActiveAutomaticFileProcessing ? FileNestTheme.accentBlue : FileNestTheme.success)
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
                }

                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            IndexingActivitySymbol(
                                systemName: symbol(for: item.stage),
                                isAnimating: item.isActive,
                                size: 11,
                                weight: .medium
                            )
                            .foregroundStyle(color(for: item.stage))
                            Text(item.fileName)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        Text(verbatim: localizedStatus(for: item))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let progress = item.progress, item.isActive {
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

    private func symbol(for stage: AutomaticFileProcessingStage) -> String {
        switch stage {
        case .queued: return "clock"
        case .indexing: return "doc.text.magnifyingglass"
        case .waitingForOrganization: return "tray.and.arrow.down"
        case .organizing: return "folder.badge.gearshape"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for stage: AutomaticFileProcessingStage) -> Color {
        switch stage {
        case .completed: return FileNestTheme.success
        case .failed: return FileNestTheme.warning
        case .queued, .waitingForOrganization: return .secondary
        case .indexing, .organizing: return FileNestTheme.accentBlue
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
            .shadow(color: FileNestTheme.accent.opacity(configuration.isPressed ? 0.08 : 0.18), radius: 8, y: 3)
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

struct FileIconView: View {
    let file: FileRecord
    var size: CGFloat = 38

    private var image: NSImage {
        if FileManager.default.fileExists(atPath: file.path) {
            return NSWorkspace.shared.icon(forFile: file.path)
        }
        let contentType = UTType(filenameExtension: file.ext.isEmpty ? "txt" : file.ext) ?? .data
        return NSWorkspace.shared.icon(for: contentType)
    }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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

    private static func file(_ name: String, ext: String, size: Int64, daysAgo: Int, folder: String) -> FileRecord {
        let stableID = name.utf8.reduce(Int64(17)) { partial, byte in
            (partial * 31 + Int64(byte)) % 1_000_000_000
        }
        return FileRecord(
            id: -stableID,
            path: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("FileNestOrganized")
                .appendingPathComponent(folder)
                .appendingPathComponent(name).path,
            name: name,
            ext: ext,
            size: size,
            mtime: Calendar.current.date(byAdding: .day, value: -daysAgo, to: showcaseDate) ?? showcaseDate,
            category: FileCategory.documents.rawValue,
            sourceDir: "~/Downloads",
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
