import Foundation
import SwiftUI
import Combine
import AppKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case indexing
    case aiModels
    case statistics
    case rules

    var id: String { rawValue }
}

enum IndexingTaskState: Equatable, Sendable {
    case idle
    case running
    case paused
    case stopping
    case stopped
    case completed
    case failed

    var isActive: Bool {
        self == .running || self == .paused || self == .stopping
    }

    var isAnimating: Bool {
        self == .running || self == .stopping
    }

    var blocksReindexButtons: Bool { isActive }
}

enum OrganizationTaskState: Equatable, Sendable {
    case idle
    case running
    case paused
    case stopping
    case stopped
    case completed
    case failed

    var isActive: Bool {
        self == .running || self == .paused || self == .stopping
    }

    var isAnimating: Bool {
        self == .running || self == .stopping
    }
}

enum IndexingTaskKind: Equatable, Sendable {
    case automatic
    case fullReindex
    case vectorRebuild

    var logName: String {
        switch self {
        case .automatic: return "automatic"
        case .fullReindex: return "full-reindex"
        case .vectorRebuild: return "vector-rebuild"
        }
    }
}

enum ReindexConfirmationStep: Int, Identifiable, Sendable {
    case selection = 1
    case finalConfirmation = 2

    var id: Int { rawValue }
}

enum RAGReindexStage: Int, CaseIterable, Identifiable, Sendable {
    case parsingAndOCR
    case structuredChunking
    case embeddings
    case retrievalIndex
    case rerankerRuntime

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .parsingAndOCR: return "Document parsing & OCR"
        case .structuredChunking: return "Structured chunking"
        case .embeddings: return "Embedding vectors"
        case .retrievalIndex: return "SQLite vector index"
        case .rerankerRuntime: return "Reranker runtime"
        }
    }

    var detail: String {
        switch self {
        case .parsingAndOCR: return "Reread source files with Docling and the selected OCR engine"
        case .structuredChunking: return "Rebuild parent sections and retrieval chunks"
        case .embeddings: return "Regenerate vectors from existing chunks when possible"
        case .retrievalIndex: return "Recreate sqlite-vec from stored vectors without calling AI"
        case .rerankerRuntime: return "Restart the local query-time reranker; document data is unchanged"
        }
    }

    var systemImage: String {
        switch self {
        case .parsingAndOCR: return "doc.text.viewfinder"
        case .structuredChunking: return "square.split.2x1"
        case .embeddings: return "point.3.connected.trianglepath.dotted"
        case .retrievalIndex: return "cylinder.split.1x2"
        case .rerankerRuntime: return "arrow.up.arrow.down.square"
        }
    }

    var downstreamStages: Set<RAGReindexStage> {
        switch self {
        case .parsingAndOCR: return [.parsingAndOCR, .structuredChunking, .embeddings, .retrievalIndex]
        case .structuredChunking: return [.structuredChunking, .embeddings, .retrievalIndex]
        case .embeddings: return [.embeddings, .retrievalIndex]
        case .retrievalIndex: return [.retrievalIndex]
        case .rerankerRuntime: return [.rerankerRuntime]
        }
    }
}

struct LibrarySearchRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let query: String
}

enum FileChatReturnDestination: Equatable {
    case chat
    case library
}

/// Transient presentation state for one in-flight chat request.
///
/// The database remains the source of truth for completed messages. This snapshot keeps an
/// optimistic user message, the streaming assistant message, and the current pipeline stage
/// available while the user navigates between conversations.
struct ChatExecutionPresentation: Equatable {
    var userMessage: ChatMessage?
    var assistantMessage: ChatMessage
    var progress: ChatProgress?
}

struct AutomaticFileProcessingItem: Identifiable, Equatable {
    let id: Int64
    var fileName: String
    var stage: AutomaticFileProcessingStage
    var detail: String?
    var updatedAt: Date

    var isActive: Bool {
        switch stage {
        case .completed, .failed: return false
        default: return true
        }
    }

    var title: String {
        switch stage {
        case .queued: return "Queued for processing"
        case .indexing: return "Indexing file"
        case .waitingForOrganization: return "Waiting to organize"
        case .organizing: return "Organizing file"
        case .completed: return "Processing complete"
        case .failed: return "Processing failed"
        }
    }

    var subtitle: String {
        switch stage {
        case let .indexing(indexingStage): return indexingStage.statusText
        case let .failed(message): return detail ?? message
        default: return detail ?? fileName
        }
    }

    var progress: Double? {
        switch stage {
        case .queued: return 0.04
        case let .indexing(indexingStage):
            if case let .embedding(completed, total) = indexingStage, total > 0 {
                return 0.2 + 0.55 * Double(completed) / Double(total)
            }
            return 0.18
        case .waitingForOrganization: return 0.8
        case .organizing: return 0.92
        case .completed: return 1
        case .failed: return nil
        }
    }
}

/// Application-wide state that owns service instances and drives reactive UI updates.
@MainActor
final class AppState: ObservableObject {
    nonisolated static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil ||
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
        ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
    }

    let store: SQLiteStore
    let settings: AppSettings
    let watcher: FileWatcherService
    let organizer: OrganizerService
    let indexer: IndexerService
    let chat: ChatService
    let ollama: OllamaServiceManager
    let reranker: RerankerServiceManager
    let docling: DoclingServiceManager
    let paddleOCR: PaddleOCRServiceManager
    let updates: AppUpdateService

    @Published var statusText = "Ready"
    @Published var indexedCount: Int = 0
    @Published var isWatching = false
    @Published private(set) var watchDirectoryStatuses: [WatchDirectoryStatus] = []

    // Data sources for the library, chat, and other UI.
    @Published var files: [FileRecord] = []
    @Published private(set) var previewedFile: FileRecord?
    @Published var rules: [Rule] = []
    @Published var chatSessions: [ChatSession] = []
    @Published var selectedChatSessionID: Int64?
    @Published var chatMessages: [ChatMessage] = []
    @Published private(set) var runningChatSessionIDs = Set<Int64>()
    @Published private(set) var completedChatSessionIDs = Set<Int64>()
    @Published private(set) var chatExecutionPresentations = [Int64: ChatExecutionPresentation]()
    @Published private(set) var draftChatAttachmentPath: String?
    @Published private(set) var chatComposerInput = ""
    @Published private(set) var librarySearchRequest: LibrarySearchRequest?
    @Published private(set) var librarySearchHistory: [LibrarySearchHistoryEntry] = []
    @Published private(set) var quickSearchShortcutRegistrationError: String?
    @Published var statistics: AppStatistics = .empty
    @Published var selectedSettingsSection: SettingsSection = .general
    @Published var isOnboardingPresented = false
    @Published private(set) var indexingState: IndexingTaskState = .idle
    @Published private(set) var organizationState: OrganizationTaskState = .idle
    @Published private(set) var organizationProgress: OrganizationJobProgress?
    @Published private(set) var automaticFileProcessingItems: [AutomaticFileProcessingItem] = []
    @Published private(set) var indexingKind: IndexingTaskKind = .automatic
    @Published private(set) var vectorIndexRebuildProgress: VectorIndexRebuildProgress?
    @Published private(set) var isIndexConfigurationPromptPresented = false
    @Published private(set) var hasPendingAutomaticEmbeddingRebuild = false
    @Published private(set) var reindexConfirmationStep: ReindexConfirmationStep?
    @Published private(set) var pendingAdvancedReindexCategories = Set<IndexContentChangeCategory>()
    @Published private(set) var selectedAdvancedReindexCategories = Set<IndexContentChangeCategory>()
    @Published private(set) var isEmbeddingChangeReindexSelected = true
    @Published private(set) var isUnindexedFilesReindexSelected = true
    @Published private(set) var reindexUnindexedFileCount = 0
    @Published private(set) var selectedRAGReindexStages = Set<RAGReindexStage>()
    @Published private(set) var isFullPipelineReindexSelected = false
    @Published var isReindexAdvancedExpanded = false

    private var cancellables = Set<AnyCancellable>()
    private var managedSyncIndexIDs = Set<Int64>()
    private var managedSyncIndexTask: Task<Void, Never>?
    private var scheduledRefreshTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var refreshGeneration: UInt64 = 0
    private var statisticsTask: Task<Void, Never>?
    private var activeStatisticsDays: Int?
    private var pendingStatisticsDays: Int?
    private var modelServiceStatusRefreshTask: Task<Void, Never>?
    private var modelVersionCheckTask: Task<Void, Never>?
    private var reindexTask: Task<Void, Never>?
    private var organizationTask: Task<Void, Never>?
    private var organizationJobToken: UUID?
    private var organizationPhaseBeforePause: OrganizationJobPhase = .preparing
    private var notePostSaveTasks = [Int64: Task<Void, Never>]()
    private var notePostSaveTokens = [Int64: UUID]()
    private var pendingCompletedProcessingCount = 0
    private var lastCompletedProcessingFileName: String?
    private let indexingGate = IndexingExecutionGate()
    private let organizationGate = OrganizationExecutionGate()
    private var lastRebuildVectorSpace = false
    private var lastOnlyUnindexedFiles = false
    private var lastIncludeUnindexedFiles = false
    private var lastRetrievalIndexOnly = false
    private var lastForceSourceReprocessing = false
    private var lastIndexingKind: IndexingTaskKind = .fullReindex
    private var lastReindexContentCategories = Set<IndexContentChangeCategory>()
    private var isDraftChat = false
    private var chatComposerDrafts: [String: String] = [:]
    private var activeChatComposerDraftKey = "new"
    private var fileChatReturnSessionID: Int64?
    private var fileChatReturnDestination: FileChatReturnDestination?
    private let globalHotKeyService = GlobalHotKeyService()
    private var quickSearchPanelController: QuickSearchPanelController?
    private let systemNotificationsEnabled: Bool
    private let shouldSynchronizeManagedFiles: Bool
    private let shouldIndexManagedFiles: Bool
    private let startsServicesAutomatically: Bool
    private static let appliedEmbeddingSignatureKey = "index.applied_embedding_space_signature.v1"
    private static let acknowledgedContentSignatureKey = "index.acknowledged_content_processing_signature.v1"

    private static func appliedContentSignatureKey(_ category: IndexContentChangeCategory) -> String {
        "index.applied_content_category.\(category.rawValue).v1"
    }

    var isRebuildingVectorIndex: Bool {
        indexingKind == .vectorRebuild && indexingState.isActive
    }

    var indexingProgress: VectorIndexRebuildProgress? { vectorIndexRebuildProgress }
    var reindexButtonsDisabled: Bool { indexingState.blocksReindexButtons }

    var activeAutomaticFileProcessingItems: [AutomaticFileProcessingItem] {
        automaticFileProcessingItems.filter(\.isActive)
    }

    var hasActiveAutomaticFileProcessing: Bool {
        !activeAutomaticFileProcessingItems.isEmpty
    }

    var automaticProcessingStatusTitle: String {
        guard let item = activeAutomaticFileProcessingItems.sorted(by: { $0.updatedAt > $1.updatedAt }).first else {
            return "Processing queue idle"
        }
        return item.title
    }

    var automaticProcessingStatusSubtitle: String {
        guard let item = activeAutomaticFileProcessingItems.sorted(by: { $0.updatedAt > $1.updatedAt }).first else {
            return "No files are being processed"
        }
        let queued = activeAutomaticFileProcessingItems.count
        let queueText = queued > 1 ? settings.localizedFormat("%d files in queue", queued) : item.fileName
        return "\(item.subtitle) · \(queueText)"
    }

    var activeWatchDirectoryCount: Int {
        watchDirectoryStatuses.filter(\.isWatching).count
    }

    var configuredWatchDirectoryCount: Int {
        settings.watchDirs.count
    }

    var hasActiveWatchDirectories: Bool {
        isWatching && activeWatchDirectoryCount > 0
    }

    var hasWatchDirectoryAccessIssue: Bool {
        watchDirectoryStatuses.contains { $0.accessState != .accessible }
    }

    var watchStatusTitle: String {
        guard isWatching else { return "Watching paused" }
        let total = configuredWatchDirectoryCount
        guard total > 0 else { return "No watched folders added" }
        let active = activeWatchDirectoryCount
        if active == total {
            return settings.localizedFormat("Watching %d folders", active)
        }
        if active > 0 {
            return settings.localizedFormat("Watching %d of %d folders", active, total)
        }
        if watchDirectoryStatuses.contains(where: { $0.accessState == .permissionDenied }) {
            return "Watched Folder Access Required"
        }
        if watchDirectoryStatuses.contains(where: { $0.accessState == .missing }) {
            return "Watched Folder Missing"
        }
        return "Connecting to watched folders…"
    }

    var watchStatusSubtitle: String {
        guard isWatching else { return "Automatic organization is paused" }
        let denied = watchDirectoryStatuses.filter { $0.accessState == .permissionDenied }.count
        if denied > 0 {
            return settings.localizedFormat("%d folders need access restored", denied)
        }
        let missing = watchDirectoryStatuses.filter { $0.accessState == .missing }.count
        if missing > 0 {
            return settings.localizedFormat("%d folders are missing or were moved", missing)
        }
        if hasActiveWatchDirectories { return "Monitoring file changes" }
        return "Checking folder access"
    }

    var indexingStatusTitle: String {
        switch indexingState {
        case .idle:
            return indexedCount > 0 ? "Index Ready" : "Index Not Built"
        case .running:
            switch indexingKind {
            case .automatic: return "Indexing"
            case .fullReindex: return "Reindexing"
            case .vectorRebuild: return "Rebuilding vector index"
            }
        case .paused: return "Indexing Paused"
        case .stopping: return "Stopping Indexing"
        case .stopped: return "Indexing Stopped"
        case .completed: return "Indexing Complete"
        case .failed: return "Indexing Finished with Errors"
        }
    }

    var indexingStatusSubtitle: String {
        guard let progress = indexingProgress else {
            return settings.localizedFormat("%d files indexed", indexedCount)
        }
        if let stage = progress.stage {
            let stageText: String
            if case let .embedding(completed, total) = stage {
                stageText = settings.localizedFormat("Generating vectors %d/%d", completed, total)
            } else {
                stageText = settings.localized(stage.statusText)
            }
            return "\(stageText) · " + settings.localizedFormat(
                "Processed %d of %d files",
                progress.completed,
                progress.total
            )
        }
        return settings.localizedFormat(
            "Processed %d of %d files",
            progress.completed,
            progress.total
        )
    }

    var organizationStatusTitle: String {
        switch organizationState {
        case .idle: return "Ready to Organize"
        case .running:
            switch organizationProgress?.phase {
            case .preparing: return "Preparing Organization"
            case .waitingForStability: return "Waiting for Files to Stabilize"
            case .indexing: return "Building Local Index"
            case .organizing: return "Moving Files"
            default: return "Organizing"
            }
        case .paused: return "Organization Paused"
        case .stopping: return "Stopping Organization"
        case .stopped: return "Organization Stopped"
        case .completed: return "Organization Complete"
        case .failed: return "Organization Finished with Errors"
        }
    }

    var organizationStatusSubtitle: String {
        guard let progress = organizationProgress else {
            return "Only new eligible items in watched folders are processed."
        }
        if let fileName = progress.currentFileName,
           organizationState == .running {
            return settings.localizedFormat("Processing %@", fileName)
        }
        return settings.localizedFormat(
            "%d moved · %d skipped · %d failed",
            progress.moved,
            progress.skipped,
            progress.failed
        )
    }

    init(store: SQLiteStore = .shared,
         settings: AppSettings = .shared,
         organizeRoot: URL? = nil,
         startAutomatically: Bool = !AppState.isRunningTests) {
        self.store = store
        self.settings = settings
        self.startsServicesAutomatically = startAutomatically
        self.systemNotificationsEnabled = startAutomatically
        self.updates = AppUpdateService(settings: settings, enabled: startAutomatically)
        self.shouldSynchronizeManagedFiles = organizeRoot != nil || !AppState.isRunningTests
        self.shouldIndexManagedFiles = startAutomatically
        let organizer = OrganizerService(store: store, settings: settings, organizeRoot: organizeRoot)
        let indexer = IndexerService(store: store, settings: settings)
        let chat = ChatService(store: store, settings: settings, vectorStore: indexer.vectorStore)
        let ollama = OllamaServiceManager()
        let reranker = RerankerServiceManager()
        let docling = DoclingServiceManager()
        let paddleOCR = PaddleOCRServiceManager()
        // The watcher depends on the organizer and indexer, so create those first.
        let watcher = FileWatcherService(
            store: store,
            organizer: organizer,
            indexer: indexer,
            settings: settings
        )
        self.organizer = organizer
        self.indexer = indexer
        self.chat = chat
        self.ollama = ollama
        self.reranker = reranker
        self.docling = docling
        self.paddleOCR = paddleOCR
        self.watcher = watcher
        if startAutomatically {
            SystemNotificationService.shared.configure()
        }
        AppLifecycleCoordinator.shared.register(self)
        watcher.onDirectoryStatusChange = { [weak self] statuses in
            Task { @MainActor [weak self] in
                self?.applyWatchDirectoryStatuses(statuses)
            }
        }
        watcher.onAutomaticFileProcessing = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.applyAutomaticFileProcessing(event)
            }
        }
        organizer.onAutomaticOrganizationUpdate = { [weak self] fileID, stage, detail in
            Task { @MainActor [weak self] in
                guard let self,
                      let fileName = (try? self.store.file(id: fileID))?.name,
                      !fileName.isEmpty else { return }
                self.applyAutomaticFileProcessing(
                    AutomaticFileProcessingEvent(
                        fileID: fileID,
                        fileName: fileName,
                        stage: stage
                    ),
                    detail: detail
                )
            }
        }
        organizer.onLibraryChange = { [weak self] in
            Task { @MainActor in self?.scheduleLibraryRefresh() }
        }
        self.settings.attach(store: store, organizer: organizer, indexer: indexer, chat: chat, watcher: watcher)
        // SwiftUI observes AppState; forward nested changes so settings, installation progress, and service state refresh immediately.
        settings.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                DispatchQueue.main.async { [weak self] in
                    self?.refreshIndexConfigurationState()
                }
            }
            .store(in: &cancellables)
        ollama.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        reranker.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        docling.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                DispatchQueue.main.async { [weak self] in
                    self?.refreshIndexConfigurationState()
                }
            }
            .store(in: &cancellables)
        paddleOCR.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                DispatchQueue.main.async { [weak self] in
                    self?.refreshIndexConfigurationState()
                }
            }
            .store(in: &cancellables)
        updates.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        if startAutomatically {
            settings.$quickSearchShortcutKeyCode
                .combineLatest(settings.$quickSearchShortcutModifiers)
                .removeDuplicates { lhs, rhs in
                    lhs.0 == rhs.0 && lhs.1 == rhs.1
                }
                .sink { [weak self] keyCode, modifiers in
                    self?.registerQuickSearchShortcut(
                        QuickSearchShortcut(keyCode: keyCode, modifiers: modifiers)
                    )
                }
                .store(in: &cancellables)
        }
        // Organizer batching and settings access the current indexer through a proxy.
        AppStateIndexerProxy.shared.indexer = indexer
        // The XCTest host constructs a default AppState; migrate persistent state only for production launches or explicitly injected test stores.
        if startAutomatically || organizeRoot != nil {
            prepareIndexConfigurationTracking()
        }
        isOnboardingPresented = startAutomatically && !settings.onboardingCompleted
        // XCTest launches the host app; tests refresh state by default without scanning user folders.
        guard startAutomatically else {
            refresh()
            refreshChatSessions()
            return
        }
        AppLogService.shared.write(
            "application services initialized",
            category: .appLifecycle,
            level: .notice,
            metadata: [
                "onboardingCompleted": "\(settings.onboardingCompleted)",
                "watchedDirectories": "\(settings.watchDirs.count)",
            ]
        )
        // Insert default rules on first launch.
        try? store.seedDefaultRulesIfNeeded()
        // Queue missing indexes after warm-up to avoid processing the same file twice at startup.
        refreshInBackground(allowManagedIndexing: false)
        Task { [weak self] in
            guard let self else { return }
            await indexer.warmup()
            _ = await organizer.invalidateChangedManagedFileIndexes()
            if !self.refreshIndexConfigurationState() {
                self.refreshInBackground()
            }
        }
        refreshChatSessions()
        refreshLibrarySearchHistory()
        // Do not scan folders before initial setup completes; the user must first decide how to handle existing files.
        if settings.onboardingCompleted {
            startWatching()
        }
        Task { [weak self] in
            await self?.refreshModelServiceStatus()
        }
    }

    private func applyAutomaticFileProcessing(
        _ event: AutomaticFileProcessingEvent,
        detail: String? = nil
    ) {
        let now = Date()
        let previousStage = automaticFileProcessingItems.first(where: { $0.id == event.fileID })?.stage
        let resolvedFileName: String?
        if event.fileName == "File" || event.fileName.isEmpty {
            resolvedFileName = (try? store.file(id: event.fileID))?.name
        } else {
            resolvedFileName = event.fileName
        }
        if let index = automaticFileProcessingItems.firstIndex(where: { $0.id == event.fileID }) {
            if let resolvedFileName, !resolvedFileName.isEmpty {
                automaticFileProcessingItems[index].fileName = resolvedFileName
            }
            automaticFileProcessingItems[index].stage = event.stage
            automaticFileProcessingItems[index].detail = detail
            automaticFileProcessingItems[index].updatedAt = now
        } else {
            // An unidentified organizer event is not useful in the recent activity UI.
            guard let resolvedFileName, !resolvedFileName.isEmpty else { return }
            automaticFileProcessingItems.append(AutomaticFileProcessingItem(
                id: event.fileID,
                fileName: resolvedFileName,
                stage: event.stage,
                detail: detail,
                updatedAt: now
            ))
        }
        automaticFileProcessingItems.sort { $0.updatedAt > $1.updatedAt }
        // Preserve a compact recent history while keeping all work that is still active.
        let active = automaticFileProcessingItems.filter(\.isActive)
        let recent = automaticFileProcessingItems.filter { !$0.isActive }.prefix(8)
        automaticFileProcessingItems = active + recent
        if !indexingState.isActive {
            statusText = hasActiveAutomaticFileProcessing
                ? automaticProcessingStatusTitle
                : watchStatusTitle
        }
        guard previousStage != event.stage else { return }
        switch event.stage {
        case .completed:
            pendingCompletedProcessingCount += 1
            lastCompletedProcessingFileName = resolvedFileName
            if !hasActiveAutomaticFileProcessing && !organizationState.isActive {
                postCompletedProcessingNotification()
            }
        case .failed:
            let fileName = resolvedFileName ?? event.fileName
            postSystemNotification(
                titleKey: "File Processing Failed",
                body: settings.localizedFormat(
                    "FileNest could not process %@. Open FileNest for details.",
                    fileName
                ),
                identifier: "filenest.processing.failed.\(event.fileID)"
            )
        case .queued, .indexing, .waitingForOrganization, .organizing:
            break
        }
    }

    private func postCompletedProcessingNotification() {
        guard pendingCompletedProcessingCount > 0 else { return }
        let body: String
        if pendingCompletedProcessingCount == 1, let fileName = lastCompletedProcessingFileName {
            body = settings.localizedFormat("%@ finished indexing and processing.", fileName)
        } else {
            body = settings.localizedFormat(
                "%d files finished indexing and processing.",
                pendingCompletedProcessingCount
            )
        }
        postSystemNotification(
            titleKey: "File Processing Complete",
            body: body,
            identifier: "filenest.processing.complete"
        )
        pendingCompletedProcessingCount = 0
        lastCompletedProcessingFileName = nil
    }

    private func postSystemNotification(titleKey: String, body: String, identifier: String) {
        guard systemNotificationsEnabled else { return }
        SystemNotificationService.shared.post(
            title: settings.localized(titleKey),
            body: body,
            identifier: identifier
        )
    }

    private func scheduleLibraryRefresh() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.refreshInBackground()
            self.scheduledRefreshTask = nil
        }
    }

    func refresh(allowManagedIndexing: Bool = true) {
        refreshGeneration &+= 1
        _ = try? store.removeTransientFiles(preservingRoot: organizer.organizeRoot)
        let refreshedFiles: [FileRecord]
        if shouldSynchronizeManagedFiles {
            refreshedFiles = organizer.reconcileManagedFiles()
        } else {
            refreshedFiles = ((try? store.allFiles()) ?? []).filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
        }
        applyLibrarySnapshot(
            files: refreshedFiles,
            rules: (try? store.allRules()) ?? [],
            allowManagedIndexing: allowManagedIndexing
        )
    }

    func refreshInBackground(allowManagedIndexing: Bool = true) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        backgroundRefreshTask?.cancel()
        let store = store
        let organizer = organizer
        let organizeRoot = organizer.organizeRoot
        let shouldSynchronizeManagedFiles = shouldSynchronizeManagedFiles
        backgroundRefreshTask = Task { [weak self] in
            let refreshedFiles: [FileRecord]
            if shouldSynchronizeManagedFiles {
                refreshedFiles = await organizer.reconcileManagedFilesAsync()
            } else {
                refreshedFiles = await Task.detached(priority: .utility) {
                    _ = try? store.removeTransientFiles(preservingRoot: organizeRoot)
                    return ((try? store.allFiles()) ?? []).filter {
                        FileManager.default.fileExists(atPath: $0.path)
                    }
                }.value
            }
            let refreshedRules = await Task.detached(priority: .utility) {
                (try? store.allRules()) ?? []
            }.value
            guard let self,
                  !Task.isCancelled,
                  self.refreshGeneration == generation else { return }
            self.applyLibrarySnapshot(
                files: refreshedFiles,
                rules: refreshedRules,
                allowManagedIndexing: allowManagedIndexing
            )
            self.backgroundRefreshTask = nil
        }
    }

    private func applyLibrarySnapshot(
        files refreshedFiles: [FileRecord],
        rules refreshedRules: [Rule],
        allowManagedIndexing: Bool
    ) {
        files = FileRecord.sortedByNewestAdded(refreshedFiles)
        if let previewedFile {
            let refreshedPreview = files.first { candidate in
                if let id = previewedFile.id { return candidate.id == id }
                return candidate.path == previewedFile.path
            }
            self.previewedFile = refreshedPreview ?? (
                FileManager.default.fileExists(atPath: previewedFile.path) ? previewedFile : nil
            )
        }
        rules = refreshedRules
        indexedCount = files.filter { $0.indexedAt != nil }.count
        if shouldIndexManagedFiles && allowManagedIndexing { indexNewManagedFilesIfNeeded() }
        refreshStatistics()
    }

    private func indexNewManagedFilesIfNeeded() {
        guard managedSyncIndexTask == nil,
              reindexTask == nil,
              indexingState != .stopped,
              !indexingState.isActive else { return }
        let ids = files.compactMap { file -> Int64? in
            guard !FileEligibilityPolicy.shouldIgnoreFile(named: file.name),
                  file.indexedAt == nil,
                  let id = file.id,
                  managedSyncIndexIDs.insert(id).inserted else { return nil }
            return id
        }
        guard !ids.isEmpty else { return }
        // Backfill indexes serially to avoid starting many local-model tasks during a large initial sync.
        beginIndexing(kind: .automatic, total: ids.count)
        managedSyncIndexTask = Task { [weak self] in
            guard let self else { return }
            await self.indexingGate.reset()
            let records = ids.compactMap { try? self.store.file(id: $0) }
            let result = await self.indexer.indexFiles(
                records,
                checkpoint: { [indexingGate = self.indexingGate] in
                    await indexingGate.waitUntilRunnable()
                }
            ) { [weak self] progress in
                self?.vectorIndexRebuildProgress = progress
            }
            let wasStopped = result.stopped || self.indexingState == .stopping || Task.isCancelled
            ids.forEach { self.managedSyncIndexIDs.remove($0) }
            self.managedSyncIndexTask = nil
            self.finishIndexing(
                stopped: wasStopped,
                succeeded: !wasStopped && result.failed == 0,
                completed: result.completed,
                total: ids.count,
                failed: result.failed
            )
            self.refresh(allowManagedIndexing: false)
            self.refreshIndexConfigurationState()
        }
    }

    /// When split signatures are first enabled, verify the actual vector-table model. If it matches, migrate metadata only and avoid upgrade-driven recomputation.
    private func prepareIndexConfigurationTracking() {
        let embeddingSignature = settings.embeddingSpaceSignature
        if store.getSetting(Self.appliedEmbeddingSignatureKey) == nil {
            let expectedModel = settings.makeEmbeddingProvider().name
            let storedModels = (try? store.distinctEmbeddingModels()) ?? []
            if storedModels.isEmpty || storedModels == Set([expectedModel]) {
                store.setSetting(Self.appliedEmbeddingSignatureKey, embeddingSignature)
                try? store.migrateIndexedFileSignatures(to: embeddingSignature)
            } else {
                let legacyModels = storedModels.sorted().joined(separator: ",")
                store.setSetting(
                    Self.appliedEmbeddingSignatureKey,
                    "legacy:\(legacyModels)"
                )
            }
        }
        if store.getSetting(Self.acknowledgedContentSignatureKey) == nil {
            store.setSetting(
                Self.acknowledgedContentSignatureKey,
                settings.contentProcessingSignature
            )
        }
        for (category, signature) in settings.indexContentCategorySignatures
        where store.getSetting(Self.appliedContentSignatureKey(category)) == nil {
            store.setSetting(Self.appliedContentSignatureKey(category), signature)
        }
        refreshIndexConfigurationState(allowAutomaticRebuild: false)
    }

    /// Rebuilds automatically for model or provider changes; other processing changes present one user decision.
    @discardableResult
    func refreshIndexConfigurationState(allowAutomaticRebuild: Bool = true) -> Bool {
        let appliedEmbeddingSignature = store.getSetting(Self.appliedEmbeddingSignatureKey)
        hasPendingAutomaticEmbeddingRebuild = appliedEmbeddingSignature != settings.embeddingSpaceSignature

        if hasPendingAutomaticEmbeddingRebuild {
            isIndexConfigurationPromptPresented = false
            guard allowAutomaticRebuild, shouldIndexManagedFiles else { return false }
            return startReindex(kind: .vectorRebuild, rebuildVectorSpace: true)
        }

        pendingAdvancedReindexCategories = changedContentCategories()
        isIndexConfigurationPromptPresented = !pendingAdvancedReindexCategories.isEmpty && !indexingState.isActive
        return false
    }

    func reindexForPendingConfigurationChange() {
        guard isIndexConfigurationPromptPresented else { return }
        isIndexConfigurationPromptPresented = false
        reindexAll()
    }

    func skipPendingConfigurationChange() {
        AppLogService.shared.write(
            "index configuration changes skipped",
            category: .appConfiguration,
            level: .notice,
            metadata: [
                "categories": pendingAdvancedReindexCategories
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: ","),
            ]
        )
        acknowledgeContentCategories(pendingAdvancedReindexCategories)
        isIndexConfigurationPromptPresented = false
        pendingAdvancedReindexCategories = []
    }

    private func changedContentCategories() -> Set<IndexContentChangeCategory> {
        Set(settings.indexContentCategorySignatures.compactMap { category, signature in
            store.getSetting(Self.appliedContentSignatureKey(category)) == signature ? nil : category
        })
    }

    private func acknowledgeContentCategories(_ categories: Set<IndexContentChangeCategory>) {
        let signatures = settings.indexContentCategorySignatures
        for category in categories {
            if let signature = signatures[category] {
                store.setSetting(Self.appliedContentSignatureKey(category), signature)
            }
        }
        store.setSetting(Self.acknowledgedContentSignatureKey, settings.contentProcessingSignature)
    }

    func saveNote(fileID: Int64, note: String) async throws {
        let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)
        try store.updateFileNote(id: fileID, note: normalized.isEmpty ? nil : normalized)
        refresh(allowManagedIndexing: false)

        // Persistence is the save boundary. Vectorizing the note and recalculating its optional
        // AI subfolder happen in the background and never keep the Save button spinning.
        notePostSaveTasks[fileID]?.cancel()
        let token = UUID()
        notePostSaveTokens[fileID] = token
        notePostSaveTasks[fileID] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.notePostSaveTokens[fileID] == token {
                    self.notePostSaveTasks[fileID] = nil
                    self.notePostSaveTokens[fileID] = nil
                }
            }

            let indexed = await self.indexer.updateNoteIndex(fileID: fileID, note: normalized)
            guard !Task.isCancelled else { return }
            if !indexed {
                AppLogService.shared.write(
                    "note saved but note vector update failed",
                    category: .indexEmbedding,
                    level: .warning,
                    metadata: ["fileID": "\(fileID)"]
                )
            }

            do {
                try await self.organizer.organizeUsingAI(fileId: fileID)
            } catch {
                AppLogService.shared.write(
                    "background note reclassification failed: \(error)",
                    category: .organizeMove,
                    level: .warning,
                    metadata: ["fileID": "\(fileID)"]
                )
            }
            guard !Task.isCancelled else { return }
            self.refresh(allowManagedIndexing: false)
        }
    }

    func presentFilePreview(_ file: FileRecord) {
        guard file.supportsPreview else { return }
        previewedFile = file
    }

    func presentAttachedFilePreview(path: String) {
        if let record = files.first(where: { $0.path == path }) ?? (try? store.file(path: path)) {
            presentFilePreview(record)
            return
        }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let record = FileRecord(
            id: nil,
            path: path,
            name: url.lastPathComponent,
            ext: url.pathExtension,
            size: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            mtime: (attributes?[.modificationDate] as? Date) ?? Date(),
            category: FileCategory.from(extension: url.pathExtension).rawValue,
            sourceDir: url.deletingLastPathComponent().path,
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        )
        presentFilePreview(record)
    }

    func closeFilePreview() {
        previewedFile = nil
    }

    func toggleQuickSearchPanel() {
        if quickSearchPanelController == nil {
            quickSearchPanelController = QuickSearchPanelController(
                settings: settings,
                submitSearch: { [weak self] query in
                    guard let self else { return }
                    self.requestLibrarySearch(query)
                    MainWindowPresenter.shared.present()
                }
            )
        }
        quickSearchPanelController?.toggle()
    }

    func requestLibrarySearch(_ rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        closeFilePreview()
        librarySearchRequest = LibrarySearchRequest(query: query)
    }

    func consumeLibrarySearchRequest(_ requestID: UUID) {
        guard librarySearchRequest?.id == requestID else { return }
        librarySearchRequest = nil
    }

    private func registerQuickSearchShortcut(_ shortcut: QuickSearchShortcut) {
        let status = globalHotKeyService.register(shortcut: shortcut) { [weak self] in
            self?.toggleQuickSearchPanel()
        }
        quickSearchShortcutRegistrationError = status == noErr
            ? nil
            : "The shortcut could not be registered. Choose a different combination."
        guard status != noErr else { return }
        AppLogService.shared.write(
            "quick search shortcut registration failed",
            category: .appConfiguration,
            level: .warning,
            metadata: [
                "shortcut": shortcut.displayName,
                "status": "\(status)",
            ]
        )
    }

    @discardableResult
    func reindexFile(_ file: FileRecord) async -> Bool {
        guard !reindexButtonsDisabled,
              let id = file.id,
              FileManager.default.fileExists(atPath: file.path) else { return false }
        applyAutomaticFileProcessing(AutomaticFileProcessingEvent(
            fileID: id,
            fileName: file.name,
            stage: .queued
        ))
        let succeeded = await indexer.indexFile(
            id: id,
            force: true,
            forceVectorization: true,
            stageProgress: { [weak self] stage in
                await self?.applyAutomaticFileProcessing(AutomaticFileProcessingEvent(
                    fileID: id,
                    fileName: file.name,
                    stage: .indexing(stage)
                ))
            }
        )
        applyAutomaticFileProcessing(AutomaticFileProcessingEvent(
            fileID: id,
            fileName: file.name,
            stage: succeeded ? .completed : .failed("Indexing failed")
        ))
        refresh(allowManagedIndexing: false)
        return succeeded
    }

    func moveFileToTrash(_ file: FileRecord) async throws {
        let url = URL(fileURLWithPath: file.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            closePreviewIfNeeded(for: file)
            refresh(allowManagedIndexing: false)
            throw FileTrashError.fileMissing
        }

        if let id = file.id {
            await indexer.cancel(fileID: id)
        }

        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }.value

        if let id = file.id {
            try? store.deleteFile(id: id)
            managedSyncIndexIDs.remove(id)
        }
        closePreviewIfNeeded(for: file)
        AppLogService.shared.write(
            "file moved to Trash",
            category: .appLifecycle,
            metadata: ["file": file.name]
        )
        refresh(allowManagedIndexing: false)
    }

    private func closePreviewIfNeeded(for file: FileRecord) {
        guard let previewedFile else { return }
        if let id = file.id, previewedFile.id == id {
            self.previewedFile = nil
        } else if previewedFile.path == file.path {
            self.previewedFile = nil
        }
    }

    func generateNoteSummary(fileID: Int64) async throws -> String {
        guard let file = try store.file(id: fileID) else { throw FileSummaryError.fileMissing }
        return try await FileSummaryService(settings: settings).summarize(file: file)
    }

    func streamNoteSummary(fileID: Int64) throws -> AsyncThrowingStream<String, Error> {
        guard let file = try store.file(id: fileID) else { throw FileSummaryError.fileMissing }
        return FileSummaryService(settings: settings).streamSummary(file: file)
    }

    func managedSearchResults(matching keyword: String) async -> [LibrarySearchResult] {
        await chat.searchLibrary(
            keyword,
            managedRootPath: organizer.organizeRoot.standardizedFileURL.path
        )
    }

    func cachedLibrarySearch(
        matching query: String,
        isSmartSearch: Bool
    ) -> CachedLibrarySearch? {
        guard let revision = try? store.libraryRevision(),
              let record = try? store.cachedLibrarySearch(
                query: query,
                isSmartSearch: isSmartSearch
              ),
              record.revision == revision,
              let cached = try? JSONDecoder().decode(CachedLibrarySearchPayload.self, from: record.payload) else {
            return nil
        }

        let currentFiles = files.isEmpty ? ((try? store.allFiles()) ?? []) : files
        let filesByID = Dictionary(uniqueKeysWithValues: currentFiles.compactMap { file in
            file.id.map { ($0, file) }
        })
        let filesByPath = Dictionary(uniqueKeysWithValues: currentFiles.map { ($0.path, $0) })
        let hydratedResults = cached.results.compactMap { result -> LibrarySearchResult? in
            let currentFile = result.fileID.flatMap { filesByID[$0] } ?? filesByPath[result.path]
            guard let currentFile,
                  FileManager.default.fileExists(atPath: currentFile.path) else { return nil }
            return LibrarySearchResult(
                file: currentFile,
                score: result.score,
                confidence: result.confidence,
                matchKind: result.matchKind,
                snippet: result.snippet,
                sectionPath: result.sectionPath,
                pageStart: result.pageStart,
                pageEnd: result.pageEnd
            )
        }
        return CachedLibrarySearch(
            results: hydratedResults,
            smartPlan: cached.smartPlan,
            usedAI: cached.usedAI
        )
    }

    func saveLibrarySearch(
        query: String,
        results: [LibrarySearchResult],
        smartPlan: SmartLibrarySearchPlan? = nil,
        usedAI: Bool = false,
        recordHistory: Bool = true
    ) {
        let cached = CachedLibrarySearchPayload(
            results: results.map(CachedLibrarySearchResult.init),
            smartPlan: smartPlan,
            usedAI: usedAI
        )
        guard let payload = try? JSONEncoder().encode(cached),
              let revision = try? store.libraryRevision() else { return }
        do {
            try store.saveLibrarySearch(
                query: query,
                isSmartSearch: smartPlan != nil,
                resultCount: results.count,
                revision: revision,
                payload: payload,
                recordHistory: recordHistory
            )
            refreshLibrarySearchHistory()
        } catch {
            AppLogService.shared.write(
                "failed to save library search cache: \(error)",
                category: .appConfiguration,
                level: .warning
            )
        }
    }

    func refreshLibrarySearchHistory() {
        librarySearchHistory = (try? store.librarySearchHistory(limit: 20)) ?? []
    }

    func deleteLibrarySearchHistory(_ id: Int64) {
        try? store.deleteLibrarySearchHistory(id: id)
        refreshLibrarySearchHistory()
    }

    func clearLibrarySearchHistory() {
        try? store.clearLibrarySearchHistory()
        refreshLibrarySearchHistory()
    }

    func managedSmartSearchResults(
        matching query: String,
        onIntentUpdate: ((String) -> Void)? = nil
    ) async -> SmartLibrarySearchResponse {
        let response = await chat.smartSearchLibrary(
            query,
            managedRootPath: organizer.organizeRoot.standardizedFileURL.path,
            onIntentUpdate: onIntentUpdate
        )
        return response
    }

    func indexedChunks(fileID: Int64) -> [IndexedDocumentChunk] {
        (try? store.documentChunks(fileID: fileID)) ?? []
    }

    func recentlyOrganizedFiles(limit: Int = 4) -> [FileRecord] {
        let rootPath = organizer.organizeRoot.standardizedFileURL.path
        return files
            .filter { file in
                let path = URL(fileURLWithPath: file.path).standardizedFileURL.path
                return path.hasPrefix(rootPath + "/")
            }
            .sorted {
                let lhs = $0.organizedAt ?? $0.indexedAt ?? $0.discoveredAt ?? $0.mtime
                let rhs = $1.organizedAt ?? $1.indexedAt ?? $1.discoveredAt ?? $1.mtime
                return lhs > rhs
            }
            .prefix(limit)
            .map { $0 }
    }

    func refreshStatistics(days: Int = 14) {
        let safeDays = max(1, days)
        guard startsServicesAutomatically else {
            statistics = (try? store.statistics(days: safeDays)) ?? .empty
            return
        }
        if statisticsTask != nil {
            if activeStatisticsDays != safeDays { pendingStatisticsDays = safeDays }
            return
        }
        pendingStatisticsDays = safeDays
        startStatisticsRefreshIfNeeded()
    }

    private func startStatisticsRefreshIfNeeded() {
        guard statisticsTask == nil, let days = pendingStatisticsDays else { return }
        pendingStatisticsDays = nil
        activeStatisticsDays = days
        let store = store
        statisticsTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                (try? store.statistics(days: days)) ?? .empty
            }.value
            guard let self else { return }
            self.statistics = result
            self.statisticsTask = nil
            self.activeStatisticsDays = nil
            self.startStatisticsRefreshIfNeeded()
        }
    }

    func refreshModelServicesIfNeeded(force: Bool = false) async {
        await refreshModelServiceStatus()

        if let task = modelVersionCheckTask {
            await task.value
            return
        }
        guard force || settings.shouldCheckAIModelVersions() else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            async let ollamaUpdates: Void = ollama.checkForUpdates()
            async let doclingUpdates: Void = docling.checkForUpdates()
            async let paddleUpdates: Void = paddleOCR.checkForUpdates()
            _ = await (ollamaUpdates, doclingUpdates, paddleUpdates)
        }
        modelVersionCheckTask = task
        await task.value
        settings.setLastAIModelVersionCheckAt(Date())
        modelVersionCheckTask = nil
    }

    private func refreshModelServiceStatus() async {
        if let task = modelServiceStatusRefreshTask {
            await task.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            async let ollamaRefresh: Void = ollama.refresh(host: settings.ollamaHost)
            async let paddleRefresh: Void = paddleOCR.refresh()
            docling.refresh()
            async let rerankerRefresh: Void = reranker.refresh()
            _ = await (ollamaRefresh, paddleRefresh, rerankerRefresh)
            if settings.rerankerSource == AppSettings.RerankerSource.local.rawValue,
               RerankerServiceManager.isModelInstalled,
               !reranker.isRunning {
                await reranker.start()
            }
        }
        modelServiceStatusRefreshTask = task
        await task.value
        modelServiceStatusRefreshTask = nil
    }

    /// Long-lived local runtimes are owned by FileNest and must not outlive it.
    /// Docling and PaddleOCR use short-lived job subprocesses, so they have no daemon to stop here.
    func shutdownManagedServices() async {
        await reranker.shutdown()
        await ollama.stop(host: settings.ollamaHost)
    }

    func refreshChatSessions(selecting preferredID: Int64? = nil) {
        chatSessions = chat.loadSessions()
        if preferredID == nil, isDraftChat {
            selectedChatSessionID = nil
            chatMessages = []
            return
        }
        let candidate = preferredID ?? selectedChatSessionID
        if let candidate, chatSessions.contains(where: { $0.id == candidate }) {
            selectedChatSessionID = candidate
        } else {
            selectedChatSessionID = chatSessions.first?.id
        }
        if let selectedChatSessionID {
            switchChatComposerDraft(to: chatComposerDraftKey(sessionID: selectedChatSessionID))
            chatMessages = chat.loadHistory(sessionId: selectedChatSessionID)
        } else {
            switchChatComposerDraft(to: "new")
            chatMessages = []
        }
        isDraftChat = false
        draftChatAttachmentPath = nil
    }

    func markChatRunning(_ sessionID: Int64) {
        completedChatSessionIDs.remove(sessionID)
        runningChatSessionIDs.insert(sessionID)
    }

    func markChatCompleted(_ sessionID: Int64) {
        runningChatSessionIDs.remove(sessionID)
        completedChatSessionIDs.insert(sessionID)
    }

    func markChatStopped(_ sessionID: Int64) {
        runningChatSessionIDs.remove(sessionID)
    }

    func markChatSeen(_ sessionID: Int64) {
        completedChatSessionIDs.remove(sessionID)
    }

    func beginChatExecution(
        sessionID: Int64,
        userMessage: ChatMessage?,
        assistantMessage: ChatMessage,
        progress: ChatProgress
    ) {
        chatExecutionPresentations[sessionID] = ChatExecutionPresentation(
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            progress: progress
        )
        markChatRunning(sessionID)
    }

    func updateChatExecutionUserMessage(sessionID: Int64, message: ChatMessage) {
        guard var presentation = chatExecutionPresentations[sessionID] else { return }
        presentation.userMessage = message
        chatExecutionPresentations[sessionID] = presentation
    }

    func updateChatExecutionProgress(sessionID: Int64, progress: ChatProgress?) {
        guard var presentation = chatExecutionPresentations[sessionID] else { return }
        presentation.progress = progress
        chatExecutionPresentations[sessionID] = presentation
    }

    func appendChatExecutionDelta(sessionID: Int64, delta: String) {
        guard var presentation = chatExecutionPresentations[sessionID] else { return }
        presentation.progress = nil
        presentation.assistantMessage.content += delta
        chatExecutionPresentations[sessionID] = presentation
    }

    func completeChatExecution(sessionID: Int64, message: ChatMessage) {
        guard var presentation = chatExecutionPresentations[sessionID] else { return }
        presentation.progress = nil
        presentation.assistantMessage = message
        chatExecutionPresentations[sessionID] = presentation
    }

    func clearChatExecution(sessionID: Int64) {
        chatExecutionPresentations.removeValue(forKey: sessionID)
    }

    func presentedChatMessages(sessionID: Int64, persistedMessages: [ChatMessage]) -> [ChatMessage] {
        guard let presentation = chatExecutionPresentations[sessionID] else {
            return persistedMessages
        }
        var messages = persistedMessages
        if let userMessage = presentation.userMessage {
            upsertPresentedMessage(userMessage, into: &messages)
        }
        upsertPresentedMessage(presentation.assistantMessage, into: &messages)
        return messages
    }

    func refreshChatSessionsPreservingSelection() {
        refreshChatSessions(selecting: selectedChatSessionID)
    }

    private func upsertPresentedMessage(_ message: ChatMessage, into messages: inout [ChatMessage]) {
        if let id = message.id,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    func newChat(attachedFilePath: String? = nil) {
        fileChatReturnSessionID = nil
        fileChatReturnDestination = nil
        switchChatComposerDraft(to: "new", resetDestination: true)
        isDraftChat = true
        draftChatAttachmentPath = attachedFilePath
        selectedChatSessionID = nil
        chatMessages = []
    }

    func startFileChat(
        attachedFilePath: String,
        returnDestination: FileChatReturnDestination
    ) {
        let previousSessionID = selectedChatSessionID
        newChat(attachedFilePath: attachedFilePath)
        fileChatReturnSessionID = previousSessionID
        fileChatReturnDestination = returnDestination
    }

    @discardableResult
    func returnFromFileChat() -> FileChatReturnDestination {
        let destination = fileChatReturnDestination ?? .chat
        let previousSessionID = fileChatReturnSessionID
        fileChatReturnSessionID = nil
        fileChatReturnDestination = nil

        if let previousSessionID {
            selectChat(previousSessionID)
        } else {
            newChat()
        }
        return destination
    }

    func persistChatForQuestion() -> Int64? {
        if let selectedChatSessionID { return selectedChatSessionID }
        guard let session = chat.createSession(attachedFilePath: draftChatAttachmentPath),
              let id = session.id else { return nil }
        switchChatComposerDraft(to: chatComposerDraftKey(sessionID: id))
        isDraftChat = false
        selectedChatSessionID = id
        chatSessions = chat.loadSessions()
        draftChatAttachmentPath = nil
        return id
    }

    func selectChat(_ id: Int64) {
        guard selectedChatSessionID != id else { return }
        fileChatReturnSessionID = nil
        fileChatReturnDestination = nil
        switchChatComposerDraft(to: chatComposerDraftKey(sessionID: id))
        isDraftChat = false
        draftChatAttachmentPath = nil
        selectedChatSessionID = id
        chatMessages = chat.loadHistory(sessionId: id)
    }

    func attachFileToSelectedChat(_ path: String?) {
        if let selectedChatSessionID {
            _ = chat.updateAttachment(sessionId: selectedChatSessionID, path: path)
            refreshChatSessions(selecting: selectedChatSessionID)
        } else {
            isDraftChat = true
            draftChatAttachmentPath = path
        }
    }

    var currentChatAttachmentPath: String? {
        if let selectedChatSessionID {
            return chatSessions.first { $0.id == selectedChatSessionID }?.attachedFilePath
        }
        return draftChatAttachmentPath
    }

    func deleteChat(_ id: Int64) {
        runningChatSessionIDs.remove(id)
        completedChatSessionIDs.remove(id)
        chatExecutionPresentations.removeValue(forKey: id)
        chatComposerDrafts.removeValue(forKey: chatComposerDraftKey(sessionID: id))
        chat.deleteSession(id: id)
        refreshChatSessions()
    }

    func clearAllChats() {
        runningChatSessionIDs.removeAll()
        completedChatSessionIDs.removeAll()
        chatExecutionPresentations.removeAll()
        chat.clearHistory()
        chatComposerDrafts.removeAll()
        activeChatComposerDraftKey = "new"
        chatComposerInput = ""
        isDraftChat = true
        draftChatAttachmentPath = nil
        selectedChatSessionID = nil
        refreshChatSessions()
    }

    func updateChatComposerInput(_ value: String) {
        chatComposerInput = value
        chatComposerDrafts[activeChatComposerDraftKey] = value
    }

    private func chatComposerDraftKey(sessionID: Int64) -> String {
        "session:\(sessionID)"
    }

    private func switchChatComposerDraft(to key: String, resetDestination: Bool = false) {
        chatComposerDrafts[activeChatComposerDraftKey] = chatComposerInput
        if resetDestination { chatComposerDrafts.removeValue(forKey: key) }
        activeChatComposerDraftKey = key
        chatComposerInput = chatComposerDrafts[key] ?? ""
    }

    func selectSettingsSection(_ section: SettingsSection) {
        selectedSettingsSection = section
    }

    func presentOnboarding() {
        isOnboardingPresented = true
    }

    func completeOnboarding(organizeExistingFiles: Bool = false) {
        let directories = settings.watchDirs
        AppLogService.shared.write(
            "onboarding completed",
            category: .appConfiguration,
            level: .notice,
            metadata: [
                "directories": "\(directories.count)",
                "existingFiles": organizeExistingFiles ? "organize" : "preserve",
            ]
        )
        if organizeExistingFiles {
            watcher.clearPreservedEntries(in: directories)
        } else {
            watcher.preserveExistingEntries(in: directories)
        }
        settings.setOnboardingCompleted(true)
        isOnboardingPresented = false
        guard startsServicesAutomatically else { return }
        if !isWatching { startWatching() }
        if organizeExistingFiles {
            organizeExistingWatchDirectoryEntries(in: directories)
        }
    }

    func watchDirectoryInventories(for directories: [String]? = nil) -> [WatchDirectoryInventory] {
        FileWatcherService.inventories(
            for: directories ?? settings.watchDirs,
            enabledExtensions: settings.enabledExtensions,
            excludeHidden: settings.excludeHidden
        )
    }

    func watchDirectoryStatus(for path: String) -> WatchDirectoryStatus? {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return watchDirectoryStatuses.first { $0.path == normalized }
    }

    func retryWatchDirectoryAccess() {
        if isWatching {
            watcher.scanNow()
        } else {
            startWatching()
        }
        refreshWatchDirectoryStatusesFromDisk(preservingActiveState: true)
    }

    func openWatchDirectoryPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func preserveExistingWatchDirectoryEntries(in directories: [String]) {
        watcher.preserveExistingEntries(in: directories)
    }

    func clearPreservedWatchDirectoryEntries(in directories: [String]) {
        watcher.clearPreservedEntries(in: directories)
    }

    func organizeExistingWatchDirectoryEntries(in directories: [String]? = nil) {
        let paths = directories ?? settings.watchDirs
        guard !paths.isEmpty else { return }
        AppLogService.shared.write(
            "manual organization requested for watched directories",
            category: .organizeQueue,
            level: .notice,
            metadata: ["directories": "\(paths.count)"]
        )
        watcher.clearPreservedEntries(in: paths)
        organizeNow(in: paths, includePreservedEntries: true)
    }

    func startWatching() {
        watcher.start()
        isWatching = true
        refreshWatchDirectoryStatusesFromDisk()
        statusText = indexingState.isActive ? indexingStatusTitle : watchStatusTitle
    }

    func stopWatching() {
        watcher.stop()
        isWatching = false
        statusText = indexingState.isActive ? indexingStatusTitle : "Paused"
    }

    func organizeNow() {
        organizeNow(in: nil, includePreservedEntries: false)
    }

    private func organizeNow(in directories: [String]?, includePreservedEntries: Bool) {
        guard !organizationState.isActive,
              !indexingState.isActive,
              organizationTask == nil else { return }
        let token = UUID()
        organizationJobToken = token
        organizationState = .running
        organizationProgress = OrganizationJobProgress(
            phase: .preparing,
            completed: 0,
            total: 0,
            moved: 0,
            skipped: 0,
            failed: 0,
            currentFileName: nil,
            indexingStage: nil
        )
        statusText = organizationStatusTitle
        AppLogService.shared.write(
            "manual organization job started",
            category: .organizeQueue,
            level: .notice,
            metadata: [
                "directories": "\((directories ?? settings.watchDirs).count)",
                "includePreservedEntries": "\(includePreservedEntries)",
            ]
        )

        organizationTask = Task { [weak self] in
            guard let self else { return }
            await self.organizationGate.reset()
            let result = await self.watcher.organizePendingEntries(
                in: directories,
                includePreservedEntries: includePreservedEntries,
                checkpoint: { [organizationGate = self.organizationGate] in
                    await organizationGate.waitUntilRunnable()
                }
            ) { [weak self] progress in
                guard let self, self.organizationJobToken == token else { return }
                var displayedProgress = progress
                if self.organizationState == .paused {
                    self.organizationPhaseBeforePause = progress.phase
                    displayedProgress.phase = .paused
                }
                self.organizationProgress = displayedProgress
                if self.organizationState == .running {
                    self.statusText = self.organizationStatusTitle
                }
            }
            guard self.organizationJobToken == token else { return }
            let wasStopped = result.stopped || self.organizationState == .stopping || Task.isCancelled
            self.organizationState = wasStopped
                ? .stopped
                : (result.failed > 0 ? .failed : .completed)
            if var finalProgress = self.organizationProgress {
                finalProgress.phase = wasStopped
                    ? .stopped
                    : (result.failed > 0 ? .failed : .completed)
                finalProgress.currentFileName = nil
                finalProgress.indexingStage = nil
                self.organizationProgress = finalProgress
            }
            self.organizationTask = nil
            self.organizationJobToken = nil
            self.statusText = self.organizationStatusTitle
            self.refreshInBackground()
            AppLogService.shared.write(
                wasStopped ? "manual organization job stopped" : "manual organization job finished",
                category: .organizeQueue,
                level: result.failed > 0 ? .warning : .notice,
                metadata: [
                    "completed": "\(result.completed)",
                    "total": "\(result.total)",
                    "moved": "\(result.moved)",
                    "skipped": "\(result.skipped)",
                    "failed": "\(result.failed)",
                ]
            )
            self.pendingCompletedProcessingCount = 0
            self.lastCompletedProcessingFileName = nil
            self.postSystemNotification(
                titleKey: self.organizationStatusTitle,
                body: self.settings.localizedFormat(
                    "%d moved · %d skipped · %d failed",
                    result.moved,
                    result.skipped,
                    result.failed
                ),
                identifier: "filenest.organization.status"
            )
        }
    }

    func pauseOrganization() {
        guard organizationState == .running else { return }
        organizationPhaseBeforePause = organizationProgress?.phase ?? .preparing
        organizationState = .paused
        if var progress = organizationProgress {
            progress.phase = .paused
            organizationProgress = progress
        }
        statusText = organizationStatusTitle
        Task { await organizationGate.pause() }
    }

    func resumeOrganization() {
        guard organizationState == .paused else { return }
        organizationState = .running
        if var progress = organizationProgress {
            progress.phase = organizationPhaseBeforePause
            organizationProgress = progress
        }
        statusText = organizationStatusTitle
        Task { await organizationGate.resume() }
    }

    func stopOrganization() {
        guard organizationState == .running || organizationState == .paused else { return }
        organizationState = .stopping
        if var progress = organizationProgress {
            progress.phase = .stopping
            organizationProgress = progress
        }
        statusText = organizationStatusTitle
        organizationTask?.cancel()
        Task {
            await organizationGate.stop()
            await indexer.cancelAll()
        }
    }

    func reindexAll() {
        reindexUnindexedFileCount = (try? store.fileIndexCounts().unindexed) ?? 0
        pendingAdvancedReindexCategories = changedContentCategories()
        selectedAdvancedReindexCategories = []
        isEmbeddingChangeReindexSelected = true
        isUnindexedFilesReindexSelected = true
        selectedRAGReindexStages = hasEmbeddingConfigurationChange ? [.embeddings, .retrievalIndex] : []
        isFullPipelineReindexSelected = false
        isReindexAdvancedExpanded = false
        isIndexConfigurationPromptPresented = false
        reindexConfirmationStep = .selection
        if !Self.isRunningTests {
            MainWindowPresenter.shared.present()
        }
    }

    var hasDefaultEmbeddingRebuildSelection: Bool {
        isEmbeddingChangeReindexSelected && hasEmbeddingConfigurationChange
    }

    var hasEmbeddingConfigurationChange: Bool {
        store.getSetting(Self.appliedEmbeddingSignatureKey) != settings.embeddingSpaceSignature
    }

    var unindexedFileCount: Int {
        reindexUnindexedFileCount
    }

    var canAdvanceReindexConfirmation: Bool {
        hasDefaultEmbeddingRebuildSelection
            || (isUnindexedFilesReindexSelected && unindexedFileCount > 0)
            || !selectedAdvancedReindexCategories.isEmpty
            || !selectedRAGReindexStages.isEmpty
    }

    func setEmbeddingChangeReindexSelected(_ selected: Bool) {
        isEmbeddingChangeReindexSelected = selected
        if selected && hasEmbeddingConfigurationChange {
            selectedRAGReindexStages.formUnion(RAGReindexStage.embeddings.downstreamStages)
        } else if !selected {
            selectedRAGReindexStages.remove(.embeddings)
        }
    }

    func setUnindexedFilesReindexSelected(_ selected: Bool) {
        isUnindexedFilesReindexSelected = selected
    }

    func setAdvancedReindexCategory(_ category: IndexContentChangeCategory, selected: Bool) {
        guard pendingAdvancedReindexCategories.contains(category) else { return }
        if selected {
            selectedAdvancedReindexCategories.insert(category)
            selectedRAGReindexStages.formUnion(reindexStage(for: category).downstreamStages)
        } else {
            selectedAdvancedReindexCategories.remove(category)
        }
    }

    func setRAGReindexStage(_ stage: RAGReindexStage, selected: Bool) {
        isFullPipelineReindexSelected = false
        if selected {
            selectedRAGReindexStages.formUnion(stage.downstreamStages)
        } else {
            for candidate in RAGReindexStage.allCases
            where candidate.downstreamStages.contains(stage) {
                selectedRAGReindexStages.remove(candidate)
            }
            if stage == .embeddings { isEmbeddingChangeReindexSelected = false }
        }
        synchronizeAdvancedCategoriesFromStages()
    }

    func setFullPipelineReindexSelected(_ selected: Bool) {
        isFullPipelineReindexSelected = selected
        if selected {
            selectedRAGReindexStages = [
                .parsingAndOCR, .structuredChunking, .embeddings, .retrievalIndex,
            ]
            if settings.rerankerSource == AppSettings.RerankerSource.local.rawValue,
               RerankerServiceManager.isModelInstalled {
                selectedRAGReindexStages.insert(.rerankerRuntime)
            }
        } else {
            selectedRAGReindexStages = []
        }
        if selected {
            selectedAdvancedReindexCategories = pendingAdvancedReindexCategories
            isEmbeddingChangeReindexSelected = true
            isUnindexedFilesReindexSelected = true
        }
    }

    func hasDetectedChange(for stage: RAGReindexStage) -> Bool {
        switch stage {
        case .parsingAndOCR:
            return !pendingAdvancedReindexCategories.intersection([
                .documentParsing, .ocr, .indexingScope,
            ]).isEmpty
        case .structuredChunking:
            return pendingAdvancedReindexCategories.contains(.chunking)
        case .embeddings:
            return hasEmbeddingConfigurationChange
                || pendingAdvancedReindexCategories.contains(.serviceEndpoint)
        case .retrievalIndex:
            return false
        case .rerankerRuntime:
            if case .failed = reranker.state { return true }
            return settings.rerankerSource == AppSettings.RerankerSource.local.rawValue
                && RerankerServiceManager.isModelInstalled
                && !reranker.isRunning
        }
    }

    private func reindexStage(for category: IndexContentChangeCategory) -> RAGReindexStage {
        switch category {
        case .documentParsing, .ocr, .indexingScope: return .parsingAndOCR
        case .chunking: return .structuredChunking
        case .serviceEndpoint: return .embeddings
        }
    }

    private func synchronizeAdvancedCategoriesFromStages() {
        selectedAdvancedReindexCategories = Set(pendingAdvancedReindexCategories.filter {
            selectedRAGReindexStages.contains(reindexStage(for: $0))
        })
        isEmbeddingChangeReindexSelected = selectedRAGReindexStages.contains(.embeddings)
            && hasEmbeddingConfigurationChange
    }

    func advanceReindexConfirmation() {
        guard reindexConfirmationStep == .selection, canAdvanceReindexConfirmation else { return }
        reindexConfirmationStep = .finalConfirmation
    }

    func returnToReindexSelection() {
        guard reindexConfirmationStep == .finalConfirmation else { return }
        reindexConfirmationStep = .selection
    }

    func cancelReindexConfirmation() {
        reindexConfirmationStep = nil
        selectedAdvancedReindexCategories = []
        selectedRAGReindexStages = []
        isFullPipelineReindexSelected = false
    }

    func confirmReindex() {
        guard reindexConfirmationStep == .finalConfirmation else { return }
        let stages = selectedRAGReindexStages
        let rebuildEmbedding = stages.contains(.embeddings)
        let includeUnindexedFiles = isUnindexedFilesReindexSelected && unindexedFileCount > 0
        let forcesSourceReprocessing = stages.contains(.parsingAndOCR)
            || stages.contains(.structuredChunking)
        let contentCategories = selectedAdvancedReindexCategories
            .intersection(pendingAdvancedReindexCategories)
        let retrievalIndexOnly = stages.contains(.retrievalIndex)
            && !forcesSourceReprocessing
            && !rebuildEmbedding
        let restartsReranker = stages.contains(.rerankerRuntime)
        guard !stages.isEmpty || includeUnindexedFiles else { return }
        reindexConfirmationStep = nil
        selectedAdvancedReindexCategories = []
        selectedRAGReindexStages = []
        isFullPipelineReindexSelected = false
        isReindexAdvancedExpanded = false
        // Let SwiftUI commit the sheet dismissal before publishing indexing progress.
        // This avoids redrawing the sheet's first step during its close animation and
        // keeps index preparation out of the confirmation button's event cycle.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            if restartsReranker {
                Task { await self.reranker.restart() }
            }
            guard forcesSourceReprocessing || rebuildEmbedding || retrievalIndexOnly || includeUnindexedFiles else {
                return
            }
            _ = self.startReindex(
                kind: forcesSourceReprocessing
                    ? .fullReindex
                    : (rebuildEmbedding || retrievalIndexOnly ? .vectorRebuild : .fullReindex),
                rebuildVectorSpace: rebuildEmbedding,
                contentCategoriesToAcknowledge: contentCategories,
                onlyUnindexedFiles: includeUnindexedFiles && !forcesSourceReprocessing && !rebuildEmbedding && !retrievalIndexOnly,
                includeUnindexedFiles: includeUnindexedFiles && !forcesSourceReprocessing,
                retrievalIndexOnly: retrievalIndexOnly,
                forceSourceReprocessing: forcesSourceReprocessing
            )
        }
    }

    func rebuildVectorIndex() {
        startReindex(kind: .vectorRebuild, rebuildVectorSpace: true)
    }

    func pauseIndexing() {
        guard indexingState == .running else { return }
        AppLogService.shared.write(
            "indexing paused by user",
            category: .indexPipeline,
            level: .notice,
            metadata: ["kind": indexingKind.logName]
        )
        indexingState = .paused
        statusText = "Indexing Paused"
        updateProgressPhase(.paused)
        Task { await indexingGate.pause() }
    }

    func resumeIndexing() {
        guard indexingState == .paused else { return }
        AppLogService.shared.write(
            "indexing resumed by user",
            category: .indexPipeline,
            level: .notice,
            metadata: ["kind": indexingKind.logName]
        )
        indexingState = .running
        statusText = indexingStatusTitle
        updateProgressPhase(.indexing)
        Task { await indexingGate.resume() }
    }

    func stopIndexing() {
        guard indexingState == .running || indexingState == .paused else { return }
        AppLogService.shared.write(
            "indexing stop requested by user",
            category: .indexPipeline,
            level: .notice,
            metadata: ["kind": indexingKind.logName]
        )
        indexingState = .stopping
        statusText = "Stopping Indexing"
        updateProgressPhase(.stopping)
        reindexTask?.cancel()
        managedSyncIndexTask?.cancel()
        Task {
            await indexingGate.stop()
            await indexer.cancelAll()
        }
    }

    func restartIndexing() {
        guard indexingState == .stopped || indexingState == .failed || indexingState == .completed else { return }
        if lastIndexingKind == .automatic {
            indexingState = .idle
            vectorIndexRebuildProgress = nil
            refresh()
        } else {
            startReindex(
                kind: lastIndexingKind,
                rebuildVectorSpace: lastRebuildVectorSpace,
                contentCategoriesToAcknowledge: lastReindexContentCategories,
                onlyUnindexedFiles: lastOnlyUnindexedFiles,
                includeUnindexedFiles: lastIncludeUnindexedFiles,
                retrievalIndexOnly: lastRetrievalIndexOnly,
                forceSourceReprocessing: lastForceSourceReprocessing
            )
        }
    }

    @discardableResult
    private func startReindex(
        kind: IndexingTaskKind,
        rebuildVectorSpace: Bool,
        contentCategoriesToAcknowledge: Set<IndexContentChangeCategory> = [],
        onlyUnindexedFiles: Bool = false,
        includeUnindexedFiles: Bool = false,
        retrievalIndexOnly: Bool = false,
        forceSourceReprocessing: Bool = false
    ) -> Bool {
        guard !indexingState.blocksReindexButtons,
              managedSyncIndexTask == nil,
              reindexTask == nil else { return false }
        lastIndexingKind = kind
        lastRebuildVectorSpace = rebuildVectorSpace
        lastOnlyUnindexedFiles = onlyUnindexedFiles
        lastIncludeUnindexedFiles = includeUnindexedFiles
        lastRetrievalIndexOnly = retrievalIndexOnly
        lastForceSourceReprocessing = forceSourceReprocessing
        lastReindexContentCategories = contentCategoriesToAcknowledge
        let targetEmbeddingSignature = settings.embeddingSpaceSignature
        let counts = (try? store.fileIndexCounts()) ?? (
            total: files.count,
            indexed: files.filter { $0.indexedAt != nil }.count,
            unindexed: files.filter { $0.indexedAt == nil }.count
        )
        let total: Int
        if retrievalIndexOnly {
            total = indexer.vectorStore.count + (includeUnindexedFiles ? counts.unindexed : 0)
        } else if forceSourceReprocessing {
            total = counts.total
        } else if rebuildVectorSpace {
            total = counts.indexed + (includeUnindexedFiles ? counts.unindexed : 0)
        } else if onlyUnindexedFiles {
            total = counts.unindexed
        } else {
            total = counts.total
        }
        AppLogService.shared.write(
            "reindex requested",
            category: .indexPipeline,
            level: .notice,
            metadata: [
                "contentCategories": contentCategoriesToAcknowledge
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: ","),
                "kind": kind.logName,
                "includeUnindexedFiles": "\(includeUnindexedFiles)",
                "onlyUnindexedFiles": "\(onlyUnindexedFiles)",
                "rebuildVectorSpace": "\(rebuildVectorSpace)",
                "retrievalIndexOnly": "\(retrievalIndexOnly)",
                "forceSourceReprocessing": "\(forceSourceReprocessing)",
                "total": "\(total)",
            ]
        )
        beginIndexing(kind: kind, total: total)

        reindexTask = Task { [weak self] in
            guard let self else { return }
            await self.indexingGate.reset()
            let progressHandler: @MainActor (VectorIndexRebuildProgress) -> Void = { [weak self] progress in
                guard let self else { return }
                self.vectorIndexRebuildProgress = progress
                if self.indexingState != .paused && self.indexingState != .stopping {
                    self.statusText = self.indexingStatusTitle
                }
            }
            let succeeded: Bool
            if retrievalIndexOnly {
                let retrievalSucceeded = await self.indexer.rebuildRetrievalIndex(progress: progressHandler)
                if retrievalSucceeded && includeUnindexedFiles {
                    succeeded = await self.indexer.rebuildAll(
                        onlyUnindexedFiles: true,
                        checkpoint: { [indexingGate = self.indexingGate] in
                            await indexingGate.waitUntilRunnable()
                        },
                        progress: progressHandler
                    )
                } else {
                    succeeded = retrievalSucceeded
                }
            } else {
                succeeded = await self.indexer.rebuildAll(
                    rebuildVectorSpace: rebuildVectorSpace,
                    forceReprocessing: forceSourceReprocessing,
                    onlyUnindexedFiles: onlyUnindexedFiles,
                    includeUnindexedFiles: includeUnindexedFiles,
                    checkpoint: { [indexingGate = self.indexingGate] in
                        await indexingGate.waitUntilRunnable()
                    },
                    progress: progressHandler
                )
            }

            let stopped = self.indexingState == .stopping || self.vectorIndexRebuildProgress?.phase == .stopped
            let progress = self.vectorIndexRebuildProgress
            self.reindexTask = nil
            if succeeded {
                if rebuildVectorSpace {
                    self.store.setSetting(
                        Self.appliedEmbeddingSignatureKey,
                        targetEmbeddingSignature
                    )
                }
                self.acknowledgeContentCategories(contentCategoriesToAcknowledge)
            }
            self.finishIndexing(
                stopped: stopped,
                succeeded: succeeded,
                completed: progress?.completed ?? 0,
                total: progress?.total ?? total,
                failed: progress?.failed ?? 0
            )
            self.refresh(allowManagedIndexing: succeeded)
            // Retry failed model rebuilds on the next launch or settings change to avoid an immediate infinite loop.
            if kind != .vectorRebuild || succeeded {
                self.refreshIndexConfigurationState()
            }
        }
        return true
    }

    private func beginIndexing(kind: IndexingTaskKind, total: Int) {
        AppLogService.shared.write(
            "indexing task started",
            category: .indexPipeline,
            metadata: ["kind": kind.logName, "total": "\(total)"]
        )
        indexingKind = kind
        lastIndexingKind = kind
        indexingState = .running
        vectorIndexRebuildProgress = VectorIndexRebuildProgress(
            phase: .preparing,
            completed: 0,
            total: total,
            currentFileName: nil,
            failed: 0
        )
        statusText = indexingStatusTitle
    }

    private func finishIndexing(
        stopped: Bool,
        succeeded: Bool,
        completed: Int,
        total: Int,
        failed: Int
    ) {
        AppLogService.shared.write(
            "indexing task finished",
            category: .indexPipeline,
            level: stopped ? .warning : (succeeded ? .notice : .error),
            metadata: [
                "completed": "\(completed)",
                "failed": "\(failed)",
                "kind": indexingKind.logName,
                "result": stopped ? "stopped" : (succeeded ? "succeeded" : "failed"),
                "total": "\(total)",
            ]
        )
        if stopped {
            indexingState = .stopped
            vectorIndexRebuildProgress = VectorIndexRebuildProgress(
                phase: .stopped,
                completed: completed,
                total: total,
                currentFileName: nil,
                failed: failed
            )
        } else {
            indexingState = succeeded ? .completed : .failed
            vectorIndexRebuildProgress = VectorIndexRebuildProgress(
                phase: succeeded ? .completed : .failed,
                completed: completed,
                total: total,
                currentFileName: nil,
                failed: failed
            )
        }
        statusText = indexingStatusTitle
        postSystemNotification(
            titleKey: indexingStatusTitle,
            body: settings.localizedFormat(
                "Processed %d of %d files",
                completed,
                total
            ),
            identifier: "filenest.indexing.status"
        )
    }

    private func updateProgressPhase(_ phase: VectorIndexRebuildProgress.Phase) {
        let progress = vectorIndexRebuildProgress ?? VectorIndexRebuildProgress(
            phase: phase,
            completed: 0,
            total: (try? store.allFiles().count) ?? 0,
            currentFileName: nil,
            failed: 0
        )
        vectorIndexRebuildProgress = VectorIndexRebuildProgress(
            phase: phase,
            completed: progress.completed,
            total: progress.total,
            currentFileName: progress.currentFileName,
            failed: progress.failed
        )
    }

    private func restoreSteadyStatus(after nanoseconds: UInt64) {
        Task {
            try? await Task.sleep(nanoseconds: nanoseconds)
            refresh()
            statusText = indexingState.isActive
                ? indexingStatusTitle
                : watchStatusTitle
        }
    }

    private func applyWatchDirectoryStatuses(_ statuses: [WatchDirectoryStatus]) {
        watchDirectoryStatuses = statuses
        guard !indexingState.isActive else { return }
        statusText = watchStatusTitle
    }

    private func refreshWatchDirectoryStatusesFromDisk(preservingActiveState: Bool = false) {
        let activePaths = preservingActiveState
            ? Set(watchDirectoryStatuses.filter(\.isWatching).map(\.path))
            : []
        watchDirectoryStatuses = watchDirectoryInventories().map { inventory in
            WatchDirectoryStatus(
                path: inventory.path,
                accessState: inventory.accessState,
                isWatching: isWatching && activePaths.contains(inventory.path)
            )
        }
    }
}

enum FileTrashError: LocalizedError {
    case fileMissing

    var errorDescription: String? { "The file was moved or deleted." }
}
