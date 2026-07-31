import Combine
import Foundation

struct ManagedDownloadRequest: Sendable {
    let identifier: String
    let displayName: String
    let sourceURL: URL
    let expectedSHA256: String?
    let timeout: TimeInterval

    init(
        identifier: String,
        displayName: String,
        sourceURL: URL,
        expectedSHA256: String? = nil,
        timeout: TimeInterval = 900
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.expectedSHA256 = expectedSHA256
        self.timeout = timeout
    }
}

enum ManagedDownloadPhase: Equatable, Sendable {
    case queued
    case downloading
    case paused
    case cancelled
    case completed
    case failed(String)
}

struct ManagedDownloadSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let sourceURL: URL
    var phase: ManagedDownloadPhase
    var bytesReceived: Int64
    var bytesExpected: Int64?
    var updatedAt: Date

    var fractionCompleted: Double? {
        guard let bytesExpected, bytesExpected > 0 else { return nil }
        return min(max(Double(bytesReceived) / Double(bytesExpected), 0), 1)
    }
}

enum DownloadCoordinatorError: LocalizedError, Equatable {
    case invalidResponse
    case checksumMismatch
    case missingDownloadedFile
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The download server returned an invalid response."
        case .checksumMismatch:
            return "The downloaded file did not match the trusted checksum."
        case .missingDownloadedFile:
            return "The downloaded file could not be saved."
        case .cancelled:
            return "Download cancelled."
        }
    }
}

/// Coordinates FileNest-owned HTTP downloads in one resumable, observable queue.
///
/// Package managers and Ollama model pulls keep their native caches, while direct
/// runtime artifacts use this coordinator so interrupted transfers can resume.
@MainActor
final class DownloadCoordinator: ObservableObject {
    static let shared = DownloadCoordinator()

    @Published private(set) var downloads: [ManagedDownloadSnapshot] = []

    private let session: URLSession
    private let storageRoot: URL
    private var activeTasks = [String: Task<URL, Error>]()
    private var activeOperations = [String: ResumableDownloadOperation]()

    init(
        session: URLSession = .shared,
        storageRoot: URL = ManagedRuntimePaths.applicationSupportRoot
            .appendingPathComponent("Downloads", isDirectory: true)
    ) {
        self.session = session
        self.storageRoot = storageRoot
    }

    var hasActiveDownloads: Bool {
        downloads.contains { $0.phase == .queued || $0.phase == .downloading }
    }

    func download(
        _ request: ManagedDownloadRequest,
        onProgress: ((ManagedDownloadSnapshot) -> Void)? = nil
    ) async throws -> URL {
        if let activeTask = activeTasks[request.identifier] {
            return try await activeTask.value
        }

        let initial = ManagedDownloadSnapshot(
            id: request.identifier,
            displayName: request.displayName,
            sourceURL: request.sourceURL,
            phase: .queued,
            bytesReceived: 0,
            bytesExpected: nil,
            updatedAt: Date()
        )
        publish(initial, callback: onProgress)

        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.perform(request, onProgress: onProgress)
        }
        activeTasks[request.identifier] = task

        do {
            let downloadedFile = try await task.value
            activeTasks[request.identifier] = nil
            activeOperations[request.identifier] = nil
            update(
                identifier: request.identifier,
                phase: .completed,
                callback: onProgress
            )
            return downloadedFile
        } catch {
            activeTasks[request.identifier] = nil
            activeOperations[request.identifier] = nil
            let phase: ManagedDownloadPhase
            if error is CancellationError {
                phase = .paused
            } else if let coordinatorError = error as? DownloadCoordinatorError,
                      coordinatorError == .cancelled {
                phase = .cancelled
            } else {
                phase = .failed(error.localizedDescription)
            }
            update(identifier: request.identifier, phase: phase, callback: onProgress)
            throw error
        }
    }

    func cancel(identifier: String, preservingResumeData: Bool = true) async {
        guard let operation = activeOperations[identifier] else { return }
        if preservingResumeData {
            await operation.suspend()
            update(identifier: identifier, phase: .paused)
        } else {
            operation.cancel()
            update(identifier: identifier, phase: .cancelled)
        }
    }

    /// Produces and persists resume data before FileNest exits.
    func suspendAll() async {
        let operations = Array(activeOperations.values)
        await withTaskGroup(of: Void.self) { group in
            for operation in operations {
                group.addTask { await operation.suspend() }
            }
        }
    }

    func clearFinishedDownloads() {
        downloads.removeAll {
            switch $0.phase {
            case .cancelled, .completed, .failed:
                return true
            case .queued, .downloading, .paused:
                return false
            }
        }
    }

    /// Registers a download owned by a package manager or local service.
    /// The external downloader remains responsible for transport-level resume support.
    func beginExternalDownload(
        identifier: String,
        displayName: String,
        sourceURL: URL
    ) {
        publish(
            ManagedDownloadSnapshot(
                id: identifier,
                displayName: displayName,
                sourceURL: sourceURL,
                phase: .downloading,
                bytesReceived: 0,
                bytesExpected: nil,
                updatedAt: Date()
            ),
            callback: nil
        )
    }

    func updateExternalDownload(
        identifier: String,
        bytesReceived: Int64,
        bytesExpected: Int64?
    ) {
        guard var snapshot = downloads.first(where: { $0.id == identifier }) else { return }
        snapshot.phase = .downloading
        snapshot.bytesReceived = max(0, bytesReceived)
        snapshot.bytesExpected = bytesExpected.flatMap { $0 > 0 ? $0 : nil }
        snapshot.updatedAt = Date()
        publish(snapshot, callback: nil)
    }

    func finishExternalDownload(identifier: String) {
        update(identifier: identifier, phase: .completed)
    }

    func failExternalDownload(identifier: String, error: Error) {
        update(
            identifier: identifier,
            phase: .failed(error.localizedDescription)
        )
    }

    func performExternalDownload(
        identifier: String,
        displayName: String,
        sourceURL: URL,
        operation: () async throws -> Void
    ) async throws {
        beginExternalDownload(
            identifier: identifier,
            displayName: displayName,
            sourceURL: sourceURL
        )
        do {
            try await operation()
            finishExternalDownload(identifier: identifier)
        } catch {
            failExternalDownload(identifier: identifier, error: error)
            throw error
        }
    }

    private func perform(
        _ request: ManagedDownloadRequest,
        onProgress: ((ManagedDownloadSnapshot) -> Void)?
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: storageRoot,
            withIntermediateDirectories: true
        )

        let paths = DownloadStoragePaths(root: storageRoot, request: request)
        let operation = ResumableDownloadOperation(
            session: session,
            request: request,
            paths: paths
        ) { [weak self] received, expected in
            Task { @MainActor [weak self] in
                self?.updateProgress(
                    identifier: request.identifier,
                    received: received,
                    expected: expected,
                    callback: onProgress
                )
            }
        }
        activeOperations[request.identifier] = operation

        let file = try await operation.start()
        if let expectedSHA256 = request.expectedSHA256 {
            let actualSHA256 = try await Task.detached(priority: .utility) {
                try FileContentHasher.sha256(of: file)
            }.value
            guard actualSHA256.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                try? FileManager.default.removeItem(at: file)
                paths.removeResumeData()
                throw DownloadCoordinatorError.checksumMismatch
            }
        }
        paths.removeResumeData()
        return file
    }

    private func updateProgress(
        identifier: String,
        received: Int64,
        expected: Int64,
        callback: ((ManagedDownloadSnapshot) -> Void)?
    ) {
        guard var snapshot = downloads.first(where: { $0.id == identifier }) else { return }
        snapshot.phase = .downloading
        snapshot.bytesReceived = max(0, received)
        snapshot.bytesExpected = expected > 0 ? expected : nil
        snapshot.updatedAt = Date()
        publish(snapshot, callback: callback)
    }

    private func update(
        identifier: String,
        phase: ManagedDownloadPhase,
        callback: ((ManagedDownloadSnapshot) -> Void)? = nil
    ) {
        guard var snapshot = downloads.first(where: { $0.id == identifier }) else { return }
        snapshot.phase = phase
        if phase == .completed, let expected = snapshot.bytesExpected {
            snapshot.bytesReceived = expected
        }
        snapshot.updatedAt = Date()
        publish(snapshot, callback: callback)
    }

    private func publish(
        _ snapshot: ManagedDownloadSnapshot,
        callback: ((ManagedDownloadSnapshot) -> Void)?
    ) {
        if let index = downloads.firstIndex(where: { $0.id == snapshot.id }) {
            downloads[index] = snapshot
        } else {
            downloads.append(snapshot)
        }
        downloads.sort { $0.updatedAt > $1.updatedAt }
        callback?(snapshot)
    }
}

private struct DownloadResumeMetadata: Codable {
    let sourceURL: URL
    let expectedSHA256: String?
}

private struct DownloadStoragePaths: Sendable {
    let completedFile: URL
    let resumeDataFile: URL
    let metadataFile: URL

    init(root: URL, request: ManagedDownloadRequest) {
        let component = Self.safeFileComponent(request.identifier)
        let fileExtension = request.sourceURL.pathExtension
        let completedName = fileExtension.isEmpty
            ? "\(component)-\(UUID().uuidString)"
            : "\(component)-\(UUID().uuidString).\(fileExtension)"
        completedFile = root.appendingPathComponent(completedName)
        resumeDataFile = root.appendingPathComponent("\(component).resume")
        metadataFile = root.appendingPathComponent("\(component).json")
    }

    func hasValidResumeData(for request: ManagedDownloadRequest) -> Bool {
        guard FileManager.default.fileExists(atPath: resumeDataFile.path),
              let data = try? Data(contentsOf: metadataFile),
              let metadata = try? JSONDecoder().decode(DownloadResumeMetadata.self, from: data),
              metadata.sourceURL == request.sourceURL,
              metadata.expectedSHA256 == request.expectedSHA256 else {
            removeResumeData()
            return false
        }
        return true
    }

    func loadResumeData(for request: ManagedDownloadRequest) -> Data? {
        guard hasValidResumeData(for: request) else { return nil }
        return try? Data(contentsOf: resumeDataFile)
    }

    func saveResumeData(_ data: Data, for request: ManagedDownloadRequest) {
        do {
            let metadata = DownloadResumeMetadata(
                sourceURL: request.sourceURL,
                expectedSHA256: request.expectedSHA256
            )
            try data.write(to: resumeDataFile, options: .atomic)
            try JSONEncoder().encode(metadata).write(to: metadataFile, options: .atomic)
        } catch {
            removeResumeData()
        }
    }

    func removeResumeData() {
        try? FileManager.default.removeItem(at: resumeDataFile)
        try? FileManager.default.removeItem(at: metadataFile)
    }

    private static func safeFileComponent(_ identifier: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = identifier.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "_"
        }
        let value = String(sanitized).prefix(96)
        return value.isEmpty ? "download" : String(value)
    }
}

private final class ResumableDownloadOperation: @unchecked Sendable {
    typealias ProgressHandler = @Sendable (_ received: Int64, _ expected: Int64) -> Void

    private let session: URLSession
    private let request: ManagedDownloadRequest
    private let paths: DownloadStoragePaths
    private let progressHandler: ProgressHandler
    private let lock = NSLock()

    private var task: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?
    private var continuation: CheckedContinuation<URL, Error>?
    private var hasCompleted = false

    init(
        session: URLSession,
        request: ManagedDownloadRequest,
        paths: DownloadStoragePaths,
        progressHandler: @escaping ProgressHandler
    ) {
        self.session = session
        self.request = request
        self.paths = paths
        self.progressHandler = progressHandler
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let task: URLSessionDownloadTask
                if let resumeData = paths.loadResumeData(for: request) {
                    task = session.downloadTask(withResumeData: resumeData) {
                        [weak self] temporaryURL, response, error in
                        self?.handleCompletion(
                            temporaryURL: temporaryURL,
                            response: response,
                            error: error
                        )
                    }
                } else {
                    var urlRequest = URLRequest(url: request.sourceURL)
                    urlRequest.timeoutInterval = request.timeout
                    task = session.downloadTask(with: urlRequest) {
                        [weak self] temporaryURL, response, error in
                        self?.handleCompletion(
                            temporaryURL: temporaryURL,
                            response: response,
                            error: error
                        )
                    }
                }
                self.task = task
                progressObservation = task.progress.observe(
                    \.fractionCompleted,
                    options: [.initial, .new]
                ) { [weak self] progress, _ in
                    self?.progressHandler(
                        progress.completedUnitCount,
                        progress.totalUnitCount
                    )
                }
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            Task { await self.suspend() }
        }
    }

    func suspend() async {
        let task = lockedTask()
        guard let task else { return }
        await withCheckedContinuation { continuation in
            task.cancel { [weak self] resumeData in
                guard let self else {
                    continuation.resume()
                    return
                }
                if let resumeData, !resumeData.isEmpty {
                    self.paths.saveResumeData(resumeData, for: self.request)
                }
                self.finish(.failure(CancellationError()))
                continuation.resume()
            }
        }
    }

    func cancel() {
        paths.removeResumeData()
        lockedTask()?.cancel()
        finish(.failure(DownloadCoordinatorError.cancelled))
    }

    private func handleCompletion(
        temporaryURL: URL?,
        response: URLResponse?,
        error: Error?
    ) {
        if let error {
            let nsError = error as NSError
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
               !resumeData.isEmpty {
                paths.saveResumeData(resumeData, for: request)
            }
            finish(.failure(error))
            return
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            finish(.failure(DownloadCoordinatorError.invalidResponse))
            return
        }
        guard let temporaryURL else {
            finish(.failure(DownloadCoordinatorError.missingDownloadedFile))
            return
        }

        do {
            try? FileManager.default.removeItem(at: paths.completedFile)
            try FileManager.default.moveItem(at: temporaryURL, to: paths.completedFile)
            finish(.success(paths.completedFile))
        } catch {
            finish(.failure(error))
        }
    }

    private func lockedTask() -> URLSessionDownloadTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !hasCompleted else {
            lock.unlock()
            return
        }
        hasCompleted = true
        let continuation = continuation
        self.continuation = nil
        progressObservation?.invalidate()
        progressObservation = nil
        task = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
