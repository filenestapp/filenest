import Foundation

enum RerankerServiceState: Equatable {
    case unavailable
    case installed
    case starting
    case running
    case failed(String)
}

/// Owns FileNest's isolated Qwen reranker runtime, model files, and local HTTP service.
/// The service implements the OpenAI/Jina-compatible `/v1/rerank` contract used by
/// `CompatibleRerankingProvider`.
@MainActor
final class RerankerServiceManager: ObservableObject {
    nonisolated static let defaultModel = "Qwen/Qwen3-Reranker-0.6B"
    nonisolated static let estimatedDownloadBytes: Int64 = 1_250_000_000
    nonisolated static let servicePort = 11_435

    @Published private(set) var state: RerankerServiceState = .unavailable
    @Published private(set) var isInstalling = false
    @Published private(set) var installProgress: Double?
    @Published private(set) var installStatus = ""
    @Published private(set) var lastError: String?
    @Published private(set) var modelDiskBytes: Int64 = 0
    @Published private(set) var managedServiceProcessIDs: [Int32] = []

    private var serviceProcess: Process?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        modelDiskBytes = Self.directorySize(Self.modelRoot)
        state = Self.isModelInstalled ? .installed : .unavailable
        Task { await refresh() }
    }

    deinit {
        serviceProcess?.terminate()
    }

    nonisolated static var installRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("FileNest/Reranker", isDirectory: true)
    }

    nonisolated static var pythonExecutable: URL {
        installRoot.appendingPathComponent("venv/bin/python")
    }

    nonisolated static var modelRoot: URL {
        installRoot.appendingPathComponent("models/qwen3-reranker-0.6b", isDirectory: true)
    }

    nonisolated static var serverScriptURL: URL {
        installRoot.appendingPathComponent("reranker_server.py")
    }

    nonisolated static var isModelInstalled: Bool {
        FileManager.default.fileExists(atPath: modelRoot.appendingPathComponent("config.json").path)
            && FileManager.default.isExecutableFile(atPath: pythonExecutable.path)
    }

    var isRunning: Bool { state == .running }

    /// Reconciles the UI with both a child process from this launch and a FileNest
    /// reranker left behind by an interrupted previous launch.
    func refresh() async {
        modelDiskBytes = Self.directorySize(Self.modelRoot)
        let processIDs = await Self.discoverManagedServiceProcessIDs()
        managedServiceProcessIDs = processIDs
        if !processIDs.isEmpty, await healthCheck() {
            state = .running
            lastError = nil
        } else if !processIDs.isEmpty {
            state = .starting
        } else {
            serviceProcess = nil
            state = Self.isModelInstalled ? .installed : .unavailable
        }
    }

    func install() async {
        guard !isInstalling else { return }
        guard let systemPython = Self.resolveSystemPython() else {
            fail("Python 3.10 or later is required to install the local reranker.")
            return
        }

        isInstalling = true
        lastError = nil
        installProgress = 0.03
        installStatus = "Preparing the isolated reranker environment…"
        defer { isInstalling = false }

        do {
            if !Self.runtimeIsReady {
                try await Task.detached(priority: .userInitiated) {
                    try Self.createEnvironment(using: systemPython)
                }.value
                installProgress = 0.18
                installStatus = "Installing the local reranker runtime…"
                try await Task.detached(priority: .userInitiated) {
                    try Self.installRuntime()
                }.value
            }

            installProgress = 0.38
            installStatus = "Downloading Qwen3-Reranker-0.6B…"
            try await Task.detached(priority: .userInitiated) {
                try Self.downloadModel()
                try Self.writeServerScript()
            }.value

            installProgress = 0.94
            installStatus = "Verifying the reranker model…"
            try await Task.detached(priority: .userInitiated) {
                try Self.verifyInstallation()
            }.value

            installProgress = 1
            installStatus = "Reranker installation complete"
            await refresh()
            await start()
        } catch {
            fail("Reranker installation failed: \(error.localizedDescription)")
            installStatus = "Installation failed"
        }
    }

    func start() async {
        guard Self.isModelInstalled else {
            await refresh()
            return
        }
        await refresh()
        if isRunning { return }
        if !managedServiceProcessIDs.isEmpty {
            for _ in 0..<20 {
                if await healthCheck() {
                    state = .running
                    lastError = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            fail("The previous local reranker process did not become ready.")
            return
        }
        if await healthCheck() {
            fail("Port \(Self.servicePort) is already used by a reranker not managed by FileNest.")
            return
        }
        do {
            try Self.writeServerScript()
            let process = Process()
            process.executableURL = Self.pythonExecutable
            process.arguments = [
                Self.serverScriptURL.path,
                "--model", Self.modelRoot.path,
                "--port", String(Self.servicePort),
            ]
            process.environment = ProcessInfo.processInfo.environment.merging([
                "HF_HUB_DISABLE_TELEMETRY": "1",
                "TOKENIZERS_PARALLELISM": "false",
            ]) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                Task { @MainActor [weak self] in
                    guard let self, self.serviceProcess === process else { return }
                    self.serviceProcess = nil
                    self.managedServiceProcessIDs.removeAll { $0 == process.processIdentifier }
                    if self.state == .running || self.state == .starting {
                        self.state = .failed("The local reranker service stopped unexpectedly.")
                    }
                }
            }
            try process.run()
            serviceProcess = process
            managedServiceProcessIDs = [process.processIdentifier]
            state = .starting
            lastError = nil

            for _ in 0..<120 {
                if await healthCheck() {
                    state = .running
                    return
                }
                if !process.isRunning { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            process.terminate()
            serviceProcess = nil
            managedServiceProcessIDs = []
            fail("The local reranker did not become ready in time.")
        } catch {
            serviceProcess = nil
            fail("Unable to start the local reranker: \(error.localizedDescription)")
        }
    }

    /// Stops every reranker process whose command is FileNest's generated server.
    /// This also cleans up a process left behind after an interrupted app launch.
    func stop() async {
        let discoveredProcessIDs = await Self.discoverManagedServiceProcessIDs()
        var processIDs = Set(discoveredProcessIDs)
        if let serviceProcess, serviceProcess.isRunning {
            serviceProcess.terminationHandler = nil
            processIDs.insert(serviceProcess.processIdentifier)
        }

        processIDs.forEach { _ = Darwin.kill($0, SIGTERM) }
        for _ in 0..<12 where processIDs.contains(where: Self.processIsRunning) {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        processIDs.filter(Self.processIsRunning).forEach { _ = Darwin.kill($0, SIGKILL) }
        serviceProcess = nil
        managedServiceProcessIDs = []
        await refresh()
    }

    func restart() async {
        await stop()
        guard Self.isModelInstalled else { return }
        await start()
    }

    func deleteModel() async throws {
        await stop()
        if FileManager.default.fileExists(atPath: Self.modelRoot.path) {
            try FileManager.default.removeItem(at: Self.modelRoot)
        }
        await refresh()
    }

    /// Called while FileNest is quitting so managed runtime processes cannot outlive the app.
    func shutdown() async {
        await stop()
    }

    private func healthCheck() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(Self.servicePort)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    private func fail(_ message: String) {
        lastError = message
        state = .failed(message)
    }

    nonisolated private static func discoverManagedServiceProcessIDs() async -> [Int32] {
        await Task.detached(priority: .utility) {
            guard let output = commandOutput(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-axo", "pid=,command="]
            ) else { return [] }
            return managedServiceProcessIDs(from: output, serverScriptPath: serverScriptURL.path)
        }.value
    }

    nonisolated static func managedServiceProcessIDs(
        from processList: String,
        serverScriptPath: String
    ) -> [Int32] {
        processList.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let line = rawLine.drop(while: \Character.isWhitespace)
            let pidText = line.prefix(while: \Character.isNumber)
            guard let pid = Int32(pidText) else { return nil }
            let command = String(line.dropFirst(pidText.count).drop(while: \Character.isWhitespace))
            guard command.contains(serverScriptPath), command.contains("--port \(servicePort)") else {
                return nil
            }
            return pid
        }.sorted()
    }

    nonisolated private static func processIsRunning(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    nonisolated private static func createEnvironment(using python: URL) throws {
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try run(executable: python, arguments: ["-m", "venv", installRoot.appendingPathComponent("venv").path])
    }

    nonisolated private static func installRuntime() throws {
        let pip = installRoot.appendingPathComponent("venv/bin/pip")
        try run(executable: pip, arguments: [
            "install", "--disable-pip-version-check",
            "sentence-transformers>=5.4,<6", "fastapi>=0.115,<1", "uvicorn>=0.34,<1",
        ])
    }

    nonisolated private static var runtimeIsReady: Bool {
        guard FileManager.default.isExecutableFile(atPath: pythonExecutable.path) else { return false }
        let process = Process()
        process.executableURL = pythonExecutable
        process.arguments = ["-c", "import fastapi, sentence_transformers, uvicorn"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    nonisolated private static func downloadModel() throws {
        try FileManager.default.createDirectory(
            at: modelRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let script = """
        from huggingface_hub import snapshot_download
        snapshot_download(repo_id='\(defaultModel)', local_dir=r'\(modelRoot.path)')
        """
        try run(executable: pythonExecutable, arguments: ["-c", script])
    }

    nonisolated private static func verifyInstallation() throws {
        let script = """
        from sentence_transformers import CrossEncoder
        model = CrossEncoder(r'\(modelRoot.path)', device='cpu')
        scores = model.predict([('File search', 'A document stored on this Mac')])
        assert len(scores) == 1
        """
        try run(executable: pythonExecutable, arguments: ["-c", script])
    }

    nonisolated private static func writeServerScript() throws {
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try Data(serverScript.utf8).write(to: serverScriptURL, options: .atomic)
    }

    nonisolated private static let serverScript = #"""
import argparse
import threading
import time
import numpy as np
import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sentence_transformers import CrossEncoder
from sentence_transformers.util import batch_to_device

parser = argparse.ArgumentParser()
parser.add_argument("--model", required=True)
parser.add_argument("--port", required=True, type=int)
args = parser.parse_args()

device = "mps" if torch.backends.mps.is_available() else "cpu"
model = CrossEncoder(args.model, device=device)
model.max_seq_length = min(model.max_seq_length or 384, 384)
inference_lock = threading.Lock()

def synchronize_device():
    if device == "mps":
        torch.mps.synchronize()

def predict_with_timings(pairs):
    length_sorted_indices = np.argsort([-model._input_length(pair) for pair in pairs])
    sorted_pairs = [pairs[index] for index in length_sorted_indices]
    sorted_scores = []
    tokenize_ms = 0.0
    inference_ms = 0.0
    with torch.inference_mode():
        for start in range(0, len(sorted_pairs), 16):
            batch = sorted_pairs[start:start + 16]
            tokenize_started = time.perf_counter()
            features = model.preprocess(batch)
            features = batch_to_device(features, device)
            tokenize_ms += (time.perf_counter() - tokenize_started) * 1000

            synchronize_device()
            inference_started = time.perf_counter()
            scores = model.forward(features)["scores"]
            scores = torch.nn.functional.sigmoid(scores)
            if model.num_labels == 1 and scores.ndim > 1:
                scores = scores.squeeze(-1)
            synchronize_device()
            inference_ms += (time.perf_counter() - inference_started) * 1000
            sorted_scores.extend(float(score.cpu().detach()) for score in scores)

    original_order = np.argsort(length_sorted_indices)
    return [sorted_scores[index] for index in original_order], tokenize_ms, inference_ms

warmup_document = (
    "A representative indexed document section containing filenames, notes, "
    "metadata, dates, invoice details, project descriptions, and extracted text. "
) * 18
warmup_started = time.perf_counter()
predict_with_timings([
    ("Find relevant files in the local library", f"{warmup_document} Candidate {index}")
    for index in range(16)
])
warmup_ms = (time.perf_counter() - warmup_started) * 1000
app = FastAPI(docs_url=None, redoc_url=None)

class RerankRequest(BaseModel):
    model: str | None = None
    query: str
    documents: list[str]
    top_n: int | None = None

@app.get("/health")
def health():
    return {
        "status": "ok",
        "device": device,
        "max_sequence_length": model.max_seq_length,
        "warmup_ms": round(warmup_ms, 2),
    }

@app.post("/v1/rerank")
def rerank(request: RerankRequest):
    if not request.documents:
        return {"results": []}
    request_started = time.perf_counter()
    try:
        with inference_lock:
            queue_ms = (time.perf_counter() - request_started) * 1000
            scores, tokenize_ms, inference_ms = predict_with_timings(
                [(request.query, document) for document in request.documents]
            )
        results = [
            {"index": index, "relevance_score": float(score)}
            for index, score in enumerate(scores)
        ]
        results.sort(key=lambda item: item["relevance_score"], reverse=True)
        total_ms = (time.perf_counter() - request_started) * 1000
        return {
            "results": results[:request.top_n] if request.top_n else results,
            "_meta": {
                "device": device,
                "document_count": len(request.documents),
                "queue_ms": round(queue_ms, 2),
                "tokenize_ms": round(tokenize_ms, 2),
                "inference_ms": round(inference_ms, 2),
                "total_ms": round(total_ms, 2),
            },
        }
    except Exception as error:
        raise HTTPException(status_code=500, detail=str(error)) from error

uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")
"""#

    nonisolated private static func resolveSystemPython() -> URL? {
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/python3" })
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            guard let output = commandOutput(executable: url, arguments: ["--version"]) else { continue }
            let parts = output.split(whereSeparator: { !$0.isNumber && $0 != "." })
                .first(where: { $0.contains(".") })?.split(separator: ".") ?? []
            if parts.count >= 2,
               let major = Int(parts[0]), let minor = Int(parts[1]),
               major > 3 || (major == 3 && minor >= 10) { return url }
        }
        return nil
    }

    nonisolated private static func run(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RerankerManagerError.commandFailed }
    }

    nonisolated private static func commandOutput(executable: URL, arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        // Drain the pipe while the child is running. Waiting first can deadlock when `ps`
        // produces more output than the pipe buffer can hold.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

private enum RerankerManagerError: LocalizedError {
    case commandFailed

    var errorDescription: String? {
        "The reranker installation command failed. Check the FileNest log for details."
    }
}
