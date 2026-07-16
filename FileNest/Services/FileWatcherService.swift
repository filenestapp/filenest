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

/// File-watching service that uses DispatchSource to monitor configured folders for new files,
/// then triggers organization and indexing.
final class FileWatcherService: @unchecked Sendable {
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
    private var pollTimer: DispatchSourceTimer?
    private var stabilityTracker = FileStabilityTracker()
    private var directoryStabilityTracker = DirectoryStabilityTracker()
    private let minimumStableDuration: TimeInterval
    private let directoryMinimumStableDuration: TimeInterval
    private let pollingInterval: TimeInterval
    /// Deduplication table for processed files, accessed only from the queue.
    private var seen: Set<String> = []
    /// Verifies indexed-file hashes once per launch to catch offline overwrites that preserve size and modification time.
    private var startupContentAuditedPaths = Set<String>()
    private var startupContentMismatchPaths = Set<String>()
    /// Avoids duplicate scan statistics in logs and records only changed diagnostic snapshots during polling.
    private var lastScanDiagnostics: [String: String] = [:]
    /// Items that already existed when the user requested manual organization; newly arriving items are unaffected.
    private var forceOrganizeEntryPaths: Set<String> = []
    private var directoryAccessStates: [String: WatchDirectoryAccessState] = [:]
    private var lastPublishedDirectoryStatuses: [WatchDirectoryStatus] = []
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
        updateAccessState(.accessible, for: path)
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

        for entry in entries {
            let directoryPath = url.standardizedFileURL.path
            if store.isWatchDirectoryBaselineEntry(
                directoryPath: directoryPath,
                entryPath: entry.path
            ) {
                baselineSkipped += 1
                continue
            }
            let name = entry.lastPathComponent
            if FileEligibilityPolicy.shouldIgnoreFile(named: name) {
                transientSkipped += 1
                continue
            }
            if settings.excludeHidden && name.hasPrefix(".") {
                hiddenSkipped += 1
                continue
            }

            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            if isDir.boolValue {
                guard let inspection = DirectoryInspector.inspect(entry) else {
                    inspectionFailures += 1
                    continue
                }
                let dedupKey = "directory|\(entry.path)|\(inspection.snapshot.signature)"
                let shouldOrganize = settings.autoOrganize || forceOrganizeEntryPaths.contains(entry.path)
                if let existing = try? store.file(path: entry.path),
                   existing.isDirectory,
                   existing.indexedAt != nil,
                   existing.contentHash == inspection.snapshot.signature {
                    seen.insert(dedupKey)
                    // Organizer rejects a folder that changes briefly before organization, such as due to .git/index.lock.
                    // Requeue the folder when it returns to the indexed snapshot so it does not remain stuck in a watched folder.
                    if shouldOrganize,
                       existing.organizedAt == nil,
                       let id = existing.id {
                        organizer.enqueue(fileId: id)
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

            let ext = entry.pathExtension.lowercased()
            if enabledExts.isNotEmpty && !enabledExts.contains(ext) {
                extensionSkipped += 1
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
            if let existing = try? store.file(path: entry.path),
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
                        organizer.enqueue(fileId: id)
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

    /// Remove records whose original top-level watched entry disappeared while FileNest
    /// was not running. Organized records are not affected because their current parent
    /// is the managed library rather than the watched directory.
    private func reconcileRemovedEntries(in directory: URL, existingPaths: Set<String>) {
        let rootPath = Self.canonicalPath(directory.path)
        let canonicalExistingPaths = Set(existingPaths.map(Self.canonicalPath))
        let fm = FileManager.default
        guard let records = try? store.allFiles() else { return }
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
                guard await indexer.indexFile(id: id, overridePath: url, forceVectorization: true) else {
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
                    Self.log(
                        "watcher stopped before directory organization",
                        category: .watchLifecycle,
                        level: .notice,
                        metadata: ["entry": record.name]
                    )
                    return
                }
                if shouldOrganize {
                    self.organizer.enqueue(fileId: id)
                    self.finishForcedOrganization(for: url.path)
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
            Self.log(
                "file discovered",
                category: .watchDiscovery,
                metadata: ["file": record.name, "fileID": "\(id)", "type": category.rawValue]
            )
            // Important: index the file while it is still in place, then organize and move it.
            // Moving first would invalidate the original path and prevent the indexer from reading the content.
            // Index from the original URL, then let the organizer update the database path after moving.
            Task {
                guard await indexer.indexFile(id: id, overridePath: url) else {
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
                    Self.log(
                        "watcher stopped before file organization",
                        category: .watchLifecycle,
                        level: .notice,
                        metadata: ["file": record.name]
                    )
                    return
                }
                if shouldOrganize {
                    self.organizer.enqueue(fileId: id)
                    self.finishForcedOrganization(for: url.path)
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
