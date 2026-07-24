import Combine
import Foundation

enum PaddleOCRServiceState: Equatable {
    case unavailable
    case ready(String)
    case installing
    case failed(String)
}

/// PaddleOCR uses its own user-level Python environment to avoid affecting system Python or Docling dependencies.
@MainActor
final class PaddleOCRServiceManager: ObservableObject {
    nonisolated static let paddleOCRVersion = "3.7.0"
    nonisolated static let paddlePaddleVersion = "3.3.1"

    @Published private(set) var state: PaddleOCRServiceState = .unavailable
    @Published private(set) var isInstalling = false
    @Published private(set) var installProgress: Double?
    @Published private(set) var installStatus = ""
    @Published private(set) var lastError: String?
    @Published private(set) var installedVersion: String?
    @Published private(set) var installedPaddlePaddleVersion: String?
    @Published private(set) var latestVersion: String?
    @Published private(set) var latestPaddlePaddleVersion: String?
    @Published private(set) var updateStatus: ManagedServiceUpdateStatus = .idle

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        refreshCachedState()
    }

    nonisolated static var installRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("FileNest/PaddleOCR", isDirectory: true)
    }

    nonisolated static var pythonExecutable: URL {
        installRoot.appendingPathComponent("venv/bin/python")
    }

    /// Cheap check for configuration signatures and hot indexing paths. The full import
    /// validation remains in `refresh()` so normal indexing never launches Python just
    /// to decide whether its configuration changed.
    nonisolated static var hasManagedEnvironment: Bool {
        FileManager.default.isExecutableFile(atPath: pythonExecutable.path)
    }

    nonisolated static var installedPackageVersion: String? {
        installedVersions()?.paddleOCR ?? (hasManagedEnvironment ? paddleOCRVersion : nil)
    }

    func refresh() async {
        let isAvailable = await Task.detached(priority: .userInitiated) {
            Self.isAvailable()
        }.value
        if isAvailable {
            let versions = Self.installedVersions()
            installedVersion = versions?.paddleOCR ?? Self.paddleOCRVersion
            installedPaddlePaddleVersion = versions?.paddlePaddle ?? Self.paddlePaddleVersion
            state = .ready("PaddleOCR \(installedVersion ?? Self.paddleOCRVersion)")
            lastError = nil
        } else {
            installedVersion = nil
            installedPaddlePaddleVersion = nil
            state = .unavailable
        }
    }

    private func refreshCachedState() {
        guard Self.hasManagedEnvironment else {
            installedVersion = nil
            installedPaddlePaddleVersion = nil
            state = .unavailable
            return
        }
        let versions = Self.installedVersions()
        installedVersion = versions?.paddleOCR ?? Self.paddleOCRVersion
        installedPaddlePaddleVersion = versions?.paddlePaddle ?? Self.paddlePaddleVersion
        state = .ready("PaddleOCR \(installedVersion ?? Self.paddleOCRVersion)")
    }

    func install() async {
        await install(
            paddleOCRTargetVersion: Self.paddleOCRVersion,
            paddlePaddleTargetVersion: Self.paddlePaddleVersion,
            isUpdate: false
        )
    }

    func checkForUpdates() async {
        guard installedVersion != nil else {
            updateStatus = .idle
            latestVersion = nil
            latestPaddlePaddleVersion = nil
            return
        }
        guard !updateStatus.isBusy else { return }

        updateStatus = .checking
        do {
            async let paddleOCR = ManagedServiceReleaseAPI.latestPyPIVersion(
                package: "paddleocr",
                session: session
            )
            async let paddlePaddle = ManagedServiceReleaseAPI.latestPyPIVersion(
                package: "paddlepaddle",
                session: session
            )
            let (latestOCR, latestRuntime) = try await (paddleOCR, paddlePaddle)
            latestVersion = latestOCR
            latestPaddlePaddleVersion = latestRuntime
            let needsUpdate = ManagedServiceReleaseAPI.isNewer(
                latestOCR,
                than: installedVersion ?? Self.paddleOCRVersion
            ) || ManagedServiceReleaseAPI.isNewer(
                latestRuntime,
                than: installedPaddlePaddleVersion ?? Self.paddlePaddleVersion
            )
            let displayVersion = ManagedServiceReleaseAPI.isNewer(
                latestOCR,
                than: installedVersion ?? Self.paddleOCRVersion
            ) ? latestOCR : "PaddlePaddle \(latestRuntime)"
            updateStatus = needsUpdate ? .updateAvailable(displayVersion) : .upToDate
        } catch {
            updateStatus = .failed(error.localizedDescription)
        }
    }

    func update() async {
        guard installedVersion != nil, !updateStatus.isBusy else { return }
        if latestVersion == nil || latestPaddlePaddleVersion == nil {
            await checkForUpdates()
        }
        guard let latestVersion, let latestPaddlePaddleVersion else { return }
        await install(
            paddleOCRTargetVersion: latestVersion,
            paddlePaddleTargetVersion: latestPaddlePaddleVersion,
            isUpdate: true
        )
    }

    private func install(
        paddleOCRTargetVersion: String,
        paddlePaddleTargetVersion: String,
        isUpdate: Bool
    ) async {
        guard !isInstalling else { return }
#if arch(x86_64)
        let message = "Local PaddleOCR requires Apple Silicon; GLM-OCR will be used automatically."
        state = .failed(message)
        lastError = message
        if isUpdate { updateStatus = .failed(message) }
        return
#else
        guard let systemPython = Self.resolveSystemPython() else {
            let message = "Python 3.10 or later is required to install PaddleOCR."
            state = .failed(message)
            lastError = message
            if isUpdate { updateStatus = .failed(message) }
            return
        }

        isInstalling = true
        state = .installing
        if isUpdate { updateStatus = .updating }
        installProgress = 0.05
        installStatus = "Creating an isolated PaddleOCR environment…"
        lastError = nil
        defer { isInstalling = false }

        do {
            let stagingRoot = Self.stagingRoot()
            defer { try? FileManager.default.removeItem(at: stagingRoot) }
            let venv = try await Task.detached(priority: .userInitiated) {
                try Self.prepareEnvironment(using: systemPython, root: stagingRoot)
            }.value
            installProgress = 0.22
            installStatus = "Installing the PaddlePaddle inference engine…"
            try await Task.detached(priority: .userInitiated) {
                try Self.installPaddlePaddle(in: venv, version: paddlePaddleTargetVersion)
            }.value
            installProgress = 0.64
            installStatus = "Installing PaddleOCR…"
            try await Task.detached(priority: .userInitiated) {
                try Self.installPaddleOCR(in: venv, version: paddleOCRTargetVersion)
            }.value
            installProgress = 0.94
            installStatus = "Verifying the PaddleOCR installation…"
            try await Task.detached(priority: .userInitiated) {
                try Self.verifyInstallation(in: venv)
                try Self.writeVersions(
                    ManagedVersions(
                        paddleOCR: paddleOCRTargetVersion,
                        paddlePaddle: paddlePaddleTargetVersion
                    ),
                    root: stagingRoot
                )
                try Self.commitEnvironment(from: stagingRoot)
            }.value
            installProgress = 1
            installStatus = isUpdate ? "PaddleOCR update complete" : "PaddleOCR installation complete"
            await refresh()
            if isUpdate {
                updateStatus = .idle
                await checkForUpdates()
            }
        } catch {
            let message = isUpdate
                ? "PaddleOCR update failed: \(error.localizedDescription)"
                : "PaddleOCR Installation Failed：\(error.localizedDescription)"
            if isUpdate {
                await refresh()
            } else {
                state = .failed(message)
            }
            lastError = message
            installStatus = "Installation Failed"
            if isUpdate { updateStatus = .failed(message) }
        }
#endif
    }

    nonisolated static func isAvailable() -> Bool {
        guard hasManagedEnvironment else { return false }
        return commandSucceeds(
            executable: pythonExecutable,
            arguments: ["-c", "import paddle, paddleocr"]
        )
    }

    nonisolated private static func resolveSystemPython() -> URL? {
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/python3" })
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if let output = commandOutput(executable: url, arguments: ["--version"]),
               supportsPython(output) { return url }
        }
        return nil
    }

    nonisolated private static func stagingRoot() -> URL {
        installRoot.deletingLastPathComponent()
            .appendingPathComponent("PaddleOCR.installing-\(UUID().uuidString)", isDirectory: true)
    }

    nonisolated private static func prepareEnvironment(using python: URL, root: URL) throws -> URL {
        let fileManager = FileManager.default
        let venv = root.appendingPathComponent("venv", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try run(executable: python, arguments: ["-m", "venv", venv.path])
        return venv
    }

    nonisolated private static func installPaddlePaddle(in venv: URL, version: String) throws {
        let pip = venv.appendingPathComponent("bin/pip")
        try run(executable: pip, arguments: [
            "install", "--disable-pip-version-check",
            "paddlepaddle==\(version)",
            "-i", "https://www.paddlepaddle.org.cn/packages/stable/cpu/",
        ])
    }

    nonisolated private static func installPaddleOCR(in venv: URL, version: String) throws {
        let pip = venv.appendingPathComponent("bin/pip")
        try run(executable: pip, arguments: [
            "install", "--disable-pip-version-check", "paddleocr==\(version)",
        ])
    }

    nonisolated private static func commitEnvironment(from stagingRoot: URL) throws {
        let fileManager = FileManager.default
        let backupRoot = installRoot.deletingLastPathComponent()
            .appendingPathComponent("PaddleOCR.backup-\(UUID().uuidString)", isDirectory: true)
        let hadExistingInstall = fileManager.fileExists(atPath: installRoot.path)
        if hadExistingInstall { try fileManager.moveItem(at: installRoot, to: backupRoot) }
        do {
            try fileManager.moveItem(at: stagingRoot, to: installRoot)
            if hadExistingInstall { try? fileManager.removeItem(at: backupRoot) }
        } catch {
            if hadExistingInstall, !fileManager.fileExists(atPath: installRoot.path) {
                try? fileManager.moveItem(at: backupRoot, to: installRoot)
            }
            throw error
        }
    }

    nonisolated private static func writeVersions(_ versions: ManagedVersions, root: URL) throws {
        let data = try JSONEncoder().encode(versions)
        try data.write(to: root.appendingPathComponent("versions.json"), options: .atomic)
    }

    nonisolated private static func installedVersions() -> ManagedVersions? {
        let url = installRoot.appendingPathComponent("versions.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ManagedVersions.self, from: data)
    }

    nonisolated private static func verifyInstallation(in venv: URL) throws {
        let python = venv.appendingPathComponent("bin/python")
        try run(executable: python, arguments: ["-c", "import paddle, paddleocr"])
    }

    nonisolated private static func run(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PaddleOCRServiceError.commandFailed }
    }

    nonisolated private static func commandSucceeds(executable: URL, arguments: [String]) -> Bool {
        (try? run(executable: executable, arguments: arguments)) != nil
    }

    nonisolated private static func commandOutput(executable: URL, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    nonisolated private static func supportsPython(_ output: String) -> Bool {
        let components = output.split(whereSeparator: { !$0.isNumber && $0 != "." })
            .first(where: { $0.contains(".") })?.split(separator: ".") ?? []
        guard components.count >= 2,
              let major = Int(components[0]), let minor = Int(components[1]) else { return false }
        return major > 3 || (major == 3 && minor >= 10)
    }

    private struct ManagedVersions: Codable {
        let paddleOCR: String
        let paddlePaddle: String
    }
}

private enum PaddleOCRServiceError: LocalizedError {
    case commandFailed

    var errorDescription: String? { "The installation command failed" }
}

final class FallbackOCRProvider: OCRProvider, ManagedOCRProviderLifecycle {
    let name: String
    private let primary: OCRProvider
    private let fallback: OCRProvider

    init(primary: OCRProvider, fallback: OCRProvider) {
        self.primary = primary
        self.fallback = fallback
        self.name = "\(primary.name)->\(fallback.name)"
    }

    func recognize(imageData: Data, mimeType: String) async throws -> String {
        try await recognizeResult(imageData: imageData, mimeType: mimeType).text
    }

    func recognizeResult(imageData: Data, mimeType: String) async throws -> OCRRecognitionResult {
        do {
            let result = try await primary.recognizeResult(
                imageData: imageData,
                mimeType: mimeType
            )
            guard Self.isWeak(result) else { return result }
            return try await fallback.recognizeResult(
                imageData: imageData,
                mimeType: mimeType
            )
        } catch {
            return try await fallback.recognizeResult(
                imageData: imageData,
                mimeType: mimeType
            )
        }
    }

    func shutdown() async {
        if let primary = primary as? ManagedOCRProviderLifecycle {
            await primary.shutdown()
        }
        if let fallback = fallback as? ManagedOCRProviderLifecycle {
            await fallback.shutdown()
        }
    }

    private static func isWeak(_ result: OCRRecognitionResult) -> Bool {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        guard !result.observations.isEmpty else { return false }

        let confidences = result.observations.compactMap(\.confidence)
        if !confidences.isEmpty,
           confidences.reduce(0, +) / Double(confidences.count) < 0.55 {
            return true
        }
        if result.observations.count == 1 {
            let significantCharacters = text.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }.count
            if significantCharacters < 8 { return true }
        }
        return false
    }
}

/// Persistent Python worker that reuses the PaddleOCR pipeline instead of reloading the model for every page.
final class PaddleOCRProvider: OCRProvider, ManagedOCRProviderLifecycle, @unchecked Sendable {
    let name = "paddleocr:PP-OCRv6"
    private let pythonExecutableURL: URL?
    private let workerSource: String
    private let queue = DispatchQueue(label: "filenest.paddleocr", qos: .userInitiated)
    private let processLock = NSLock()
    private var workerProcess: Process?
    private var workerInput: FileHandle?
    private var workerOutput: FileHandle?
    private var readBuffer = Data()
    private var activeRequestID: String?
    private var isShuttingDown = false

    init(pythonExecutableURL: URL? = nil, workerScript: String? = nil) {
        self.pythonExecutableURL = pythonExecutableURL
        self.workerSource = workerScript ?? Self.workerScript
    }

    deinit { requestWorkerShutdown() }

    func recognize(imageData: Data, mimeType: String) async throws -> String {
        try await recognizeResult(imageData: imageData, mimeType: mimeType).text
    }

    func recognizeResult(imageData: Data,
                         mimeType: String) async throws -> OCRRecognitionResult {
        let python = pythonExecutableURL ?? PaddleOCRServiceManager.pythonExecutable
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw PaddleOCRProviderError.unavailable
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(throwing: PaddleOCRProviderError.unavailable)
                        return
                    }
                    do {
                        continuation.resume(returning: try self.run(
                            python: python,
                            imageData: imageData,
                            mimeType: mimeType
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.requestWorkerShutdown()
        }
    }

    /// Closes the worker's input stream first so Python can finish the active
    /// inference and let Paddle release its native thread pool normally. Paddle's
    /// native runtime is not signal-safe during inference, so a slow worker is
    /// allowed to finish in the background instead of being force-terminated.
    func shutdown() async {
        let process = beginShutdown()
        requestWorkerShutdown()
        guard let process else { return }
        if await Self.waitForExit(process, timeout: 6) {
            await waitForPendingRequests()
            clearWorker(process)
            return
        }

        AppLogService.shared.write(
            "PaddleOCR worker is still finishing its active request after stdin closed; leaving it to exit normally",
            category: .indexExtraction,
            level: .warning
        )
    }

    private func beginShutdown() -> Process? {
        processLock.lock()
        defer { processLock.unlock() }
        isShuttingDown = true
        return workerProcess
    }

    private func run(python: URL,
                     imageData: Data,
                     mimeType: String) throws -> OCRRecognitionResult {
        guard let input = ensureWorker(python: python) else { throw PaddleOCRProviderError.unavailable }
        let requestID = UUID().uuidString
        let payload: [String: Any] = [
            "id": requestID,
            "mime_type": mimeType,
            "image": imageData.base64EncodedString(),
        ]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            throw PaddleOCRProviderError.invalidResponse
        }
        var line = payloadData
        line.append(0x0A)
        processLock.lock()
        activeRequestID = requestID
        processLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 180) { [weak self] in
            self?.terminateWorker(requestID: requestID)
        }

        do {
            try input.write(contentsOf: line)
            guard let responseData = readResponseLine(),
                  let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  object["id"] as? String == requestID,
                  object["ok"] as? Bool == true,
                  let text = object["text"] as? String else {
                clearActiveRequest(requestID)
                throw PaddleOCRProviderError.invalidResponse
            }
            clearActiveRequest(requestID)
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let observations = (object["observations"] as? [[String: Any]] ?? []).compactMap {
                observationObject -> OCRTextObservation? in
                guard let observationText = observationObject["text"] as? String,
                      !observationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let confidence = (observationObject["confidence"] as? NSNumber)?.doubleValue
                let box = observationObject["box"] as? [NSNumber]
                let bounds: OCRBoundingBox?
                if let box, box.count >= 4 {
                    bounds = OCRBoundingBox(
                        x: box[0].doubleValue,
                        y: box[1].doubleValue,
                        width: max(0, box[2].doubleValue - box[0].doubleValue),
                        height: max(0, box[3].doubleValue - box[1].doubleValue)
                    )
                } else {
                    bounds = nil
                }
                return OCRTextObservation(
                    text: observationText.trimmingCharacters(in: .whitespacesAndNewlines),
                    confidence: confidence,
                    bounds: bounds
                )
            }
            let normalizedObservations = observations.isEmpty && !trimmedText.isEmpty
                ? [OCRTextObservation(text: trimmedText, confidence: nil, bounds: nil)]
                : observations
            return OCRRecognitionResult(text: trimmedText, observations: normalizedObservations)
        } catch {
            clearActiveRequest(requestID)
            terminateWorker()
            throw error
        }
    }

    private func ensureWorker(python: URL) -> FileHandle? {
        processLock.lock()
        guard !isShuttingDown else {
            processLock.unlock()
            return nil
        }
        if let process = workerProcess, process.isRunning, let input = workerInput {
            processLock.unlock()
            return input
        }
        if let process = workerProcess, !process.isRunning {
            workerProcess = nil
            workerInput = nil
            workerOutput = nil
            activeRequestID = nil
            readBuffer.removeAll(keepingCapacity: true)
        }
        processLock.unlock()

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = python
        process.arguments = ["-u", "-c", workerSource]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        processLock.lock()
        workerProcess = process
        workerInput = input.fileHandleForWriting
        workerOutput = output.fileHandleForReading
        readBuffer.removeAll(keepingCapacity: true)
        processLock.unlock()
        return input.fileHandleForWriting
    }

    private func readResponseLine() -> Data? {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.prefix(upTo: newline)
                readBuffer.removeSubrange(...newline)
                return Data(line)
            }
            processLock.lock()
            let output = workerOutput
            processLock.unlock()
            guard let output else { return nil }
            let data = output.availableData
            guard !data.isEmpty else { return nil }
            readBuffer.append(data)
        }
    }

    private func clearActiveRequest(_ requestID: String) {
        processLock.lock()
        if activeRequestID == requestID { activeRequestID = nil }
        processLock.unlock()
    }

    private func requestWorkerShutdown() {
        processLock.lock()
        let input = workerInput
        workerInput = nil
        processLock.unlock()
        try? input?.close()
    }

    private func clearWorker(_ process: Process) {
        processLock.lock()
        guard workerProcess === process else {
            processLock.unlock()
            return
        }
        let input = workerInput
        let output = workerOutput
        workerProcess = nil
        workerInput = nil
        workerOutput = nil
        activeRequestID = nil
        readBuffer.removeAll(keepingCapacity: true)
        processLock.unlock()
        try? input?.close()
        try? output?.close()
    }

    private func waitForPendingRequests() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    private func terminateWorker(requestID: String? = nil) {
        processLock.lock()
        if let requestID, activeRequestID != requestID {
            processLock.unlock()
            return
        }
        let process = workerProcess
        workerProcess = nil
        workerInput = nil
        workerOutput = nil
        activeRequestID = nil
        processLock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private static func waitForExit(_ process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !process.isRunning
    }

    private static let workerScript = #"""
import base64
import json
import os
import tempfile
import sys
from paddleocr import PaddleOCR

pipeline = PaddleOCR(
    lang="ch",
    device="cpu",
    use_doc_orientation_classify=False,
    use_doc_unwarping=False,
    use_textline_orientation=False,
)

def collect_observations(value):
    if isinstance(value, dict):
        if isinstance(value.get("rec_texts"), list):
            texts = value["rec_texts"]
            scores = value.get("rec_scores", [])
            boxes = value.get("rec_boxes", [])
            observations = []
            for index, text in enumerate(texts):
                text = str(text).strip()
                if not text:
                    continue
                score = float(scores[index]) if index < len(scores) else None
                box = boxes[index] if index < len(boxes) else None
                if box is not None:
                    box = [float(component) for component in box[:4]]
                observations.append({"text": text, "confidence": score, "box": box})
            return observations
        observations = []
        for nested in value.values():
            observations.extend(collect_observations(nested))
        return observations
    if isinstance(value, (list, tuple)):
        observations = []
        for nested in value:
            observations.extend(collect_observations(nested))
        return observations
    return []

for line in sys.stdin:
    request = None
    path = None
    try:
        request = json.loads(line)
        suffix = ".png"
        mime = request.get("mime_type", "")
        if "jpeg" in mime or "jpg" in mime:
            suffix = ".jpg"
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as image_file:
            image_file.write(base64.b64decode(request["image"]))
            path = image_file.name
        observations = []
        for result in pipeline.predict(path):
            payload = getattr(result, "json", result)
            if callable(payload):
                payload = payload()
            observations.extend(collect_observations(payload))
        response = {
            "id": request.get("id"),
            "ok": True,
            "text": "\n".join(item["text"] for item in observations),
            "observations": observations,
        }
    except Exception as error:
        response = {
            "id": request.get("id") if isinstance(request, dict) else None,
            "ok": False,
            "error": str(error),
        }
    finally:
        if path:
            try:
                os.remove(path)
            except OSError:
                pass
    print(json.dumps(response, ensure_ascii=False), flush=True)
"""#
}

private enum PaddleOCRProviderError: LocalizedError {
    case unavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: return "PaddleOCR is not installed"
        case .invalidResponse: return "PaddleOCR returned an invalid result"
        }
    }
}

final class OllamaOCRProvider: OCRProvider {
    let name: String
    private let host: String
    private let model: String
    private let session: URLSession

    init(host: String, model: String, session: URLSession = .shared) {
        self.host = host
        self.model = model
        self.session = session
        self.name = "ollama-ocr:\(model)"
    }

    func recognize(imageData: Data, mimeType: String) async throws -> String {
        let base = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/chat") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": false,
            "messages": [[
                "role": "user",
                "content": PromptCatalog.OCR.recognizeText,
                "images": [imageData.base64EncodedString()],
            ]],
        ])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? String else { throw URLError(.cannotParseResponse) }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    }
}

final class CloudOCRProvider: OCRProvider {
    let name: String
    private let format: AppSettings.CloudAPIFormat
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(format: AppSettings.CloudAPIFormat, baseURL: String, apiKey: String,
         model: String, session: URLSession = .shared) {
        self.format = format
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.name = "cloud-ocr:\(format.rawValue):\(model)"
    }

    func recognize(imageData: Data, mimeType: String) async throws -> String {
        switch format {
        case .openAI:
            return try await recognizeOpenAI(imageData: imageData, mimeType: mimeType)
        case .anthropic:
            return try await recognizeAnthropic(imageData: imageData, mimeType: mimeType)
        }
    }

    private func recognizeOpenAI(imageData: Data, mimeType: String) async throws -> String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/chat/completions") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 45
        let dataURL = "data:\(mimeType);base64,\(imageData.base64EncodedString())"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": PromptCatalog.OCR.recognizeText],
                    ["type": "image_url", "image_url": ["url": dataURL]],
                ],
            ]],
        ])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw URLError(.cannotParseResponse) }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recognizeAnthropic(imageData: Data, mimeType: String) async throws -> String {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/messages") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 45
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 4_096,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": [
                        "type": "base64", "media_type": mimeType,
                        "data": imageData.base64EncodedString(),
                    ]],
                    ["type": "text", "text": PromptCatalog.OCR.recognizeText],
                ],
            ]],
        ])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = object["content"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
        let text = blocks.compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw URLError(.cannotParseResponse) }
        return text
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    }
}
