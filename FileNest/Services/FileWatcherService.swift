import Foundation
import Darwin

enum WatchDirectoryAccessState: String, Equatable, Sendable {
    case accessible
    case permissionDenied
    case missing
    case unavailable
}

struct WatchDirectoryStatus: Identifiable, Equatable, Sendable {
    let path: String
    let accessState: WatchDirectoryAccessState
    let isWatching: Bool

    var id: String { path }
}

struct WatchDirectoryInventory: Identifiable, Equatable {
    let path: String
    let fileCount: Int
    let directoryCount: Int
    let accessState: WatchDirectoryAccessState

    var id: String { path }
    var itemCount: Int { fileCount + directoryCount }
    var isAccessible: Bool { accessState == .accessible }
}

enum OrganizationJobPhase: Equatable, Sendable {
    case preparing
    case waitingForStability
    case indexing
    case organizing
    case paused
    case stopping
    case stopped
    case completed
    case failed
}

struct OrganizationJobProgress: Equatable, Sendable {
    var phase: OrganizationJobPhase
    var completed: Int
    var total: Int
    var moved: Int
    var skipped: Int
    var failed: Int
    var currentFileName: String?
    var indexingStage: IndexingStage?
    /// A small, display-only preview of files that have not started yet.
    var upcomingFileNames: [String] = []

    var fractionCompleted: Double {
        guard total > 0 else { return phase == .completed ? 1 : 0 }
        return min(1, Double(completed) / Double(total))
    }
}

struct OrganizationBatchResult: Equatable, Sendable {
    let completed: Int
    let total: Int
    let moved: Int
    let skipped: Int
    let failed: Int
    let stopped: Bool
}

/// A visible lifecycle for files discovered by automatic watching.
enum AutomaticFileProcessingStage: Equatable, Sendable {
    case queued
    case duplicate(originalFileName: String)
    case indexing(IndexingStage)
    case waitingForOrganization
    case organizing
    case completed
    case failed(String)
}

struct AutomaticFileProcessingEvent: Sendable {
    let fileID: Int64
    let fileName: String
    let stage: AutomaticFileProcessingStage
}

actor OrganizationExecutionGate {
    private enum State {
        case running
        case paused
        case stopped
    }

    private var state: State = .running

    func reset() { state = .running }
    func pause() { if state == .running { state = .paused } }
    func resume() { if state == .paused { state = .running } }
    func stop() { state = .stopped }

    func waitUntilRunnable() async -> Bool {
        while state == .paused {
            guard !Task.isCancelled else { return false }
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return false
            }
        }
        return state == .running && !Task.isCancelled
    }
}

/// File-watching service that uses DispatchSource to monitor configured folders for new files,
/// then triggers organization and indexing.
final class FileWatcherService: @unchecked Sendable {
    private enum EntryExclusion {
        case transient
        case hidden
        case unsupportedExtension
    }

    private struct ManualCandidate {
        let url: URL
        let isDirectory: Bool
        var fingerprint: String?
        var stableSince: Date?
    }

    private struct CachedDirectoryInspection {
        let inspection: DirectoryInspection
        let expiresAt: Date
    }

    private struct DirectoryInspectionRetry {
        let failures: Int
        let nextAttemptAt: Date
    }

    private static let pendingBaselinePathsKey = "watch.pending_baseline_paths.v1"
    private let store: SQLiteStore
    private let organizer: OrganizerService
    private let indexer: IndexerService
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    /// Serial queue for all scan operations, preventing concurrent corruption of shared state.
    private let queue = DispatchQueue(label: "filenest.watcher")
    private var running = false
    /// Changes on every start and stop to identify stale asynchronous indexing tasks.
    private var runGeneration: UInt64 = 0
    var isRunning: Bool { queue.sync { running } }
    private let settings: AppSettings
    /// Forwarded to AppState so automatic work is not invisible to the user.
    var onAutomaticFileProcessing: (@Sendable (AutomaticFileProcessingEvent) -> Void)?
    /// Refreshes the library when a watcher operation persists metadata without moving a file.
    var onLibraryChange: (@Sendable () -> Void)?
    private var pollTimer: DispatchSourceTimer?
    private var stabilityTracker = FileStabilityTracker()
    private var directoryStabilityTracker = DirectoryStabilityTracker()
    private var directoryInspectionCache = [String: CachedDirectoryInspection]()
    private var directoryInspectionRetries = [String: DirectoryInspectionRetry]()
    private let minimumStableDuration: TimeInterval
    private let directoryMinimumStableDuration: TimeInterval
    private let pollingInterval: TimeInterval
    /// Deduplication table for processed files, accessed only from the queue.
    private var seen: Set<String> = []
    /// Verifies indexed-file hashes once per launch to catch offline overwrites that preserve size and modification time.
    private var startupContentAuditedPaths = Set<String>()
    private var startupContentMismatchPaths = Set<String>()
    /// Serializes the one-time SHA-256 inventory used for duplicate detection.
    /// Several watcher tasks may discover files at once, but only one is allowed to
    /// fill missing hashes before any of them look for an indexed original.
    private let contentHashInventoryQueue = DispatchQueue(label: "filenest.duplicate-hash-inventory")
    /// Avoids duplicate scan statistics in logs and records only changed diagnostic snapshots during polling.
    private var lastScanDiagnostics: [String: String] = [:]
    /// Items that already existed when the user requested manual organization; newly arriving items are unaffected.
    private var forceOrganizeEntryPaths: Set<String> = []
    private var directoryAccessStates: [String: WatchDirectoryAccessState] = [:]
    private var lastPublishedDirectoryStatuses: [WatchDirectoryStatus] = []
    private var manualOrganizationActive = false
    var onDirectoryStatusChange: (@Sendable ([WatchDirectoryStatus]) -> Void)?
    var watchedDirectoryCount: Int { queue.sync { sources.count } }

    init(store: SQLiteStore,
         organizer: OrganizerService,
         indexer: IndexerService,
         settings: AppSettings = .shared,
         minimumStableDuration: TimeInterval = 2,
         directoryMinimumStableDuration: TimeInterval = 30,
         pollingInterval: TimeInterval = 10) {
        self.store = store
        self.organizer = organizer
        self.indexer = indexer
        self.settings = settings
        self.minimumStableDuration = minimumStableDuration
        self.directoryMinimumStableDuration = directoryMinimumStableDuration
        self.pollingInterval = pollingInterval
    }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    private func startLocked() {
        guard !running else { return }
        runGeneration &+= 1
        running = true
        // A watcher restart is a new reconciliation pass. Keeping old dedup keys here
        // would hide offline overwrites whose size and mtime were intentionally preserved.
        seen.removeAll()
        startupContentAuditedPaths.removeAll()
        startupContentMismatchPaths.removeAll()
        directoryInspectionCache.removeAll()
        directoryInspectionRetries.removeAll()
        let dirs = settings.watchDirs.compactMap { URL(fileURLWithPath: $0) }
        Self.log(
            "watcher starting",
            category: .watchLifecycle,
            metadata: [
                "directories": "\(dirs.count)",
                "extensions": "\(settings.enabledExtensions.count)",
                "autoOrganize": "\(settings.autoOrganize)",
            ]
        )
        reconcileWatchedDirectories()
        startPolling()
        // Populate the persisted checksum inventory in the background. Duplicate
        // decisions for later arrivals can then compare against the complete
        // existing library without delaying the first filesystem event.
        Task { [weak self] in
            self?.prepareExistingContentHashes()
            self?.onLibraryChange?()
        }
        Self.log(
            "watcher started",
            category: .watchLifecycle,
            metadata: ["sources": "\(sources.count)", "pollSeconds": "\(pollingInterval)"]
        )
        publishDirectoryStatusesIfChanged()
    }

    func stop() {
        queue.sync {
            running = false
            runGeneration &+= 1
            for source in sources.values { source.cancel() }
            sources.removeAll()
            pollTimer?.cancel()
            pollTimer = nil
            stabilityTracker = FileStabilityTracker()
            directoryStabilityTracker = DirectoryStabilityTracker()
            directoryInspectionCache.removeAll()
            directoryInspectionRetries.removeAll()
            startupContentAuditedPaths.removeAll()
            startupContentMismatchPaths.removeAll()
            lastScanDiagnostics.removeAll()
            Self.log("watcher stopped", category: .watchLifecycle, level: .notice)
            publishDirectoryStatusesIfChanged()
        }
    }

    /// Immediately scans the current watched folders; effective only while watching is active.
    func scanNow() {
        queue.sync {
            guard running else { return }
            reconcileWatchedDirectories()
            for dir in settings.watchDirs {
                scanDirectory(URL(fileURLWithPath: dir))
            }
        }
    }

    /// Saves the folder's current direct children as a baseline; these items stay in place while later additions are processed normally.
    func preserveExistingEntries(in directoryPaths: [String]) {
        queue.sync {
            for path in Self.normalizedDirectoryPaths(directoryPaths) {
                do {
                    let entries = try Self.directEntryPaths(in: path)
                    try store.replaceWatchDirectoryBaseline(
                        directoryPath: path,
                        entryPaths: entries
                    )
                    setBaselinePending(false, for: path)
                    Self.log(
                        "existing entries preserved",
                        category: .watchBaseline,
                        metadata: ["directory": URL(fileURLWithPath: path).lastPathComponent,
                                   "entries": "\(entries.count)"]
                    )
                } catch {
                    setBaselinePending(true, for: path)
                    Self.log(
                        "existing entries were not preserved because the directory is unavailable: \(error)",
                        category: .watchBaseline,
                        level: .warning,
                        metadata: ["directory": URL(fileURLWithPath: path).lastPathComponent]
                    )
                }
            }
        }
    }

    /// Clears the keep-in-place baseline and forces organization only for items that exist when called.
    func organizeExistingEntries(in directoryPaths: [String]) {
        queue.sync {
            let paths = Self.normalizedDirectoryPaths(directoryPaths)
            do {
                try store.clearWatchDirectoryBaselines(directoryPaths: paths)
                setBaselinesPending(false, for: paths)
                Self.log(
                    "preserved-entry baselines cleared for manual organization",
                    category: .watchBaseline,
                    level: .notice,
                    metadata: ["directories": "\(paths.count)"]
                )
            } catch {
                Self.log(
                    "failed to clear preserved-entry baselines: \(error)",
                    category: .watchBaseline,
                    level: .error
                )
            }
            for path in paths {
                if let entries = try? Self.directEntryPaths(in: path) {
                    forceOrganizeEntryPaths.formUnion(entries)
                }
            }
            seen.removeAll()
            guard running else { return }
            reconcileWatchedDirectories()
            for path in paths {
                scanDirectory(URL(fileURLWithPath: path))
            }
        }
    }

    func clearPreservedEntries(in directoryPaths: [String]) {
        let paths = Self.normalizedDirectoryPaths(directoryPaths)
        queue.sync {
            do {
                try store.clearWatchDirectoryBaselines(directoryPaths: paths)
                setBaselinesPending(false, for: paths)
                Self.log(
                    "preserved-entry baselines cleared",
                    category: .watchBaseline,
                    metadata: ["directories": "\(paths.count)"]
                )
            } catch {
                Self.log(
                    "failed to clear preserved-entry baselines: \(error)",
                    category: .watchBaseline,
                    level: .error
                )
            }
        }
    }

    /// Processes the direct children of watched folders with the same eligibility and stability
    /// guarantees as automatic discovery. Existing library records are never reclassified here.
    func organizePendingEntries(
        in directoryPaths: [String]? = nil,
        includePreservedEntries: Bool = false,
        recursively: Bool = false,
        checkpoint: @escaping @Sendable () async -> Bool,
        progress: @escaping @MainActor @Sendable (OrganizationJobProgress) -> Void
    ) async -> OrganizationBatchResult {
        let paths = Self.normalizedDirectoryPaths(directoryPaths ?? settings.watchDirs)
        queue.sync { manualOrganizationActive = true }
        defer {
            queue.async { [weak self] in
                guard let self else { return }
                self.manualOrganizationActive = false
                guard self.running else { return }
                for path in paths {
                    self.scanDirectory(URL(fileURLWithPath: path))
                }
            }
        }

        var state = OrganizationJobProgress(
            phase: .preparing,
            completed: 0,
            total: 0,
            moved: 0,
            skipped: 0,
            failed: 0,
            currentFileName: nil,
            indexingStage: nil
        )
        await progress(state)

        var candidates = [ManualCandidate]()
        let enabledExtensions = Set(settings.enabledExtensions.map { $0.lowercased() })
        for path in paths {
            guard await checkpoint() else {
                return stoppedResult(from: state)
            }
            let directory = URL(fileURLWithPath: path)
            if recursively {
                candidates.append(contentsOf: recursiveManualCandidates(
                    in: directory,
                    enabledExtensions: enabledExtensions
                ))
                continue
            }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsSubdirectoryDescendants]
            ) else { continue }
            let baseline = includePreservedEntries
                ? Set<String>()
                : ((try? store.watchDirectoryBaselineEntries(directoryPath: path)) ?? [])
            for entry in entries where !baseline.contains(entry.path) {
                // Never feed the managed destination folder back into an ad-hoc organization pass.
                guard entry.standardizedFileURL.path != organizer.organizeRoot.standardizedFileURL.path else {
                    continue
                }
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                guard exclusionReason(
                    for: entry,
                    isDirectory: isDirectory,
                    enabledExtensions: enabledExtensions
                ) == nil else { continue }
                candidates.append(ManualCandidate(url: entry, isDirectory: isDirectory))
            }
        }

        state.total = candidates.count
        state.upcomingFileNames = Array(candidates.prefix(10).map { $0.url.lastPathComponent })
        await progress(state)
        guard !candidates.isEmpty else {
            state.phase = .completed
            await progress(state)
            return result(from: state, stopped: false)
        }

        while !candidates.isEmpty {
            guard await checkpoint() else {
                state.phase = .stopped
                await progress(state)
                return result(from: state, stopped: true)
            }

            let now = Date()
            var ready = [ManualCandidate]()
            var remaining = [ManualCandidate]()
            for var candidate in candidates {
                guard let fingerprint = candidateFingerprint(candidate) else {
                    state.completed += 1
                    state.skipped += 1
                    continue
                }
                if candidate.fingerprint != fingerprint {
                    candidate.fingerprint = fingerprint
                    candidate.stableSince = now
                    remaining.append(candidate)
                    continue
                }
                let minimumDuration = candidate.isDirectory
                    ? directoryMinimumStableDuration
                    : minimumStableDuration
                if let stableSince = candidate.stableSince,
                   now.timeIntervalSince(stableSince) >= minimumDuration {
                    ready.append(candidate)
                } else {
                    remaining.append(candidate)
                }
            }
            candidates = remaining
            state.upcomingFileNames = Array((ready + candidates).prefix(10).map { $0.url.lastPathComponent })

            guard !ready.isEmpty else {
                state.phase = .waitingForStability
                state.currentFileName = candidates.first?.url.lastPathComponent
                state.indexingStage = nil
                await progress(state)
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    state.phase = .stopped
                    await progress(state)
                    return result(from: state, stopped: true)
                }
                continue
            }

            for (index, candidate) in ready.enumerated() {
                guard await checkpoint() else {
                    state.phase = .stopped
                    await progress(state)
                    return result(from: state, stopped: true)
                }
                state.phase = .indexing
                state.currentFileName = candidate.url.lastPathComponent
                state.indexingStage = nil
                state.upcomingFileNames = Array(
                    (Array(ready.dropFirst(index + 1)) + candidates)
                        .prefix(10)
                        .map { $0.url.lastPathComponent }
                )
                await progress(state)

                guard let fileID = register(candidate) else {
                    state.completed += 1
                    state.failed += 1
                    await progress(state)
                    continue
                }
                if let original = await linkDuplicateIfNeeded(
                    fileID: fileID,
                    url: candidate.url,
                    isDirectory: candidate.isDirectory
                ) {
                    state.completed += 1
                    state.skipped += 1
                    state.currentFileName = candidate.url.lastPathComponent
                    state.indexingStage = nil
                    await progress(state)
                    Self.log(
                        "manual organization skipped duplicate file indexing",
                        category: .organizeQueue,
                        level: .notice,
                        metadata: [
                            "file": candidate.url.lastPathComponent,
                            "original": original.name,
                        ]
                    )
                    continue
                }
                let progressSnapshot = state
                let indexed = await indexer.indexFile(
                    id: fileID,
                    overridePath: candidate.url,
                    forceVectorization: candidate.isDirectory,
                    checkpoint: checkpoint
                ) { stage in
                    await progress(OrganizationJobProgress(
                        phase: .indexing,
                        completed: progressSnapshot.completed,
                        total: progressSnapshot.total,
                        moved: progressSnapshot.moved,
                        skipped: progressSnapshot.skipped,
                        failed: progressSnapshot.failed,
                        currentFileName: candidate.url.lastPathComponent,
                        indexingStage: stage,
                        // Indexer callbacks report a narrow stage snapshot. Preserve
                        // the job-level queue preview so the pending-files control
                        // does not disappear while a document is being indexed.
                        upcomingFileNames: progressSnapshot.upcomingFileNames
                    ))
                }
                guard indexed else {
                    let canContinue = await checkpoint()
                    if Task.isCancelled || !canContinue {
                        state.phase = .stopped
                        await progress(state)
                        return result(from: state, stopped: true)
                    }
                    state.completed += 1
                    state.failed += 1
                    await progress(state)
                    continue
                }

                state.phase = .organizing
                state.indexingStage = nil
                await progress(state)
                let pathBeforeMove = (try? store.file(id: fileID))?.path
                do {
                    try await organizer.organizeUsingAI(fileId: fileID, checkpoint: checkpoint)
                    let updated = try? store.file(id: fileID)
                    if updated?.organizedAt != nil, updated?.path != pathBeforeMove {
                        state.moved += 1
                    } else {
                        state.skipped += 1
                    }
                } catch {
                    state.failed += 1
                    Self.log(
                        "manual organization failed: \(error)",
                        category: .organizeQueue,
                        level: .error,
                        metadata: ["entry": candidate.url.lastPathComponent]
                    )
                }
                state.completed += 1
                await progress(state)
            }
        }

        state.phase = state.failed > 0 ? .failed : .completed
        state.currentFileName = nil
        state.indexingStage = nil
        state.upcomingFileNames = []
        await progress(state)
        return result(from: state, stopped: false)
    }

    /// Enumerates file leaves only. Directories remain in place while their eligible contents
    /// are processed, which prevents a recursive pass from moving a parent before its children.
    private func recursiveManualCandidates(
        in root: URL,
        enabledExtensions: Set<String>
    ) -> [ManualCandidate] {
        guard !isRepositoryDirectory(root) else {
            Self.log(
                "recursive organization skipped repository root",
                category: .organizeQueue,
                level: .notice,
                metadata: ["directory": root.lastPathComponent]
            )
            return []
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]
        let options: FileManager.DirectoryEnumerationOptions = settings.excludeHidden
            ? [.skipsHiddenFiles, .skipsPackageDescendants]
            : [.skipsPackageDescendants]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: options,
            errorHandler: { url, error in
                Self.log(
                    "recursive organization could not read directory",
                    category: .organizeQueue,
                    level: .warning,
                    metadata: ["directory": url.lastPathComponent, "error": error.localizedDescription]
                )
                return true
            }
        ) else { return [] }

        let managedRoot = organizer.organizeRoot.standardizedFileURL.path
        var candidates = [ManualCandidate]()
        while let entry = enumerator.nextObject() as? URL {
            let values = try? entry.resourceValues(forKeys: keys)
            let isDirectory = values?.isDirectory == true
            let isSymbolicLink = values?.isSymbolicLink == true

            if isDirectory {
                if isSymbolicLink ||
                    entry.standardizedFileURL.path == managedRoot ||
                    isRepositoryDirectory(entry) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard !isSymbolicLink,
                  exclusionReason(
                    for: entry,
                    isDirectory: false,
                    enabledExtensions: enabledExtensions
                  ) == nil else { continue }
            candidates.append(ManualCandidate(url: entry, isDirectory: false))
        }
        return candidates
    }

    /// Source-control worktrees are intentionally excluded as a unit. Moving only some of
    /// their nested files would make a repository unusable, so the enumerator skips them.
    private func isRepositoryDirectory(_ directory: URL) -> Bool {
        let metadataNames = [".git", ".hg", ".svn"]
        if metadataNames.contains(directory.lastPathComponent) { return true }
        return metadataNames.contains { marker in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(marker).path)
        }
    }

    private func exclusionReason(
        for entry: URL,
        isDirectory: Bool,
        enabledExtensions: Set<String>
    ) -> EntryExclusion? {
        let name = entry.lastPathComponent
        if FileEligibilityPolicy.shouldIgnoreFile(named: name) { return .transient }
        if settings.excludeHidden && name.hasPrefix(".") { return .hidden }
        if !isDirectory,
           enabledExtensions.isNotEmpty,
           !enabledExtensions.contains(entry.pathExtension.lowercased()) {
            return .unsupportedExtension
        }
        return nil
    }

    private func candidateFingerprint(_ candidate: ManualCandidate) -> String? {
        if candidate.isDirectory {
            return DirectoryInspector.inspect(candidate.url)?.snapshot.signature
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.url.path) else {
            return nil
        }
        let size = Int64((attributes[.size] as? NSNumber)?.intValue ?? 0)
        let modificationDate = (attributes[.modificationDate] as? Date) ?? .distantPast
        return "\(size)|\(modificationDate.timeIntervalSinceReferenceDate)"
    }

    private func register(_ candidate: ManualCandidate) -> Int64? {
        if candidate.isDirectory {
            guard let inspection = DirectoryInspector.inspect(candidate.url) else { return nil }
            let existing = try? store.file(path: candidate.url.path)
            let record = FileRecord(
                id: existing?.id,
                path: candidate.url.path,
                name: candidate.url.lastPathComponent,
                ext: "",
                size: inspection.snapshot.totalSize,
                mtime: inspection.snapshot.latestModificationDate,
                category: inspection.category.rawValue,
                sourceDir: candidate.url.deletingLastPathComponent().path,
                indexedAt: existing?.indexedAt,
                contentHash: existing?.contentHash,
                title: existing?.title,
                contentText: existing?.contentText,
                discoveredAt: existing?.discoveredAt ?? Date(),
                organizedAt: existing?.organizedAt,
                note: existing?.note,
                organizationSubfolder: existing?.organizationSubfolder,
                isDirectory: true
            )
            return try? store.upsertFile(record)
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.url.path) else {
            return nil
        }
        let existing = try? store.file(path: candidate.url.path)
        let record = FileRecord(
            id: existing?.id,
            path: candidate.url.path,
            name: candidate.url.lastPathComponent,
            ext: candidate.url.pathExtension,
            size: Int64((attributes[.size] as? NSNumber)?.intValue ?? 0),
            mtime: (attributes[.modificationDate] as? Date) ?? Date(),
            category: FileCategory.from(extension: candidate.url.pathExtension).rawValue,
            sourceDir: candidate.url.deletingLastPathComponent().path,
            indexedAt: existing?.indexedAt,
            contentHash: existing?.contentHash,
            title: existing?.title,
            contentText: existing?.contentText,
            discoveredAt: existing?.discoveredAt ?? Date(),
            organizedAt: existing?.organizedAt,
            note: existing?.note,
            organizationSubfolder: existing?.organizationSubfolder
        )
        return try? store.upsertFile(record)
    }

    private func result(from progress: OrganizationJobProgress, stopped: Bool) -> OrganizationBatchResult {
        OrganizationBatchResult(
            completed: progress.completed,
            total: progress.total,
            moved: progress.moved,
            skipped: progress.skipped,
            failed: progress.failed,
            stopped: stopped
        )
    }

    private func stoppedResult(from progress: OrganizationJobProgress) -> OrganizationBatchResult {
        result(from: progress, stopped: true)
    }

    static func inventories(
        for directoryPaths: [String],
        enabledExtensions: [String],
        excludeHidden: Bool
    ) -> [WatchDirectoryInventory] {
        let enabled = Set(enabledExtensions.map { $0.lowercased() })
        return normalizedDirectoryPaths(directoryPaths).map { path in
            let url = URL(fileURLWithPath: path)
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsSubdirectoryDescendants]
                )
            } catch {
                return WatchDirectoryInventory(
                    path: path,
                    fileCount: 0,
                    directoryCount: 0,
                    accessState: accessState(for: error)
                )
            }
            var fileCount = 0
            var directoryCount = 0
            for entry in entries {
                let name = entry.lastPathComponent
                if FileEligibilityPolicy.shouldIgnoreFile(named: name) { continue }
                if excludeHidden && name.hasPrefix(".") { continue }
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDirectory {
                    directoryCount += 1
                } else if enabled.isEmpty || enabled.contains(entry.pathExtension.lowercased()) {
                    fileCount += 1
                }
            }
            return WatchDirectoryInventory(
                path: path,
                fileCount: fileCount,
                directoryCount: directoryCount,
                accessState: .accessible
            )
        }
    }

    /// Watches one folder by monitoring write events on its directory descriptor with DispatchSource.
    private func watchDirectory(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path
        guard sources[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            let state = Self.accessState(forPOSIXCode: errno)
            if updateAccessState(state, for: path) {
                Self.log(
                    "failed to attach directory source",
                    category: .watchLifecycle,
                    level: .error,
                    metadata: [
                        "accessState": state.rawValue,
                        "directory": standardizedURL.lastPathComponent,
                    ]
                )
            }
            publishDirectoryStatusesIfChanged()
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.sources[path]?.data ?? []
            if events.contains(.delete) || events.contains(.rename) {
                self.removeWatchDirectory(path: path)
                self.reconcileWatchedDirectories()
                return
            }
            self.scanDirectory(standardizedURL)
        }
        src.setCancelHandler { [fd] in
            close(fd)
        }
        sources[path] = src
        src.resume()
        // Record the first snapshot on startup; later events or polling process files after they stabilize.
        if scanDirectory(standardizedURL) {
            Self.log(
                "directory source attached",
                category: .watchLifecycle,
                metadata: ["directory": standardizedURL.lastPathComponent]
            )
        }
    }

    private func removeWatchDirectory(path: String, logLifecycle: Bool = true) {
        guard let source = sources.removeValue(forKey: path) else { return }
        source.cancel()
        lastScanDiagnostics.removeValue(forKey: path)
        if logLifecycle {
            Self.log(
                "directory source detached",
                category: .watchLifecycle,
                level: .notice,
                metadata: ["directory": URL(fileURLWithPath: path).lastPathComponent]
            )
        }
    }

    /// Reconciles configuration with disk state, releasing sources for missing folders and restoring them when they reappear.
    private func reconcileWatchedDirectories() {
        let directories = settings.watchDirs.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let desiredPaths = Set(directories.map(\.path))

        for path in Array(sources.keys) {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            if !desiredPaths.contains(path) || !exists || !isDirectory.boolValue {
                removeWatchDirectory(path: path)
            }
        }

        directoryAccessStates = directoryAccessStates.filter { desiredPaths.contains($0.key) }

        for directory in directories where sources[directory.path] == nil {
            watchDirectory(directory)
        }
        publishDirectoryStatusesIfChanged()
    }

    /// Periodic polling fallback for events that DispatchSource may miss.
    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollingInterval, repeating: pollingInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.reconcileWatchedDirectories()
            for dir in self.settings.watchDirs {
                self.scanDirectory(URL(fileURLWithPath: dir))
            }
        }
        timer.resume()
        pollTimer = timer
    }

    /// Scans a folder for added or modified files; called only on the serial queue, so seen requires no extra locking.
    @discardableResult
    private func scanDirectory(_ url: URL) -> Bool {
        guard !manualOrganizationActive else { return true }
        let fm = FileManager.default
        let path = url.standardizedFileURL.path
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            let state = Self.accessState(for: error)
            if updateAccessState(state, for: path) {
                Self.log(
                    "directory scan failed",
                    category: .watchScan,
                    level: .error,
                    metadata: ["accessState": state.rawValue, "directory": url.lastPathComponent]
                )
            }
            if sources[path] != nil { removeWatchDirectory(path: path, logLifecycle: false) }
            publishDirectoryStatusesIfChanged()
            return false
        }
        let previousState = directoryAccessStates[path]
        _ = updateAccessState(.accessible, for: path)
        if previousState != nil && previousState != .accessible {
            Self.log(
                "directory access restored; starting incremental scan",
                category: .watchLifecycle,
                level: .notice,
                metadata: ["directory": url.lastPathComponent]
            )
        }
        publishDirectoryStatusesIfChanged()

        let enabledExts = Set(settings.enabledExtensions.map { $0.lowercased() })
        let now = Date()
        var processedThisScan = 0
        var baselineSkipped = 0
        var transientSkipped = 0
        var hiddenSkipped = 0
        var extensionSkipped = 0
        var unstableSkipped = 0
        var inspectionFailures = 0
        let existingPaths = Set(entries.map(\.path))

        if pendingBaselinePaths().contains(path) {
            do {
                try store.replaceWatchDirectoryBaseline(
                    directoryPath: path,
                    entryPaths: existingPaths
                )
                setBaselinePending(false, for: path)
                Self.log(
                    "deferred existing-entry baseline created after directory access was restored",
                    category: .watchBaseline,
                    level: .notice,
                    metadata: ["directory": url.lastPathComponent, "entries": "\(existingPaths.count)"]
                )
            } catch {
                Self.log(
                    "failed to create deferred existing-entry baseline: \(error)",
                    category: .watchBaseline,
                    level: .error,
                    metadata: ["directory": url.lastPathComponent]
                )
                return false
            }
        }

        // Remove baseline items missing from disk; a later item at the same path is treated as new.
        try? store.retainWatchDirectoryBaselineEntries(
            directoryPath: url.standardizedFileURL.path,
            existingEntryPaths: existingPaths
        )
        let baselineEntries = (try? store.watchDirectoryBaselineEntries(directoryPath: path)) ?? []
        let storedFilesByPath = (try? store.files(atPaths: existingPaths)) ?? [:]

        for entry in entries {
            if baselineEntries.contains(entry.path) {
                baselineSkipped += 1
                continue
            }
            let name = entry.lastPathComponent
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            if let exclusion = exclusionReason(
                for: entry,
                isDirectory: isDir.boolValue,
                enabledExtensions: enabledExts
            ) {
                switch exclusion {
                case .transient: transientSkipped += 1
                case .hidden: hiddenSkipped += 1
                case .unsupportedExtension: extensionSkipped += 1
                }
                continue
            }
            if isDir.boolValue {
                guard let inspection = inspectWatchedDirectory(entry, observedAt: now) else {
                    inspectionFailures += 1
                    continue
                }
                let dedupKey = "directory|\(entry.path)|\(inspection.snapshot.signature)"
                let shouldOrganize = settings.autoOrganize || forceOrganizeEntryPaths.contains(entry.path)
                if let existing = storedFilesByPath[entry.path],
                   existing.isDirectory,
                   existing.indexedAt != nil,
                   existing.contentHash == inspection.snapshot.signature {
                    seen.insert(dedupKey)
                    // Organizer rejects a folder that changes briefly before organization, such as due to .git/index.lock.
                    // Requeue the folder when it returns to the indexed snapshot so it does not remain stuck in a watched folder.
                    if shouldOrganize,
                       existing.organizedAt == nil,
                       let id = existing.id {
                        organizer.enqueue(fileId: id, force: shouldOrganize && !settings.autoOrganize)
                        finishForcedOrganization(for: entry.path)
                    }
                    continue
                }
                if seen.contains(dedupKey) { continue }
                guard directoryStabilityTracker.isStable(
                    path: entry.path,
                    snapshot: inspection.snapshot,
                    observedAt: now,
                    minimumStableDuration: directoryMinimumStableDuration
                ) else {
                    unstableSkipped += 1
                    continue
                }
                seen.insert(dedupKey)
                processedThisScan += 1
                handleNewDirectory(
                    at: entry,
                    inspection: inspection,
                    dedupKey: dedupKey,
                    shouldOrganize: shouldOrganize
                )
                continue
            }

            // Deduplicate processed paths unless their modification time changed.
            let attrs = try? fm.attributesOfItem(atPath: entry.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? now
            let size = Int64((attrs?[.size] as? NSNumber)?.intValue ?? 0)
            let dedupKey = "\(entry.path)|\(size)|\(mtime.timeIntervalSinceReferenceDate)"
            let shouldOrganize = settings.autoOrganize || forceOrganizeEntryPaths.contains(entry.path)
            if seen.contains(dedupKey) { continue }

            // Verify the content hash once per launch even when metadata is unchanged, so sync-tool overwrites are detected
            // when they preserve size and modification time.
            if let existing = storedFilesByPath[entry.path],
               existing.size == size,
               abs(existing.mtime.timeIntervalSince(mtime)) < 0.001,
               existing.indexedAt != nil,
               existing.contentHash != nil {
                if startupContentAuditedPaths.insert(entry.path).inserted {
                    let currentHash = try? FileContentHasher.sha256(of: entry)
                    if currentHash != existing.contentHash {
                        startupContentMismatchPaths.insert(entry.path)
                        Self.log(
                            "content changed while size and modification date stayed the same",
                            category: .watchDiscovery,
                            level: .notice,
                            metadata: ["file": name]
                        )
                    }
                }
                if !startupContentMismatchPaths.contains(entry.path) {
                    seen.insert(dedupKey)
                    if shouldOrganize,
                       existing.organizedAt == nil,
                       let id = existing.id {
                        organizer.enqueue(fileId: id, force: shouldOrganize && !settings.autoOrganize)
                        finishForcedOrganization(for: entry.path)
                    }
                    continue
                }
            }

            let snapshot = FileSnapshot(size: size, modificationDate: mtime)
            guard stabilityTracker.isStable(path: entry.path,
                                             snapshot: snapshot,
                                             observedAt: now,
                                             minimumStableDuration: minimumStableDuration) else {
                unstableSkipped += 1
                continue
            }

            seen.insert(dedupKey)
            processedThisScan += 1
            handleNewFile(
                at: entry,
                mtime: mtime,
                size: size,
                dedupKey: dedupKey,
                shouldOrganize: shouldOrganize
            )
        }
        reconcileRemovedEntries(in: url, existingPaths: existingPaths)
        stabilityTracker.retainExistingPaths(existingPaths, in: url.standardizedFileURL.path)
        directoryStabilityTracker.retainExistingPaths(existingPaths, in: url.standardizedFileURL.path)
        logScanDiagnosticsIfChanged(
            directory: url,
            entries: entries.count,
            processed: processedThisScan,
            baselineSkipped: baselineSkipped,
            transientSkipped: transientSkipped,
            hiddenSkipped: hiddenSkipped,
            extensionSkipped: extensionSkipped,
            unstableSkipped: unstableSkipped,
            inspectionFailures: inspectionFailures
        )
        // Keep the latest 2,000 entries to prevent unbounded growth of seen.
        if seen.count > 2000 {
            seen = Set(seen.suffix(1000))
        }
        return true
    }

    /// Large or actively changing directory trees are retried with exponential backoff.
    /// A short successful-result cache also coalesces duplicate FSEvent and polling scans.
    private func inspectWatchedDirectory(_ url: URL, observedAt now: Date) -> DirectoryInspection? {
        let path = url.standardizedFileURL.path
        if let retry = directoryInspectionRetries[path], retry.nextAttemptAt > now {
            return nil
        }
        if let cached = directoryInspectionCache[path], cached.expiresAt > now {
            return cached.inspection
        }

        guard let inspection = DirectoryInspector.inspect(url, budget: .watcher) else {
            directoryInspectionCache.removeValue(forKey: path)
            let failures = min(8, (directoryInspectionRetries[path]?.failures ?? 0) + 1)
            let delay = min(15 * 60, max(pollingInterval, 15) * pow(2, Double(failures - 1)))
            directoryInspectionRetries[path] = DirectoryInspectionRetry(
                failures: failures,
                nextAttemptAt: now.addingTimeInterval(delay)
            )
            return nil
        }

        directoryInspectionRetries.removeValue(forKey: path)
        directoryInspectionCache[path] = CachedDirectoryInspection(
            inspection: inspection,
            expiresAt: now.addingTimeInterval(min(5, max(1, pollingInterval / 2)))
        )
        return inspection
    }

    /// Remove records whose original top-level watched entry disappeared while FileNest
    /// was not running. Organized records are not affected because their current parent
    /// is the managed library rather than the watched directory.
    private func reconcileRemovedEntries(in directory: URL, existingPaths: Set<String>) {
        let rootPath = Self.canonicalPath(directory.path)
        let canonicalExistingPaths = Set(existingPaths.map(Self.canonicalPath))
        let fm = FileManager.default
        guard let records = try? store.libraryFiles(inSourceDirectory: directory.path) else { return }
        for record in records {
            let path = Self.canonicalPath(record.path)
            let parentPath = Self.canonicalPath(
                URL(fileURLWithPath: path).deletingLastPathComponent().path
            )
            guard parentPath == rootPath,
                  !canonicalExistingPaths.contains(path),
                  !fm.fileExists(atPath: record.path),
                  let id = record.id else { continue }
            do {
                try store.deleteFile(id: id)
                startupContentAuditedPaths.remove(path)
                startupContentMismatchPaths.remove(path)
                Self.log(
                    "missing watched entry removed from index",
                    category: .watchDiscovery,
                    level: .notice,
                    metadata: ["entry": record.name]
                )
            } catch {
                Self.log(
                    "failed to remove missing watched entry: \(error)",
                    category: .watchDiscovery,
                    level: .error,
                    metadata: ["entry": record.name]
                )
            }
        }
    }

    private func handleNewDirectory(at url: URL,
                                    inspection: DirectoryInspection,
                                    dedupKey: String,
                                    shouldOrganize: Bool) {
        let generation = runGeneration
        let existing = try? store.file(path: url.path)
        let record = FileRecord(
            id: existing?.id,
            path: url.path,
            name: url.lastPathComponent,
            ext: "",
            size: inspection.snapshot.totalSize,
            mtime: inspection.snapshot.latestModificationDate,
            category: inspection.category.rawValue,
            sourceDir: url.deletingLastPathComponent().path,
            indexedAt: existing?.indexedAt,
            contentHash: existing?.contentHash,
            title: existing?.title,
            contentText: existing?.contentText,
            discoveredAt: existing?.discoveredAt ?? Date(),
            organizedAt: existing?.organizedAt,
            note: existing?.note,
            organizationSubfolder: existing?.organizationSubfolder,
            isDirectory: true
        )
        do {
            let id = try store.upsertFile(record)
            reportAutomaticProcessing(fileID: id, fileName: record.name, stage: .queued)
            Self.log(
                "stable directory discovered",
                category: .watchDiscovery,
                metadata: [
                    "entry": record.name,
                    "fileID": "\(id)",
                    "reference": inspection.referenceFile?.lastPathComponent ?? "none",
                ]
            )
            Task {
                if let original = await self.linkDuplicateIfNeeded(fileID: id, url: url, isDirectory: false) {
                    self.reportAutomaticProcessing(
                        fileID: id,
                        fileName: record.name,
                        stage: .duplicate(originalFileName: original.name)
                    )
                    Self.log(
                        "watcher linked duplicate file without indexing",
                        category: .watchDiscovery,
                        level: .notice,
                        metadata: ["file": record.name, "original": original.name]
                    )
                    self.onLibraryChange?()
                    return
                }
                guard await indexer.indexFile(
                    id: id,
                    overridePath: url,
                    forceVectorization: true,
                    stageProgress: { [weak self] stage in
                        self?.reportAutomaticProcessing(fileID: id, fileName: record.name, stage: .indexing(stage))
                    }
                ) else {
                    self.reportAutomaticProcessing(fileID: id, fileName: record.name, stage: .failed("Indexing failed"))
                    Self.log(
                        "directory indexing failed; keeping entry in place",
                        category: .watchDiscovery,
                        level: .warning,
                        metadata: ["entry": record.name]
                    )
                    self.allowRetry(for: dedupKey)
                    return
                }
                guard await self.isActive(generation: generation) else {
                    self.reportAutomaticProcessing(fileID: id, fileName: record.name, stage: .failed("Watching paused"))
                    Self.log(
                        "watcher stopped before directory organization",
                        category: .watchLifecycle,
                        level: .notice,
                        metadata: ["entry": record.name]
                    )
                    return
                }
                if shouldOrganize {
                    self.reportAutomaticProcessing(fileID: id, fileName: record.name, stage: .waitingForOrganization)
                    self.organizer.enqueue(fileId: id, force: shouldOrganize && !self.settings.autoOrganize)
                    self.finishForcedOrganization(for: url.path)
                } else {
                    self.reportAutomaticProcessing(fileID: id, fileName: record.name, stage: .completed)
                }
            }
        } catch {
            Self.log(
                "failed to register discovered directory: \(error)",
                category: .watchDiscovery,
                level: .error,
                metadata: ["entry": record.name]
            )
            allowRetry(for: dedupKey)
        }
    }

    private func handleNewFile(
        at url: URL,
        mtime: Date,
        size: Int64,
        dedupKey: String,
        shouldOrganize: Bool
    ) {
        let generation = runGeneration
        let ext = url.pathExtension
        let category = FileCategory.from(extension: ext)
        let existing = try? store.file(path: url.path)
        let record = FileRecord(
            id: existing?.id, path: url.path, name: url.lastPathComponent, ext: ext,
            size: size, mtime: mtime, category: category.rawValue,
            sourceDir: url.deletingLastPathComponent().path,
            indexedAt: existing?.indexedAt, contentHash: existing?.contentHash,
            title: existing?.title, contentText: existing?.contentText,
            discoveredAt: existing?.discoveredAt ?? Date()
        )
        do {
            let id = try store.upsertFile(record)
            reportAutomaticProcessing(fileID: id, fileName: record.name, stage: .queued)
            Self.log(
                "file discovered",
                category: .watchDiscovery,
                metadata: ["file": record.name, "fileID": "\(id)", "type": category.rawValue]
            )
            // Important: index the file while it is still in place, then organize and move it.
            // Moving first would invalidate the original path and prevent the indexer from reading the content.
            // Index from the original URL, then let the organizer update the database path after moving.
            Task {
                if let original = await self.linkDuplicateIfNeeded(
                    fileID: id,
                    url: url,
                    isDirectory: false
                ) {
                    self.reportAutomaticProcessing(
                        fileID: id,
                        fileName: record.name,
                        stage: .duplicate(originalFileName: original.name)
                    )
                    Self.log(
                        "watcher linked duplicate file without indexing",
                        category: .watchDiscovery,
                        level: .notice,
                        metadata: ["file": record.name, "original": original.name]
                    )
                    self.onLibraryChange?()
                    return
                }
                guard await indexer.indexFile(
                    id: id,
                    overridePath: url,
                    stageProgress: { [weak self] stage in
                        self?.reportAutomaticProcessing(fileID: id, fileName: record.name, stage: .indexing(stage))
                    }
                ) else {
                    self.reportAutomaticProcessing(fileID: id, fileName: record.name, stage: .failed("Indexing failed"))
                    Self.log(
                        "file indexing failed; keeping file in place",
                        category: .watchDiscovery,
                        level: .warning,
                        metadata: ["file": record.name]
                    )
                    self.allowRetry(for: dedupKey)
                    return
                }
                guard await self.isActive(generation: generation) else {
                    self.reportAutomaticProcessing(fileID: id, fileName: record.name, stage: .failed("Watching paused"))
                    Self.log(
                        "watcher stopped before file organization",
                        category: .watchLifecycle,
                        level: .notice,
                        metadata: ["file": record.name]
                    )
                    return
                }
                if shouldOrganize {
                    self.reportAutomaticProcessing(fileID: id, fileName: record.name, stage: .waitingForOrganization)
                    self.organizer.enqueue(fileId: id, force: shouldOrganize && !self.settings.autoOrganize)
                    self.finishForcedOrganization(for: url.path)
                } else {
                    self.reportAutomaticProcessing(fileID: id, fileName: record.name, stage: .completed)
                }
            }
        } catch {
            Self.log(
                "failed to register discovered file: \(error)",
                category: .watchDiscovery,
                level: .error,
                metadata: ["file": record.name]
            )
            allowRetry(for: dedupKey)
        }
    }

    private func allowRetry(for dedupKey: String) {
        queue.async { [weak self] in
            self?.seen.remove(dedupKey)
        }
    }

    /// Calculates hashes only for legacy files that lack one. New arrivals call this
    /// before indexing, ensuring a duplicate comparison always considers the full
    /// existing library rather than only recently indexed files.
    private func prepareExistingContentHashes() {
        contentHashInventoryQueue.sync {
            let candidates = (try? store.filesMissingContentHash()) ?? []
            for file in candidates {
                guard !file.isDirectory,
                      let id = file.id,
                      FileManager.default.fileExists(atPath: file.path),
                      let hash = try? FileContentHasher.sha256(of: URL(fileURLWithPath: file.path)) else {
                    continue
                }
                try? store.updateFileContentHash(id: id, contentHash: hash)
            }
        }
    }

    /// Links a newly discovered regular file to an already indexed original with
    /// matching bytes. The duplicate keeps its own filesystem path, but does not
    /// create extraction, chunk, or embedding rows.
    private func linkDuplicateIfNeeded(
        fileID: Int64,
        url: URL,
        isDirectory: Bool
    ) async -> FileRecord? {
        guard !isDirectory, FileManager.default.fileExists(atPath: url.path) else { return nil }
        prepareExistingContentHashes()
        guard let contentHash = try? FileContentHasher.sha256(of: url),
              let original = try? store.indexedOriginal(
                matchingContentHash: contentHash,
                excludingFileID: fileID
              ),
              let originalID = original.id else {
            return nil
        }
        await indexer.cancel(fileID: fileID)
        await indexer.vectorStore.remove(fileId: fileID)
        do {
            try store.markFileAsDuplicate(
                id: fileID,
                originalFileID: originalID,
                contentHash: contentHash
            )
            return original
        } catch {
            Self.log(
                "could not persist duplicate file link",
                category: .watchDiscovery,
                level: .error,
                metadata: ["file": url.lastPathComponent, "error": error.localizedDescription]
            )
            return nil
        }
    }

    private func reportAutomaticProcessing(
        fileID: Int64,
        fileName: String,
        stage: AutomaticFileProcessingStage
    ) {
        onAutomaticFileProcessing?(AutomaticFileProcessingEvent(
            fileID: fileID,
            fileName: fileName,
            stage: stage
        ))
    }

    private func finishForcedOrganization(for path: String) {
        queue.async { [weak self] in
            self?.forceOrganizeEntryPaths.remove(path)
        }
    }

    private func isActive(generation: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: self.running && self.runGeneration == generation)
            }
        }
    }

    private func logScanDiagnosticsIfChanged(
        directory: URL,
        entries: Int,
        processed: Int,
        baselineSkipped: Int,
        transientSkipped: Int,
        hiddenSkipped: Int,
        extensionSkipped: Int,
        unstableSkipped: Int,
        inspectionFailures: Int
    ) {
        let signature = [
            entries, processed, baselineSkipped, transientSkipped, hiddenSkipped,
            extensionSkipped, unstableSkipped, inspectionFailures,
        ].map(String.init).joined(separator: "|")
        let path = directory.standardizedFileURL.path
        guard lastScanDiagnostics[path] != signature else { return }
        lastScanDiagnostics[path] = signature
        Self.log(
            "directory scan snapshot changed",
            category: .watchScan,
            level: .debug,
            metadata: [
                "directory": directory.lastPathComponent,
                "entries": "\(entries)",
                "processed": "\(processed)",
                "baseline": "\(baselineSkipped)",
                "transient": "\(transientSkipped)",
                "hidden": "\(hiddenSkipped)",
                "extension": "\(extensionSkipped)",
                "unstable": "\(unstableSkipped)",
                "inspectionFailed": "\(inspectionFailures)",
            ]
        )
    }

    static func log(
        _ message: String,
        category: AppLogCategory,
        level: AppLogLevel = .info,
        metadata: [String: String] = [:]
    ) {
        AppLogService.shared.write(message, category: category, level: level, metadata: metadata)
    }

    private static func normalizedDirectoryPaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }

    private func updateAccessState(_ state: WatchDirectoryAccessState, for path: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard directoryAccessStates[normalizedPath] != state else { return false }
        directoryAccessStates[normalizedPath] = state
        return true
    }

    private func publishDirectoryStatusesIfChanged() {
        let statuses = Self.normalizedDirectoryPaths(settings.watchDirs).map { path in
            WatchDirectoryStatus(
                path: path,
                accessState: directoryAccessStates[path] ?? .unavailable,
                isWatching: running && sources[path] != nil && directoryAccessStates[path] == .accessible
            )
        }
        guard statuses != lastPublishedDirectoryStatuses else { return }
        lastPublishedDirectoryStatuses = statuses
        onDirectoryStatusChange?(statuses)
    }

    private static func accessState(for error: Error) -> WatchDirectoryAccessState {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.Code.fileReadNoPermission.rawValue {
            return .permissionDenied
        }
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.Code.fileNoSuchFile.rawValue {
            return .missing
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return accessState(forPOSIXCode: Int32(nsError.code))
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return accessState(forPOSIXCode: Int32(underlying.code))
        }
        return .unavailable
    }

    private static func accessState(forPOSIXCode code: Int32) -> WatchDirectoryAccessState {
        if code == EACCES || code == EPERM { return .permissionDenied }
        if code == ENOENT { return .missing }
        return .unavailable
    }

    private func pendingBaselinePaths() -> Set<String> {
        guard let raw = store.getSetting(Self.pendingBaselinePathsKey),
              let data = raw.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(paths)
    }

    private func setBaselinePending(_ pending: Bool, for path: String) {
        setBaselinesPending(pending, for: [path])
    }

    private func setBaselinesPending(_ pending: Bool, for paths: [String]) {
        var stored = pendingBaselinePaths()
        let normalizedPaths = Set(Self.normalizedDirectoryPaths(paths))
        if pending {
            stored.formUnion(normalizedPaths)
        } else {
            stored.subtract(normalizedPaths)
        }
        guard let data = try? JSONEncoder().encode(stored.sorted()),
              let raw = String(data: data, encoding: .utf8) else { return }
        store.setSetting(Self.pendingBaselinePathsKey, raw)
    }

    private static func directEntryPaths(in directoryPath: String) throws -> Set<String> {
        let url = URL(fileURLWithPath: directoryPath)
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
        // Preserve the path representation returned by contentsOfDirectory; scanning uses the same API.
        // Renormalizing between /var and /private/var would produce unequal baseline paths for the same file.
        return Set(entries.map(\.path))
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }
}

private extension Collection {
    var isNotEmpty: Bool { !isEmpty }
}
