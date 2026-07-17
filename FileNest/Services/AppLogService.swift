import Foundation
import OSLog

enum AppLogLevel: String, CaseIterable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case notice = "NOTICE"
    case warning = "WARNING"
    case error = "ERROR"
}

enum AppLogCategory: String, CaseIterable, Sendable {
    case appLifecycle = "app.lifecycle"
    case appConfiguration = "app.configuration"
    case watchLifecycle = "watch.lifecycle"
    case watchScan = "watch.scan"
    case watchBaseline = "watch.baseline"
    case watchDiscovery = "watch.discovery"
    case indexPipeline = "index.pipeline"
    case indexExtraction = "index.extraction"
    case indexEmbedding = "index.embedding"
    case indexPersistence = "index.persistence"
    case organizeRules = "organize.rules"
    case organizeQueue = "organize.queue"
    case organizeMove = "organize.move"
    case vectorLifecycle = "vector.lifecycle"
    case vectorWrite = "vector.write"
    case vectorSearch = "vector.search"
    case chat = "chat"
}

/// FileNest local diagnostic logs, written serially by day and retained for a limited number of days.
final class AppLogService: @unchecked Sendable {
    static let shared = AppLogService()
    static let defaultRetentionDays = 3
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.local.filenest"
    static var unifiedLogStreamCommand: String {
        "/usr/bin/log stream --style compact --predicate 'subsystem == \"\(subsystem)\"'"
    }

    let directoryURL: URL
    let retentionDays: Int

    private let queue = DispatchQueue(label: "com.local.filenest.file-log")
    private let calendar: Calendar
    private let now: () -> Date
    private let sessionID: String
    private var lastPrunedDay: String?

    init(directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("FileNestLogs", isDirectory: true),
         retentionDays: Int = AppLogService.defaultRetentionDays,
         calendar: Calendar = .current,
         now: @escaping () -> Date = Date.init) {
        self.directoryURL = directoryURL
        self.retentionDays = max(1, retentionDays)
        self.calendar = calendar
        self.now = now
        self.sessionID = String(UUID().uuidString.prefix(8)).lowercased()
        queue.sync {
            prepareDirectoryAndPrune(referenceDate: now())
        }
    }

    /// Supports tests and a small number of dynamic categories; production code should prefer AppLogCategory.
    func write(_ message: String, category: String) {
        write(message, categoryName: category, level: .info, metadata: [:])
    }

    func write(
        _ message: String,
        category: AppLogCategory,
        level: AppLogLevel = .info,
        metadata: [String: String] = [:]
    ) {
        write(message, categoryName: category.rawValue, level: level, metadata: metadata)
    }

    private func write(
        _ message: String,
        categoryName: String,
        level: AppLogLevel,
        metadata: [String: String]
    ) {
        let cleanMessage = Self.singleLine(message)
        let cleanMetadata = metadata
            .map { (Self.singleLine($0.key), Self.singleLine($0.value)) }
            .sorted { $0.0 < $1.0 }
        let metadataText = cleanMetadata.isEmpty
            ? ""
            : " " + cleanMetadata.map { "\($0.0)=\(Self.quotedIfNeeded($0.1))" }.joined(separator: " ")
        emitUnifiedLog(
            "\(cleanMessage) session=\(sessionID)\(metadataText)",
            category: categoryName,
            level: level
        )
        queue.async { [self] in
            let date = now()
            prepareDirectoryAndPrune(referenceDate: date)
            let line = "[\(timestampString(date))] [\(level.rawValue)] [\(categoryName)] " +
                "\(cleanMessage) session=\(sessionID)\(metadataText)\n"
            guard let data = line.data(using: .utf8) else { return }
            append(data, to: logURL(for: date))
        }
    }

    @discardableResult
    func clear() -> Int {
        queue.sync {
            let urls = logFilesOnQueue()
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
            lastPrunedDay = nil
            return urls.count
        }
    }

    func logFiles() -> [URL] {
        queue.sync { logFilesOnQueue() }
    }

    func flush() {
        queue.sync {}
    }

    private func prepareDirectoryAndPrune(referenceDate: Date) {
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let day = dayString(referenceDate)
        guard lastPrunedDay != day else { return }
        lastPrunedDay = day

        let startOfToday = calendar.startOfDay(for: referenceDate)
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -(retentionDays - 1),
            to: startOfToday
        ) else { return }

        for url in logFilesOnQueue() {
            let name = url.lastPathComponent
            if name == "indexer.log" || name == "watcher.log" {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            guard let date = dateFromLogFileName(name), date < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func logFilesOnQueue() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("filenest-") && name.hasSuffix(".log") ||
                name == "indexer.log" || name == "watcher.log"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func logURL(for date: Date) -> URL {
        directoryURL.appendingPathComponent("filenest-\(dayString(date)).log")
    }

    private func append(_ data: Data, to url: URL) {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func timestampString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func dateFromLogFileName(_ name: String) -> Date? {
        guard name.hasPrefix("filenest-"), name.hasSuffix(".log") else { return nil }
        let start = name.index(name.startIndex, offsetBy: "filenest-".count)
        let end = name.index(name.endIndex, offsetBy: -".log".count)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(name[start..<end]))
    }

    private func emitUnifiedLog(_ message: String, category: String, level: AppLogLevel) {
        let logger = Logger(subsystem: Self.subsystem, category: category)
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .notice:
            logger.notice("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func quotedIfNeeded(_ value: String) -> String {
        guard value.contains(where: { $0.isWhitespace || $0 == "=" || $0 == "\"" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\""
    }
}
