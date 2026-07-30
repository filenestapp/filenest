import Foundation
import SwiftUI
import Combine
import AppKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case indexing
    case reindexActivity
    case aiModels
    case aiSkills
    case statistics
    case rules

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: return "General"
        case .indexing: return "Index & Organize"
        case .reindexActivity: return "Reindex Task"
        case .aiModels: return "AI Models"
        case .aiSkills: return "AI Skills"
        case .statistics: return "Statistics"
        case .rules: return "Organization Rules"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .indexing: return "folder.badge.gearshape"
        case .reindexActivity: return "list.bullet.clipboard"
        case .aiModels: return "cpu"
        case .aiSkills: return "brain.head.profile"
        case .statistics: return "chart.bar.xaxis"
        case .rules: return "list.bullet.rectangle.portrait"
        }
    }

    var detail: String {
        switch self {
        case .general: return "General settings and application behavior"
        case .indexing: return "Control indexing, organization, and file processing"
        case .reindexActivity: return "Monitor the active reindex queue and control its progress"
        case .aiModels: return "Configure chat, embedding, OCR, and local services"
        case .aiSkills: return "Review and manage learned AI skills"
        case .statistics: return "Review file, index, token, and storage activity"
        case .rules: return "Create and manage file organization rules"
        }
    }

    var group: SettingsSectionGroup {
        switch self {
        case .general, .indexing, .reindexActivity: return .fileManagement
        case .aiModels, .aiSkills: return .artificialIntelligence
        case .statistics, .rules: return .insights
        }
    }

    func matchesSettingsSearch(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        let searchableText = "\(label) \(detail) \(searchKeywords)"
        return searchableText.localizedCaseInsensitiveContains(normalized)
    }

    private var searchKeywords: String {
        switch self {
        case .general:
            return "language appearance shortcut logs updates folders watching"
        case .indexing:
            return "index chunks vectors embedding organize OCR document media duplicate"
        case .reindexActivity:
            return "reindex task queue progress failed pending pause resume stop"
        case .aiModels:
            return "Ollama cloud API model reranker Docling PaddleOCR Whisper FFmpeg"
        case .aiSkills:
            return "feedback learning prompt skills rating"
        case .statistics:
            return "usage storage tokens files charts"
        case .rules:
            return "rules folders extensions ignore classification"
        }
    }
}

enum SettingsSectionGroup: String, CaseIterable, Identifiable {
    case fileManagement
    case artificialIntelligence
    case insights

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fileManagement: return "File Management"
        case .artificialIntelligence: return "Artificial Intelligence"
        case .insights: return "Insights"
        }
    }
}

enum IndexingTaskState: Equatable, Sendable {
    case idle
    case running
    case paused
    case stopping
    case stopped
    case completed
    case completedWithErrors
    case failed

    var isActive: Bool {
        self == .running || self == .paused || self == .stopping
    }

    var isAnimating: Bool {
        self == .running || self == .stopping
    }

    var blocksReindexButtons: Bool { isActive }
}

enum IndexingCompletionOutcome: Equatable, Sendable {
    case completed
    case completedWithErrors
    case failed
    case stopped

    init(
        stopped: Bool,
        operationSucceeded: Bool,
        successfulFiles: Int,
        failedFiles: Int
    ) {
        if stopped {
            self = .stopped
        } else if operationSucceeded {
            self = .completed
        } else if failedFiles > 0, successfulFiles > 0 {
            self = .completedWithErrors
        } else {
            self = .failed
        }
    }
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

enum LibrarySearchMode: String, Equatable, Sendable {
    case standard
    case smart
}

/// Application-owned search state. Keeping this outside LibraryView lets retrieval
/// continue when the user navigates to chat or settings.
struct LibrarySearchActivity: Equatable {
    let id: UUID
    let query: String
    let mode: LibrarySearchMode
    let categories: Set<FileCategory>
    let startedAt: Date
    var isActive: Bool
    var wasCancelled: Bool
    var stage: LibrarySearchProgressStage?
    var intent: String
    var results: [LibrarySearchResult]?
    var smartPlan: SmartLibrarySearchPlan?
    var usedAI: Bool
    var completedAt: Date?
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

private struct PendingOrganizationJob: Codable {
    let directories: [String]?
    let includePreservedEntries: Bool
    let recursively: Bool
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

    var isAnimating: Bool {
        if case .duplicate = stage { return false }
        return isActive
    }

    var title: String {
        switch stage {
        case .queued: return "Queued for processing"
        case .duplicate: return "Duplicate file needs review"
        case .indexing: return "Indexing file"
        case .waitingForOrganization: return "Waiting to organize"
        case .organizing: return "Organizing file"
        case .completed: return "Processing complete"
        case .failed: return "Processing failed"
        }
    }

    var subtitle: String {
        switch stage {
        case let .duplicate(originalFileName): return originalFileName
        case let .indexing(indexingStage): return indexingStage.statusText
        case let .failed(message): return detail ?? message
        default: return detail ?? fileName
        }
    }

    var progress: Double? {
        switch stage {
        case .queued: return 0.04
        case .duplicate: return nil
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
    let ragLearning: RAGLearningService
    let agentSkills: AgentSkillService
    let ollama: OllamaServiceManager
    let reranker: RerankerServiceManager
    let docling: DoclingServiceManager
    let paddleOCR: PaddleOCRServiceManager
    let ffmpeg: FFmpegServiceManager
    let whisper: WhisperServiceManager
    let updates: AppUpdateService

    @Published var statusText = "Ready"
    @Published var indexedCount: Int = 0
    @Published var isWatching = false
    @Published private(set) var watchDirectoryStatuses: [WatchDirectoryStatus] = []

    // Data sources for the library, chat, and other UI.
    @Published var files: [FileRecord] = []
    @Published private(set) var recentOrganizedFiles: [FileRecord] = []
    @Published private(set) var previewedFile: FileRecord?
    @Published var rules: [Rule] = []
    @Published var chatSessions: [ChatSession] = []
    @Published var selectedChatSessionID: Int64?
    @Published var chatMessages: [ChatMessage] = []
    @Published private(set) var hasEarlierChatMessages = false
    @Published private(set) var runningChatSessionIDs = Set<Int64>()
    @Published private(set) var completedChatSessionIDs = Set<Int64>()
    @Published private(set) var chatExecutionPresentations = [Int64: ChatExecutionPresentation]()
    @Published private(set) var draftChatAttachmentPath: String?
    @Published private(set) var chatComposerInput = ""
    @Published private(set) var librarySearchRequest: LibrarySearchRequest?
    @Published private(set) var librarySearchPresentationID: UUID?
    @Published private(set) var librarySearchHistory: [LibrarySearchHistoryEntry] = []
    @Published private(set) var librarySearchActivity: LibrarySearchActivity?
    @Published private(set) var hasUnreadCompletedLibrarySearch = false
    @Published private(set) var ragFeedbackRecords: [RAGFeedbackRecord] = []
    @Published private(set) var aiSystemSkills: [AISystemSkill] = []
    @Published private(set) var installedAgentSkills: [AgentSkill] = []
    @Published private(set) var agentSkillDiagnostics: [AgentSkillDiagnostic] = []
    @Published private(set) var fileCreationDates = [String: Date]()
    @Published private(set) var duplicateFileGroups: [DuplicateFileGroup] = []
    @Published private(set) var duplicateScanProgress: DuplicateScanProgress?
    @Published private(set) var duplicateTrashProgress: DuplicateTrashProgress?
    @Published private(set) var duplicateScanError: String?
    @Published private(set) var quickSearchShortcutRegistrationError: String?
    @Published var statistics: AppStatistics = .empty
    @Published var selectedSettingsSection: SettingsSection = .general
    @Published private(set) var isSettingsPresented = false
    @Published var isOnboardingPresented = false
    @Published private(set) var indexingState: IndexingTaskState = .idle
    @Published private(set) var organizationState: OrganizationTaskState = .idle
    @Published private(set) var organizationProgress: OrganizationJobProgress?
    @Published private(set) var automaticFileProcessingItems: [AutomaticFileProcessingItem] = []
    @Published private(set) var indexingKind: IndexingTaskKind = .automatic
    @Published private(set) var vectorIndexRebuildProgress: VectorIndexRebuildProgress?
    @Published private(set) var reindexJobSummary: ReindexJobSummary?
    @Published private(set) var isIndexConfigurationPromptPresented = false
    @Published private(set) var hasPendingAutomaticEmbeddingRebuild = false
    @Published private(set) var reindexConfirmationStep: ReindexConfirmationStep?
    @Published private(set) var pendingAdvancedReindexCategories = Set<IndexContentChangeCategory>()
    @Published private(set) var selectedAdvancedReindexCategories = Set<IndexContentChangeCategory>()
    @Published private(set) var isEmbeddingChangeReindexSelected = true
    @Published private(set) var isUnindexedFilesReindexSelected = true
    /// Limits a configuration-driven transcription rebuild to files whose media transcript can change.
    @Published private(set) var isAffectedMediaOnlyReindexSelected = false
    @Published private(set) var selectedReindexFileCategories = Set<FileCategory>()
    @Published private(set) var reindexUnindexedFileCount = 0
    @Published private(set) var selectedRAGReindexStages = Set<RAGReindexStage>()
    @Published private(set) var isFullPipelineReindexSelected = false
    @Published var isReindexAdvancedExpanded = false

    private var cancellables = Set<AnyCancellable>()
    private var managedSyncIndexIDs = Set<Int64>()
    private var managedSyncIndexTask: Task<Void, Never>?
    private var scheduledRefreshTask: Task<Void, Never>?
    private var backgroundRefreshTask: Task<Void, Never>?
    private var librarySearchTask: Task<Void, Never>?
    private var librarySearchViewIsVisible = false
    private var librarySearchStageStartedAt: Date?
    private var librarySearchStageDurations = [String: Int]()
    private var librarySearchTemporarilyPausedIndexing = false
    private var refreshGeneration: UInt64 = 0
    private var statisticsTask: Task<Void, Never>?
    private var activeStatisticsDays: Int?
    private var pendingStatisticsDays: Int?
    private var pendingStatisticsForceModelRefresh = false
    private var statisticsViewIsVisible = false
    private var statisticsIsDirty = true
    private var lastStatisticsRefreshAt: Date?
    private var lastStatisticsDays: Int?
    private var creationDateRefreshTask: Task<Void, Never>?
    private var lastCreationDateRefreshAt: Date?
    private var modelServiceStatusRefreshTask: Task<Void, Never>?
    private var servicePresentationRefreshTask: Task<Void, Never>?
    private var modelVersionCheckTask: Task<Void, Never>?
    private var reindexTask: Task<Void, Never>?
    private var activeReindexJobID: Int64?
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
    private var lastOnlyMediaFiles = false
    private var lastReindexFileCategories = Set<FileCategory>()
    private var lastRetrievalIndexOnly = false
    private var lastForceSourceReprocessing = false
    private var lastIndexingKind: IndexingTaskKind = .fullReindex
    private var lastReindexContentCategories = Set<IndexContentChangeCategory>()
    private var isDraftChat = false
    private var chatComposerDrafts: [String: String] = [:]
    private var libraryFilesByID = [Int64: FileRecord]()
    private var libraryFilesByPath = [String: FileRecord]()
    private var activeChatComposerDraftKey = "new"
    private var fileChatReturnSessionID: Int64?
    private var fileChatReturnDestination: FileChatReturnDestination?
    private var hasPreparedInitialMainView = false
    private let globalHotKeyService = GlobalHotKeyService()
    private var quickSearchPanelController: QuickSearchPanelController?
    private let systemNotificationsEnabled: Bool
    private let shouldSynchronizeManagedFiles: Bool
    private let shouldIndexManagedFiles: Bool
    private let startsServicesAutomatically: Bool
    private static let appliedEmbeddingSignatureKey = "index.applied_embedding_space_signature.v1"
    private static let acknowledgedContentSignatureKey = "index.acknowledged_content_processing_signature.v1"
    private static let mediaTranscriptionSignatureMigrationKey = "index.media_transcription_signature_migration.v1"
    private static let pendingOrganizationJobKey = "organization.pending_manual_job.v1"
    private static let chatHistoryPageSize = 40

    private static func appliedContentSignatureKey(_ category: IndexContentChangeCategory) -> String {
        "index.applied_content_category.\(category.rawValue).v1"
    }

    var isRebuildingVectorIndex: Bool {
        indexingKind == .vectorRebuild && indexingState.isActive
    }

    var indexingProgress: VectorIndexRebuildProgress? { vectorIndexRebuildProgress }
    var reindexButtonsDisabled: Bool { indexingState.blocksReindexButtons }
    var hasReindexActivity: Bool {
        reindexJobSummary != nil || (indexingKind != .automatic && indexingState.isActive)
    }
    var isScanningForDuplicates: Bool { duplicateScanProgress != nil }
    var isRemovingDuplicates: Bool { duplicateTrashProgress != nil }
    var duplicateConfirmationFileCount: Int { files.filter { $0.duplicateOfFileID != nil }.count }

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
        case .completedWithErrors: return "Indexing Completed with Errors"
        case .failed: return "Indexing Failed"
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
         indexer providedIndexer: IndexerService? = nil,
         startAutomatically: Bool = !AppState.isRunningTests) {
        self.store = store
        self.settings = settings
        self.startsServicesAutomatically = startAutomatically
        self.systemNotificationsEnabled = startAutomatically
        self.updates = AppUpdateService(settings: settings, enabled: startAutomatically)
        self.shouldSynchronizeManagedFiles = organizeRoot != nil || !AppState.isRunningTests
        self.shouldIndexManagedFiles = startAutomatically
        let organizer = OrganizerService(store: store, settings: settings, organizeRoot: organizeRoot)
        let indexer = providedIndexer ?? IndexerService(store: store, settings: settings)
        let agentSkills = AgentSkillService(store: store)
        _ = agentSkills.refresh()
        agentSkills.migrateLegacySkills((try? store.allAISystemSkills()) ?? [])
        let chat = ChatService(
            store: store,
            settings: settings,
            vectorStore: indexer.vectorStore,
            skillService: agentSkills
        )
        let ragLearning = RAGLearningService(
            store: store,
            settings: settings,
            skillService: agentSkills
        )
        let ollama = OllamaServiceManager()
        let reranker = RerankerServiceManager()
        let docling = DoclingServiceManager()
        let paddleOCR = PaddleOCRServiceManager()
        let ffmpeg = FFmpegServiceManager()
        let whisper = WhisperServiceManager()
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
        self.ragLearning = ragLearning
        self.agentSkills = agentSkills
        self.ollama = ollama
        self.reranker = reranker
        self.docling = docling
        self.paddleOCR = paddleOCR
        self.ffmpeg = ffmpeg
        self.whisper = whisper
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
        watcher.onLibraryChange = { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleLibraryRefresh() }
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
            .sink { [weak self] _ in self?.scheduleServicePresentationRefresh() }
            .store(in: &cancellables)
        reranker.objectWillChange
            .sink { [weak self] _ in self?.scheduleServicePresentationRefresh() }
            .store(in: &cancellables)
        docling.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleServicePresentationRefresh()
                DispatchQueue.main.async { [weak self] in
                    self?.refreshIndexConfigurationState()
                }
            }
            .store(in: &cancellables)
        paddleOCR.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleServicePresentationRefresh()
                DispatchQueue.main.async { [weak self] in
                    self?.refreshIndexConfigurationState()
                }
            }
            .store(in: &cancellables)
        ffmpeg.objectWillChange
            .sink { [weak self] _ in self?.scheduleServicePresentationRefresh() }
            .store(in: &cancellables)
        whisper.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleServicePresentationRefresh()
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
        refreshInBackground(allowManagedIndexing: false, synchronizeManagedFiles: true)
        let initialLibraryRefreshTask = backgroundRefreshTask
        Task { [weak self] in
            guard let self else { return }
            async let vectorWarmup: Void = indexer.warmup()
            await initialLibraryRefreshTask?.value
            await vectorWarmup
            // A resumed job may immediately need Ollama, Docling, OCR, or media runtimes.
            // Wait for configured local services to be ready instead of racing startup.
            await self.refreshModelServiceStatus()
            if self.resumePendingReindexIfNeeded() {
                self.isIndexConfigurationPromptPresented = false
            } else {
                _ = await organizer.invalidateChangedManagedFileIndexes()
                if !self.refreshIndexConfigurationState() {
                    self.refreshInBackground()
                }
            }
        }
        refreshChatSessions()
        refreshLibrarySearchHistory()
        refreshRAGLearningState()
        // Do not scan folders before initial setup completes; the user must first decide how to handle existing files.
        if settings.onboardingCompleted {
            startWatching()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.resumePendingOrganizationIfNeeded()
            }
        }
        Task { [weak self] in
            await self?.refreshModelServiceStatus()
        }
        if settings.llmChoice != AppSettings.LLMChoice.none.rawValue {
            Task { @MainActor [weak self] in
                await self?.ragLearning.processPendingFeedback()
                self?.refreshRAGLearningState()
            }
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
        case let .duplicate(originalFileName):
            postSystemNotification(
                titleKey: "Duplicate File Detected",
                body: settings.localizedFormat(
                    "%@ matches %@. Review duplicate files before deleting.",
                    resolvedFileName ?? event.fileName,
                    originalFileName
                ),
                identifier: "filenest.duplicate.detected.\(event.fileID)"
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
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.refreshInBackground()
            self.scheduledRefreshTask = nil
        }
    }

    /// Service managers publish several changes during a single probe or model
    /// download. Coalescing their presentation updates prevents those progress
    /// changes from invalidating the entire application view tree repeatedly.
    private func scheduleServicePresentationRefresh() {
        guard servicePresentationRefreshTask == nil else { return }
        servicePresentationRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.objectWillChange.send()
            self.servicePresentationRefreshTask = nil
        }
    }

    func refresh(allowManagedIndexing: Bool = true) {
        // Production refreshes can enumerate managed folders and decode the full
        // library. Keep the synchronous path only for deterministic test setup.
        guard !startsServicesAutomatically else {
            refreshInBackground(allowManagedIndexing: allowManagedIndexing)
            return
        }
        refreshGeneration &+= 1
        _ = try? store.removeTransientFiles(preservingRoot: organizer.organizeRoot)
        let refreshedFiles: [FileRecord]
        if shouldSynchronizeManagedFiles {
            refreshedFiles = organizer.reconcileManagedFiles()
        } else {
            refreshedFiles = ((try? store.libraryFiles()) ?? []).filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
        }
        applyLibrarySnapshot(
            files: refreshedFiles,
            rules: (try? store.allRules()) ?? [],
            recentFiles: (try? store.recentlyOrganizedFiles(
                rootPath: organizer.organizeRoot.standardizedFileURL.path,
                limit: 4
            )) ?? [],
            allowManagedIndexing: allowManagedIndexing
        )
    }

    func refreshInBackground(
        allowManagedIndexing: Bool = true,
        synchronizeManagedFiles: Bool = false
    ) {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let startedAt = Date()
        backgroundRefreshTask?.cancel()
        let store = store
        let organizer = organizer
        let organizeRoot = organizer.organizeRoot
        let shouldSynchronizeManagedFiles = shouldSynchronizeManagedFiles && synchronizeManagedFiles
        backgroundRefreshTask = Task { [weak self] in
            let refreshedFiles: [FileRecord]
            if shouldSynchronizeManagedFiles {
                refreshedFiles = await organizer.reconcileManagedFilesAsync()
            } else {
                refreshedFiles = await Task.detached(priority: .utility) {
                    (try? store.libraryFiles()) ?? []
                }.value
            }
            let sortedFiles = await Task.detached(priority: .utility) {
                FileRecord.sortedByNewestAdded(refreshedFiles)
            }.value
            async let refreshedRulesTask: [Rule] = Task.detached(priority: .utility) {
                (try? store.allRules()) ?? []
            }.value
            async let recentFilesTask: [FileRecord] = Task.detached(priority: .utility) {
                (try? store.recentlyOrganizedFiles(
                    rootPath: organizeRoot.standardizedFileURL.path,
                    limit: 4
                )) ?? []
            }.value
            let (refreshedRules, refreshedRecentFiles) = await (
                refreshedRulesTask,
                recentFilesTask
            )
            guard let self,
                  !Task.isCancelled,
                  self.refreshGeneration == generation else { return }
            self.applyLibrarySnapshot(
                files: sortedFiles,
                rules: refreshedRules,
                recentFiles: refreshedRecentFiles,
                allowManagedIndexing: allowManagedIndexing,
                filesAreSorted: true
            )
            let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
            if durationMilliseconds >= 250 {
                AppLogService.shared.write(
                    "library snapshot refreshed",
                    category: .performance,
                    metadata: [
                        "durationMs": "\(durationMilliseconds)",
                        "files": "\(refreshedFiles.count)",
                        "managed": "\(shouldSynchronizeManagedFiles)",
                    ]
                )
            }
            self.backgroundRefreshTask = nil
        }
    }

    private func applyLibrarySnapshot(
        files refreshedFiles: [FileRecord],
        rules refreshedRules: [Rule],
        recentFiles refreshedRecentFiles: [FileRecord],
        allowManagedIndexing: Bool,
        filesAreSorted: Bool = false
    ) {
        let sortedFiles = filesAreSorted
            ? refreshedFiles
            : FileRecord.sortedByNewestAdded(refreshedFiles)
        let libraryChanged = files != sortedFiles
        if libraryChanged {
            files = sortedFiles
            libraryFilesByID = Dictionary(uniqueKeysWithValues: sortedFiles.compactMap { file in
                file.id.map { ($0, file) }
            })
            libraryFilesByPath = Dictionary(uniqueKeysWithValues: sortedFiles.map { ($0.path, $0) })
        }
        if let previewedFile {
            let refreshedPreview = previewedFile.id.flatMap { libraryFilesByID[$0] }
                ?? libraryFilesByPath[previewedFile.path]
            let resolvedPreview = refreshedPreview ?? (
                FileManager.default.fileExists(atPath: previewedFile.path) ? previewedFile : nil
            )
            if self.previewedFile != resolvedPreview {
                self.previewedFile = resolvedPreview
            }
        }
        if rules != refreshedRules { rules = refreshedRules }
        if recentOrganizedFiles != refreshedRecentFiles {
            recentOrganizedFiles = refreshedRecentFiles
        }
        let refreshedIndexedCount = sortedFiles.filter { $0.indexedAt != nil }.count
        if indexedCount != refreshedIndexedCount { indexedCount = refreshedIndexedCount }
        if shouldIndexManagedFiles && allowManagedIndexing { indexNewManagedFilesIfNeeded() }
        if libraryChanged { markStatisticsDirty() }
    }

    private func indexNewManagedFilesIfNeeded() {
        guard managedSyncIndexTask == nil,
              reindexTask == nil,
              indexingState != .stopped,
              !indexingState.isActive else { return }
        let ids = files.compactMap { file -> Int64? in
            guard !FileEligibilityPolicy.shouldIgnoreFile(named: file.name),
                  file.duplicateOfFileID == nil,
                  file.indexedAt == nil,
                  let id = file.id,
                  managedSyncIndexIDs.insert(id).inserted else { return nil }
            return id
        }
        guard !ids.isEmpty else { return }
        // The indexer applies a conservative adaptive concurrency cap during large backfills.
        beginIndexing(kind: .automatic, total: ids.count)
        managedSyncIndexTask = Task { [weak self] in
            guard let self else { return }
            await self.indexingGate.reset()
            let records = ids.compactMap { try? self.store.file(id: $0) }
            let result = await self.indexer.indexFiles(
                records,
                executionGate: self.indexingGate,
                progress: { [weak self] progress in
                self?.vectorIndexRebuildProgress = progress
                }
            )
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
        migrateMediaTranscriptionSignaturesIfNeeded()
        let appliedEmbeddingSignature = store.getSetting(Self.appliedEmbeddingSignatureKey)
        hasPendingAutomaticEmbeddingRebuild = appliedEmbeddingSignature != settings.embeddingSpaceSignature

        if activeReindexJobID != nil || store.hasResumableReindexJob() {
            isIndexConfigurationPromptPresented = false
            return indexingState.isActive
        }

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

    /// Splits the new media-transcription signature from the old document and scope signatures
    /// without turning an app upgrade into an accidental full-library source rebuild. If media
    /// transcription is already enabled, leave its new signature unapplied so the confirmation
    /// flow can offer the targeted media-only rebuild instead.
    private func migrateMediaTranscriptionSignaturesIfNeeded() {
        guard store.getSetting(Self.mediaTranscriptionSignatureMigrationKey) == nil else { return }
        defer { store.setSetting(Self.mediaTranscriptionSignatureMigrationKey, "1") }
        guard store.getSetting(Self.appliedContentSignatureKey(.documentParsing)) != nil else { return }
        let signatures = settings.indexContentCategorySignatures
        if let signature = signatures[.documentParsing] {
            store.setSetting(Self.appliedContentSignatureKey(.documentParsing), signature)
        }
        if let signature = signatures[.indexingScope] {
            store.setSetting(Self.appliedContentSignatureKey(.indexingScope), signature)
        }
        if !settings.mediaTranscriptionEnabled,
           let signature = signatures[.mediaTranscription] {
            store.setSetting(Self.appliedContentSignatureKey(.mediaTranscription), signature)
        }
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
        previewedFile = file
    }

    /// Toggles the inspector for a file. Keeping this decision in shared state makes
    /// every file entry point follow the same open/close behavior.
    func toggleFilePreview(_ file: FileRecord) {
        if isPreviewing(file) {
            closeFilePreview()
        } else {
            presentFilePreview(file)
        }
    }

    func toggleFilePreview(fileID: Int64) {
        guard let file = try? store.file(id: fileID) else { return }
        toggleFilePreview(file)
    }

    func presentAttachedFilePreview(path: String) {
        if let record = files.first(where: { $0.path == path }) ?? (try? store.file(path: path)) {
            toggleFilePreview(record)
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
        toggleFilePreview(record)
    }

    func closeFilePreview() {
        previewedFile = nil
    }

    /// Prevents an inspector for one file from remaining visible in an unrelated chat.
    func closeFilePreviewUnlessMatchingAttachment(_ attachmentPath: String?) {
        guard let previewedFile else { return }
        guard let attachmentPath,
              previewedFile.path == attachmentPath else {
            closeFilePreview()
            return
        }
    }

    private func isPreviewing(_ file: FileRecord) -> Bool {
        guard let previewedFile else { return false }
        if let fileID = file.id, let previewID = previewedFile.id {
            return fileID == previewID
        }
        return previewedFile.path == file.path
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

    func presentCompletedLibrarySearch() {
        guard librarySearchActivity?.results != nil else { return }
        dismissSettings()
        closeFilePreview()
        librarySearchPresentationID = UUID()
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

    /// This intentionally does not hash files. It only restores groups that can
    /// already be determined from the persisted SHA-256 values, allowing the
    /// duplicate manager to open immediately without starting a new scan.
    func loadKnownDuplicateFileGroups() {
        guard !isScanningForDuplicates, !isRemovingDuplicates else { return }
        duplicateFileGroups = DuplicateFileGroup.groups(from: files)
        duplicateScanError = nil
    }

    /// Computes SHA-256 hashes from the current bytes on disk. Stored hashes are
    /// updated as a cache, but every scan verifies the content again so a stale
    /// index can never cause an incorrect duplicate recommendation.
    func scanForDuplicateFiles() async {
        let candidates = files.filter {
            !$0.isDirectory && FileManager.default.fileExists(atPath: $0.path)
        }
        duplicateScanError = nil
        duplicateFileGroups = []
        duplicateScanProgress = DuplicateScanProgress(scannedCount: 0, totalCount: candidates.count)
        guard !candidates.isEmpty else {
            duplicateScanProgress = nil
            return
        }

        var scannedFiles = [FileRecord]()
        scannedFiles.reserveCapacity(candidates.count)

        for (index, file) in candidates.enumerated() {
            guard !Task.isCancelled else {
                duplicateScanProgress = nil
                return
            }
            let filePath = file.path
            let hash = await Task.detached(priority: .utility) {
                try? FileContentHasher.sha256(of: URL(fileURLWithPath: filePath))
            }.value
            if let hash {
                var hashedFile = file
                hashedFile.contentHash = hash
                scannedFiles.append(hashedFile)
                if let id = file.id { try? store.updateFileContentHash(id: id, contentHash: hash) }
            }
            duplicateScanProgress = DuplicateScanProgress(
                scannedCount: index + 1,
                totalCount: candidates.count
            )
        }

        guard !Task.isCancelled else {
            duplicateScanProgress = nil
            return
        }
        let hashesByPath = Dictionary(uniqueKeysWithValues: scannedFiles.compactMap { file -> (String, String)? in
            guard let hash = file.contentHash else { return nil }
            return (file.path, hash)
        })
        files = files.map { file in
            var updated = file
            if let hash = hashesByPath[file.path] { updated.contentHash = hash }
            return updated
        }
        duplicateFileGroups = DuplicateFileGroup.groups(from: scannedFiles)
        duplicateScanProgress = nil
        AppLogService.shared.write(
            "duplicate file scan completed",
            category: .appLifecycle,
            metadata: [
                "scanned": "\(scannedFiles.count)",
                "groups": "\(duplicateFileGroups.count)",
            ]
        )
    }

    /// Moves only user-selected duplicate copies to the macOS Trash. The retained
    /// original in each duplicate group is never included in this operation.
    func moveDuplicateFilesToTrash(paths: Set<String>) async -> DuplicateTrashResult {
        let duplicateEntries = duplicateFileGroups.flatMap { group in
            group.duplicateFiles.map { (file: $0, expectedHash: group.contentHash) }
        }
        let duplicatesByPath = Dictionary(uniqueKeysWithValues: duplicateEntries.map {
            ($0.file.path, $0)
        })
        let selectedFiles = paths.compactMap { duplicatesByPath[$0] }
        var movedCount = 0
        var failedFileNames = [String]()
        var movedPaths = Set<String>()
        duplicateTrashProgress = DuplicateTrashProgress(
            completedCount: 0,
            totalCount: selectedFiles.count,
            currentFileName: selectedFiles.first?.file.name
        )

        for (index, entry) in selectedFiles.enumerated() {
            duplicateTrashProgress = DuplicateTrashProgress(
                completedCount: index,
                totalCount: selectedFiles.count,
                currentFileName: entry.file.name
            )
            let filePath = entry.file.path
            let currentHash = await Task.detached(priority: .utility) {
                try? FileContentHasher.sha256(of: URL(fileURLWithPath: filePath))
            }.value
            guard currentHash == entry.expectedHash else {
                failedFileNames.append(entry.file.name)
                applyAutomaticFileProcessing(AutomaticFileProcessingEvent(
                    fileID: entry.file.id ?? -1,
                    fileName: entry.file.name,
                    stage: .failed("Duplicate file changed")
                ))
                duplicateTrashProgress = DuplicateTrashProgress(
                    completedCount: index + 1,
                    totalCount: selectedFiles.count,
                    currentFileName: entry.file.name
                )
                continue
            }
            do {
                try await moveFileToTrash(entry.file)
                movedCount += 1
                movedPaths.insert(entry.file.path)
                applyAutomaticFileProcessing(AutomaticFileProcessingEvent(
                    fileID: entry.file.id ?? -1,
                    fileName: entry.file.name,
                    stage: .completed
                ))
            } catch {
                failedFileNames.append(entry.file.name)
                applyAutomaticFileProcessing(AutomaticFileProcessingEvent(
                    fileID: entry.file.id ?? -1,
                    fileName: entry.file.name,
                    stage: .failed("Could not move duplicate to Trash")
                ))
            }
            duplicateTrashProgress = DuplicateTrashProgress(
                completedCount: index + 1,
                totalCount: selectedFiles.count,
                currentFileName: entry.file.name
            )
        }
        duplicateTrashProgress = nil
        if !movedPaths.isEmpty {
            // The just-scanned groups already contain the exact retained files and
            // hashes. Remove only the files moved to Trash instead of starting a
            // second full SHA-256 scan immediately after the delete queue finishes.
            duplicateFileGroups = duplicateFileGroups.compactMap { group in
                let remainingFiles = group.files.filter { !movedPaths.contains($0.path) }
                guard remainingFiles.count > 1 else { return nil }
                return DuplicateFileGroup(contentHash: group.contentHash, files: remainingFiles)
            }
        }
        return DuplicateTrashResult(movedCount: movedCount, failedFileNames: failedFileNames)
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

    func setLibrarySearchViewVisible(_ isVisible: Bool) {
        librarySearchViewIsVisible = isVisible
        if isVisible {
            hasUnreadCompletedLibrarySearch = false
        }
    }

    func startLibrarySearch(
        matching rawQuery: String,
        mode: LibrarySearchMode,
        categories: Set<FileCategory> = [],
        recordHistory: Bool,
        debounceNanoseconds: UInt64 = 0
    ) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearLibrarySearch()
            return
        }

        librarySearchTask?.cancel()
        let activity = LibrarySearchActivity(
            id: UUID(),
            query: query,
            mode: mode,
            categories: categories,
            startedAt: Date(),
            isActive: true,
            wasCancelled: false,
            stage: mode == .smart ? .analyzingQuery : .matchingMetadata,
            intent: "",
            results: nil,
            smartPlan: nil,
            usedAI: false,
            completedAt: nil
        )
        librarySearchActivity = activity
        hasUnreadCompletedLibrarySearch = false
        librarySearchStageStartedAt = activity.startedAt
        librarySearchStageDurations = [:]
        AppLogService.shared.write(
            "library search started",
            category: .searchLifecycle,
            metadata: [
                "categories": "\(categories.count)",
                "mode": mode.rawValue,
                "searchID": String(activity.id.uuidString.prefix(8)).lowercased(),
            ]
        )

        librarySearchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }
            guard self.isCurrentLibrarySearch(activity.id), !Task.isCancelled else { return }

            if categories.isEmpty,
               let cached = self.cachedLibrarySearch(
                   matching: query,
                   isSmartSearch: mode == .smart
               ) {
                if recordHistory {
                    self.saveLibrarySearch(
                        query: query,
                        results: cached.results,
                        smartPlan: cached.smartPlan,
                        usedAI: cached.usedAI,
                        recordHistory: true
                    )
                }
                self.completeLibrarySearch(
                    id: activity.id,
                    results: cached.results,
                    smartPlan: cached.smartPlan,
                    usedAI: cached.usedAI,
                    cacheHit: true
                )
                return
            }

            let indexingPauseTask = self.prioritizeLibrarySearchOverIndexing()
            switch mode {
            case .standard:
                if let indexingPauseTask {
                    _ = await indexingPauseTask.value
                }
                let quickResults = await self.managedQuickSearchResults(
                    matching: query,
                    categories: categories,
                    onStage: { [weak self] stage in
                        Task { @MainActor [weak self] in
                            self?.transitionLibrarySearch(id: activity.id, to: stage)
                        }
                    }
                )
                guard self.isCurrentLibrarySearch(activity.id), !Task.isCancelled else { return }
                self.transitionLibrarySearch(id: activity.id, to: .matchingContent)
                self.updateLibrarySearch(id: activity.id) { $0.results = quickResults }
                do {
                    try await Task.sleep(nanoseconds: 650_000_000)
                } catch {
                    return
                }
                guard self.isCurrentLibrarySearch(activity.id), !Task.isCancelled else { return }
                let results = await self.managedSearchResults(
                    matching: query,
                    categories: categories,
                    onStage: { [weak self] stage in
                        Task { @MainActor [weak self] in
                            self?.transitionLibrarySearch(id: activity.id, to: stage)
                        }
                    }
                )
                guard self.isCurrentLibrarySearch(activity.id), !Task.isCancelled else { return }
                if categories.isEmpty {
                    self.saveLibrarySearch(
                        query: query,
                        results: results,
                        recordHistory: recordHistory
                    )
                }
                self.completeLibrarySearch(
                    id: activity.id,
                    results: results,
                    smartPlan: nil,
                    usedAI: false,
                    cacheHit: false
                )

            case .smart:
                let response = await self.managedSmartSearchResults(
                    matching: query,
                    categories: categories,
                    onIntentUpdate: { [weak self] intent in
                        Task { @MainActor [weak self] in
                            self?.updateLibrarySearch(id: activity.id) { $0.intent = intent }
                        }
                    },
                    onStage: { [weak self] stage in
                        Task { @MainActor [weak self] in
                            self?.transitionLibrarySearch(id: activity.id, to: stage)
                        }
                    },
                    beforeRetrieval: {
                        if let indexingPauseTask {
                            _ = await indexingPauseTask.value
                        }
                    }
                )
                guard self.isCurrentLibrarySearch(activity.id), !Task.isCancelled else { return }
                if categories.isEmpty {
                    self.saveLibrarySearch(
                        query: query,
                        results: response.results,
                        smartPlan: response.plan,
                        usedAI: response.usedAI,
                        recordHistory: recordHistory
                    )
                }
                self.completeLibrarySearch(
                    id: activity.id,
                    results: response.results,
                    smartPlan: response.plan,
                    usedAI: response.usedAI,
                    cacheHit: false
                )
            }
        }
    }

    func cancelLibrarySearch() {
        guard let activity = librarySearchActivity, activity.isActive else { return }
        librarySearchTask?.cancel()
        librarySearchTask = nil
        recordCurrentLibrarySearchStage(id: activity.id)
        updateLibrarySearch(id: activity.id) {
            $0.isActive = false
            $0.wasCancelled = true
            $0.stage = nil
            $0.intent = ""
            $0.completedAt = Date()
        }
        AppLogService.shared.write(
            "library search cancelled",
            category: .searchLifecycle,
            metadata: [
                "durationMs": "\(Int(Date().timeIntervalSince(activity.startedAt) * 1_000))",
                "mode": activity.mode.rawValue,
                "searchID": String(activity.id.uuidString.prefix(8)).lowercased(),
            ]
        )
        restoreIndexingAfterLibrarySearch()
    }

    func clearLibrarySearch() {
        librarySearchTask?.cancel()
        librarySearchTask = nil
        librarySearchActivity = nil
        librarySearchStageStartedAt = nil
        librarySearchStageDurations = [:]
        hasUnreadCompletedLibrarySearch = false
        restoreIndexingAfterLibrarySearch()
    }

    private func isCurrentLibrarySearch(_ id: UUID) -> Bool {
        librarySearchActivity?.id == id
    }

    private func updateLibrarySearch(
        id: UUID,
        _ update: (inout LibrarySearchActivity) -> Void
    ) {
        guard var activity = librarySearchActivity, activity.id == id else { return }
        update(&activity)
        librarySearchActivity = activity
    }

    private func transitionLibrarySearch(
        id: UUID,
        to stage: LibrarySearchProgressStage
    ) {
        guard let activity = librarySearchActivity,
              activity.id == id,
              activity.isActive,
              activity.stage != stage else { return }
        recordCurrentLibrarySearchStage(id: id)
        updateLibrarySearch(id: id) { $0.stage = stage }
        librarySearchStageStartedAt = Date()
    }

    private func recordCurrentLibrarySearchStage(id: UUID) {
        guard let activity = librarySearchActivity,
              activity.id == id,
              let stage = activity.stage,
              let stageStartedAt = librarySearchStageStartedAt else { return }
        let duration = Int(Date().timeIntervalSince(stageStartedAt) * 1_000)
        librarySearchStageDurations[stage.logName, default: 0] += max(0, duration)
        librarySearchStageStartedAt = nil
    }

    private func completeLibrarySearch(
        id: UUID,
        results: [LibrarySearchResult],
        smartPlan: SmartLibrarySearchPlan?,
        usedAI: Bool,
        cacheHit: Bool
    ) {
        guard let activity = librarySearchActivity, activity.id == id else { return }
        recordCurrentLibrarySearchStage(id: id)
        let completedAt = Date()
        updateLibrarySearch(id: id) {
            $0.results = results
            $0.smartPlan = smartPlan
            $0.usedAI = usedAI
            $0.isActive = false
            $0.wasCancelled = false
            $0.stage = nil
            $0.completedAt = completedAt
        }
        librarySearchTask = nil

        var metadata = librarySearchStageDurations.mapValues(String.init)
        metadata["cacheHit"] = "\(cacheHit)"
        metadata["durationMs"] = "\(Int(completedAt.timeIntervalSince(activity.startedAt) * 1_000))"
        metadata["mode"] = activity.mode.rawValue
        metadata["results"] = "\(results.count)"
        metadata["searchID"] = String(activity.id.uuidString.prefix(8)).lowercased()
        AppLogService.shared.write(
            "library search stage timings completed",
            category: .searchPerformance,
            metadata: metadata
        )
        restoreIndexingAfterLibrarySearch()

        guard !librarySearchViewIsVisible else { return }
        hasUnreadCompletedLibrarySearch = true
        let bodyKey = activity.mode == .smart
            ? "Smart Search found %d related files."
            : "Search found %d related files."
        postSystemNotification(
            titleKey: "Search Complete",
            body: settings.localizedFormat(bodyKey, results.count),
            identifier: "filenest.search.complete"
        )
    }

    private func prioritizeLibrarySearchOverIndexing() -> Task<Bool, Never>? {
        guard !librarySearchTemporarilyPausedIndexing,
              indexingState == .running else { return nil }
        librarySearchTemporarilyPausedIndexing = true
        indexingState = .paused
        statusText = "Indexing Paused for Search"
        updateProgressPhase(.paused)
        AppLogService.shared.write(
            "indexing temporarily paused for interactive search",
            category: .searchLifecycle,
            metadata: ["kind": indexingKind.logName]
        )
        return Task { await indexingGate.pauseAndDrain() }
    }

    private func restoreIndexingAfterLibrarySearch() {
        guard librarySearchTemporarilyPausedIndexing else { return }
        librarySearchTemporarilyPausedIndexing = false
        guard indexingState == .paused else { return }
        indexingState = .running
        statusText = indexingStatusTitle
        updateProgressPhase(.indexing)
        AppLogService.shared.write(
            "indexing resumed after interactive search",
            category: .searchLifecycle,
            metadata: ["kind": indexingKind.logName]
        )
        Task { await indexingGate.resume() }
    }

    func managedSearchResults(
        matching keyword: String,
        categories: Set<FileCategory> = [],
        onStage: ((LibrarySearchProgressStage) -> Void)? = nil
    ) async -> [LibrarySearchResult] {
        let startedAt = Date()
        let results = await chat.searchLibrary(
            keyword,
            managedRootPath: organizer.organizeRoot.standardizedFileURL.path,
            includeSemantic: true,
            allowedCategories: categories,
            onStage: onStage
        )
        logLibrarySearchPerformance(
            mode: "semantic",
            startedAt: startedAt,
            resultCount: results.count
        )
        return results
    }

    func managedQuickSearchResults(
        matching keyword: String,
        categories: Set<FileCategory> = [],
        onStage: ((LibrarySearchProgressStage) -> Void)? = nil
    ) async -> [LibrarySearchResult] {
        let startedAt = Date()
        let results = await chat.searchLibrary(
            keyword,
            managedRootPath: organizer.organizeRoot.standardizedFileURL.path,
            includeSemantic: false,
            includeChunkContent: false,
            allowedCategories: categories,
            onStage: onStage
        )
        logLibrarySearchPerformance(
            mode: "keyword",
            startedAt: startedAt,
            resultCount: results.count
        )
        return results
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
              let cached = try? JSONDecoder().decode(CachedLibrarySearchPayload.self, from: record.payload),
              cached.pipelineVersion == CachedLibrarySearchPayload.currentPipelineVersion else {
            return nil
        }

        if libraryFilesByPath.isEmpty {
            let currentFiles = files.isEmpty ? ((try? store.libraryFiles()) ?? []) : files
            libraryFilesByID = Dictionary(uniqueKeysWithValues: currentFiles.compactMap { file in
                file.id.map { ($0, file) }
            })
            libraryFilesByPath = Dictionary(uniqueKeysWithValues: currentFiles.map { ($0.path, $0) })
        }
        let filesByID = libraryFilesByID
        let filesByPath = libraryFilesByPath
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
                pageEnd: result.pageEnd,
                evidence: result.evidence
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
            pipelineVersion: CachedLibrarySearchPayload.currentPipelineVersion,
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

    func refreshRAGLearningState() {
        ragFeedbackRecords = (try? store.ragFeedbackRecords()) ?? []
        aiSystemSkills = (try? store.allAISystemSkills()) ?? []
        installedAgentSkills = agentSkills.refresh()
        agentSkillDiagnostics = agentSkills.diagnostics()
    }

    func processPendingRAGFeedbackIfPossible() {
        guard settings.llmChoice != AppSettings.LLMChoice.none.rawValue else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.ragLearning.processPendingFeedback()
            self.refreshRAGLearningState()
        }
    }

    @discardableResult
    func submitChatFeedback(
        message: ChatMessage,
        rating: RAGFeedbackRating,
        reason: String?,
        bestFileID: Int64?,
        bestFileReason: String?
    ) -> RAGFeedbackRecord? {
        guard let messageID = message.id,
              let sessionID = message.sessionId else { return nil }
        do {
            let record = try store.upsertRAGFeedback(
                messageID: messageID,
                sessionID: sessionID,
                rating: rating,
                reason: reason,
                bestFileID: bestFileID,
                bestFileReason: bestFileReason
            )
            var updatedMessage = message
            updatedMessage.feedback = rating == .accurate ? "helpful" : "notHelpful"
            try? store.updateChatMessage(updatedMessage)
            refreshRAGLearningState()
            scheduleRAGFeedbackAnalysis(record.id)
            return record
        } catch {
            AppLogService.shared.write(
                "chat RAG feedback persistence failed",
                category: .chat,
                level: .error,
                metadata: ["message_id": "\(messageID)", "error": error.localizedDescription]
            )
            return nil
        }
    }

    @discardableResult
    func submitSearchFeedback(
        query: String,
        isSmartSearch: Bool,
        results: [LibrarySearchResult],
        rating: RAGFeedbackRating,
        reason: String?,
        bestFileID: Int64?,
        bestFileReason: String?
    ) -> RAGFeedbackRecord? {
        let fileIDs = results.compactMap(\.file.id)
        do {
            let record = try store.upsertSearchFeedback(
                query: query,
                sourceKind: isSmartSearch ? .smartSearch : .search,
                resultFileIDs: fileIDs,
                rating: rating,
                reason: reason,
                bestFileID: bestFileID,
                bestFileReason: bestFileReason
            )
            refreshRAGLearningState()
            scheduleRAGFeedbackAnalysis(record.id)
            return record
        } catch {
            AppLogService.shared.write(
                "library RAG feedback persistence failed",
                category: .chat,
                level: .error,
                metadata: ["query": query, "error": error.localizedDescription]
            )
            return nil
        }
    }

    func retryRAGFeedbackAnalysis(_ feedback: RAGFeedbackRecord) {
        scheduleRAGFeedbackAnalysis(feedback.id)
    }

    func removeChatFeedback(message: ChatMessage) {
        guard let messageID = message.id else { return }
        try? store.deleteRAGFeedback(messageID: messageID)
        var updatedMessage = message
        updatedMessage.feedback = nil
        try? store.updateChatMessage(updatedMessage)
        refreshRAGLearningState()
    }

    func setAISystemSkillEnabled(_ skill: AISystemSkill, enabled: Bool) {
        guard let id = skill.id else { return }
        try? store.setAISystemSkillEnabled(id: id, enabled: enabled)
        refreshRAGLearningState()
    }

    func deleteAISystemSkill(_ skill: AISystemSkill) {
        guard let id = skill.id else { return }
        try? store.deleteAISystemSkill(id: id)
        refreshRAGLearningState()
    }

    func setAgentSkillEnabled(_ skill: AgentSkill, enabled: Bool) {
        agentSkills.setEnabled(skill, enabled: enabled)
        // Bundled skills are a fixed product baseline.  Do not let an attempted UI
        // toggle disable the legacy mirror either, otherwise a later migration can
        // produce an inconsistent managed state.
        guard skill.origin != .bundled else {
            refreshRAGLearningState()
            return
        }
        if let legacy = aiSystemSkills.first(where: { $0.key == skill.name }),
           let id = legacy.id {
            try? store.setAISystemSkillEnabled(id: id, enabled: enabled)
        }
        refreshRAGLearningState()
    }

    func deleteManagedAgentSkill(_ skill: AgentSkill) {
        do {
            try agentSkills.removeManagedSkill(skill)
            if let legacy = aiSystemSkills.first(where: { $0.key == skill.name }),
               let id = legacy.id {
                try? store.deleteAISystemSkill(id: id)
            }
        } catch {
            AppLogService.shared.write(
                "managed Agent Skill removal failed",
                category: .chat,
                level: .error,
                metadata: ["skill": skill.name, "error": error.localizedDescription]
            )
        }
        refreshRAGLearningState()
    }

    func revealAgentSkillsFolder() {
        try? FileManager.default.createDirectory(
            at: agentSkills.managedDirectory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([agentSkills.managedDirectory])
    }

    func importAgentSkillPackage(from skillFileURL: URL) throws {
        _ = try agentSkills.importSkillPackage(from: skillFileURL)
        refreshRAGLearningState()
    }

    private func scheduleRAGFeedbackAnalysis(_ id: Int64?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.ragLearning.analyzeFeedback(id: id)
            self.refreshRAGLearningState()
        }
    }

    func managedSmartSearchResults(
        matching query: String,
        categories: Set<FileCategory> = [],
        onIntentUpdate: ((String) -> Void)? = nil,
        onStage: ((LibrarySearchProgressStage) -> Void)? = nil,
        beforeRetrieval: (() async -> Void)? = nil
    ) async -> SmartLibrarySearchResponse {
        let startedAt = Date()
        let response = await chat.smartSearchLibrary(
            query,
            managedRootPath: organizer.organizeRoot.standardizedFileURL.path,
            allowedCategories: categories,
            onIntentUpdate: onIntentUpdate,
            onStage: onStage,
            beforeRetrieval: beforeRetrieval
        )
        logLibrarySearchPerformance(
            mode: "smart",
            startedAt: startedAt,
            resultCount: response.results.count
        )
        return response
    }

    private func logLibrarySearchPerformance(
        mode: String,
        startedAt: Date,
        resultCount: Int
    ) {
        AppLogService.shared.write(
            "library search completed",
            category: .performance,
            metadata: [
                "durationMs": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
                "mode": mode,
                "results": "\(resultCount)",
            ]
        )
    }

    func indexedChunks(fileID: Int64) -> [IndexedDocumentChunk] {
        (try? store.documentChunks(fileID: fileID)) ?? []
    }

    func indexedChunkCount(fileID: Int64) async -> Int {
        let store = store
        return await Task.detached(priority: .utility) {
            (try? store.documentChunkCount(fileID: fileID)) ?? 0
        }.value
    }

    func loadIndexedChunks(
        fileID: Int64,
        offset: Int = 0,
        limit: Int? = nil
    ) async -> [IndexedDocumentChunk] {
        let store = store
        return await Task.detached(priority: .utility) {
            (try? store.documentChunks(fileID: fileID, limit: limit, offset: offset)) ?? []
        }.value
    }

    func recentlyOrganizedFiles(limit: Int = 4) -> [FileRecord] {
        Array(recentOrganizedFiles.prefix(max(0, limit)))
    }

    func setStatisticsViewVisible(_ isVisible: Bool) {
        statisticsViewIsVisible = isVisible
    }

    func markStatisticsDirty() {
        statisticsIsDirty = true
        guard statisticsViewIsVisible else { return }
        refreshStatistics(days: lastStatisticsDays ?? 14)
    }

    func refreshStatistics(
        days: Int = 14,
        force: Bool = false,
        forceModelStorageRefresh: Bool = false
    ) {
        let safeDays = max(1, days)
        if !force,
           !statisticsIsDirty,
           lastStatisticsDays == safeDays,
           let lastStatisticsRefreshAt,
           Date().timeIntervalSince(lastStatisticsRefreshAt) < 5 * 60 {
            return
        }
        guard startsServicesAutomatically else {
            let modelBytes = store.cachedLocalModelStorageBytes(forceRefresh: forceModelStorageRefresh)
            statistics = (try? store.statistics(days: safeDays, localModelBytes: modelBytes)) ?? .empty
            statisticsIsDirty = false
            lastStatisticsDays = safeDays
            lastStatisticsRefreshAt = Date()
            return
        }
        if statisticsTask != nil {
            if activeStatisticsDays != safeDays || force || forceModelStorageRefresh {
                pendingStatisticsDays = safeDays
            }
            pendingStatisticsForceModelRefresh = pendingStatisticsForceModelRefresh || forceModelStorageRefresh
            return
        }
        pendingStatisticsDays = safeDays
        pendingStatisticsForceModelRefresh = forceModelStorageRefresh
        startStatisticsRefreshIfNeeded()
    }

    private func startStatisticsRefreshIfNeeded() {
        guard statisticsTask == nil, let days = pendingStatisticsDays else { return }
        pendingStatisticsDays = nil
        let forceModelStorageRefresh = pendingStatisticsForceModelRefresh
        pendingStatisticsForceModelRefresh = false
        activeStatisticsDays = days
        statisticsIsDirty = false
        let store = store
        statisticsTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let modelBytes = store.cachedLocalModelStorageBytes(forceRefresh: forceModelStorageRefresh)
                return (try? store.statistics(days: days, localModelBytes: modelBytes)) ?? .empty
            }.value
            guard let self else { return }
            self.statistics = result
            self.lastStatisticsDays = days
            self.lastStatisticsRefreshAt = Date()
            self.statisticsTask = nil
            self.activeStatisticsDays = nil
            if self.statisticsIsDirty, self.statisticsViewIsVisible {
                self.pendingStatisticsDays = self.pendingStatisticsDays ?? days
            }
            self.startStatisticsRefreshIfNeeded()
        }
    }

    /// Loads cached creation dates from SQLite and fills only one bounded filesystem batch.
    /// Repeated Library navigation therefore never stats every file in the collection.
    func refreshPersistedCreationDates(force: Bool = false, batchSize: Int = 256) {
        guard creationDateRefreshTask == nil else { return }
        if !force,
           let lastCreationDateRefreshAt,
           Date().timeIntervalSince(lastCreationDateRefreshAt) < 10 * 60 {
            return
        }
        lastCreationDateRefreshAt = Date()
        let store = store
        creationDateRefreshTask = Task { [weak self] in
            let dates = await Task.detached(priority: .utility) { () -> [String: Date] in
                let candidates = (try? store.fileCreationDateBackfillCandidates(limit: batchSize)) ?? []
                var resolvedByID = [Int64: Date]()
                for candidate in candidates {
                    guard !Task.isCancelled else { break }
                    let url = URL(fileURLWithPath: candidate.path)
                    let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                        ?? candidate.fallback
                    resolvedByID[candidate.fileID] = createdAt
                }
                try? store.saveFileCreationDates(resolvedByID)
                return (try? store.fileCreationDates()) ?? [:]
            }.value
            guard let self else { return }
            self.fileCreationDates = dates
            self.creationDateRefreshTask = nil
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
            async let ollamaRefresh: Void = refreshAndStartConfiguredOllama()
            async let paddleRefresh: Void = paddleOCR.refresh()
            docling.refresh()
            async let rerankerRefresh: Void = reranker.refresh()
            ffmpeg.refresh()
            whisper.refresh()
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

    private func refreshAndStartConfiguredOllama() async {
        let host = settings.ollamaHost
        await ollama.refresh(host: host)
        guard settings.requiresOllamaService else {
            AppLogService.shared.write(
                "Ollama automatic startup skipped because no active provider requires it",
                category: .appLifecycle,
                level: .debug
            )
            return
        }
        guard OllamaServiceManager.isLocalServiceHost(host) else {
            AppLogService.shared.write(
                "Ollama automatic startup skipped for a remote service host",
                category: .appLifecycle,
                level: .notice,
                metadata: ["host": host]
            )
            return
        }
        guard ollama.state != .running else { return }
        guard ollama.executablePath != nil else {
            AppLogService.shared.write(
                "Ollama automatic startup could not find an installed executable",
                category: .appLifecycle,
                level: .warning
            )
            return
        }

        AppLogService.shared.write(
            "Ollama automatic startup requested",
            category: .appLifecycle,
            level: .notice,
            metadata: ["host": host]
        )
        await ollama.start(
            host: host,
            flashAttentionEnabled: settings.ollamaFlashAttentionEnabled
        )
    }

    /// Long-lived local runtimes are owned by FileNest and must not outlive it.
    /// Active indexing tasks are cancelled first, then persistent provider workers
    /// receive a graceful shutdown request before model services are stopped.
    func shutdownManagedServices() async {
        watcher.stop()
        librarySearchTask?.cancel()
        let activeOrganizationTask = organizationTask
        let activeReindexTask = reindexTask
        let activeManagedSyncTask = managedSyncIndexTask

        // Keep the persisted job descriptor so a manual organization can restart safely after
        // the next launch. The worker will rescan source folders and skip files already moved.
        if activeOrganizationTask != nil {
            activeOrganizationTask?.cancel()
            await organizationGate.stop()
        }
        // Stop at the next safe file boundary and wait for the worker to persist its terminal
        // state before local model services are shut down.
        if activeReindexTask != nil || activeManagedSyncTask != nil {
            activeReindexTask?.cancel()
            activeManagedSyncTask?.cancel()
            await indexingGate.stop()
        }
        await indexer.cancelAll()
        await indexer.shutdownManagedProviders()
        await activeOrganizationTask?.value
        await activeReindexTask?.value
        await activeManagedSyncTask?.value
        await reranker.shutdown()
        await ollama.stop(host: settings.ollamaHost)
    }

    func refreshChatSessions(selecting preferredID: Int64? = nil) {
        chatSessions = chat.loadSessions()
        if preferredID == nil, isDraftChat {
            selectedChatSessionID = nil
            chatMessages = []
            hasEarlierChatMessages = false
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
            let pageLimit = max(Self.chatHistoryPageSize, min(400, chatMessages.count))
            let page = chat.loadHistoryPage(sessionId: selectedChatSessionID, limit: pageLimit)
            chatMessages = page.messages
            hasEarlierChatMessages = page.hasEarlier
        } else {
            switchChatComposerDraft(to: "new")
            chatMessages = []
            hasEarlierChatMessages = false
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

    /// Starts each application run on an unpersisted blank chat while preserving navigation
    /// and conversation state for subsequent main-window appearances in the same process.
    @discardableResult
    func prepareInitialMainViewChatIfNeeded() -> Bool {
        guard !hasPreparedInitialMainView else { return false }
        hasPreparedInitialMainView = true
        newChat()
        return true
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
        hasEarlierChatMessages = false
        closeFilePreviewUnlessMatchingAttachment(attachedFilePath)
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

    /// Saves and publishes the user message before the asynchronous answer pipeline starts.
    func saveUserQuestionForImmediateDisplay(_ question: String, sessionID: Int64) -> ChatMessage? {
        guard let message = chat.saveUserQuestion(question, sessionId: sessionID) else { return nil }
        upsertPresentedMessage(message, into: &chatMessages)
        chatSessions = chat.loadSessions()
        return message
    }

    func selectChat(_ id: Int64) {
        guard selectedChatSessionID != id else { return }
        let attachmentPath = chatSessions.first { $0.id == id }?.attachedFilePath
        fileChatReturnSessionID = nil
        fileChatReturnDestination = nil
        switchChatComposerDraft(to: chatComposerDraftKey(sessionID: id))
        isDraftChat = false
        draftChatAttachmentPath = nil
        selectedChatSessionID = id
        let page = chat.loadHistoryPage(sessionId: id, limit: Self.chatHistoryPageSize)
        chatMessages = page.messages
        hasEarlierChatMessages = page.hasEarlier
        closeFilePreviewUnlessMatchingAttachment(attachmentPath)
    }

    func loadEarlierChatMessages() async {
        guard let sessionID = selectedChatSessionID,
              let beforeID = chatMessages.compactMap(\.id).first else { return }
        let chat = chat
        let pageSize = Self.chatHistoryPageSize
        let page = await Task.detached(priority: .userInitiated) {
            chat.loadHistoryPage(
                sessionId: sessionID,
                beforeID: beforeID,
                limit: pageSize
            )
        }.value
        guard selectedChatSessionID == sessionID else { return }
        let existingIDs = Set(chatMessages.compactMap(\.id))
        chatMessages = page.messages.filter { message in
            guard let id = message.id else { return true }
            return !existingIDs.contains(id)
        } + chatMessages
        hasEarlierChatMessages = page.hasEarlier
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

    func presentSettings(_ section: SettingsSection = .general) {
        refreshReindexJobSummary()
        selectedSettingsSection = section
        closeFilePreview()
        isSettingsPresented = true
    }

    func refreshReindexJobSummary() {
        reindexJobSummary = try? store.latestReindexJobSummary()
        if reindexJobSummary == nil,
           selectedSettingsSection == .reindexActivity,
           !indexingState.isActive {
            selectedSettingsSection = .indexing
        }
    }

    func dismissSettings() {
        closeFilePreview()
        isSettingsPresented = false
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
        organizeNewFilesInWatchedDirectories()
    }

    /// Organizes only files that arrived after the watched-folder baseline was created.
    /// Existing files intentionally remain untouched unless the user chooses the explicit
    /// existing-files action in Settings.
    func organizeNewFilesInWatchedDirectories() {
        organizeNow(in: nil, includePreservedEntries: false)
    }

    /// Runs one organization pass for ad-hoc folders without changing watch settings.
    func organizeDirectoriesOnce(_ directoryPaths: [String], recursively: Bool = false) {
        let paths = normalizedOrganizationDirectoryPaths(directoryPaths)
        guard !paths.isEmpty else { return }
        organizeNow(in: paths, includePreservedEntries: true, recursively: recursively)
    }

    /// Presents a multi-folder picker for a one-time organization pass. Selected folders are
    /// never persisted to the monitoring configuration.
    func chooseDirectoriesForOneTimeOrganization() {
        guard !organizationState.isActive, !indexingState.isActive else { return }

        let panel = NSOpenPanel()
        panel.title = settings.localized("Choose Folders to Organize")
        panel.message = settings.localized("Selected folders are processed once and are not added to monitoring.")
        panel.prompt = settings.localized("Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK, let self else { return }
            Task { @MainActor in
                self.confirmOneTimeOrganization(in: panel.urls.map(\.path))
            }
        }
    }

    private func confirmOneTimeOrganization(in directoryPaths: [String]) {
        let paths = normalizedOrganizationDirectoryPaths(directoryPaths)
        guard !paths.isEmpty,
              !organizationState.isActive,
              !indexingState.isActive else { return }

        let alert = NSAlert()
        alert.messageText = settings.localized("Organize Selected Folders?")
        alert.informativeText = settings.localizedFormat(
            "FileNest will process files in %d selected folders according to your rules. These folders will not be added to monitoring.",
            paths.count
        )
        alert.addButton(withTitle: settings.localized("Organize"))
        alert.addButton(withTitle: settings.localized("Cancel"))
        let recursiveCheckbox = NSButton(
            checkboxWithTitle: settings.localized("Include Subfolders"),
            target: nil,
            action: nil
        )
        recursiveCheckbox.toolTip = settings.localized(
            "Process supported files in nested folders. Git, Mercurial, and Subversion repositories are skipped."
        )
        alert.accessoryView = recursiveCheckbox

        let beginOrganization: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let recursively = recursiveCheckbox.state == .on
            Task { @MainActor in self?.organizeDirectoriesOnce(paths, recursively: recursively) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: beginOrganization)
        } else {
            beginOrganization(alert.runModal())
        }
    }

    private func normalizedOrganizationDirectoryPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  seen.insert(url.path).inserted else { return nil }
            return url.path
        }
    }

    private func organizeNow(
        in directories: [String]?,
        includePreservedEntries: Bool,
        recursively: Bool = false
    ) {
        guard !organizationState.isActive,
              !indexingState.isActive,
              organizationTask == nil else { return }
        persistPendingOrganizationJob(
            directories: directories,
            includePreservedEntries: includePreservedEntries,
            recursively: recursively
        )
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
                "recursively": "\(recursively)",
            ]
        )

        organizationTask = Task { [weak self] in
            guard let self else { return }
            await self.organizationGate.reset()
            let result = await self.watcher.organizePendingEntries(
                in: directories,
                includePreservedEntries: includePreservedEntries,
                recursively: recursively,
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
            if !wasStopped {
                self.clearPendingOrganizationJob()
            }
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
        clearPendingOrganizationJob()
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

    private func persistPendingOrganizationJob(
        directories: [String]?,
        includePreservedEntries: Bool,
        recursively: Bool
    ) {
        let job = PendingOrganizationJob(
            directories: directories,
            includePreservedEntries: includePreservedEntries,
            recursively: recursively
        )
        guard let data = try? JSONEncoder().encode(job) else { return }
        UserDefaults.standard.set(data, forKey: Self.pendingOrganizationJobKey)
    }

    private func clearPendingOrganizationJob() {
        UserDefaults.standard.removeObject(forKey: Self.pendingOrganizationJobKey)
    }

    private func resumePendingOrganizationIfNeeded() {
        guard !organizationState.isActive,
              !indexingState.isActive,
              let data = UserDefaults.standard.data(forKey: Self.pendingOrganizationJobKey),
              let job = try? JSONDecoder().decode(PendingOrganizationJob.self, from: data) else { return }

        let directories = job.directories.map(normalizedOrganizationDirectoryPaths)
        if let directories, directories.isEmpty {
            clearPendingOrganizationJob()
            return
        }
        AppLogService.shared.write(
            "resuming interrupted manual organization job",
            category: .organizeQueue,
            level: .notice,
            metadata: ["directories": "\((directories ?? settings.watchDirs).count)"]
        )
        organizeNow(
            in: directories,
            includePreservedEntries: job.includePreservedEntries,
            recursively: job.recursively
        )
    }

    func reindexAll() {
        reindexUnindexedFileCount = (try? store.fileIndexCounts().unindexed) ?? 0
        pendingAdvancedReindexCategories = changedContentCategories()
        let hasMediaTranscriptionChange = pendingAdvancedReindexCategories.contains(.mediaTranscription)
        selectedAdvancedReindexCategories = hasMediaTranscriptionChange ? [.mediaTranscription] : []
        isEmbeddingChangeReindexSelected = true
        isUnindexedFilesReindexSelected = true
        isAffectedMediaOnlyReindexSelected = hasMediaTranscriptionChange
        selectedReindexFileCategories = []
        selectedRAGReindexStages = hasEmbeddingConfigurationChange ? [.embeddings, .retrievalIndex] : []
        if hasMediaTranscriptionChange {
            selectedRAGReindexStages.formUnion(RAGReindexStage.parsingAndOCR.downstreamStages)
        }
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
            || !selectedReindexFileCategories.isEmpty
    }

    var canLimitReindexFileTypes: Bool {
        !hasDefaultEmbeddingRebuildSelection
    }

    var reindexFileTypeScopeDescription: String {
        guard !selectedReindexFileCategories.isEmpty else {
            return settings.localized("All file types")
        }
        return selectedReindexFileCategories
            .sorted { $0.label < $1.label }
            .map { settings.localized($0.label) }
            .joined(separator: ", ")
    }

    func setEmbeddingChangeReindexSelected(_ selected: Bool) {
        isEmbeddingChangeReindexSelected = selected
        if selected { selectedReindexFileCategories = [] }
        if selected && hasEmbeddingConfigurationChange {
            selectedRAGReindexStages.formUnion(RAGReindexStage.embeddings.downstreamStages)
        } else if !selected {
            selectedRAGReindexStages.remove(.embeddings)
        }
    }

    func setUnindexedFilesReindexSelected(_ selected: Bool) {
        isUnindexedFilesReindexSelected = selected
    }

    func setReindexFileCategory(_ category: FileCategory, selected: Bool) {
        guard canLimitReindexFileTypes else { return }
        if selected {
            selectedReindexFileCategories.insert(category)
        } else {
            selectedReindexFileCategories.remove(category)
        }
        guard !selectedReindexFileCategories.isEmpty else { return }
        // A file-type scope updates the selected files in the active vector store.
        // A global embedding-space rebuild must always cover the full library.
        selectedRAGReindexStages.formUnion([.parsingAndOCR, .structuredChunking])
        isFullPipelineReindexSelected = false
    }

    var hasPendingMediaTranscriptionReindex: Bool {
        pendingAdvancedReindexCategories.contains(.mediaTranscription)
    }

    var willReindexAffectedMediaOnly: Bool {
        isAffectedMediaOnlyReindexSelected
            && selectedAdvancedReindexCategories == [.mediaTranscription]
    }

    func setAffectedMediaOnlyReindexSelected(_ selected: Bool) {
        guard hasPendingMediaTranscriptionReindex else {
            isAffectedMediaOnlyReindexSelected = false
            return
        }
        isAffectedMediaOnlyReindexSelected = selected
        if selected {
            // A transcript change requires source processing and every persisted downstream stage.
            selectedAdvancedReindexCategories = [.mediaTranscription]
            selectedRAGReindexStages.formUnion(RAGReindexStage.parsingAndOCR.downstreamStages)
            isFullPipelineReindexSelected = false
        }
    }

    func setAdvancedReindexCategory(_ category: IndexContentChangeCategory, selected: Bool) {
        guard pendingAdvancedReindexCategories.contains(category) else { return }
        if selected {
            if category != .mediaTranscription {
                isAffectedMediaOnlyReindexSelected = false
            }
            selectedAdvancedReindexCategories.insert(category)
            selectedRAGReindexStages.formUnion(reindexStage(for: category).downstreamStages)
        } else {
            selectedAdvancedReindexCategories.remove(category)
            if category == .mediaTranscription {
                isAffectedMediaOnlyReindexSelected = false
            }
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
        if selected { selectedReindexFileCategories = [] }
        if selected { isAffectedMediaOnlyReindexSelected = false }
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
                .documentParsing, .ocr, .indexingScope, .mediaTranscription,
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
        case .documentParsing, .ocr, .indexingScope, .mediaTranscription: return .parsingAndOCR
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
        isAffectedMediaOnlyReindexSelected = false
        selectedReindexFileCategories = []
    }

    func confirmReindex() {
        guard reindexConfirmationStep == .finalConfirmation else { return }
        let stages = selectedRAGReindexStages
        let fileCategories = selectedReindexFileCategories
        // A restricted source rebuild updates selected records in-place. Replacing
        // the embedding space is intentionally reserved for a full-library run.
        let rebuildEmbedding = stages.contains(.embeddings) && fileCategories.isEmpty
        let includeUnindexedFiles = isUnindexedFilesReindexSelected && unindexedFileCount > 0
        let forcesSourceReprocessing = stages.contains(.parsingAndOCR)
            || stages.contains(.structuredChunking)
            || !fileCategories.isEmpty
        let contentCategories = selectedAdvancedReindexCategories
            .intersection(pendingAdvancedReindexCategories)
        let onlyMediaFiles = isAffectedMediaOnlyReindexSelected
            && contentCategories == [.mediaTranscription]
        let retrievalIndexOnly = stages.contains(.retrievalIndex)
            && !forcesSourceReprocessing
            && !rebuildEmbedding
        let restartsReranker = stages.contains(.rerankerRuntime)
        let explicitlyRequestsFullPipeline = isFullPipelineReindexSelected
        guard !stages.isEmpty || includeUnindexedFiles else { return }
        reindexConfirmationStep = nil
        selectedAdvancedReindexCategories = []
        selectedRAGReindexStages = []
        isFullPipelineReindexSelected = false
        isAffectedMediaOnlyReindexSelected = false
        selectedReindexFileCategories = []
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
            if !explicitlyRequestsFullPipeline,
               self.reindexJobSummary?.failed ?? 0 > 0,
               self.resumePendingReindexIfNeeded() {
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
                forceSourceReprocessing: forcesSourceReprocessing,
                onlyMediaFiles: onlyMediaFiles,
                fileCategories: fileCategories
            )
        }
    }

    func rebuildVectorIndex() {
        if reindexJobSummary?.failed ?? 0 > 0,
           resumePendingReindexIfNeeded() {
            return
        }
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
        Task { await indexingGate.pauseAndDrain() }
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
        guard indexingState == .stopped
                || indexingState == .failed
                || indexingState == .completed
                || indexingState == .completedWithErrors else {
            return
        }
        if lastIndexingKind == .automatic {
            indexingState = .idle
            vectorIndexRebuildProgress = nil
            refresh()
        } else {
            if resumePendingReindexIfNeeded() {
                return
            }
            startReindex(
                kind: lastIndexingKind,
                rebuildVectorSpace: lastRebuildVectorSpace,
                contentCategoriesToAcknowledge: lastReindexContentCategories,
                onlyUnindexedFiles: lastOnlyUnindexedFiles,
                includeUnindexedFiles: lastIncludeUnindexedFiles,
                retrievalIndexOnly: lastRetrievalIndexOnly,
                forceSourceReprocessing: lastForceSourceReprocessing,
                onlyMediaFiles: lastOnlyMediaFiles,
                fileCategories: lastReindexFileCategories
            )
        }
    }

    func resumeReindexJobFromSettings() {
        if indexingState == .idle {
            _ = resumePendingReindexIfNeeded()
        } else {
            restartIndexing()
        }
    }

    func retryFailedReindexFiles(_ fileIDs: Set<Int64>) {
        guard !fileIDs.isEmpty,
              reindexTask == nil,
              managedSyncIndexTask == nil,
              !indexingState.isActive,
              let summary = reindexJobSummary,
              let jobID = summary.job.id else {
            return
        }
        let visibleFailedIDs = Set(
            summary.files
                .filter { $0.state == .failed }
                .map(\.fileID)
        )
        let requestedIDs = fileIDs.intersection(visibleFailedIDs)
        guard !requestedIDs.isEmpty else { return }
        let targetFiles = requestedIDs.compactMap { try? store.file(id: $0) }
        let targetIDs = Set(targetFiles.compactMap(\.id))
        guard !targetFiles.isEmpty, !targetIDs.isEmpty else { return }
        if summary.job.rebuildVectorSpace, !summary.job.forceSourceReprocessing {
            AppLogService.shared.write(
                "embedding-space retries must run together to preserve atomic vector replacement",
                category: .indexPipeline,
                level: .notice,
                metadata: ["jobID": "\(jobID)"]
            )
            resumeReindexJobFromSettings()
            return
        }

        do {
            let preparedCount = try store.prepareFailedReindexFilesForRetry(
                jobID: jobID,
                fileIDs: targetIDs
            )
            guard preparedCount > 0 else { return }
        } catch {
            AppLogService.shared.write(
                "failed to prepare reindex files for retry: \(error)",
                category: .indexPipeline,
                level: .error,
                metadata: ["jobID": "\(jobID)"]
            )
            return
        }

        let kind: IndexingTaskKind = summary.job.kind == IndexingTaskKind.vectorRebuild.logName
            ? .vectorRebuild
            : .fullReindex
        activeReindexJobID = jobID
        store.setReindexJobStatus(jobID: jobID, status: .running)
        refreshReindexJobSummary()
        let usesShadowRetry = summary.job.rebuildVectorSpace
            && summary.job.forceSourceReprocessing
        let retryTotal = usesShadowRetry ? summary.total : targetFiles.count
        let retryInitialCompleted = usesShadowRetry ? summary.completed : 0
        beginIndexing(
            kind: kind,
            total: retryTotal,
            initialCompleted: retryInitialCompleted
        )

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
            let completionHandler: @Sendable (Int64, Bool) async -> Void = {
                [store = self.store] fileID, succeeded in
                store.markReindexJobFile(
                    jobID: jobID,
                    fileID: fileID,
                    state: succeeded ? .completed : .failed
                )
            }
            let result: IndexBatchResult
            if usesShadowRetry {
                let fileCategories = Set(
                    summary.job.fileCategoryRawValues.compactMap(FileCategory.init(rawValue:))
                )
                let succeeded = await self.indexer.rebuildAll(
                    rebuildVectorSpace: true,
                    forceReprocessing: true,
                    onlyUnindexedFiles: summary.job.onlyUnindexedFiles,
                    includeUnindexedFiles: summary.job.includeUnindexedFiles,
                    onlyMediaFiles: summary.job.onlyMediaFiles,
                    fileCategories: fileCategories,
                    fileIDs: targetIDs,
                    totalOverride: retryTotal,
                    initialCompleted: retryInitialCompleted,
                    resumeShadow: true,
                    expectedShadowFileCount: summary.total,
                    executionGate: self.indexingGate,
                    fileCompletion: completionHandler,
                    progress: progressHandler
                )
                let progress = self.vectorIndexRebuildProgress
                let stopped = progress?.phase == .stopped || Task.isCancelled
                let failed = progress?.failed ?? 0
                if !succeeded, !stopped, failed == 0 {
                    for fileID in targetIDs {
                        self.store.markReindexJobFile(
                            jobID: jobID,
                            fileID: fileID,
                            state: .failed
                        )
                    }
                }
                result = IndexBatchResult(
                    completed: progress?.completed ?? retryInitialCompleted,
                    failed: succeeded ? 0 : (failed > 0 ? failed : targetFiles.count),
                    stopped: stopped
                )
            } else {
                result = await self.indexer.indexFiles(
                    targetFiles,
                    force: true,
                    executionGate: self.indexingGate,
                    fileCompletion: completionHandler,
                    progress: progressHandler
                )
            }
            let stopped = result.stopped
                || self.indexingState == .stopping
                || Task.isCancelled
            self.reindexTask = nil
            self.activeReindexJobID = nil

            let latestProgress = try? self.store.reindexJobProgress(jobID: jobID)
            let remainingCount = latestProgress.map {
                max($0.totalFiles - $0.completed, 0)
            } ?? 0
            let persistedFailed = latestProgress?.failed ?? result.failed
            let persistedCompleted = latestProgress?.completed
                ?? max(result.completed - result.failed, 0)
            if !stopped, result.failed == 0, remainingCount == 0 {
                if usesShadowRetry {
                    try? self.store.migrateIndexedFileSignatures(
                        to: summary.job.targetEmbeddingSignature
                    )
                    self.store.setSetting(
                        Self.appliedEmbeddingSignatureKey,
                        summary.job.targetEmbeddingSignature
                    )
                    self.acknowledgeContentCategories(
                        Set(
                            summary.job.contentCategoryRawValues.compactMap(
                                IndexContentChangeCategory.init(rawValue:)
                            )
                        )
                    )
                }
                self.store.deleteReindexJob(jobID: jobID)
            } else {
                let status: ReindexJobStatus
                if stopped {
                    status = .interrupted
                } else if persistedFailed > 0, persistedCompleted > 0 {
                    status = .completedWithErrors
                } else if result.failed > 0 {
                    status = .failed
                } else {
                    status = .interrupted
                }
                self.store.setReindexJobStatus(
                    jobID: jobID,
                    status: status
                )
            }

            self.finishIndexing(
                stopped: stopped,
                succeeded: !stopped && result.failed == 0 && remainingCount == 0,
                completed: result.completed,
                total: retryTotal,
                failed: persistedFailed,
                successfulFiles: persistedCompleted
            )
            self.refreshReindexJobSummary()
            self.refresh(allowManagedIndexing: result.failed == 0)
        }
    }

    @discardableResult
    private func resumePendingReindexIfNeeded() -> Bool {
        guard reindexTask == nil,
              managedSyncIndexTask == nil,
              !indexingState.isActive,
              let job = try? store.resumableReindexJob(),
              let jobID = job.id else {
            return false
        }
        if job.rebuildVectorSpace,
           job.targetEmbeddingSignature != settings.embeddingSpaceSignature {
            AppLogService.shared.write(
                "persisted reindex job superseded by a newer embedding configuration",
                category: .indexPipeline,
                level: .notice,
                metadata: ["jobID": "\(jobID)"]
            )
            store.deleteReindexJob(jobID: jobID)
            Task { await indexer.vectorStore.discardShadowRebuild() }
            return false
        }
        let kind: IndexingTaskKind
        switch job.kind {
        case IndexingTaskKind.vectorRebuild.logName:
            kind = .vectorRebuild
        case IndexingTaskKind.automatic.logName:
            kind = .automatic
        default:
            kind = .fullReindex
        }
        let contentCategories = Set(
            job.contentCategoryRawValues.compactMap(IndexContentChangeCategory.init(rawValue:))
        )
        let fileCategories = Set(
            job.fileCategoryRawValues.compactMap(FileCategory.init(rawValue:))
        )
        AppLogService.shared.write(
            "resuming persisted reindex job",
            category: .indexPipeline,
            level: .notice,
            metadata: [
                "jobID": "\(jobID)",
                "kind": job.kind,
                "total": "\(job.total)",
            ]
        )
        isIndexConfigurationPromptPresented = false
        return startReindex(
            kind: kind,
            rebuildVectorSpace: job.rebuildVectorSpace,
            contentCategoriesToAcknowledge: contentCategories,
            onlyUnindexedFiles: job.onlyUnindexedFiles,
            includeUnindexedFiles: job.includeUnindexedFiles,
            retrievalIndexOnly: job.retrievalIndexOnly,
            forceSourceReprocessing: job.forceSourceReprocessing,
            onlyMediaFiles: job.onlyMediaFiles,
            fileCategories: fileCategories,
            resumingJob: job
        )
    }

    @discardableResult
    private func startReindex(
        kind: IndexingTaskKind,
        rebuildVectorSpace: Bool,
        contentCategoriesToAcknowledge: Set<IndexContentChangeCategory> = [],
        onlyUnindexedFiles: Bool = false,
        includeUnindexedFiles: Bool = false,
        retrievalIndexOnly: Bool = false,
        forceSourceReprocessing: Bool = false,
        onlyMediaFiles: Bool = false,
        fileCategories: Set<FileCategory> = [],
        resumingJob: ReindexJobRecord? = nil
    ) -> Bool {
        guard !indexingState.blocksReindexButtons,
              managedSyncIndexTask == nil,
              reindexTask == nil else { return false }
        lastIndexingKind = kind
        lastRebuildVectorSpace = rebuildVectorSpace
        lastOnlyUnindexedFiles = onlyUnindexedFiles
        lastIncludeUnindexedFiles = includeUnindexedFiles
        lastOnlyMediaFiles = onlyMediaFiles
        lastReindexFileCategories = fileCategories
        lastRetrievalIndexOnly = retrievalIndexOnly
        lastForceSourceReprocessing = forceSourceReprocessing
        lastReindexContentCategories = contentCategoriesToAcknowledge
        let targetEmbeddingSignature = resumingJob?.targetEmbeddingSignature
            ?? settings.embeddingSpaceSignature
        let scopedFiles = ((try? store.libraryFiles()) ?? files).filter { file in
            file.duplicateOfFileID == nil
                && (!onlyMediaFiles || AppSettings.mediaTranscriptionExtensions.contains(file.ext.lowercased()))
                && (fileCategories.isEmpty || fileCategories.contains(file.categoryEnum))
        }
        let targetFiles: [FileRecord]
        if retrievalIndexOnly {
            targetFiles = includeUnindexedFiles
                ? scopedFiles.filter { $0.indexedAt == nil }
                : []
        } else if onlyUnindexedFiles {
            targetFiles = scopedFiles.filter { $0.indexedAt == nil }
        } else if rebuildVectorSpace && !forceSourceReprocessing {
            targetFiles = scopedFiles.filter {
                $0.indexedAt != nil || (includeUnindexedFiles && $0.indexedAt == nil)
            }
        } else {
            targetFiles = scopedFiles
        }
        let persistedJob: ReindexJobRecord
        let remainingFileIDs: Set<Int64>
        let initialCompleted: Int
        let isResuming = resumingJob != nil
        let total: Int
        if let resumingJob, let jobID = resumingJob.id {
            let jobProgress = (try? store.reindexJobProgress(jobID: jobID))
                ?? (completed: 0, failed: 0, totalFiles: resumingJob.total)
            persistedJob = resumingJob
            remainingFileIDs = Set(
                (try? store.reindexJobFileIDs(jobID: jobID, includeCompleted: false)) ?? []
            )
            initialCompleted = jobProgress.completed
            total = retrievalIndexOnly
                ? resumingJob.total
                : max(jobProgress.totalFiles, jobProgress.completed + remainingFileIDs.count)
            store.setReindexJobStatus(jobID: jobID, status: .running)
        } else {
            let calculatedTotal: Int
            if retrievalIndexOnly {
                calculatedTotal = indexer.vectorStore.count + targetFiles.count
            } else {
                calculatedTotal = targetFiles.count
            }
            let now = Date()
            let descriptor = ReindexJobRecord(
                id: nil,
                kind: kind.logName,
                rebuildVectorSpace: rebuildVectorSpace,
                contentCategoriesJSON: ReindexJobRecord.encodeStrings(
                    contentCategoriesToAcknowledge.map(\.rawValue)
                ),
                onlyUnindexedFiles: onlyUnindexedFiles,
                includeUnindexedFiles: includeUnindexedFiles,
                retrievalIndexOnly: retrievalIndexOnly,
                forceSourceReprocessing: forceSourceReprocessing,
                onlyMediaFiles: onlyMediaFiles,
                fileCategoriesJSON: ReindexJobRecord.encodeStrings(fileCategories.map(\.rawValue)),
                targetEmbeddingSignature: targetEmbeddingSignature,
                status: ReindexJobStatus.running.rawValue,
                total: calculatedTotal,
                createdAt: now,
                updatedAt: now
            )
            do {
                persistedJob = try store.createReindexJob(
                    descriptor,
                    fileIDs: targetFiles.compactMap(\.id)
                )
            } catch {
                AppLogService.shared.write(
                    "reindex job persistence failed: \(error)",
                    category: .indexPipeline,
                    level: .error
                )
                return false
            }
            remainingFileIDs = Set(targetFiles.compactMap(\.id))
            initialCompleted = 0
            total = calculatedTotal
        }
        guard let jobID = persistedJob.id else { return false }
        activeReindexJobID = jobID
        refreshReindexJobSummary()
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
                "onlyMediaFiles": "\(onlyMediaFiles)",
                "fileCategories": fileCategories.map(\.rawValue).sorted().joined(separator: ","),
                "rebuildVectorSpace": "\(rebuildVectorSpace)",
                "retrievalIndexOnly": "\(retrievalIndexOnly)",
                "forceSourceReprocessing": "\(forceSourceReprocessing)",
                "resuming": "\(isResuming)",
                "completedBeforeStart": "\(initialCompleted)",
                "filesScheduled": "\(remainingFileIDs.count)",
                "total": "\(total)",
            ]
        )
        beginIndexing(kind: kind, total: total, initialCompleted: initialCompleted)

        reindexTask = Task { [weak self] in
            guard let self else { return }
            await self.indexingGate.reset()
            if !isResuming {
                await self.indexer.vectorStore.discardShadowRebuild()
            }
            let progressHandler: @MainActor (VectorIndexRebuildProgress) -> Void = { [weak self] progress in
                guard let self else { return }
                self.vectorIndexRebuildProgress = progress
                let recordedFiles = (self.reindexJobSummary?.completed ?? 0)
                    + (self.reindexJobSummary?.failed ?? 0)
                if progress.completed > recordedFiles {
                    self.refreshReindexJobSummary()
                }
                if self.indexingState != .paused && self.indexingState != .stopping {
                    self.statusText = self.indexingStatusTitle
                }
            }
            let completionHandler: @Sendable (Int64, Bool) async -> Void = {
                [store = self.store] fileID, succeeded in
                store.markReindexJobFile(
                    jobID: jobID,
                    fileID: fileID,
                    state: succeeded ? .completed : .failed
                )
            }
            let succeeded: Bool
            if retrievalIndexOnly {
                let retrievalSucceeded = await self.indexer.rebuildRetrievalIndex(progress: progressHandler)
                if retrievalSucceeded && includeUnindexedFiles {
                    succeeded = await self.indexer.rebuildAll(
                        onlyUnindexedFiles: true,
                        fileIDs: remainingFileIDs,
                        totalOverride: total,
                        initialCompleted: initialCompleted,
                        executionGate: self.indexingGate,
                        fileCompletion: completionHandler,
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
                    onlyMediaFiles: onlyMediaFiles,
                    fileCategories: fileCategories,
                    fileIDs: remainingFileIDs,
                    totalOverride: total,
                    initialCompleted: initialCompleted,
                    resumeShadow: isResuming,
                    executionGate: self.indexingGate,
                    fileCompletion: completionHandler,
                    progress: progressHandler
                )
            }

            let stopped = self.indexingState == .stopping
                || self.vectorIndexRebuildProgress?.phase == .stopped
                || Task.isCancelled
            let progress = self.vectorIndexRebuildProgress
            self.reindexTask = nil
            let persistedProgress = try? self.store.reindexJobProgress(jobID: jobID)
            let persistedFailed = persistedProgress?.failed ?? progress?.failed ?? 0
            let persistedCompleted = persistedProgress?.completed
                ?? max((progress?.completed ?? 0) - persistedFailed, 0)
            if succeeded {
                if rebuildVectorSpace {
                    try? self.store.migrateIndexedFileSignatures(to: targetEmbeddingSignature)
                    self.store.setSetting(
                        Self.appliedEmbeddingSignatureKey,
                        targetEmbeddingSignature
                    )
                }
                self.acknowledgeContentCategories(contentCategoriesToAcknowledge)
                self.store.deleteReindexJob(jobID: jobID)
            } else {
                self.store.setReindexJobStatus(
                    jobID: jobID,
                    status: stopped
                        ? .interrupted
                        : (persistedFailed > 0 && persistedCompleted > 0
                            ? .completedWithErrors
                            : .failed)
                )
            }
            self.activeReindexJobID = nil
            self.refreshReindexJobSummary()
            self.finishIndexing(
                stopped: stopped,
                succeeded: succeeded,
                completed: progress?.completed ?? 0,
                total: progress?.total ?? total,
                failed: persistedFailed,
                successfulFiles: persistedCompleted
            )
            self.refreshReindexJobSummary()
            if succeeded {
                _ = await self.organizer.invalidateChangedManagedFileIndexes()
            }
            self.refresh(allowManagedIndexing: succeeded)
            if succeeded {
                self.refreshIndexConfigurationState()
            } else {
                self.isIndexConfigurationPromptPresented = false
            }
        }
        return true
    }

    private func beginIndexing(kind: IndexingTaskKind, total: Int, initialCompleted: Int = 0) {
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
            completed: initialCompleted,
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
        failed: Int,
        successfulFiles: Int? = nil
    ) {
        let outcome = IndexingCompletionOutcome(
            stopped: stopped,
            operationSucceeded: succeeded,
            successfulFiles: successfulFiles ?? max(completed - failed, 0),
            failedFiles: failed
        )
        let resultName: String
        let logLevel: AppLogLevel
        switch outcome {
        case .completed:
            resultName = "succeeded"
            logLevel = .notice
        case .completedWithErrors:
            resultName = "completed-with-errors"
            logLevel = .warning
        case .failed:
            resultName = "failed"
            logLevel = .error
        case .stopped:
            resultName = "stopped"
            logLevel = .warning
        }
        AppLogService.shared.write(
            "indexing task finished",
            category: .indexPipeline,
            level: logLevel,
            metadata: [
                "completed": "\(completed)",
                "failed": "\(failed)",
                "kind": indexingKind.logName,
                "result": resultName,
                "total": "\(total)",
            ]
        )
        switch outcome {
        case .stopped:
            indexingState = .stopped
            vectorIndexRebuildProgress = VectorIndexRebuildProgress(
                phase: .stopped,
                completed: completed,
                total: total,
                currentFileName: nil,
                failed: failed
            )
        case .completed:
            indexingState = .completed
            vectorIndexRebuildProgress = VectorIndexRebuildProgress(
                phase: .completed,
                completed: completed,
                total: total,
                currentFileName: nil,
                failed: failed
            )
        case .completedWithErrors:
            indexingState = .completedWithErrors
            vectorIndexRebuildProgress = VectorIndexRebuildProgress(
                phase: .completed,
                completed: completed,
                total: total,
                currentFileName: nil,
                failed: failed
            )
        case .failed:
            indexingState = .failed
            vectorIndexRebuildProgress = VectorIndexRebuildProgress(
                phase: .failed,
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
            total: (try? store.fileIndexCounts().total) ?? 0,
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
