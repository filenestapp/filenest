import Foundation

/// Rule-based classifier backed by the database rule table and built-in extension categories.
/// Hybrid mode matches rules first, then falls back to the extension category.
final class RuleClassifier: Classifier {
    private let rules: [Rule]
    private let strategy: ClassificationStrategy

    init(rules: [Rule], strategy: String) {
        // Sort by descending priority.
        self.rules = rules.filter { $0.enabled }.sorted { $0.priority > $1.priority }
        self.strategy = ClassificationStrategy(storedValue: strategy)
    }

    func classify(_ file: FileRecord) -> ClassificationDecision? {
        let ext = file.ext.lowercased()

        // Manual and AI-generated rules are both stored as deterministic extension conditions and use the same execution path.
        for rule in rules where rule.type == RuleType.rule.rawValue || rule.type == RuleType.ai.rawValue {
            let extensions = rule.pattern.split(separator: ",").map {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return value.hasPrefix(".") ? String(value.dropFirst()) : value
            }
            if extensions.contains(ext),
               (rule.actionEnum == .ignore || OrganizationTarget.folderName(from: rule.targetFolder) != nil) {
                return ClassificationDecision(
                    category: FileCategory.from(extension: ext),
                    targetFolder: OrganizationTarget.folderName(from: rule.targetFolder) ?? "Ignored",
                    matchedRuleID: rule.id,
                    action: rule.actionEnum
                )
            }
        }

        guard strategy == .hybrid else { return nil }
        let category = FileCategory.from(extension: ext)
        return ClassificationDecision(
            category: category,
            targetFolder: category.folderName,
            matchedRuleID: nil
        )
    }
}

/// Organization failure types distinguish move, database update, and physical rollback failures.
enum OrganizerError: LocalizedError {
    case moveFailed(fileName: String, reason: String)
    case databaseUpdateFailed(fileName: String, reason: String)
    case rollbackFailed(fileName: String, databaseReason: String, rollbackReason: String)

    var errorDescription: String? {
        switch self {
        case let .moveFailed(fileName, reason):
            return "Failed to move \(fileName): \(reason)"
        case let .databaseUpdateFailed(fileName, reason):
            return "Database update failed for \(fileName); move was rolled back: \(reason)"
        case let .rollbackFailed(fileName, databaseReason, rollbackReason):
            return "Database update failed for \(fileName): \(databaseReason); rollback failed: \(rollbackReason)"
        }
    }
}

/// Organization service that moves files to the destination root and category subfolder, handling conflicts and undo records.
final class OrganizerService: @unchecked Sendable {
    typealias MoveItem = (URL, URL) throws -> Void
    typealias SubfolderResolver = (FileRecord) async -> String?

    private let store: SQLiteStore
    private let settings: AppSettings
    private let organizeRootOverride: URL?
    private let strategyOverride: ClassificationStrategy?
    private let moveItem: MoveItem
    private let subfolderResolver: SubfolderResolver?
    private let scheduleQueue = DispatchQueue(label: "filenest.organizer.schedule")
    private let reconciliationQueue = DispatchQueue(
        label: "filenest.organizer.reconciliation",
        qos: .utility
    )
    private let reconciliationStateLock = NSLock()
    private var reconciliationWaiters = [CheckedContinuation<[FileRecord], Never>]()
    private var reconciliationIsRunning = false
    private var pendingFileIDs = Set<Int64>()
    private var scheduledWorkItem: DispatchWorkItem?
    var onLibraryChange: (() -> Void)?
    var onAutomaticOrganizationUpdate: (@Sendable (Int64, AutomaticFileProcessingStage, String?) -> Void)?

    init(store: SQLiteStore,
         settings: AppSettings,
         organizeRoot: URL? = nil,
         strategy: ClassificationStrategy? = nil,
         subfolderResolver: SubfolderResolver? = nil,
         moveItem: @escaping MoveItem = { source, destination in
             try FileManager.default.moveItem(at: source, to: destination)
         }) {
        self.store = store
        self.settings = settings
        self.organizeRootOverride = organizeRoot
        self.strategyOverride = strategy
        self.subfolderResolver = subfolderResolver
        self.moveItem = moveItem
    }

    /// Destination root: creates FileNestOrganized in the user's home directory by default, with one subfolder per category.
    var organizeRoot: URL {
        organizeRootOverride
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("FileNestOrganized")
    }

    /// Synchronous organization entry point for deterministic rules and tests; unmatched files go to the Uncategorized subfolder.
    func organize(fileId: Int64) throws {
        guard let file = try store.file(id: fileId),
              let decision = classificationDecision(for: file) else { return }
        guard decision.action == .organize else {
            AppLogService.shared.write("entry ignored by rule", category: .organizeRules,
                                       metadata: ["entry": file.name])
            return
        }
        let subfolder = decision.matchedRuleID == nil ? "Uncategorized" : decision.targetFolder
        try move(fileId: fileId, decision: decision, subfolder: subfolder)
    }

    /// Production organization entry point: the extension determines the primary folder, while rules or AI derive the secondary folder from the title, note, and body.
    func organizeUsingAI(
        fileId: Int64,
        checkpoint: (@Sendable () async -> Bool)? = nil
    ) async throws {
        guard await canContinue(checkpoint) else { return }
        guard let file = try store.file(id: fileId),
              let decision = classificationDecision(for: file) else { return }
        guard decision.action == .organize else {
            AppLogService.shared.write("entry ignored by rule", category: .organizeRules,
                                       metadata: ["entry": file.name])
            return
        }
        let subfolder: String
        if decision.matchedRuleID != nil {
            subfolder = decision.targetFolder
        } else if let resolved = await resolveSubfolder(for: file) {
            subfolder = resolved
        } else if let existing = file.organizationSubfolder,
                  OrganizationTarget.folderName(from: existing) != nil {
            subfolder = existing
        } else {
            subfolder = "Uncategorized"
        }
        guard await canContinue(checkpoint) else { return }
        try move(fileId: fileId, decision: decision, subfolder: subfolder)
    }

    private func canContinue(_ checkpoint: (@Sendable () async -> Bool)?) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await checkpoint?() ?? true
    }

    private func classificationDecision(for file: FileRecord) -> ClassificationDecision? {
        if file.isDirectory {
            return ClassificationDecision(
                category: file.categoryEnum,
                targetFolder: file.categoryEnum.folderName,
                matchedRuleID: nil
            )
        }
        let rules = (try? store.allRules()) ?? []
        let strategy = strategyOverride?.rawValue ?? settings.classifyStrategy
        let classifier = RuleClassifier(rules: rules, strategy: strategy)
        guard let decision = classifier.classify(file) else {
            AppLogService.shared.write("no matching rule; keeping entry in place",
                                       category: .organizeRules, level: .notice,
                                       metadata: ["entry": file.name])
            return nil
        }
        // Legacy built-in rules only select the primary file-type folder; do not let a Documents-to-Documents match block the new AI secondary classification.
        if decision.targetFolder == decision.category.folderName {
            return ClassificationDecision(
                category: decision.category,
                targetFolder: decision.targetFolder,
                matchedRuleID: nil
            )
        }
        return decision
    }

    private func resolveSubfolder(for file: FileRecord) async -> String? {
        if let subfolderResolver,
           let value = await subfolderResolver(file),
           let safeValue = OrganizationTarget.folderName(from: value) {
            return safeValue
        }
        return await FileSubfolderClassifier(provider: settings.makeLLMProvider()).classify(file)
    }

    private func move(fileId: Int64,
                      decision: ClassificationDecision,
                      subfolder: String) throws {
        guard var file = try store.file(id: fileId),
              let safeSubfolder = OrganizationTarget.folderName(from: subfolder) else { return }

        if file.isDirectory {
            guard let current = DirectoryInspector.inspect(URL(fileURLWithPath: file.path)),
                  current.snapshot.signature == file.contentHash else {
                AppLogService.shared.write("directory changed after indexing; waiting for stability",
                                           category: .organizeMove, level: .warning,
                                           metadata: ["entry": file.name])
                return
            }
        }

        let destDir = organizeRoot
            .appendingPathComponent(decision.category.folderName, isDirectory: true)
            .appendingPathComponent(safeSubfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let src = URL(fileURLWithPath: file.path)
        let dst = destDir.appendingPathComponent(file.name)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        guard src.path != dst.path else { return }

        // Resolve name conflicts by appending a number.
        let finalDst = resolveConflict(at: dst)

        do {
            try moveItem(src, finalDst)
        } catch {
            let reason = String(describing: error)
            AppLogService.shared.write("move failed: \(reason)", category: .organizeMove,
                                       level: .error, metadata: ["entry": file.name])
            throw OrganizerError.moveFailed(fileName: file.name, reason: reason)
        }

        file.path = finalDst.path
        file.category = decision.category.rawValue
        file.organizedAt = Date()
        file.organizationSubfolder = safeSubfolder
        do {
            _ = try store.upsertFile(file)
            AppLogService.shared.write(
                "entry moved",
                category: .organizeMove,
                metadata: [
                    "entry": src.lastPathComponent,
                    "category": decision.category.rawValue,
                    "subfolder": safeSubfolder,
                    "destinationName": finalDst.lastPathComponent,
                ]
            )
            onLibraryChange?()
        } catch {
            let databaseError = error
            do {
                try moveItem(finalDst, src)
            } catch {
                let databaseReason = String(describing: databaseError)
                let rollbackReason = String(describing: error)
                AppLogService.shared.write(
                    "database update and move rollback failed: \(databaseReason); \(rollbackReason)",
                    category: .organizeMove,
                    level: .error,
                    metadata: ["entry": file.name]
                )
                throw OrganizerError.rollbackFailed(
                    fileName: file.name,
                    databaseReason: databaseReason,
                    rollbackReason: rollbackReason
                )
            }
            let reason = String(describing: databaseError)
            AppLogService.shared.write("database update failed; move rolled back: \(reason)",
                                       category: .organizeMove, level: .error,
                                       metadata: ["entry": file.name])
            throw OrganizerError.databaseUpdateFailed(fileName: file.name, reason: reason)
        }
    }

    /// Called after the watcher finishes indexing. Batched mode runs when either the item threshold or maximum wait is reached.
    func enqueue(fileId: Int64, force: Bool = false) {
        guard settings.autoOrganize || force else { return }
        if AppSettings.AutoOrganizeMode(rawValue: settings.autoOrganizeMode) == .immediate {
            AppLogService.shared.write("immediate organization queued", category: .organizeQueue,
                                       level: .debug, metadata: ["fileID": "\(fileId)"])
            process([fileId])
            return
        }
        scheduleQueue.async { [weak self] in
            guard let self else { return }
            self.pendingFileIDs.insert(fileId)
            if self.pendingFileIDs.count >= self.settings.autoOrganizeBatchSize {
                self.drainPendingLocked()
            } else {
                self.armTimerLocked()
            }
        }
    }

    func reschedulePending() {
        scheduleQueue.async { [weak self] in
            guard let self else { return }
            self.scheduledWorkItem?.cancel()
            self.scheduledWorkItem = nil
            guard self.settings.autoOrganize else {
                self.pendingFileIDs.removeAll()
                return
            }
            if AppSettings.AutoOrganizeMode(rawValue: self.settings.autoOrganizeMode) == .immediate {
                self.drainPendingLocked()
            } else if !self.pendingFileIDs.isEmpty {
                self.armTimerLocked()
            }
        }
    }

    private func armTimerLocked() {
        scheduledWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.drainPendingLocked() }
        scheduledWorkItem = work
        let delay = max(30, settings.autoOrganizeIntervalSeconds)
        scheduleQueue.asyncAfter(deadline: .now() + .seconds(delay), execute: work)
    }

    private func drainPendingLocked() {
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        let ids = pendingFileIDs.sorted()
        pendingFileIDs.removeAll()
        AppLogService.shared.write("organization batch started", category: .organizeQueue,
                                   metadata: ["files": "\(ids.count)"])
        process(ids)
    }

    private func process(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            for id in ids {
                do {
                    self.onAutomaticOrganizationUpdate?(id, .organizing, nil)
                    try await self.organizeUsingAI(fileId: id)
                    self.onAutomaticOrganizationUpdate?(id, .completed, nil)
                } catch {
                    self.onAutomaticOrganizationUpdate?(id, .failed("Organization failed"), String(describing: error))
                    AppLogService.shared.write("scheduled organization failed: \(error)",
                                               category: .organizeQueue, level: .error,
                                               metadata: ["fileID": "\(id)"])
                }
            }
        }
    }

    /// Treats FileNestOrganized as the library source of truth: recursively imports new files and removes stale records.
    func reconcileManagedFilesAsync() async -> [FileRecord] {
        await withCheckedContinuation { continuation in
            reconciliationStateLock.lock()
            reconciliationWaiters.append(continuation)
            guard !reconciliationIsRunning else {
                reconciliationStateLock.unlock()
                return
            }
            reconciliationIsRunning = true
            reconciliationStateLock.unlock()

            reconciliationQueue.async {
                let result = self.reconcileManagedFiles()
                self.reconciliationStateLock.lock()
                let waiters = self.reconciliationWaiters
                self.reconciliationWaiters.removeAll(keepingCapacity: true)
                self.reconciliationIsRunning = false
                self.reconciliationStateLock.unlock()
                waiters.forEach { $0.resume(returning: result) }
            }
        }
    }

    /// Treats FileNestOrganized as the library source of truth: recursively imports new files and removes stale records.
    func reconcileManagedFiles() -> [FileRecord] {
        let startedAt = Date()
        let fm = FileManager.default
        try? fm.createDirectory(at: organizeRoot, withIntermediateDirectories: true)
        let rootPath = organizeRoot.standardizedFileURL.path
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey
        ]
        let enumerator = fm.enumerator(
            at: organizeRoot,
            includingPropertiesForKeys: keys,
            options: settings.excludeHidden ? [.skipsHiddenFiles] : []
        )
        let storedBeforeReconciliation = (try? store.libraryFiles(rootPath: rootPath)) ?? []
        let storedByCanonicalPath = Dictionary(
            storedBeforeReconciliation.map { (Self.canonicalPath($0.path), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var diskPaths = Set<String>()
        var pendingUpserts: [FileRecord] = []
        var staleFileIDs = Set<Int64>()
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let path = url.standardizedFileURL.path
            let existing = storedByCanonicalPath[Self.canonicalPath(path)]
            if values.isDirectory == true {
                if let existing, existing.isDirectory {
                    diskPaths.insert(existing.path)
                    enumerator?.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            diskPaths.insert(existing?.path ?? path)
            let ext = url.pathExtension.lowercased()
            let size = Int64(values.fileSize ?? 0)
            let modificationDate = values.contentModificationDate ?? Date()
            let metadataChanged = existing.map {
                $0.size != size || abs($0.mtime.timeIntervalSince(modificationDate)) >= 0.001
            } ?? false
            let relative = String(path.dropFirst(min(path.count, rootPath.count)))
                .split(separator: "/")
                .map(String.init)
            let subfolder = relative.count >= 3 ? relative[1] : existing?.organizationSubfolder
            let record = FileRecord(
                id: existing?.id,
                path: existing?.path ?? path,
                name: url.lastPathComponent,
                ext: ext,
                size: size,
                mtime: modificationDate,
                category: FileCategory.from(extension: ext).rawValue,
                sourceDir: existing?.sourceDir ?? url.deletingLastPathComponent().path,
                indexedAt: existing?.indexedAt,
                contentHash: existing?.contentHash,
                title: existing?.title,
                contentText: existing?.contentText,
                discoveredAt: existing?.discoveredAt,
                organizedAt: existing?.organizedAt ?? Date(),
                note: existing?.note,
                organizationSubfolder: subfolder
            )
            let recordChanged = existing == nil ||
                metadataChanged ||
                existing?.name != record.name ||
                existing?.ext != record.ext ||
                existing?.category != record.category ||
                existing?.organizationSubfolder != record.organizationSubfolder ||
                existing?.isDirectory != record.isDirectory ||
                existing?.organizedAt == nil
            if recordChanged {
                pendingUpserts.append(record)
            }
            if metadataChanged, let id = existing?.id {
                staleFileIDs.insert(id)
            }
        }

        do {
            try store.applyManagedFileChanges(
                upserts: pendingUpserts,
                staleFileIDs: staleFileIDs
            )
        } catch {
            AppLogService.shared.write(
                "managed library reconciliation persistence failed: \(error)",
                category: .organizeQueue,
                level: .error,
                metadata: ["changes": "\(pendingUpserts.count)"]
            )
        }

        let missingIDs = Set(storedBeforeReconciliation.compactMap { record -> Int64? in
            guard Self.isInside(record.path, rootPath: rootPath),
                  !diskPaths.contains(record.path) else { return nil }
            return record.id
        })
        if !missingIDs.isEmpty {
            do {
                try store.deleteFiles(ids: missingIDs)
            } catch {
                AppLogService.shared.write(
                    "managed library stale-row deletion failed: \(error)",
                    category: .organizeQueue,
                    level: .error,
                    metadata: ["files": "\(missingIDs.count)"]
                )
            }
        }
        let reconciledFiles = ((try? store.libraryFiles(rootPath: rootPath)) ?? []).filter {
            Self.isInside($0.path, rootPath: rootPath) && diskPaths.contains($0.path)
        }
        let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        if durationMilliseconds >= 100 || !pendingUpserts.isEmpty || !missingIDs.isEmpty {
            AppLogService.shared.write(
                "managed library reconciliation completed",
                category: .performance,
                level: .debug,
                metadata: [
                    "durationMs": "\(durationMilliseconds)",
                    "diskFiles": "\(diskPaths.count)",
                    "upserts": "\(pendingUpserts.count)",
                    "deleted": "\(missingIDs.count)",
                ]
            )
        }
        return reconciledFiles
    }

    /// A low-priority startup audit catches tools that overwrite content while preserving
    /// both file size and modification time. Only RAG-eligible files and managed directories
    /// are hashed so large unrelated media does not slow launch.
    func invalidateChangedManagedFileIndexes(force: Bool = false, now: Date = Date()) async -> Int {
        let auditTimestampKey = "managed_content_audit.last_completed_at.v1"
        let auditCursorKey = "managed_content_audit.last_file_id.v1"
        let auditInterval: TimeInterval = 24 * 60 * 60
        if !force,
           let rawTimestamp = store.getSetting(auditTimestampKey),
           let timestamp = TimeInterval(rawTimestamp),
           now.timeIntervalSince1970 - timestamp < auditInterval {
            AppLogService.shared.write(
                "startup content audit skipped within TTL",
                category: .indexPipeline,
                level: .debug
            )
            return 0
        }

        let rootPath = organizeRoot.standardizedFileURL.path
        let cursor = Int64(store.getSetting(auditCursorKey) ?? "") ?? 0
        let fetchedCandidates: [FileRecord]
        do {
            fetchedCandidates = try store.managedContentAuditCandidates(
                rootPath: rootPath,
                fileExtensions: Set(AppSettings.defaultVectorizeExtensions),
                afterID: cursor,
                limit: 256
            )
        } catch {
            AppLogService.shared.write(
                "startup content audit candidate query failed: \(error)",
                category: .indexPipeline,
                level: .error
            )
            return 0
        }

        let maximumAuditBytes: Int64 = 256 * 1_024 * 1_024
        var selectedCandidates = [FileRecord]()
        var selectedBytes: Int64 = 0
        for candidate in fetchedCandidates {
            let candidateBytes = max(0, candidate.size)
            if !selectedCandidates.isEmpty,
               selectedBytes + candidateBytes > maximumAuditBytes {
                break
            }
            selectedCandidates.append(candidate)
            selectedBytes += candidateBytes
        }

        let changedIDs = await Task.detached(priority: .utility) {
            selectedCandidates.compactMap { record -> Int64? in
                guard !Task.isCancelled,
                      FileManager.default.fileExists(atPath: record.path) else { return nil }
                guard let id = record.id, let expectedHash = record.contentHash else { return nil }
                let currentHash: String?
                if record.isDirectory {
                    currentHash = DirectoryInspector.inspect(URL(fileURLWithPath: record.path))?.snapshot.signature
                } else {
                    currentHash = try? FileContentHasher.sha256(of: URL(fileURLWithPath: record.path))
                }
                guard let currentHash, currentHash != expectedHash else { return nil }
                return id
            }
        }.value
        guard !Task.isCancelled else { return 0 }
        if !changedIDs.isEmpty {
            try? store.applyManagedFileChanges(upserts: [], staleFileIDs: Set(changedIDs))
        }
        if let lastID = selectedCandidates.last?.id {
            store.setSetting(auditCursorKey, String(lastID))
        }
        store.setSetting(auditTimestampKey, String(now.timeIntervalSince1970))
        if !changedIDs.isEmpty {
            AppLogService.shared.write(
                "startup content audit invalidated managed indexes",
                category: .indexPipeline,
                level: .notice,
                metadata: [
                    "audited": "\(selectedCandidates.count)",
                    "bytes": "\(selectedBytes)",
                    "files": "\(changedIDs.count)",
                ]
            )
        } else {
            AppLogService.shared.write(
                "startup content audit completed",
                category: .indexPipeline,
                level: .debug,
                metadata: [
                    "audited": "\(selectedCandidates.count)",
                    "bytes": "\(selectedBytes)",
                ]
            )
        }
        return changedIDs.count
    }

    func isManagedPath(_ path: String) -> Bool {
        Self.isInside(path, rootPath: organizeRoot.standardizedFileURL.path)
    }

    private static func isInside(_ path: String, rootPath: String) -> Bool {
        canonicalPath(path).hasPrefix(canonicalPath(rootPath) + "/")
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func resolveConflict(at url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            var candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(baseName) (\(i))")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}

private extension Collection {
    var isNotEmpty: Bool { !isEmpty }
}
