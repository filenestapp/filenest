import Foundation
import Darwin

/// 文件监听服务：用 DispatchSource 监听指定目录的新增文件，
/// 触发归类(Organizer) + 索引(Indexer)。
final class FileWatcherService {
    private let store: SQLiteStore
    private let organizer: OrganizerService
    private let indexer: IndexerService
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fds: [CInt] = []
    /// 串行队列：所有扫描操作排队执行，避免共享状态并发损坏
    private let queue = DispatchQueue(label: "filenest.watcher")
    private(set) var isRunning = false
    private let settings = AppSettings.shared
    private var pollTimer: DispatchSourceTimer?
    /// 已处理文件去重表 —— 用锁保护，避免并发损坏
    private var seen: Set<String> = []
    private let seenLock = NSLock()

    init(store: SQLiteStore, organizer: OrganizerService, indexer: IndexerService) {
        self.store = store
        self.organizer = organizer
        self.indexer = indexer
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        let dirs = settings.watchDirs.compactMap { URL(fileURLWithPath: $0) }
        Self.log("start: watching \(dirs.count) dirs: \(dirs.map(\.path))")
        Self.log("enabledExts count=\(settings.enabledExtensions.count), autoOrganize=\(settings.autoOrganize)")
        for dir in dirs { watchDirectory(dir) }
        startPolling()
        Self.log("start complete, sources=\(sources.count), fds=\(fds.count)")
    }

    func stop() {
        isRunning = false
        for s in sources { s.cancel() }
        sources.removeAll()
        for fd in fds { close(fd) }
        fds.removeAll()
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// 监听单个目录：用 DispatchSource 监视目录描述符的写入事件
    private func watchDirectory(_ url: URL) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.log("open failed for \(url.path)")
            return
        }
        fds.append(fd)
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
        // 启动时先扫一遍
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
            let dedupKey = "\(entry.path)|\(Int(mtime.timeIntervalSince1970))"
            seenLock.lock()
            let alreadySeen = seen.contains(dedupKey)
            if !alreadySeen { seen.insert(dedupKey) }
            seenLock.unlock()
            if alreadySeen {
                continue
            }
            processedThisScan += 1

            let size = Int64((attrs?[.size] as? NSNumber)?.intValue ?? 0)
            handleNewFile(at: entry, mtime: mtime, size: size)
        }
        Self.log("scanned \(url.path): \(entries.count) entries, processed \(processedThisScan) new")
        // 防止 seen 无限增长：保留最近 2000 条
        seenLock.lock()
        if seen.count > 2000 {
            seen = Set(seen.suffix(1000))
        }
        seenLock.unlock()
    }

    private func handleNewFile(at url: URL, mtime: Date, size: Int64) {
        let ext = url.pathExtension
        let category = FileCategory.from(extension: ext)
        let record = FileRecord(
            id: nil, path: url.path, name: url.lastPathComponent, ext: ext,
            size: size, mtime: mtime, category: category.rawValue,
            sourceDir: url.deletingLastPathComponent().path,
            indexedAt: Date(), contentHash: nil, title: nil, contentText: nil
        )
        do {
            let id = try store.upsertFile(record)
            Self.log("new file \(record.name) -> id=\(id), category=\(category.label)")
            // 重要：先索引（此时文件还在原位），再整理移动。
            // 若先移动再索引，indexer 会因原路径失效而抓取不到内容。
            // 索引用原 url（文件当前所在），整理后由 organizer 更新 DB 中的 path。
            Task {
                await indexer.indexFile(id: id, overridePath: url)
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
