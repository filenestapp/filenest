import Foundation

struct OMPLaunchConfiguration: Equatable, Sendable {
    let executableURL: URL
    var arguments: [String] = []
    let workingDirectoryURL: URL
    var environment: [String: String] = [:]
    var startupTimeout: TimeInterval = 10
    var requestTimeout: TimeInterval = 30
}

enum OMPRPCConnectionError: LocalizedError, Equatable {
    case alreadyStarted
    case notRunning
    case startupTimedOut
    case requestTimedOut(String)
    case processTerminated(Int32)
    case unsupportedProtocol
    case invalidResponse(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .alreadyStarted: return "The OMP RPC process has already started."
        case .notRunning: return "The OMP RPC process is not running."
        case .startupTimedOut: return "The OMP RPC process did not become ready in time."
        case let .requestTimedOut(id): return "The OMP RPC request '\(id)' timed out."
        case let .processTerminated(status): return "The OMP RPC process exited with status \(status)."
        case .unsupportedProtocol: return "The OMP RPC process does not support protocol v2."
        case let .invalidResponse(reason): return "The OMP RPC response was invalid: \(reason)"
        case let .transport(reason): return "The OMP RPC transport failed: \(reason)"
        }
    }
}

/// Owns one OMP RPC process, request correlation, v2 frame decoding, and host-tool callbacks.
actor OMPRPCConnection {
    typealias DiagnosticHandler = @Sendable (String) -> Void

    private struct PendingRequest {
        let continuation: CheckedContinuation<OMPRPCFrame, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let configuration: OMPLaunchConfiguration
    private let diagnosticHandler: DiagnosticHandler?
    private let decoder = OMPRPCFrameDecoder()
    private var lineBuffer = Data()
    private var process: Process?
    private var standardInput: FileHandle?
    private var standardOutput: FileHandle?
    private var standardError: FileHandle?
    private var readyFrame: OMPRPCFrame?
    private var readyContinuation: CheckedContinuation<OMPRPCFrame, Error>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var pendingRequests: [String: PendingRequest] = [:]
    private var eventContinuations: [UUID: AsyncThrowingStream<OMPRPCFrame, Error>.Continuation] = [:]
    private var hostToolExecutor: AgentHostToolExecuting?
    private var hostToolTasks: [String: Task<AgentHostToolResult, Never>] = [:]
    private var stopped = false

    init(configuration: OMPLaunchConfiguration, diagnosticHandler: DiagnosticHandler? = nil) {
        self.configuration = configuration
        self.diagnosticHandler = diagnosticHandler
    }

    func start() async throws {
        guard process == nil else { throw OMPRPCConnectionError.alreadyStarted }

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workingDirectoryURL
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = ProcessInfo.processInfo.environment.merging(configuration.environment) { _, configured in
            configured
        }

        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receiveStandardOutput(data) }
        }
        let errorHandle = errorPipe.fileHandleForReading
        errorHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receiveStandardError(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.handleTermination(status: process.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil
            throw OMPRPCConnectionError.transport(error.localizedDescription)
        }

        self.process = process
        standardInput = inputPipe.fileHandleForWriting
        standardOutput = outputHandle
        standardError = errorHandle
        stopped = false

        let ready = try await waitUntilReady()
        let supported = ready["supportedProtocolVersions"]?.arrayValue?.compactMap(\.integerValue) ?? []
        guard supported.contains(2) else {
            await shutdown()
            throw OMPRPCConnectionError.unsupportedProtocol
        }
        _ = try await request(
            type: "negotiate_protocol",
            fields: ["protocolVersion": .number(2)]
        )
    }

    func events() -> AsyncThrowingStream<OMPRPCFrame, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    func request(
        type: String,
        fields: [String: AgentJSONValue] = [:],
        timeout: TimeInterval? = nil
    ) async throws -> OMPRPCFrame {
        guard process?.isRunning == true, let standardInput else {
            throw OMPRPCConnectionError.notRunning
        }
        let id = "req_\(UUID().uuidString.lowercased())"
        var object = fields
        object["id"] = .string(id)
        object["type"] = .string(type)
        let frame = try encodedLine(.object(object))
        let effectiveTimeout = max(0.1, timeout ?? configuration.requestTimeout)

        let response: OMPRPCFrame = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.expireRequest(id)
                }
                pendingRequests[id] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                do {
                    try standardInput.write(contentsOf: frame)
                } catch {
                    failRequest(id, error: OMPRPCConnectionError.transport(error.localizedDescription))
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.failRequest(id, error: CancellationError()) }
        }

        guard response.type == "response" else {
            throw OMPRPCConnectionError.invalidResponse("Expected a response frame.")
        }
        guard response.success == true else {
            let reason = response["error"]?.stringValue ?? "The request failed."
            throw OMPRPCConnectionError.invalidResponse(reason)
        }
        return response
    }

    func send(_ value: AgentJSONValue) throws {
        guard process?.isRunning == true, let standardInput else {
            throw OMPRPCConnectionError.notRunning
        }
        do {
            try standardInput.write(contentsOf: encodedLine(value))
        } catch {
            throw OMPRPCConnectionError.transport(error.localizedDescription)
        }
    }

    func setHostTools(executor: AgentHostToolExecuting) async throws {
        hostToolExecutor = executor
        let definitions = await executor.definitions
        _ = try await request(
            type: "set_host_tools",
            fields: ["tools": .array(definitions.map(\.jsonValue))]
        )
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        standardOutput?.readabilityHandler = nil
        standardError?.readabilityHandler = nil
        try? standardInput?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
        finish(error: nil)
        process = nil
        standardInput = nil
        standardOutput = nil
        standardError = nil
    }

    private func waitUntilReady() async throws -> OMPRPCFrame {
        if let readyFrame { return readyFrame }
        return try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            let timeout = max(0.1, configuration.startupTimeout)
            readyTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.expireReady()
            }
        }
    }

    private func receiveStandardOutput(_ data: Data) {
        guard !stopped else { return }
        lineBuffer.append(data)

        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let line = Data(lineBuffer[..<newlineIndex])
            lineBuffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty else { continue }
            do {
                if let frame = try decoder.decode(line: line) {
                    handle(frame)
                }
            } catch {
                finish(error: error)
                process?.terminate()
                return
            }
        }

        if lineBuffer.count > OMPRPCFrameDecoder.defaultMaximumPhysicalFrameBytes {
            finish(error: OMPRPCFrameDecoderError.physicalFrameTooLarge)
            process?.terminate()
        }
    }

    private func receiveStandardError(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        diagnosticHandler?(String(text.prefix(4_096)))
    }

    private func handle(_ frame: OMPRPCFrame) {
        if frame.type == "ready" {
            readyFrame = frame
            readyTimeoutTask?.cancel()
            readyTimeoutTask = nil
            readyContinuation?.resume(returning: frame)
            readyContinuation = nil
            return
        }

        if frame.type == "response", let id = frame.id, let pending = pendingRequests.removeValue(forKey: id) {
            pending.timeoutTask.cancel()
            pending.continuation.resume(returning: frame)
            return
        }

        if frame.type == "host_tool_call" {
            beginHostToolCall(frame)
        } else if frame.type == "host_tool_cancel",
                  let targetID = frame["targetId"]?.stringValue {
            hostToolTasks.removeValue(forKey: targetID)?.cancel()
        }

        for continuation in eventContinuations.values {
            continuation.yield(frame)
        }
    }

    private func beginHostToolCall(_ frame: OMPRPCFrame) {
        guard let id = frame.id,
              let toolName = frame["toolName"]?.stringValue,
              let executor = hostToolExecutor else {
            return
        }
        let arguments = frame["arguments"] ?? .object([:])
        let task = Task {
            await executor.execute(toolName: toolName, arguments: arguments)
        }
        hostToolTasks[id] = task
        Task { [weak self] in
            let result = await task.value
            await self?.completeHostToolCall(id: id, result: result)
        }
    }

    private func completeHostToolCall(id: String, result: AgentHostToolResult) {
        guard hostToolTasks.removeValue(forKey: id) != nil else { return }
        var object: [String: AgentJSONValue] = [
            "type": .string("host_tool_result"),
            "id": .string(id),
            "result": result.jsonValue,
        ]
        if result.isError { object["isError"] = .bool(true) }
        try? send(.object(object))
    }

    private func handleTermination(status: Int32) {
        guard !stopped else { return }
        stopped = true
        finish(error: OMPRPCConnectionError.processTerminated(status))
    }

    private func finish(error: Error?) {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        if let readyContinuation {
            if let error {
                readyContinuation.resume(throwing: error)
            } else {
                readyContinuation.resume(throwing: CancellationError())
            }
            self.readyContinuation = nil
        }
        for pending in pendingRequests.values {
            pending.timeoutTask.cancel()
            if let error {
                pending.continuation.resume(throwing: error)
            } else {
                pending.continuation.resume(throwing: CancellationError())
            }
        }
        pendingRequests.removeAll()
        for task in hostToolTasks.values { task.cancel() }
        hostToolTasks.removeAll()
        for continuation in eventContinuations.values {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
        eventContinuations.removeAll()
        decoder.reset()
        lineBuffer.removeAll(keepingCapacity: false)
    }

    private func expireReady() {
        guard let readyContinuation else { return }
        self.readyContinuation = nil
        readyTimeoutTask = nil
        readyContinuation.resume(throwing: OMPRPCConnectionError.startupTimedOut)
        process?.terminate()
    }

    private func expireRequest(_ id: String) {
        failRequest(id, error: OMPRPCConnectionError.requestTimedOut(id))
    }

    private func failRequest(_ id: String, error: Error) {
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        pending.timeoutTask.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func encodedLine(_ value: AgentJSONValue) throws -> Data {
        var data = try value.encodedData()
        data.append(0x0A)
        guard data.count <= OMPRPCFrameDecoder.defaultMaximumPhysicalFrameBytes else {
            throw OMPRPCFrameDecoderError.physicalFrameTooLarge
        }
        return data
    }
}
