import AppKit
import SwiftUI

struct OnboardingView: View {
    private enum Step: Hashable {
        case welcome
        case basics
        case localRuntime
        case localModels
        case cloudAPI
        case mediaRuntime
        case finish

        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .basics: return "Basic Setup"
            case .localRuntime: return "Local Components"
            case .localModels: return "Model Downloads"
            case .cloudAPI: return "Cloud API"
            case .mediaRuntime: return "Audio & Video"
            case .finish: return "Get Started"
            }
        }

        var icon: String {
            switch self {
            case .welcome: return "sparkles"
            case .basics: return "slider.horizontal.3"
            case .localRuntime: return "shippingbox"
            case .localModels: return "square.stack.3d.up"
            case .cloudAPI: return "cloud"
            case .mediaRuntime: return "waveform"
            case .finish: return "checkmark.circle"
            }
        }
    }

    private enum CloudService: String, CaseIterable, Identifiable {
        case chat
        case embedding
        case ocr

        var id: String { rawValue }
        var label: String {
            switch self {
            case .chat: return "Chat Model"
            case .embedding: return "Embedding"
            case .ocr: return "OCR"
            }
        }
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var currentStep: Step = .welcome
    @State private var cloudService: CloudService = .chat
    @State private var isDownloadingAll = false
    @State private var batchTotalBytes: Int64 = 0
    @State private var batchCompletedBytes: Int64 = 0
    @State private var watchDirectoryInventories: [WatchDirectoryInventory] = []
    @State private var organizeExistingFiles = false
    @State private var selectedGenerationModel = OllamaModelRecommendation.defaultGenerationModel
    @State private var selectedEmbeddingModel = OllamaModelRecommendation.defaultEmbeddingModel

    private var usesCloud: Bool {
        appState.settings.llmChoice == AppSettings.LLMChoice.cloud.rawValue
    }

    private var steps: [Step] {
        var result: [Step] = usesCloud
            ? [.welcome, .basics, .cloudAPI]
            : [.welcome, .basics, .localRuntime, .localModels]
        if appState.settings.mediaTranscriptionEnabled { result.append(.mediaRuntime) }
        result.append(.finish)
        return result
    }

    private var currentIndex: Int {
        steps.firstIndex(of: currentStep) ?? 0
    }

    private var recommendation: OllamaModelProfile {
        OllamaModelRecommendation.recommendedForCurrentDevice
    }

    private var requiredModels: [(role: String, model: String, icon: String)] {
        [
            ("Generation", selectedGenerationModel, "sparkles"),
            ("Embedding Model", selectedEmbeddingModel,
             "point.3.connected.trianglepath.dotted"),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                stepRail
                    .frame(width: 190)
                Divider()
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            navigation
        }
        .frame(width: 920, height: 700)
        .background(FileNestTheme.surface)
        .task {
            prepareFirstRunDefaultsIfNeeded()
            if appState.settings.llmChoice == AppSettings.LLMChoice.none.rawValue {
                configureAIMode(.ollama)
            }
            async let ollamaRefresh: Void = appState.ollama.refresh(host: appState.settings.ollamaHost)
            async let paddleRefresh: Void = appState.paddleOCR.refresh()
            appState.docling.refresh()
            appState.ffmpeg.refresh()
            appState.whisper.refresh()
            _ = await (ollamaRefresh, paddleRefresh)
        }
        .onChange(of: appState.settings.watchDirs) { _ in
            if currentStep == .finish { refreshWatchDirectoryInventories() }
        }
        .onChange(of: selectedGenerationModel) { model in
            appState.settings.setOllamaModel(model)
        }
        .onChange(of: selectedEmbeddingModel) { model in
            appState.settings.setOllamaEmbeddingModel(model)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, currentStep == .finish {
                refreshWatchDirectoryInventories()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            BrandMark(size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("FileNest Setup")
                    .font(.system(size: 18, weight: .semibold))
                Text("Set up file watching and AI in a few minutes")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 7) {
                Text(appState.settings.localizedFormat(
                    "Step %d of %d",
                    currentIndex + 1,
                    steps.count
                ))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(currentIndex + 1), total: Double(steps.count))
                    .progressViewStyle(.linear)
                    .tint(FileNestTheme.accent)
                    .frame(width: 130)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 76)
    }

    private var stepRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Setup Progress")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 8)

            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                HStack(spacing: 11) {
                    ZStack {
                        Circle()
                            .fill(railCircleColor(index: index, step: step))
                        if index < currentIndex {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: step.icon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(step == currentStep ? .white : .secondary)
                        }
                    }
                    .frame(width: 26, height: 26)

                    Text(LocalizedStringKey(step.title))
                        .font(.system(size: 12, weight: step == currentStep ? .semibold : .regular))
                        .foregroundStyle(step == currentStep ? Color.primary : .secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(
                    step == currentStep ? FileNestTheme.selection : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
            }

            Spacer()

            VStack(alignment: .leading, spacing: 7) {
                Label("Settings save automatically", systemImage: "checkmark.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(FileNestTheme.success)
                Text("You can change these later in Settings.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 24)
        .padding(.bottom, 20)
        .background(FileNestTheme.secondarySurface.opacity(0.55))
    }

    private var stepContent: some View {
        ScrollView {
            Group {
                switch currentStep {
                case .welcome: welcomeStep
                case .basics: basicSettingsStep
                case .localRuntime: localRuntimeStep
                case .localModels: localModelsStep
                case .cloudAPI: cloudAPIStep
                case .mediaRuntime: mediaRuntimeStep
                case .finish: finishStep
                }
            }
            .frame(maxWidth: 650, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 28) {
            Spacer(minLength: 28)
            ZStack {
                RoundedRectangle(cornerRadius: 15)
                    .fill(FileNestTheme.selection)
                    .frame(width: 88, height: 88)
                BrandMark(size: 58)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Automate file organization and retrieval")
                    .font(.system(size: 26, weight: .semibold))
                Text("Choose which folders to watch and whether to use local models or cloud APIs. FileNest will prepare only what is needed.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            OnboardingSection {
                VStack(spacing: 0) {
                    WelcomeFeatureRow(icon: "folder.badge.gearshape", title: "Watch & Organize",
                                      detail: "Desktop and Downloads are watched by default, and you can add more folders.")
                    Divider().padding(.leading, 42)
                    WelcomeFeatureRow(icon: "brain.head.profile", title: "Choose How AI Runs",
                                      detail: "Local mode keeps data private; cloud mode avoids large model downloads.")
                    Divider().padding(.leading, 42)
                    WelcomeFeatureRow(icon: "doc.text.magnifyingglass", title: "Document Parsing & Vector Search",
                                      detail: "Understand different file types with Docling, embeddings, and OCR.")
                }
            }
            Label("About 2–5 minutes; model downloads depend on network speed", systemImage: "clock")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer(minLength: 20)
        }
    }

    private var basicSettingsStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            OnboardingStepHeader(
                title: "Basic Setup",
                subtitle: "Configure appearance, watched folders, and how AI runs.",
                icon: "slider.horizontal.3"
            )

            OnboardingSection(title: "Interface Preferences") {
                VStack(spacing: 0) {
                    OnboardingFormRow(label: "Language") {
                        Picker("", selection: Binding(
                            get: { appState.settings.appLanguage },
                            set: { appState.settings.setAppLanguage($0) }
                        )) {
                            ForEach(AppSettings.AppLanguage.allCases) { language in
                                Text(LocalizedStringKey(language.label)).tag(language.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 250)
                    }
                    Divider().padding(.leading, 132)
                    OnboardingFormRow(label: "Appearance") {
                        Picker("", selection: Binding(
                            get: { appState.settings.appearance },
                            set: { appState.settings.setAppearance($0) }
                        )) {
                            ForEach(AppSettings.AppAppearance.allCases) { appearance in
                                Text(LocalizedStringKey(appearance.label)).tag(appearance.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 250)
                    }
                }
            }

            OnboardingSection(title: "AI Mode") {
                HStack(spacing: 10) {
                    AIModeChoice(
                        title: "Local Ollama",
                        detail: "Data stays on this Mac; models are required",
                        icon: "cpu",
                        selected: !usesCloud
                    ) { configureAIMode(.ollama) }
                    AIModeChoice(
                        title: "Cloud API",
                        detail: "No model download; API keys are required",
                        icon: "cloud",
                        selected: usesCloud
                    ) { configureAIMode(.cloud) }
                }
                .padding(12)
            }

            OnboardingSection(title: "Audio & Video") {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(FileNestTheme.accent)
                        .frame(width: 38, height: 38)
                        .background(FileNestTheme.accent.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Transcribe audio and video for search and chat")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Adds an FFmpeg and OpenAI Whisper setup step, then indexes time-coded transcripts for RAG.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { appState.settings.mediaTranscriptionEnabled },
                        set: { appState.settings.setMediaTranscriptionEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 62)
            }

            OnboardingSection(title: "Watched Folders") {
                VStack(spacing: 0) {
                    if appState.settings.watchDirs.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.questionmark")
                                .foregroundStyle(.secondary)
                            Text("No watched folders added")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                    } else {
                        ForEach(Array(appState.settings.watchDirs.enumerated()), id: \.element) { index, path in
                            let inventory = appState.watchDirectoryInventories(for: [path]).first
                            WatchDirectoryRow(
                                path: path,
                                accessState: inventory?.accessState ?? .unavailable,
                                reauthorize: { appState.openWatchDirectoryPrivacySettings() },
                                remove: { removeWatchDirectory(path) }
                            )
                            if index < appState.settings.watchDirs.count - 1 {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Button {
                            chooseWatchDirectories()
                        } label: {
                            Label("Add Folder…", systemImage: "plus")
                        }
                        .buttonStyle(InlineActionButtonStyle())

                        Spacer()

                        Button("Restore Default Folders") { restoreDefaultWatchDirectories() }
                            .buttonStyle(InlineActionButtonStyle(tint: .secondary))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                }
            }
        }
    }

    private var localRuntimeStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            OnboardingStepHeader(
                title: "Install Local Components",
                subtitle: "Ollama runs local AI, while Docling is preferred for document parsing.",
                icon: "shippingbox"
            )

            OnboardingSection {
                VStack(spacing: 0) {
                    DependencyRow(
                        title: "Ollama",
                        detail: ollamaDetail,
                        icon: "cpu",
                        ready: appState.ollama.state == .running,
                        busy: appState.ollama.isInstalling || appState.ollama.state == .starting,
                        progress: appState.ollama.installProgress,
                        buttonTitle: appState.ollama.executablePath == nil ? "Install & Start Automatically" : "Start Service"
                    ) { Task { await ensureOllamaRunning() } }
                    Divider().padding(.leading, 70)
                    DependencyRow(
                        title: "Docling",
                        detail: doclingDetail,
                        icon: "doc.text.magnifyingglass",
                        ready: doclingReady,
                        busy: appState.docling.isInstalling,
                        progress: appState.docling.installProgress,
                        buttonTitle: "Install Docling"
                    ) { Task { await appState.docling.install() } }
                    Divider().padding(.leading, 70)
                    DependencyRow(
                        title: "PaddleOCR",
                        detail: paddleOCRDetail,
                        icon: "text.viewfinder",
                        ready: paddleOCRReady,
                        busy: appState.paddleOCR.isInstalling,
                        progress: appState.paddleOCR.installProgress,
                        buttonTitle: "Install PaddleOCR"
                    ) { Task { await appState.paddleOCR.install() } }
                }
            }

            OnboardingNotice(
                icon: "lock.shield",
                text: "Components are installed in an isolated FileNest user environment without changing system Python or requiring administrator access.",
                color: FileNestTheme.success
            )
        }
    }

    private var mediaRuntimeStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            OnboardingStepHeader(
                title: "Set Up Audio & Video Transcription",
                subtitle: "Install the local decoder and OpenAI Whisper model used to turn media into searchable transcripts.",
                icon: "waveform"
            )

            SystemResourceStrip(
                memory: SystemProfile.memoryLabel,
                disk: SystemProfile.availableDiskLabel,
                architecture: SystemProfile.architectureLabel
            )

            OnboardingSection(title: "Local Components") {
                VStack(spacing: 0) {
                    DependencyRow(
                        title: "FFmpeg",
                        detail: ffmpegDetail,
                        icon: "film.stack",
                        ready: appState.ffmpeg.executablePath != nil,
                        busy: appState.ffmpeg.isInstalling,
                        progress: appState.ffmpeg.installProgress,
                        buttonTitle: "Install FFmpeg"
                    ) { Task { await appState.ffmpeg.install() } }
                    Divider().padding(.leading, 70)
                    DependencyRow(
                        title: "OpenAI Whisper",
                        detail: whisperRuntimeDetail,
                        icon: "waveform.badge.mic",
                        ready: appState.whisper.installedVersion != nil,
                        busy: appState.whisper.isInstalling && appState.whisper.installingModel == nil,
                        progress: appState.whisper.installProgress,
                        buttonTitle: "Install Whisper"
                    ) { Task { await appState.whisper.installRuntime() } }
                }
            }

            OnboardingSection(title: "Transcription Model") {
                VStack(spacing: 0) {
                    OnboardingFormRow(label: "Model") {
                        Picker("", selection: Binding(
                            get: { appState.settings.whisperModel },
                            set: { appState.settings.setWhisperModel($0) }
                        )) {
                            ForEach(WhisperModelCatalog.models) { model in
                                Text("\(model.id) · \(model.parameters) · \(model.approximateSize)")
                                    .tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 310)
                    }
                    Divider().padding(.leading, 132)
                    let selected = WhisperModelCatalog.option(appState.settings.whisperModel)
                    DependencyRow(
                        title: "Whisper Model",
                        detail: "\(selected.id) · \(selected.parameters) · \(selected.approximateSize) · \(appState.settings.localized(selected.detail))",
                        icon: "arrow.down.circle",
                        ready: appState.whisper.isModelInstalled(selected.id),
                        busy: appState.whisper.installingModel == selected.id,
                        progress: appState.whisper.installProgress,
                        buttonTitle: "Download Model"
                    ) { Task { await appState.whisper.downloadModel(selected.id) } }
                }
            }

            OnboardingNotice(
                icon: "lock.shield",
                text: "Media decoding and transcription run locally. Only the resulting text chunks follow your configured Embedding provider.",
                color: FileNestTheme.success
            )
        }
    }

    private var localModelsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            OnboardingStepHeader(
                title: "Download Local Models",
                subtitle: "Choose the generation and embedding models FileNest downloads; Qwen 9B and 0.6B are selected by default.",
                icon: "square.stack.3d.up"
            )

            SystemResourceStrip(
                memory: SystemProfile.memoryLabel,
                disk: SystemProfile.availableDiskLabel,
                architecture: SystemProfile.architectureLabel
            )

            OnboardingSection(title: "Required Models") {
                VStack(spacing: 0) {
                    modelPickerRow(
                        title: "Generation",
                        selection: $selectedGenerationModel,
                        models: OllamaModelRecommendation.generationModels
                    )
                    Divider().padding(.leading, 58)
                    modelPickerRow(
                        title: "Embedding Model",
                        selection: $selectedEmbeddingModel,
                        models: OllamaModelRecommendation.embeddingModels
                    )
                    Divider().padding(.leading, 58)
                    ForEach(Array(requiredModels.enumerated()), id: \.element.model) { index, item in
                        modelRow(role: item.role, model: item.model, icon: item.icon)
                        if index < requiredModels.count - 1 {
                            Divider().padding(.leading, 58)
                        }
                    }
                }
            }

            HStack {
                Label(appState.settings.localizedFormat(
                    "Estimated remaining download: %@",
                    ByteCountFormatter.string(fromByteCount: remainingDownloadBytes, countStyle: .file)
                ), systemImage: "internaldrive")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(hasEnoughDiskSpace ? Color.secondary : FileNestTheme.warning)
                Spacer()
                Text(appState.settings.localizedFormat("%@ available", SystemProfile.availableDiskLabel))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if !hasEnoughDiskSpace {
                OnboardingNotice(
                    icon: "exclamationmark.triangle",
                    text: "Not enough free disk space. Free some space or use a cloud API.",
                    color: FileNestTheme.warning
                )
            }

            if let error = appState.ollama.lastError {
                OnboardingNotice(
                    icon: "exclamationmark.triangle",
                    text: appState.settings.localized(error),
                    color: FileNestTheme.warning
                )
            }

            if isDownloadingAll {
                batchProgressPanel
            }

            Button {
                Task { await downloadAllModels() }
            } label: {
                if isDownloadingAll {
                    HStack(spacing: 8) {
                        if batchTotalBytes > 0 {
                            ProgressView(value: batchDownloadProgress)
                                .frame(width: 84)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text("Preparing required models…")
                    }
                } else {
                    Label("Download All Required Models", systemImage: "arrow.down.circle.fill")
                }
            }
            .buttonStyle(GradientButtonStyle())
            .disabled(isDownloadingAll || appState.ollama.pullingModel != nil || !hasEnoughDiskSpace)
        }
    }

    private var cloudAPIStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            OnboardingStepHeader(
                title: "Configure Cloud APIs",
                subtitle: "Configure chat, embedding, and OCR services separately. You can change them later in Settings.",
                icon: "cloud"
            )

            Picker("Cloud Service", selection: $cloudService) {
                ForEach(CloudService.allCases) { service in
                    Text(LocalizedStringKey(service.label)).tag(service)
                }
            }
            .pickerStyle(.segmented)

            OnboardingSection(title: cloudSectionTitle) {
                cloudForm
            }

            if currentCloudAPIKey.isEmpty {
                OnboardingNotice(
                    icon: "key",
                    text: "The API key is empty. You can set it later, but the related AI feature will remain unavailable.",
                    color: FileNestTheme.warning
                )
            }

            OnboardingNotice(
                icon: "hand.raised",
                text: "When using cloud services, relevant prompts, document chunks, or images are sent to the configured API. The index database remains on this Mac.",
                color: FileNestTheme.accentBlue
            )
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            OnboardingStepHeader(
                title: "Ready to Start",
                subtitle: "Review the watched folders and decide whether to organize files already in them.",
                icon: "checkmark.circle"
            )

            OnboardingSection(title: "Watched Folders") {
                VStack(spacing: 0) {
                    if watchDirectoryInventories.isEmpty {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.questionmark")
                                .foregroundStyle(.secondary)
                            Text("No watched folders added")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 52)
                    } else {
                        ForEach(Array(watchDirectoryInventories.enumerated()), id: \.element.id) { index, inventory in
                            HStack(spacing: 11) {
                                Image(systemName: inventory.isAccessible ? "folder.fill" : "folder.badge.questionmark")
                                    .foregroundStyle(inventory.isAccessible ? FileNestTheme.accent : FileNestTheme.warning)
                                    .frame(width: 22)
                                Text(URL(fileURLWithPath: inventory.path).tildeAbbreviatedPath)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if inventory.isAccessible {
                                    Text(appState.settings.localizedFormat(
                                        "%d files · %d folders",
                                        inventory.fileCount,
                                        inventory.directoryCount
                                    ))
                                } else {
                                    Text(LocalizedStringKey(accessStateLabel(inventory.accessState)))
                                        .foregroundStyle(FileNestTheme.warning)
                                    Button("Restore Access…") {
                                        appState.openWatchDirectoryPrivacySettings()
                                    }
                                    .controlSize(.small)
                                    Button {
                                        refreshWatchDirectoryInventories()
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Check Again")
                                }
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .frame(height: 52)
                            if index < watchDirectoryInventories.count - 1 {
                                Divider().padding(.leading, 47)
                            }
                        }
                    }
                }
            }

            OnboardingSection(title: "Existing Files") {
                VStack(spacing: 0) {
                    finishChoice(
                        title: "Keep Existing Files, Process New Files Only",
                        detail: "Existing files will not be indexed or moved. Files added after setup will be processed automatically.",
                        icon: "arrow.right.circle",
                        selected: !organizeExistingFiles
                    ) {
                        organizeExistingFiles = false
                    }
                    Divider().padding(.leading, 58)
                    finishChoice(
                        title: "Organize Existing Files Now",
                        detail: appState.settings.localizedFormat(
                            "Process the current %d items and organize them using your rules.",
                            watchDirectoryInventories.reduce(0) { $0 + $1.itemCount }
                        ),
                        icon: "wand.and.stars",
                        selected: organizeExistingFiles
                    ) {
                        organizeExistingFiles = true
                    }
                }
            }

            OnboardingNotice(
                icon: organizeExistingFiles ? "exclamationmark.triangle" : "checkmark.shield",
                text: organizeExistingFiles
                    ? "Organizing now indexes existing files and may move them according to your organization rules."
                    : "This choice is saved. You can process these files later in Settings → Index & Organize.",
                color: organizeExistingFiles ? FileNestTheme.warning : FileNestTheme.success
            )
        }
        .onAppear(perform: refreshWatchDirectoryInventories)
    }

    private func finishChoice(
        title: String,
        detail: String,
        icon: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? FileNestTheme.accent : .secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        (selected ? FileNestTheme.accent : Color.secondary).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(LocalizedStringKey(detail))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? FileNestTheme.accent : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cloudForm: some View {
        switch cloudService {
        case .chat:
            VStack(spacing: 0) {
                cloudFormatRow(
                    value: appState.settings.cloudAPIFormat,
                    setter: appState.settings.setCloudAPIFormat
                )
                Divider().padding(.leading, 132)
                cloudTextRow(label: "Base URL", value: appState.settings.cloudBaseURL,
                             setter: appState.settings.setCloudBaseURL)
                Divider().padding(.leading, 132)
                cloudSecureRow(label: "API Key", value: appState.settings.cloudAPIKey,
                               setter: appState.settings.setCloudKey)
                Divider().padding(.leading, 132)
                cloudTextRow(label: "Model", value: appState.settings.cloudModel,
                             setter: appState.settings.setCloudModel)
            }
        case .embedding:
            VStack(spacing: 0) {
                cloudTextRow(
                    label: "API Format",
                    value: appState.settings.localized("OpenAI-compatible /embeddings"),
                    setter: nil
                )
                Divider().padding(.leading, 132)
                cloudTextRow(label: "Base URL", value: appState.settings.cloudEmbeddingBaseURL,
                             setter: appState.settings.setCloudEmbeddingBaseURL)
                Divider().padding(.leading, 132)
                cloudSecureRow(label: "API Key", value: appState.settings.cloudEmbeddingAPIKey,
                               setter: appState.settings.setCloudEmbeddingAPIKey)
                Divider().padding(.leading, 132)
                cloudTextRow(label: "Model", value: appState.settings.cloudEmbeddingModel,
                             setter: appState.settings.setCloudEmbeddingModel)
            }
        case .ocr:
            VStack(spacing: 0) {
                cloudFormatRow(
                    value: appState.settings.cloudOCRFormat,
                    setter: appState.settings.setCloudOCRFormat
                )
                Divider().padding(.leading, 132)
                cloudTextRow(label: "Base URL", value: appState.settings.cloudOCRBaseURL,
                             setter: appState.settings.setCloudOCRBaseURL)
                Divider().padding(.leading, 132)
                cloudSecureRow(label: "API Key", value: appState.settings.cloudOCRAPIKey,
                               setter: appState.settings.setCloudOCRAPIKey)
                Divider().padding(.leading, 132)
                cloudTextRow(label: "Model", value: appState.settings.cloudOCRModel,
                             setter: appState.settings.setCloudOCRModel)
            }
        }
    }

    private var navigation: some View {
        HStack {
            Button("Set Up Later") { finishOnboarding(organizeExisting: false) }
                .buttonStyle(InlineActionButtonStyle(tint: .secondary))
            Spacer()
            if currentIndex > 0 {
                Button("Back") { navigate(to: steps[currentIndex - 1]) }
                    .buttonStyle(QuietButtonStyle(compact: true))
            }
            if currentIndex < steps.count - 1 {
                Button("Continue") { navigate(to: steps[currentIndex + 1]) }
                    .buttonStyle(GradientButtonStyle(compact: true))
            } else {
                Button("Finish Setup") {
                    finishOnboarding(organizeExisting: organizeExistingFiles)
                }
                    .buttonStyle(GradientButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 66)
    }

    private func railCircleColor(index: Int, step: Step) -> Color {
        if index < currentIndex || step == currentStep { return FileNestTheme.accent }
        return FileNestTheme.border
    }

    private func navigate(to step: Step) {
        if step == .finish { refreshWatchDirectoryInventories() }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            currentStep = step
        } else {
            withAnimation(.easeOut(duration: 0.18)) { currentStep = step }
        }
    }

    private func finishOnboarding(organizeExisting: Bool) {
        appState.completeOnboarding(organizeExistingFiles: organizeExisting)
        dismiss()
    }

    private func refreshWatchDirectoryInventories() {
        watchDirectoryInventories = appState.watchDirectoryInventories()
    }

    private func accessStateLabel(_ state: WatchDirectoryAccessState) -> String {
        switch state {
        case .accessible: return "Accessible"
        case .permissionDenied: return "Access Denied"
        case .missing: return "Folder Missing"
        case .unavailable: return "Temporarily Unavailable"
        }
    }

    private func configureAIMode(_ choice: AppSettings.LLMChoice) {
        appState.settings.setLLMChoice(choice.rawValue)
        switch choice {
        case .ollama:
            appState.settings.setEmbeddingSource(AppSettings.EmbeddingSource.ollama.rawValue)
            appState.settings.setOCRSource(AppSettings.OCRSource.local.rawValue)
            applySelectedModels()
        case .cloud:
            appState.settings.setEmbeddingSource(AppSettings.EmbeddingSource.cloud.rawValue)
            appState.settings.setOCRSource(AppSettings.OCRSource.cloud.rawValue)
        case .none:
            break
        }
    }

    private func prepareFirstRunDefaultsIfNeeded() {
        guard !appState.settings.onboardingCompleted else { return }
        let defaults = AppSettings.defaultWatchDirectories()
        let current = Set(appState.settings.watchDirs.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        if current.isEmpty || current.isSubset(of: Set(defaults)) {
            appState.settings.setWatchDirs(defaults)
        }
        if !usesCloud {
            configureAIMode(.ollama)
        }
    }

    private func chooseWatchDirectories() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = appState.settings.localized("Add")
        guard panel.runModal() == .OK else { return }
        updateWatchDirectories(appState.settings.watchDirs + panel.urls.map(\.path))
    }

    private func removeWatchDirectory(_ path: String) {
        updateWatchDirectories(appState.settings.watchDirs.filter { $0 != path })
    }

    private func restoreDefaultWatchDirectories() {
        updateWatchDirectories(AppSettings.defaultWatchDirectories())
    }

    private func updateWatchDirectories(_ paths: [String]) {
        var seen = Set<String>()
        let normalized = paths.compactMap { path -> String? in
            let value = URL(fileURLWithPath: path).standardizedFileURL.path
            return seen.insert(value).inserted ? value : nil
        }
        let previous = Set(appState.settings.watchDirs.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        let next = Set(normalized)
        let added = Array(next.subtracting(previous))
        let removed = Array(previous.subtracting(next))
        // Keep files in place as the safe default until the wizard's final choice, preventing the running watcher from processing them early.
        appState.preserveExistingWatchDirectoryEntries(in: added)
        appState.clearPreservedWatchDirectoryEntries(in: removed)
        appState.settings.setWatchDirs(normalized)
        if appState.isWatching {
            appState.stopWatching()
            appState.startWatching()
        }
    }

    private var ollamaDetail: String {
        if appState.ollama.isInstalling { return appState.ollama.installStatus }
        switch appState.ollama.state {
        case .running: return "Local AI service is running"
        case .starting: return "Starting the local AI service…"
        case .stopped: return "Not installed or the service is stopped"
        case .failed(let message): return message
        }
    }

    private var doclingReady: Bool {
        if case .ready = appState.docling.state { return true }
        return false
    }

    private var doclingDetail: String {
        if appState.docling.isInstalling { return appState.docling.installStatus }
        switch appState.docling.state {
        case .ready(let version): return version
        case .installing: return "Installing Docling…"
        case .unavailable: return "Not installed; FileNest will use its built-in parser"
        case .failed(let message): return message
        }
    }

    private var paddleOCRReady: Bool {
        if case .ready = appState.paddleOCR.state { return true }
        return false
    }

    private var paddleOCRDetail: String {
        if appState.paddleOCR.isInstalling { return appState.paddleOCR.installStatus }
        switch appState.paddleOCR.state {
        case .ready(let version): return version
        case .installing: return "Installing PaddleOCR…"
        case .unavailable: return "Primary local OCR engine; GLM-OCR is used automatically when unavailable"
        case .failed(let message): return message
        }
    }

    private var ffmpegDetail: String {
        if appState.ffmpeg.isInstalling { return appState.ffmpeg.installStatus }
        if let version = appState.ffmpeg.version { return "FFmpeg \(version) is ready" }
        return "Required to decode audio tracks before local transcription"
    }

    private var whisperRuntimeDetail: String {
        if appState.whisper.isInstalling, appState.whisper.installingModel == nil {
            return appState.whisper.installStatus
        }
        if let version = appState.whisper.installedVersion { return "OpenAI Whisper \(version) is ready" }
        return "Installed in an isolated FileNest Python environment"
    }

    private func applySelectedModels() {
        appState.settings.setOllamaModel(selectedGenerationModel)
        appState.settings.setOllamaEmbeddingModel(selectedEmbeddingModel)
        appState.settings.setOllamaOCRModel("glm-ocr")
    }

    private func modelInfo(for model: String) -> OllamaModelInfo? {
        let requested = model.contains(":") ? model : model + ":latest"
        return appState.ollama.models.first { $0.name == model || $0.name == requested }
    }

    private func isModelInstalled(_ model: String) -> Bool {
        modelInfo(for: model) != nil
    }

    private func displaySize(for model: String) -> String {
        let bytes = modelInfo(for: model)?.size ?? OllamaModelCatalog.estimatedDownloadBytes(for: model)
        guard let bytes else { return appState.settings.localized("Unknown size") }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var remainingDownloadBytes: Int64 {
        requiredModels.reduce(0) { result, item in
            guard !isModelInstalled(item.model) else { return result }
            return result + (OllamaModelCatalog.estimatedDownloadBytes(for: item.model) ?? 0)
        }
    }

    private var hasEnoughDiskSpace: Bool {
        SystemProfile.availableDiskBytes == 0 || remainingDownloadBytes <= SystemProfile.availableDiskBytes
    }

    private var batchDownloadProgress: Double {
        guard batchTotalBytes > 0 else { return 0 }
        var downloaded = batchCompletedBytes
        if let model = appState.ollama.pullingModel,
           let fraction = appState.ollama.pullProgress,
           let modelBytes = OllamaModelCatalog.estimatedDownloadBytes(for: model) {
            downloaded += Int64(Double(modelBytes) * min(max(fraction, 0), 1))
        }
        return min(max(Double(downloaded) / Double(batchTotalBytes), 0), 1)
    }

    private var batchProgressDetail: String {
        if let model = appState.ollama.pullingModel {
            return appState.settings.localizedFormat("Downloading %@", model)
        }
        if appState.ollama.isInstalling {
            return appState.settings.localized(appState.ollama.installStatus)
        }
        return appState.settings.localized("Preparing required models…")
    }

    private var batchProgressPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(FileNestTheme.accent)
                Text(batchProgressDetail)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if batchTotalBytes > 0 {
                    Text(batchDownloadProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            if batchTotalBytes > 0 {
                ProgressView(value: batchDownloadProgress)
                    .tint(FileNestTheme.accent)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(FileNestTheme.selection.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Overall progress")
        .accessibilityValue(Text(batchDownloadProgress, format: .percent.precision(.fractionLength(0))))
    }

    private func modelPickerRow(
        title: LocalizedStringKey,
        selection: Binding<String>,
        models: [String]
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Picker("", selection: selection) {
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 210)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .disabled(isDownloadingAll || appState.ollama.pullingModel != nil)
    }

    private func modelRow(role: String, model: String, icon: String) -> some View {
        let installed = isModelInstalled(model)
        let pulling = appState.ollama.pullingModel == model
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(installed ? FileNestTheme.success : FileNestTheme.accent)
                .frame(width: 34, height: 34)
                .background(
                    (installed ? FileNestTheme.success : FileNestTheme.accent).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(LocalizedStringKey(role))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if model == OllamaModelRecommendation.defaultGenerationModel {
                        Text("Default")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(FileNestTheme.accentBlue)
                    } else if model == recommendation.generationModel {
                        Text("Recommended")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(FileNestTheme.accent)
                    } else if model == OllamaModelRecommendation.defaultEmbeddingModel {
                        Text("Default")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(FileNestTheme.accentBlue)
                    }
                }
                Text(model)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            Spacer()
            Text(displaySize(for: model))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            if pulling {
                VStack(alignment: .trailing, spacing: 4) {
                    if let progress = appState.ollama.pullProgress {
                        HStack(spacing: 6) {
                            Text(LocalizedStringKey(appState.ollama.pullStatus))
                                .lineLimit(1)
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                                .fontDesign(.monospaced)
                        }
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        ProgressView(value: progress)
                            .tint(FileNestTheme.accent)
                            .frame(width: 118)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(LocalizedStringKey(appState.ollama.pullStatus))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 132)
            } else if installed {
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(FileNestTheme.success)
                    .frame(width: 108, alignment: .trailing)
            } else {
                Button("Download") { Task { await downloadModel(model) } }
                    .buttonStyle(QuietButtonStyle(compact: true, foreground: FileNestTheme.accent))
                    .disabled(appState.ollama.pullingModel != nil || isDownloadingAll)
                    .frame(width: 108, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 68)
    }

    private func ensureOllamaRunning() async {
        if appState.ollama.state == .running,
           (!OllamaServiceManager.isLocalServiceHost(appState.settings.ollamaHost)
               || appState.ollama.canStopManagedService) {
            return
        }
        await appState.startConfiguredOllama(installIfNeeded: true)
    }

    private func downloadModel(_ model: String) async {
        await ensureOllamaRunning()
        guard appState.ollama.state == .running else { return }
        await appState.ollama.pull(model: model, host: appState.settings.ollamaHost)
    }

    private func downloadAllModels() async {
        isDownloadingAll = true
        applySelectedModels()
        let pendingModels = requiredModels.filter { !isModelInstalled($0.model) }
        batchTotalBytes = pendingModels.reduce(0) {
            $0 + (OllamaModelCatalog.estimatedDownloadBytes(for: $1.model) ?? 0)
        }
        batchCompletedBytes = 0
        defer {
            isDownloadingAll = false
            batchTotalBytes = 0
            batchCompletedBytes = 0
        }
        await ensureOllamaRunning()
        guard appState.ollama.state == .running else { return }
        for item in pendingModels where !isModelInstalled(item.model) {
            await appState.ollama.pull(model: item.model, host: appState.settings.ollamaHost)
            if appState.ollama.lastError != nil { break }
            batchCompletedBytes += OllamaModelCatalog.estimatedDownloadBytes(for: item.model) ?? 0
        }
    }

    private var cloudSectionTitle: String {
        switch cloudService {
        case .chat: return "Chat Model API"
        case .embedding: return "Embedding API"
        case .ocr: return "OCR API"
        }
    }

    private var currentCloudAPIKey: String {
        switch cloudService {
        case .chat: return appState.settings.cloudAPIKey
        case .embedding: return appState.settings.cloudEmbeddingAPIKey
        case .ocr: return appState.settings.cloudOCRAPIKey
        }
    }

    private func cloudFormatRow(value: String, setter: @escaping (String) -> Void) -> some View {
        OnboardingFormRow(label: "API Format") {
            Picker("", selection: Binding(get: { value }, set: setter)) {
                ForEach(AppSettings.CloudAPIFormat.allCases) { format in
                    Text(format.label).tag(format.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 310)
        }
    }

    private func cloudTextRow(
        label: String,
        value: String,
        setter: ((String) -> Void)?
    ) -> some View {
        OnboardingFormRow(label: label) {
            if let setter {
                TextField("", text: Binding(get: { value }, set: setter))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 310)
            } else {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 310, alignment: .leading)
            }
        }
    }

    private func cloudSecureRow(
        label: String,
        value: String,
        setter: @escaping (String) -> Void
    ) -> some View {
        OnboardingFormRow(label: label) {
            SecureField("", text: Binding(get: { value }, set: setter))
                .textFieldStyle(.roundedBorder)
                .frame(width: 310)
        }
    }
}

private struct OnboardingStepHeader: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(FileNestTheme.accent)
                .frame(width: 40, height: 40)
                .background(FileNestTheme.selection, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 20, weight: .semibold))
                Text(LocalizedStringKey(subtitle))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OnboardingSection<Content: View>: View {
    var title: String?
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            content()
        }
        .background(FileNestTheme.elevatedSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(FileNestTheme.border) }
    }
}

private struct OnboardingFormRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 14) {
            Text(LocalizedStringKey(label))
                .font(.system(size: 11, weight: .medium))
                .frame(width: 118, alignment: .leading)
            Spacer(minLength: 0)
            content()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}

private struct AIModeChoice: View {
    let title: String
    let detail: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(selected ? FileNestTheme.accent : .secondary)
                    .frame(width: 34, height: 34)
                    .background(selected ? FileNestTheme.selection : FileNestTheme.secondarySurface,
                                in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title))
                        .font(.system(size: 12, weight: .semibold))
                    Text(LocalizedStringKey(detail))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? FileNestTheme.accent : .secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 64)
            .contentShape(Rectangle())
            .background(selected ? FileNestTheme.selection.opacity(0.8) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? FileNestTheme.accent.opacity(0.45) : FileNestTheme.border)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct WatchDirectoryRow: View {
    let path: String
    let accessState: WatchDirectoryAccessState
    let reauthorize: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: accessState == .accessible ? "folder.fill" : "folder.badge.questionmark")
                .font(.system(size: 12))
                .foregroundStyle(accessState == .accessible ? FileNestTheme.accent : FileNestTheme.warning)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: path).tildeAbbreviatedPath)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if accessState != .accessible {
                    Text(LocalizedStringKey(statusLabel))
                        .font(.system(size: 9))
                        .foregroundStyle(FileNestTheme.warning)
                }
            }
            Spacer()
            if accessState != .accessible {
                Button("Restore Access…", action: reauthorize)
                    .font(.system(size: 10))
                    .controlSize(.small)
            }
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove watched folder")
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private var statusLabel: String {
        switch accessState {
        case .accessible: return "Accessible"
        case .permissionDenied: return "Access Denied"
        case .missing: return "Folder Missing"
        case .unavailable: return "Temporarily Unavailable"
        }
    }
}

private struct DependencyRow: View {
    @EnvironmentObject private var appState: AppState
    let title: String
    let detail: String
    let icon: String
    let ready: Bool
    let busy: Bool
    let progress: Double?
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(ready ? FileNestTheme.success : FileNestTheme.accent)
                .frame(width: 42, height: 42)
                .background((ready ? FileNestTheme.success : FileNestTheme.accent).opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(LocalizedStringKey(title))
                        .font(.system(size: 13, weight: .semibold))
                    if ready {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(FileNestTheme.success)
                    }
                }
                Text(verbatim: appState.settings.localizedRuntimeMessage(detail))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if busy {
                VStack(alignment: .trailing, spacing: 6) {
                    if let progress {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        ProgressView(value: progress)
                            .tint(FileNestTheme.accent)
                            .frame(width: 128)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Installation progress")
            } else if !ready {
                Button(LocalizedStringKey(buttonTitle), action: action)
                    .buttonStyle(QuietButtonStyle(compact: true, foreground: FileNestTheme.accent))
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 82)
    }
}

private struct WelcomeFeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(FileNestTheme.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.system(size: 12, weight: .semibold))
                Text(LocalizedStringKey(detail)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }
}

private struct OnboardingNotice: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(LocalizedStringKey(text))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SystemResourceStrip: View {
    let memory: String
    let disk: String
    let architecture: String

    var body: some View {
        HStack(spacing: 0) {
            SystemResourceCell(icon: "memorychip", label: "Memory", value: memory)
            Divider().frame(height: 38)
            SystemResourceCell(icon: "internaldrive", label: "Available Disk", value: disk)
            Divider().frame(height: 38)
            SystemResourceCell(icon: "cpu", label: "Processor", value: architecture)
        }
        .frame(height: 68)
        .background(FileNestTheme.elevatedSurface.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(FileNestTheme.border) }
    }
}

private struct SystemResourceCell: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FileNestTheme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(label))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity)
    }
}

private enum SystemProfile {
    static let memoryBytes = Int64(ProcessInfo.processInfo.physicalMemory)

    static var availableDiskBytes: Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        return values?.volumeAvailableCapacityForImportantUsage
            ?? Int64(values?.volumeAvailableCapacity ?? 0)
    }

    static var memoryLabel: String {
        ByteCountFormatter.string(fromByteCount: memoryBytes, countStyle: .memory)
    }

    static var availableDiskLabel: String {
        ByteCountFormatter.string(fromByteCount: availableDiskBytes, countStyle: .file)
    }

    static var architectureLabel: String {
#if arch(arm64)
        return "Apple Silicon"
#else
        return "Intel"
#endif
    }
}
