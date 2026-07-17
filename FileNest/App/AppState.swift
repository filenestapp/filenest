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
    @Published private(set) var draftChatAttachmentPath: String?
    @Published private(set) var chatComposerInput = ""
    @Published var statistics: AppStatistics = .empty
    @Published var selectedSettingsSection: SettingsSection = .general
    @Published var isOnboardingPresented = false
    @Published private(set) var indexingState: IndexingTaskState = .idle
    @Published private(set) var indexingKind: IndexingTaskKind = .automatic
    @Published private(set) var vectorIndexRebuildProgress: VectorIndexRebuildProgress?
    @Published private(set) var isIndexConfigurationPromptPresented = false
    @Published private(set) var hasPendingAutomaticEmbeddingRebuild = false
    @Published private(set) var reindexConfirmationStep: ReindexConfirmationStep?
    @Published private(set) var pendingAdvancedReindexCategories = Set<IndexContentChangeCategory>()
    @Published private(set) var selectedAdvancedReindexCategories = Set<IndexContentChangeCategory>()
    @Published private(set) var isEmbeddingChangeReindexSelected = true
    @Published private(set) var isUnindexedFilesReindexSelected = true
    @Published var isReindexAdvancedExpanded = false

    private var cancellables = Set<AnyCancellable>()
    private var managedSyncIndexIDs = Set<Int64>()
    private var managedSyncIndexTask: Task<Void, Never>?
    private var reindexTask: Task<Void, Never>?
    private var notePostSaveTasks = [Int64: Task<Void, Never>]()
    private var notePostSaveTokens = [Int64: UUID]()
    private let indexingGate = IndexingExecutionGate()
    private var lastRebuildVectorSpace = false
    private var lastOnlyUnindexedFiles = false
    private var lastIncludeUnindexedFiles = false
    private var lastIndexingKind: IndexingTaskKind = .fullReindex
    private var lastReindexContentCategories = Set<IndexContentChangeCategory>()
    private var isDraftChat = false
    private var chatComposerDrafts: [String: String] = [:]
    private var activeChatComposerDraftKey = "new"
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

    init(store: SQLiteStore = .shared,
         settings: AppSettings = .shared,
         organizeRoot: URL? = nil,
         startAutomatically: Bool = !AppState.isRunningTests) {
        self.store = store
        self.settings = settings
        self.startsServicesAutomatically = startAutomatically
        self.updates = AppUpdateService(settings: settings, enabled: startAutomatically)
        self.shouldSynchronizeManagedFiles = organizeRoot != nil || !AppState.isRunningTests
        self.shouldIndexManagedFiles = startAutomatically
        let organizer = OrganizerService(store: store, settings: settings, organizeRoot: organizeRoot)
        let indexer = IndexerService(store: store, settings: settings)
        let chat = ChatService(store: store, settings: settings, vectorStore: indexer.vectorStore)
        let ollama = OllamaServiceManager()
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
        self.docling = docling
        self.paddleOCR = paddleOCR
        self.watcher = watcher
        watcher.onDirectoryStatusChange = { [weak self] statuses in
            Task { @MainActor [weak self] in
                self?.applyWatchDirectoryStatuses(statuses)
            }
        }
        organizer.onLibraryChange = { [weak self] in
            Task { @MainActor in self?.refresh() }
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
        refresh(allowManagedIndexing: false)
        Task { [weak self] in
            guard let self else { return }
            await indexer.warmup()
            _ = await organizer.invalidateChangedManagedFileIndexes()
            if !self.refreshIndexConfigurationState() {
                self.refresh()
            }
        }
        refreshChatSessions()
        // Do not scan folders before initial setup completes; the user must first decide how to handle existing files.
        if settings.onboardingCompleted {
            startWatching()
        }
        Task {
            async let ollamaRefresh: Void = ollama.refresh(host: settings.ollamaHost)
            async let paddleRefresh: Void = paddleOCR.refresh()
            _ = await (ollamaRefresh, paddleRefresh)
            async let ollamaUpdates: Void = ollama.checkForUpdates()
            async let doclingUpdates: Void = docling.checkForUpdates()
            async let paddleUpdates: Void = paddleOCR.checkForUpdates()
            _ = await (ollamaUpdates, doclingUpdates, paddleUpdates)
        }
    }

    func refresh(allowManagedIndexing: Bool = true) {
        _ = try? store.removeTransientFiles(preservingRoot: organizer.organizeRoot)
        if shouldSynchronizeManagedFiles {
            files = FileRecord.sortedByNewestAdded(organizer.reconcileManagedFiles())
        } else {
            files = FileRecord.sortedByNewestAdded(((try? store.allFiles()) ?? []).filter {
                FileManager.default.fileExists(atPath: $0.path)
            })
        }
        if let previewedFile {
            let refreshedPreview = files.first { candidate in
                if let id = previewedFile.id { return candidate.id == id }
                return candidate.path == previewedFile.path
            }
            self.previewedFile = refreshedPreview ?? (
                FileManager.default.fileExists(atPath: previewedFile.path) ? previewedFile : nil
            )
        }
        rules = (try? store.allRules()) ?? []
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

    func closeFilePreview() {
        previewedFile = nil
    }

    @discardableResult
    func reindexFile(_ file: FileRecord) async -> Bool {
        guard !reindexButtonsDisabled,
              let id = file.id,
              FileManager.default.fileExists(atPath: file.path) else { return false }
        let succeeded = await indexer.indexFile(
            id: id,
            force: true,
            forceVectorization: true
        )
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
        await chat.searchLibrary(keyword).filter {
            organizer.isManagedPath($0.file.path) && FileManager.default.fileExists(atPath: $0.file.path)
        }
    }

    func managedSmartSearchResults(
        matching query: String,
        onIntentUpdate: ((String) -> Void)? = nil
    ) async -> SmartLibrarySearchResponse {
        let response = await chat.smartSearchLibrary(
            query,
            onIntentUpdate: onIntentUpdate
        )
        let results = response.results.filter {
            organizer.isManagedPath($0.file.path) && FileManager.default.fileExists(atPath: $0.file.path)
        }
        return SmartLibrarySearchResponse(
            results: results,
            plan: response.plan,
            usedAI: response.usedAI
        )
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
        statistics = (try? store.statistics(days: days)) ?? .empty
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

    func newChat(attachedFilePath: String? = nil) {
        switchChatComposerDraft(to: "new", resetDestination: true)
        isDraftChat = true
        draftChatAttachmentPath = attachedFilePath
        selectedChatSessionID = nil
        chatMessages = []
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
        chatComposerDrafts.removeValue(forKey: chatComposerDraftKey(sessionID: id))
        chat.deleteSession(id: id)
        refreshChatSessions()
    }

    func clearAllChats() {
        runningChatSessionIDs.removeAll()
        completedChatSessionIDs.removeAll()
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
        if !isWatching { startWatching() }
        statusText = "Organizing Existing Files"
        watcher.organizeExistingEntries(in: paths)
        restoreSteadyStatus(after: 2_000_000_000)
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
        statusText = "Organizing"
        organizer.runOnce()
        restoreSteadyStatus(after: 2_000_000_000)
    }

    func reindexAll() {
        pendingAdvancedReindexCategories = changedContentCategories()
        selectedAdvancedReindexCategories = []
        isEmbeddingChangeReindexSelected = true
        isUnindexedFilesReindexSelected = true
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
        ((try? store.allFiles()) ?? []).filter { $0.id != nil && $0.indexedAt == nil }.count
    }

    var canAdvanceReindexConfirmation: Bool {
        hasDefaultEmbeddingRebuildSelection
            || (isUnindexedFilesReindexSelected && unindexedFileCount > 0)
            || !selectedAdvancedReindexCategories.isEmpty
    }

    func setEmbeddingChangeReindexSelected(_ selected: Bool) {
        isEmbeddingChangeReindexSelected = selected
    }

    func setUnindexedFilesReindexSelected(_ selected: Bool) {
        isUnindexedFilesReindexSelected = selected
    }

    func setAdvancedReindexCategory(_ category: IndexContentChangeCategory, selected: Bool) {
        guard pendingAdvancedReindexCategories.contains(category) else { return }
        if selected {
            selectedAdvancedReindexCategories.insert(category)
        } else {
            selectedAdvancedReindexCategories.remove(category)
        }
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
    }

    func confirmReindex() {
        guard reindexConfirmationStep == .finalConfirmation else { return }
        let rebuildEmbedding = hasDefaultEmbeddingRebuildSelection
        let includeUnindexedFiles = isUnindexedFilesReindexSelected && unindexedFileCount > 0
        let contentCategories = selectedAdvancedReindexCategories
            .intersection(pendingAdvancedReindexCategories)
        guard rebuildEmbedding || includeUnindexedFiles || !contentCategories.isEmpty else { return }
        reindexConfirmationStep = nil
        selectedAdvancedReindexCategories = []
        isReindexAdvancedExpanded = false
        _ = startReindex(
            kind: rebuildEmbedding ? .vectorRebuild : .fullReindex,
            rebuildVectorSpace: rebuildEmbedding,
            contentCategoriesToAcknowledge: contentCategories,
            onlyUnindexedFiles: includeUnindexedFiles && !rebuildEmbedding && contentCategories.isEmpty,
            includeUnindexedFiles: includeUnindexedFiles && rebuildEmbedding && contentCategories.isEmpty
        )
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
                includeUnindexedFiles: lastIncludeUnindexedFiles
            )
        }
    }

    @discardableResult
    private func startReindex(
        kind: IndexingTaskKind,
        rebuildVectorSpace: Bool,
        contentCategoriesToAcknowledge: Set<IndexContentChangeCategory> = [],
        onlyUnindexedFiles: Bool = false,
        includeUnindexedFiles: Bool = false
    ) -> Bool {
        guard !indexingState.blocksReindexButtons,
              managedSyncIndexTask == nil,
              reindexTask == nil else { return false }
        lastIndexingKind = kind
        lastRebuildVectorSpace = rebuildVectorSpace
        lastOnlyUnindexedFiles = onlyUnindexedFiles
        lastIncludeUnindexedFiles = includeUnindexedFiles
        lastReindexContentCategories = contentCategoriesToAcknowledge
        let targetEmbeddingSignature = settings.embeddingSpaceSignature
        let allFiles = (try? store.allFiles()) ?? []
        let total: Int
        if !contentCategoriesToAcknowledge.isEmpty {
            total = allFiles.count
        } else if rebuildVectorSpace {
            total = allFiles.filter { $0.indexedAt != nil }.count
                + (includeUnindexedFiles ? allFiles.filter { $0.indexedAt == nil }.count : 0)
        } else if onlyUnindexedFiles {
            total = allFiles.filter { $0.indexedAt == nil }.count
        } else {
            total = allFiles.count
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
                "total": "\(total)",
            ]
        )
        beginIndexing(kind: kind, total: total)

        reindexTask = Task { [weak self] in
            guard let self else { return }
            await self.indexingGate.reset()
            let succeeded = await self.indexer.rebuildAll(
                rebuildVectorSpace: rebuildVectorSpace,
                forceReprocessing: !contentCategoriesToAcknowledge.isEmpty,
                onlyUnindexedFiles: onlyUnindexedFiles,
                includeUnindexedFiles: includeUnindexedFiles,
                checkpoint: { [indexingGate = self.indexingGate] in
                    await indexingGate.waitUntilRunnable()
                }
            ) { [weak self] progress in
                guard let self else { return }
                self.vectorIndexRebuildProgress = progress
                if self.indexingState != .paused && self.indexingState != .stopping {
                    self.statusText = self.indexingStatusTitle
                }
            }

            let stopped = self.indexingState == .stopping || self.vectorIndexRebuildProgress?.phase == .stopped
            let progress = self.vectorIndexRebuildProgress
            self.reindexTask = nil
            if succeeded {
                if kind == .vectorRebuild {
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
