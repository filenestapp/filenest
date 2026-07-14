import Foundation
import Darwin

/// 文件监听服务：用 DispatchSource 监听指定目录的新增文件，
/// 触发归类(Organizer) + 索引(Indexer)。
final class FileWatcherService: @unchecked Sendable {
    private let store: SQLiteStore
    private let organizer: OrganizerService
    private let indexer: IndexerService
    private var sources: [DispatchSourceFileSystemObject] = []
    /// 串行队列：所有扫描操作排队执行，避免共享状态并发损坏
    private let queue = DispatchQueue(label: "filenest.watcher")
    private var running = false
    var isRunning: Bool { queue.sync { running } }
    private let settings = AppSettings.shared
    private var pollTimer: DispatchSourceTimer?
    private var stabilityTracker = FileStabilityTracker()
    private let minimumStableDuration: TimeInterval = 2
    /// 仅由 queue 访问的已处理文件去重表
    private var seen: Set<String> = []

    init(store: SQLiteStore, organizer: OrganizerService, indexer: IndexerService) {
        self.store = store
        self.organizer = organizer
        self.indexer = indexer
    }

    func start() {
        queue.async { [weak self] in self?.startLocked() }
    }

    private func startLocked() {
        guard !running else { return }
        running = true
        let dirs = settings.watchDirs.compactMap { URL(fileURLWithPath: $0) }
        Self.log("start: watching \(dirs.count) dirs: \(dirs.map(\.path))")
        Self.log("enabledExts count=\(settings.enabledExtensions.count), autoOrganize=\(settings.autoOrganize)")
        for dir in dirs { watchDirectory(dir) }
        startPolling()
        Self.log("start complete, sources=\(sources.count)")
    }

    func stop() {
        queue.sync {
            running = false
            for source in sources { source.cancel() }
            sources.removeAll()
            pollTimer?.cancel()
            pollTimer = nil
            stabilityTracker = FileStabilityTracker()
        }
    }

    /// 监听单个目录：用 DispatchSource 监视目录描述符的写入事件
    private func watchDirectory(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.log("open failed for \(url.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        let weakURL = url
        src.setEventHandler { [weak self] in
            self?.scanDirectory(weakURL)
        }
        src.setCancelHandler { [fd] in
            close(fd)
        }
        src.resume()
        sources.append(src)
        // 启动时记录第一份快照，文件稳定后由后续事件或轮询处理。
        scanDirectory(url)
    }

    /// 定时轮询兜底（DispatchSource 对部分事件不敏感，用轮询保证捕获新文件）
    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for dir in self.settings.watchDirs {
                self.scanDirectory(URL(fileURLWithPath: dir))
            }
        }
        timer.resume()
        pollTimer = timer
    }

    /// 扫描目录，发现新增/修改文件（仅在 serial queue 上调用，seen 无需额外加锁）
    private func scanDirectory(_ url: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: url,
                                                       includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                                                       options: [.skipsSubdirectoryDescendants]) else {
            NSLog("[Watcher] scan failed: cannot list \(url.path)")
            return
        }

        let enabledExts = Set(settings.enabledExtensions.map { $0.lowercased() })
        let now = Date()
        var processedThisScan = 0
        let existingPaths = Set(entries.map(\.path))

        for entry in entries {
            let name = entry.lastPathComponent
            if settings.excludeHidden && name.hasPrefix(".") { continue }
            if name == ".DS_Store" { continue }

            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            if isDir.boolValue { continue }

            let ext = entry.pathExtension.lowercased()
            if enabledExts.isNotEmpty && !enabledExts.contains(ext) {
                Self.log("skip \(name): ext '\(ext)' not in enabled list (\(enabledExts.count) enabled)")
                continue
            }

            // 去重：同一路径已处理过则跳过（除非 mtime 变了）
            let attrs = try? fm.attributesOfItem(atPath: entry.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? now
            let size = Int64((attrs?[.size] as? NSNumber)?.intValue ?? 0)
            let dedupKey = "\(entry.path)|\(size)|\(mtime.timeIntervalSinceReferenceDate)"
            if seen.contains(dedupKey) { continue }

            // 已成功索引且文件元数据未变化，重启后无需再次计算内容哈希。
            if let existing = try? store.file(path: entry.path),
               existing.size == size,
               abs(existing.mtime.timeIntervalSince(mtime)) < 0.001,
               existing.indexedAt != nil,
               existing.contentHash != nil {
                seen.insert(dedupKey)
                continue
            }

            let snapshot = FileSnapshot(size: size, modificationDate: mtime)
            guard stabilityTracker.isStable(path: entry.path,
                                             snapshot: snapshot,
                                             observedAt: now,
                                             minimumStableDuration: minimumStableDuration) else {
                continue
            }

            seen.insert(dedupKey)
            processedThisScan += 1
            handleNewFile(at: entry, mtime: mtime, size: size, dedupKey: dedupKey)
        }
        stabilityTracker.retainExistingPaths(existingPaths)
        Self.log("scanned \(url.path): \(entries.count) entries, processed \(processedThisScan) new")
        // 防止 seen 无限增长：保留最近 2000 条
        if seen.count > 2000 {
            seen = Set(seen.suffix(1000))
        }
    }

    private func handleNewFile(at url: URL, mtime: Date, size: Int64, dedupKey: String) {
        let ext = url.pathExtension
        let category = FileCategory.from(extension: ext)
        let existing = try? store.file(path: url.path)
        let record = FileRecord(
            id: existing?.id, path: url.path, name: url.lastPathComponent, ext: ext,
            size: size, mtime: mtime, category: category.rawValue,
            sourceDir: url.deletingLastPathComponent().path,
            indexedAt: existing?.indexedAt, contentHash: existing?.contentHash,
            title: existing?.title, contentText: existing?.contentText
        )
        do {
            let id = try store.upsertFile(record)
            Self.log("new file \(record.name) -> id=\(id), category=\(category.label)")
            // 重要：先索引（此时文件还在原位），再整理移动。
            // 若先移动再索引，indexer 会因原路径失效而抓取不到内容。
            // 索引用原 url（文件当前所在），整理后由 organizer 更新 DB 中的 path。
            Task {
                guard await indexer.indexFile(id: id, overridePath: url) else {
                    Self.log("index failed for \(record.name); keeping file in place")
                    self.allowRetry(for: dedupKey)
                    return
                }
                if self.settings.autoOrganize {
                    do {
                        try self.organizer.organize(fileId: id)
                    } catch {
                        Self.log("organize failed for \(record.name): \(error)")
                    }
                }
            }
        } catch {
            Self.log("handle new file failed: \(error)")
            allowRetry(for: dedupKey)
        }
    }

    private func allowRetry(for dedupKey: String) {
        queue.async { [weak self] in
            self?.seen.remove(dedupKey)
        }
    }

    // MARK: - 文件日志
    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("FileNestLogs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("watcher.log")
    }()
    static func log(_ msg: String) {
        let line = "[\(Date().formatted(.dateTime))] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path),
               let h = FileHandle(forWritingAtPath: logURL.path) {
                h.seekToEndOfFile(); h.write(data); h.closeFile()
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}

private extension Collection {
    var isNotEmpty: Bool { !isEmpty }
}
