import Foundation
import Darwin

struct OllamaModelDetails: Equatable, Sendable, Decodable {
    let format: String?
    let family: String?
    let parameterSize: String?
    let quantizationLevel: String?
    let architecture: String?
    let contextLength: Int?
    let embeddingLength: Int?
    let contextLengthIsExplicit: Bool

    enum CodingKeys: String, CodingKey {
        case format, family
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
    }

    init(format: String? = nil,
         family: String? = nil,
         parameterSize: String? = nil,
         quantizationLevel: String? = nil,
         architecture: String? = nil,
         contextLength: Int? = nil,
         embeddingLength: Int? = nil,
         contextLengthIsExplicit: Bool = false) {
        self.format = format
        self.family = family
        self.parameterSize = parameterSize
        self.quantizationLevel = quantizationLevel
        self.architecture = architecture
        self.contextLength = contextLength
        self.embeddingLength = embeddingLength
        self.contextLengthIsExplicit = contextLengthIsExplicit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            format: try container.decodeIfPresent(String.self, forKey: .format),
            family: try container.decodeIfPresent(String.self, forKey: .family),
            parameterSize: try container.decodeIfPresent(String.self, forKey: .parameterSize),
            quantizationLevel: try container.decodeIfPresent(String.self, forKey: .quantizationLevel)
        )
    }

    func merging(_ newer: OllamaModelDetails) -> OllamaModelDetails {
        OllamaModelDetails(
            format: newer.format ?? format,
            family: newer.family ?? family,
            parameterSize: newer.parameterSize ?? parameterSize,
            quantizationLevel: newer.quantizationLevel ?? quantizationLevel,
            architecture: newer.architecture ?? architecture,
            contextLength: newer.contextLength ?? contextLength,
            embeddingLength: newer.embeddingLength ?? embeddingLength,
            contextLengthIsExplicit: newer.contextLengthIsExplicit || contextLengthIsExplicit
        )
    }
}

struct OllamaModelInfo: Identifiable, Equatable, Decodable {
    let name: String
    let size: Int64
    let modifiedAt: String?
    let details: OllamaModelDetails?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, size, details
        case modifiedAt = "modified_at"
    }

    func withDetails(_ value: OllamaModelDetails) -> OllamaModelInfo {
        OllamaModelInfo(
            name: name,
            size: size,
            modifiedAt: modifiedAt,
            details: details?.merging(value) ?? value
        )
    }
}

enum OllamaModelMetadataParser {
    static func details(from data: Data) -> OllamaModelDetails? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rawDetails = object["details"] as? [String: Any]
        let modelInfo = object["model_info"] as? [String: Any]
        let parameters = object["parameters"] as? String
        let explicitContext = parameters.flatMap { parameter(named: "num_ctx", in: $0) }
        let modelContext = integerValue(in: modelInfo, keySuffix: ".context_length")
        let embeddingLength = integerValue(in: modelInfo, keySuffix: ".embedding_length")
        let parameterSize = rawDetails?["parameter_size"] as? String
            ?? formattedParameterCount(modelInfo?["general.parameter_count"] as? NSNumber)

        return OllamaModelDetails(
            format: rawDetails?["format"] as? String,
            family: rawDetails?["family"] as? String,
            parameterSize: parameterSize,
            quantizationLevel: rawDetails?["quantization_level"] as? String,
            architecture: modelInfo?["general.architecture"] as? String,
            contextLength: explicitContext ?? modelContext,
            embeddingLength: embeddingLength,
            contextLengthIsExplicit: explicitContext != nil
        )
    }

    private static func integerValue(in values: [String: Any]?, keySuffix: String) -> Int? {
        values?.first { key, value in
            key.hasSuffix(keySuffix) && ((value as? NSNumber)?.intValue ?? 0) > 0
        }.flatMap { ($0.value as? NSNumber)?.intValue }
    }

    private static func parameter(named name: String, in parameters: String) -> Int? {
        for line in parameters.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count >= 2, parts[0] == Substring(name), let value = Int(parts[1]) {
                return value
            }
        }
        return nil
    }

    private static func formattedParameterCount(_ count: NSNumber?) -> String? {
        guard let count else { return nil }
        let value = count.doubleValue
        if value >= 1_000_000_000 { return String(format: "%.1fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.0fM", value / 1_000_000) }
        return count.stringValue
    }
}

actor OllamaModelMetadataCache {
    static let shared = OllamaModelMetadataCache()

    private struct Entry {
        let modifiedAt: String?
        let details: OllamaModelDetails
    }

    private var entries: [String: Entry] = [:]

    func details(host: String, model: String, modifiedAt: String? = nil) -> OllamaModelDetails? {
        guard let entry = entries[key(host: host, model: model)] else { return nil }
        if let modifiedAt, let cachedModifiedAt = entry.modifiedAt, modifiedAt != cachedModifiedAt {
            return nil
        }
        return entry.details
    }

    func store(_ details: OllamaModelDetails, host: String, model: String, modifiedAt: String? = nil) {
        entries[key(host: host, model: model)] = Entry(modifiedAt: modifiedAt, details: details)
    }

    func remove(host: String, model: String) {
        entries.removeValue(forKey: key(host: host, model: model))
    }

    private func key(host: String, model: String) -> String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return "\(normalizedHost)|\(OllamaServiceManager.canonicalModelName(model))"
    }
}

struct OllamaModelProfile: Identifiable, Equatable {
    let id: String
    let minimumMemoryGB: Int
    let memoryLabel: String
    let generationModel: String
    let embeddingModel: String
    let embeddingSize: String
    let contextRange: String

    func menuTitle(isRecommended: Bool) -> String {
        let prefix = isRecommended ? "Recommended · " : ""
        return "\(prefix)\(memoryLabel) — \(generationModel)"
    }
}

enum OllamaModelRecommendation {
    static let defaultGenerationModel = "qwen3.5:9b"
    static let defaultEmbeddingModel = "qwen3-embedding:0.6b"
    static let generationModels = ["qwen3.5:2b", "qwen3.5:4b", defaultGenerationModel]
    static let embeddingModels = [defaultEmbeddingModel, "qwen3-embedding:4b", "qwen3-embedding:8b"]
    static let profiles: [OllamaModelProfile] = [
        OllamaModelProfile(
            id: "memory-8", minimumMemoryGB: 8, memoryLabel: "8GB Memory",
            generationModel: "qwen3.5:2b", embeddingModel: "qwen3-embedding:0.6b",
            embeddingSize: "0.6b", contextRange: "4K–8K"
        ),
        OllamaModelProfile(
            id: "memory-16", minimumMemoryGB: 16, memoryLabel: "16GB Memory",
            generationModel: "qwen3.5:4b", embeddingModel: "qwen3-embedding:0.6b",
            embeddingSize: "0.6b", contextRange: "8K–16K"
        ),
        OllamaModelProfile(
            id: "memory-24", minimumMemoryGB: 24, memoryLabel: "24GB Memory",
            generationModel: "qwen3.5:9b", embeddingModel: "qwen3-embedding:0.6b",
            embeddingSize: "0.6b", contextRange: "16K–32K"
        ),
        OllamaModelProfile(
            id: "memory-32", minimumMemoryGB: 32, memoryLabel: "32GB Memory",
            generationModel: "qwen3.5:9b", embeddingModel: "qwen3-embedding:4b",
            embeddingSize: "4b", contextRange: "16K–32K"
        ),
        OllamaModelProfile(
            id: "memory-64", minimumMemoryGB: 64, memoryLabel: "64GB or More",
            generationModel: "qwen3.5:9b", embeddingModel: "qwen3-embedding:8b",
            embeddingSize: "8b", contextRange: "32K–64K"
        ),
    ]

    static var defaultProfile: OllamaModelProfile {
        profiles.first {
            $0.generationModel == defaultGenerationModel
                && $0.embeddingModel == defaultEmbeddingModel
        } ?? profiles[0]
    }

    static var currentMemoryGB: Int {
        let bytesPerGB = Double(1_024 * 1_024 * 1_024)
        return max(Int((Double(ProcessInfo.processInfo.physicalMemory) / bytesPerGB).rounded()), 1)
    }

    static var recommendedForCurrentDevice: OllamaModelProfile {
        recommended(forMemoryGB: currentMemoryGB)
    }

    static func recommended(forMemoryGB memoryGB: Int) -> OllamaModelProfile {
        profiles.last(where: { memoryGB >= $0.minimumMemoryGB }) ?? profiles[0]
    }

    static func orderedProfiles(forMemoryGB memoryGB: Int) -> [OllamaModelProfile] {
        let recommended = recommended(forMemoryGB: memoryGB)
        return [recommended] + profiles.filter { $0.id != recommended.id }
    }
}

enum OllamaModelCatalog {
    /// Download sizes of Ollama's official default tags as of July 2026, used for pre-download capacity guidance.
    private static let downloadSizes: [String: Int64] = [
        "qwen3.5:0.8b": 1_000_000_000,
        "qwen3.5:2b": 2_700_000_000,
        "qwen3.5:4b": 3_400_000_000,
        "qwen3.5:9b": 6_600_000_000,
        "qwen3-embedding:0.6b": 639_000_000,
        "qwen3-embedding:4b": 2_500_000_000,
        "qwen3-embedding:8b": 4_700_000_000,
        "glm-ocr": 2_200_000_000,
        "glm-ocr:latest": 2_200_000_000,
        "glm-ocr:q8_0": 1_600_000_000,
    ]

    static func estimatedDownloadBytes(for model: String) -> Int64? {
        downloadSizes[model.lowercased()]
    }
}

enum OllamaServiceState: Equatable {
    case stopped
    case starting
    case running
    case failed(String)

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running: return "Running"
        case .failed: return "Failed to Start"
        }
    }
}

@MainActor
final class OllamaServiceManager: ObservableObject {
    @Published private(set) var state: OllamaServiceState = .stopped
    @Published private(set) var models: [OllamaModelInfo] = []
    @Published private(set) var executablePath: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var pullingModel: String?
    @Published private(set) var pullProgress: Double?
    @Published private(set) var pullStatus = ""
    @Published private(set) var isInstalling = false
    @Published private(set) var installProgress: Double?
    @Published private(set) var installStatus = ""
    @Published private(set) var lastError: String?
    @Published private(set) var managedServiceProcessIDs: [Int32] = []
    @Published private(set) var installedVersion: String?
    @Published private(set) var latestVersion: String?
    @Published private(set) var updateStatus: ManagedServiceUpdateStatus = .idle
    @Published private(set) var activeHost: String?

    private let session: URLSession
    private var launchedProcess: Process?
    private var latestDownloadURL: URL?

    init(session: URLSession = .shared) {
        self.session = session
        let executable = Self.resolveExecutable()
        executablePath = executable?.path
        installedVersion = executable.flatMap(Self.installedVersion(for:))
    }

    var canStopManagedService: Bool {
        launchedProcess?.isRunning == true || !managedServiceProcessIDs.isEmpty
    }

    var isManagedInstall: Bool {
        guard let executablePath else { return false }
        return Self.isFileNestManagedExecutable(URL(fileURLWithPath: executablePath))
    }

    func isModelInstalled(_ model: String) -> Bool {
        models.contains { Self.modelNamesMatch($0.name, model) }
    }

    func chatModels(embeddingModel: String, ocrModel: String) -> [OllamaModelInfo] {
        models.filter {
            Self.isChatModel($0.name, embeddingModel: embeddingModel, ocrModel: ocrModel)
        }
    }

    nonisolated static func isChatModel(_ model: String,
                                        embeddingModel: String,
                                        ocrModel: String) -> Bool {
        if modelNamesMatch(model, embeddingModel) || modelNamesMatch(model, ocrModel) { return false }
        let normalized = model.lowercased()
        let auxiliaryMarkers = [
            "embedding", "-embed", "_embed", "nomic-embed", "mxbai-embed",
            "bge-", "bge_", "e5-", "e5_", "glm-ocr", "-ocr", "_ocr",
        ]
        return !auxiliaryMarkers.contains(where: normalized.contains)
    }

    nonisolated static func modelNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        canonicalModelName(lhs) == canonicalModelName(rhs)
    }

    nonisolated static func canonicalModelName(_ rawName: String) -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name.hasSuffix(":latest") ? String(name.dropLast(":latest".count)) : name
    }

    nonisolated static let officialDownloadURL = URL(string: "https://ollama.com/download/Ollama.dmg")!

    nonisolated static var localApplicationURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("FileNest", isDirectory: true)
            .appendingPathComponent("Ollama", isDirectory: true)
            .appendingPathComponent("Ollama.app", isDirectory: true)
    }

    func refresh(host: String) async {
        isRefreshing = true
        defer { isRefreshing = false }
        let executable = Self.resolveExecutable()
        executablePath = executable?.path
        installedVersion = executable.flatMap(Self.installedVersion(for:))
        let discoveredProcessIDs = await Self.discoverManagedServiceProcessIDs()
        if discoveredProcessIDs != managedServiceProcessIDs {
            Self.log(
                discoveredProcessIDs.isEmpty
                    ? "FileNest-managed Ollama service not detected"
                    : "FileNest-managed Ollama service detected pids=\(discoveredProcessIDs)"
            )
        }
        managedServiceProcessIDs = discoveredProcessIDs

        do {
            let listedModels = try await fetchModels(host: host)
            models = await hydrateModelDetails(listedModels, host: host)
            state = .running
            activeHost = host
            lastError = nil
        } catch {
            models = []
            if launchedProcess?.isRunning == true {
                state = .starting
            } else {
                state = .stopped
                activeHost = nil
            }
        }
    }

    func checkForUpdates() async {
        guard isManagedInstall else {
            updateStatus = .idle
            latestVersion = nil
            latestDownloadURL = nil
            return
        }
        guard !updateStatus.isBusy else { return }

        updateStatus = .checking
        do {
            let release = try await ManagedServiceReleaseAPI.latestGitHubRelease(session: session)
            latestVersion = release.version
            latestDownloadURL = release.macOSDMGURL
            guard let installedVersion else {
                updateStatus = .failed("Could not read the installed version")
                return
            }
            updateStatus = ManagedServiceReleaseAPI.isNewer(release.version, than: installedVersion)
                ? .updateAvailable(release.version)
                : .upToDate
        } catch {
            latestDownloadURL = nil
            updateStatus = .failed(error.localizedDescription)
        }
    }

    func update(host: String, flashAttentionEnabled: Bool = true) async {
        guard isManagedInstall,
              case let .updateAvailable(targetVersion) = updateStatus,
              let downloadURL = latestDownloadURL else { return }
        if state == .running, !canStopManagedService {
            updateStatus = .failed("The running Ollama service is not managed by FileNest. Stop it before updating.")
            return
        }
        updateStatus = .updating
        if canStopManagedService {
            await stop(host: host)
            guard !canStopManagedService else {
                updateStatus = .failed(lastError ?? "Ollama update failed")
                return
            }
        }
        await installAndStart(
            host: host,
            flashAttentionEnabled: flashAttentionEnabled,
            downloadURL: downloadURL
        )
        guard lastError == nil else {
            updateStatus = .failed(lastError ?? "Ollama update failed")
            return
        }
        let executable = Self.resolveExecutable()
        executablePath = executable?.path
        installedVersion = executable.flatMap(Self.installedVersion(for:))
        guard let installedVersion,
              !ManagedServiceReleaseAPI.isNewer(targetVersion, than: installedVersion) else {
            let detectedVersion = installedVersion ?? "unknown"
            Self.log(
                "Ollama update verification failed expected=\(targetVersion) detected=\(detectedVersion)",
                level: .error
            )
            installStatus = "Ollama update verification failed"
            updateStatus = .failed("Ollama update verification failed")
            return
        }
        installStatus = "Ollama update complete and running"
        updateStatus = .upToDate
    }

    /// Downloads the official Ollama DMG into FileNest's user-level directory and starts the service after installation.
    /// Does not write to /Applications or create a /usr/local/bin link, so administrator privileges are unnecessary.
    func installAndStart(
        host: String,
        flashAttentionEnabled: Bool = true,
        downloadURL: URL = officialDownloadURL
    ) async {
        guard !isInstalling else { return }
        guard #available(macOS 14.0, *) else {
            let message = "This version of Ollama requires macOS 14 Sonoma or later."
            state = .failed(message)
            lastError = message
            return
        }

        isInstalling = true
        installProgress = 0
        installStatus = "Downloading from Ollama’s official site…"
        lastError = nil
        defer { isInstalling = false }

        do {
            let retainedDMG = try await DownloadCoordinator.shared.download(
                ManagedDownloadRequest(
                    identifier: "ollama-runtime",
                    displayName: "Ollama Runtime",
                    sourceURL: downloadURL
                )
            ) { [weak self] snapshot in
                guard let fraction = snapshot.fractionCompleted else { return }
                self?.installProgress = fraction * 0.72
            }
            defer { try? FileManager.default.removeItem(at: retainedDMG) }

            installProgress = 0.76
            installStatus = "Verifying and installing in your user directory…"
            let executable = try await Task.detached(priority: .userInitiated) {
                try Self.installDownloadedDMG(at: retainedDMG)
            }.value
            executablePath = executable.path
            installedVersion = Self.installedVersion(for: executable)
            installProgress = 0.94
            installStatus = "Installation complete. Starting the service…"
            await start(host: host, flashAttentionEnabled: flashAttentionEnabled)
            if state == .running {
                installProgress = 1
                installStatus = "Ollama is installed and running"
            }
        } catch {
            let message = "Ollama installation failed: \(error.localizedDescription)"
            installStatus = "Installation Failed"
            state = .failed(message)
            lastError = message
        }
    }

    func start(host: String, flashAttentionEnabled: Bool = true) async {
        if !isInstalling { installProgress = nil }
        guard Self.isLocalServiceHost(host) else {
            await refresh(host: host)
            guard state == .running else {
                let message = "The configured remote Ollama service is unavailable."
                state = .failed(message)
                lastError = message
                Self.log(message, level: .error)
                return
            }
            return
        }

        let managedProcesses = await Self.discoverManagedServiceProcessIDs()
        if !managedProcesses.isEmpty,
           (try? await fetchModels(host: host)) != nil {
            managedServiceProcessIDs = managedProcesses
            await refresh(host: host)
            return
        }

        guard let launchHost = Self.firstAvailableLocalHost(startingAt: host) else {
            let message = "No available local port was found for Ollama."
            state = .failed(message)
            lastError = message
            Self.log(message, level: .error)
            return
        }
        if launchHost != host {
            Self.log(
                "Ollama port unavailable; selected fallback host",
                level: .notice,
                metadata: ["requestedHost": host, "activeHost": launchHost]
            )
        }

        if let process = launchedProcess, process.isRunning {
            state = .starting
            lastError = nil
            let runningHost = activeHost ?? launchHost
            if await waitUntilReady(host: runningHost, process: process) {
                await refresh(host: runningHost)
                Self.log("Ollama became ready pid=\(process.processIdentifier)")
            } else {
                markStartupFailure(host: runningHost)
            }
            return
        }

        guard let executable = Self.resolveExecutable() else {
            let message = "Ollama was not found. Install Ollama first."
            state = .failed(message)
            lastError = message
            return
        }
        do {
            try Self.prepareManagedModelDirectory()
        } catch {
            let message = "Unable to prepare the FileNest Ollama model directory: \(error.localizedDescription)"
            state = .failed(message)
            lastError = message
            Self.log(message, level: .error)
            return
        }

        state = .starting
        lastError = nil
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        if let serviceHost = Self.ollamaHostEnvironment(from: launchHost) {
            environment["OLLAMA_HOST"] = serviceHost
        }
        environment["OLLAMA_MODELS"] = ManagedRuntimePaths.ollamaModelsRoot.path
        environment["OLLAMA_FLASH_ATTENTION"] = flashAttentionEnabled ? "true" : "false"
        process.environment = environment

        do {
            Self.log(
                "Ollama start requested flashAttention=\(flashAttentionEnabled)",
                metadata: ["host": launchHost]
            )
            try process.run()
            launchedProcess = process
            activeHost = launchHost
            if Self.isFileNestManagedExecutable(executable) {
                managedServiceProcessIDs = [process.processIdentifier]
            }
            process.terminationHandler = { [weak self] terminated in
                Task { @MainActor in
                    guard let self, self.launchedProcess === terminated else { return }
                    self.launchedProcess = nil
                    self.managedServiceProcessIDs.removeAll { $0 == terminated.processIdentifier }
                    if case .starting = self.state {
                        let message = "The Ollama service exited immediately after launch."
                        self.state = .failed(message)
                        self.lastError = message
                    } else {
                        self.state = .stopped
                    }
                    self.activeHost = nil
                }
            }

            if await waitUntilReady(host: launchHost, process: process) {
                await refresh(host: launchHost)
                Self.log("Ollama started pid=\(process.processIdentifier)")
                return
            }
            markStartupFailure(host: launchHost)
        } catch {
            let message = "Unable to start Ollama: \(error.localizedDescription)"
            state = .failed(message)
            activeHost = nil
            lastError = message
            Self.log(message, level: .error)
        }
    }

    private func waitUntilReady(host: String, process: Process) async -> Bool {
        // Cold starts may take longer while Ollama initializes its runtime. Keep this async
        // so application launch and the main window remain responsive.
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if (try? await fetchModels(host: host)) != nil { return true }
            if !process.isRunning { return false }
        }
        return false
    }

    private func markStartupFailure(host: String) {
        let message = "The service started but could not connect to \(host)."
        state = .failed(message)
        lastError = message
        Self.log(message, level: .error)
    }

    func stop(host: String) async {
        managedServiceProcessIDs = await Self.discoverManagedServiceProcessIDs()
        var processIDs = Set(managedServiceProcessIDs)
        if let process = launchedProcess, process.isRunning {
            processIDs.insert(process.processIdentifier)
        }
        guard !processIDs.isEmpty else {
            if state == .running {
                lastError = "This Ollama service was started outside FileNest. Stop it from its original launcher."
            }
            return
        }

        Self.log("Ollama stop requested pids=\(processIDs.sorted())")
        processIDs.forEach { _ = Darwin.kill($0, SIGTERM) }
        for _ in 0..<12 where processIDs.contains(where: Self.processIsRunning) {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        processIDs.filter(Self.processIsRunning).forEach { _ = Darwin.kill($0, SIGINT) }
        for _ in 0..<8 where processIDs.contains(where: Self.processIsRunning) {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let remaining = processIDs.filter(Self.processIsRunning)
        launchedProcess = nil
        managedServiceProcessIDs = []
        if remaining.isEmpty {
            state = .stopped
            models = []
            activeHost = nil
            lastError = nil
            Self.log("Ollama stopped")
        } else {
            let message = "The Ollama service could not stop (PIDs: \(remaining.sorted().map(String.init).joined(separator: ", ")))."
            lastError = message
            Self.log(message, level: .error)
        }
        await refresh(host: host)
        if !remaining.isEmpty { lastError = "The Ollama service could not stop. Try again later." }
    }

    func pull(model rawName: String, host: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard let url = endpoint(host: host, path: "/api/pull") else {
            lastError = "The Ollama address is invalid."
            return
        }

        pullingModel = name
        pullProgress = nil
        pullStatus = "Preparing Download"
        lastError = nil
        defer { pullingModel = nil }
        let downloadIdentifier = "ollama-model-\(Self.canonicalModelName(name))"
        DownloadCoordinator.shared.beginExternalDownload(
            identifier: downloadIdentifier,
            displayName: name,
            sourceURL: url
        )

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 3_600
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "stream": true])

            let (bytes, response) = try await session.bytes(for: request)
            try Self.validate(response)
            for try await line in bytes.lines where !line.isEmpty {
                guard let data = line.data(using: .utf8),
                      let update = try? JSONDecoder().decode(PullUpdate.self, from: data) else { continue }
                if let error = update.error { throw OllamaManagerError.server(error) }
                pullStatus = update.status ?? "Downloading"
                if let completed = update.completed, let total = update.total, total > 0 {
                    pullProgress = min(max(Double(completed) / Double(total), 0), 1)
                    DownloadCoordinator.shared.updateExternalDownload(
                        identifier: downloadIdentifier,
                        bytesReceived: Int64(clamping: completed),
                        bytesExpected: Int64(clamping: total)
                    )
                }
            }
            pullProgress = 1
            pullStatus = "Download Complete"
            DownloadCoordinator.shared.finishExternalDownload(identifier: downloadIdentifier)
            await refresh(host: host)
        } catch {
            lastError = "Model download failed: \(error.localizedDescription)"
            pullStatus = "Download Failed"
            DownloadCoordinator.shared.failExternalDownload(
                identifier: downloadIdentifier,
                error: error
            )
        }
    }

    func delete(model: String, host: String) async {
        guard let url = endpoint(host: host, path: "/api/delete") else {
            lastError = "The Ollama address is invalid."
            return
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["name": model])
            let (_, response) = try await session.data(for: request)
            try Self.validate(response)
            await OllamaModelMetadataCache.shared.remove(host: host, model: model)
            await refresh(host: host)
        } catch {
            lastError = "Failed to delete model: \(error.localizedDescription)"
        }
    }

    private func fetchModels(host: String) async throws -> [OllamaModelInfo] {
        guard let url = endpoint(host: host, path: "/api/tags") else {
            throw OllamaManagerError.invalidHost
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        return try JSONDecoder().decode(TagsResponse.self, from: data).models
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func hydrateModelDetails(_ listedModels: [OllamaModelInfo],
                                     host: String) async -> [OllamaModelInfo] {
        var hydrated = [OllamaModelInfo]()
        hydrated.reserveCapacity(listedModels.count)
        for model in listedModels {
            if let cached = await OllamaModelMetadataCache.shared.details(
                host: host,
                model: model.name,
                modifiedAt: model.modifiedAt
            ) {
                hydrated.append(model.withDetails(cached))
                continue
            }
            guard let details = try? await fetchModelDetails(host: host, model: model.name) else {
                hydrated.append(model)
                continue
            }
            await OllamaModelMetadataCache.shared.store(
                details,
                host: host,
                model: model.name,
                modifiedAt: model.modifiedAt
            )
            hydrated.append(model.withDetails(details))
        }
        return hydrated
    }

    private func fetchModelDetails(host: String, model: String) async throws -> OllamaModelDetails {
        guard let url = endpoint(host: host, path: "/api/show") else {
            throw OllamaManagerError.invalidHost
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let details = OllamaModelMetadataParser.details(from: data) else {
            throw OllamaManagerError.badResponse
        }
        return details
    }

    private func endpoint(host: String, path: String) -> URL? {
        let base = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: base + path)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw OllamaManagerError.badResponse
        }
    }

    private static func resolveExecutable() -> URL? {
        let executable = localApplicationURL.appendingPathComponent("Contents/Resources/ollama")
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    nonisolated private static func prepareManagedModelDirectory() throws {
        let manager = FileManager.default
        let managed = ManagedRuntimePaths.ollamaModelsRoot
        if manager.fileExists(atPath: managed.path) { return }

        let legacy = manager.homeDirectoryForCurrentUser
            .appendingPathComponent(".ollama/models", isDirectory: true)
        try manager.createDirectory(
            at: managed.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if manager.fileExists(atPath: legacy.path) {
            try manager.moveItem(at: legacy, to: managed)
            log("Migrated Ollama models into the FileNest-managed directory")
        } else {
            try manager.createDirectory(at: managed, withIntermediateDirectories: true)
        }
    }

    nonisolated private static func installedVersion(for executable: URL) -> String? {
        if let data = try? runProcess(executable: executable.path, arguments: ["--version"]),
           let version = version(fromCommandOutput: data) {
            return version
        }
        let application = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if application.pathExtension == "app",
           let bundle = Bundle(url: application),
           let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return ManagedServiceReleaseAPI.normalized(version)
        }
        return nil
    }

    nonisolated static func version(fromCommandOutput data: Data) -> String? {
        guard let output = String(data: data, encoding: .utf8),
              let version = output.split(whereSeparator: { !$0.isNumber && $0 != "." })
                .first(where: { $0.contains(".") }) else { return nil }
        return ManagedServiceReleaseAPI.normalized(String(version))
    }

    nonisolated private static func isFileNestManagedExecutable(_ executable: URL) -> Bool {
        executable.standardizedFileURL.path == localApplicationURL
            .appendingPathComponent("Contents/Resources/ollama")
            .standardizedFileURL.path
    }

    nonisolated private static func discoverManagedServiceProcessIDs() async -> [Int32] {
        await Task.detached(priority: .utility) {
            let executable = localApplicationURL
                .appendingPathComponent("Contents/Resources/ollama")
                .standardizedFileURL.path
            guard FileManager.default.isExecutableFile(atPath: executable) else { return [] }
            let pattern = "^\(regularExpressionEscaped(executable)) serve( |$)"
            guard let output = try? runProcess(
                executable: "/usr/bin/pgrep",
                arguments: ["-f", pattern]
            ), let text = String(data: output, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).compactMap { rawPID in
                Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines))
            }.sorted()
        }.value
    }

    nonisolated private static func regularExpressionEscaped(_ value: String) -> String {
        NSRegularExpression.escapedPattern(for: value)
    }

    nonisolated static func managedServiceProcessIDs(from processList: String,
                                                     executablePath: String) -> [Int32] {
        let expectedCommand = executablePath + " serve"
        return processList.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            let line = rawLine.drop(while: \Character.isWhitespace)
            let pidText = line.prefix(while: \Character.isNumber)
            guard let pid = Int32(pidText) else { return nil }
            let command = line.dropFirst(pidText.count).drop(while: \Character.isWhitespace)
            guard command == expectedCommand || command.hasPrefix(expectedCommand + " ") else { return nil }
            return pid
        }
    }

    nonisolated private static func processIsRunning(_ pid: Int32) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    nonisolated private static func log(
        _ message: String,
        level: AppLogLevel = .info,
        metadata: [String: String] = [:]
    ) {
        AppLogService.shared.write(
            message,
            category: .appLifecycle,
            level: level,
            metadata: metadata
        )
    }

    nonisolated private static func installDownloadedDMG(at dmgURL: URL) throws -> URL {
        let attach = try runProcess(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-nobrowse", "-readonly", "-plist", dmgURL.path]
        )
        guard let plist = try PropertyListSerialization.propertyList(from: attach, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPath = entities.compactMap({ $0["mount-point"] as? String }).last else {
            throw OllamaManagerError.invalidDiskImage
        }

        defer {
            _ = try? runProcess(executable: "/usr/bin/hdiutil", arguments: ["detach", mountPath, "-force"])
        }

        let mountURL = URL(fileURLWithPath: mountPath, isDirectory: true)
        let sourceApplication = mountURL.appendingPathComponent("Ollama.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceApplication.path) else {
            throw OllamaManagerError.applicationMissing
        }

        try verifyCodeSignature(of: sourceApplication)

        let destinationApplication = localApplicationURL
        let installRoot = destinationApplication.deletingLastPathComponent()
        let parent = installRoot.deletingLastPathComponent()
        let stagingRoot = parent.appendingPathComponent("Ollama.installing-\(UUID().uuidString)", isDirectory: true)
        let stagingApplication = stagingRoot.appendingPathComponent("Ollama.app", isDirectory: true)
        let backupRoot = parent.appendingPathComponent("Ollama.backup-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stagingRoot) }
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        _ = try runProcess(executable: "/usr/bin/ditto", arguments: [sourceApplication.path, stagingApplication.path])
        try verifyCodeSignature(of: stagingApplication)

        let hadExistingInstall = fileManager.fileExists(atPath: installRoot.path)
        if hadExistingInstall {
            try fileManager.moveItem(at: installRoot, to: backupRoot)
        }
        do {
            try fileManager.moveItem(at: stagingRoot, to: installRoot)
            if hadExistingInstall { try? fileManager.removeItem(at: backupRoot) }
        } catch {
            if hadExistingInstall, !fileManager.fileExists(atPath: installRoot.path) {
                try? fileManager.moveItem(at: backupRoot, to: installRoot)
            }
            throw error
        }

        let executable = destinationApplication.appendingPathComponent("Contents/Resources/ollama")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw OllamaManagerError.executableMissing
        }
        return executable
    }

    nonisolated private static func verifyCodeSignature(of application: URL) throws {
        do {
            _ = try runProcess(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", application.path]
            )
            _ = try runProcess(
                executable: "/usr/sbin/spctl",
                arguments: ["--assess", "--type", "execute", application.path]
            )
        } catch {
            throw OllamaManagerError.invalidSignature
        }
    }

    @discardableResult
    nonisolated private static func runProcess(executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw OllamaManagerError.commandFailed(detail ?? executable)
        }
        return data
    }

    private static func ollamaHostEnvironment(from host: String) -> String? {
        guard let components = URLComponents(string: host), let hostname = components.host else { return nil }
        return components.port.map { "\(hostname):\($0)" } ?? hostname
    }

    nonisolated static func isLocalServiceHost(_ host: String) -> Bool {
        guard let rawHostname = URLComponents(string: host)?.host?.lowercased() else { return false }
        let hostname = rawHostname.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return hostname == "localhost"
            || hostname == "127.0.0.1"
            || hostname == "::1"
            || hostname == "0.0.0.0"
    }

    nonisolated static func localHostCandidates(
        startingAt host: String,
        maximumAttempts: Int = 20
    ) -> [String] {
        guard maximumAttempts > 0,
              let components = URLComponents(string: host),
              let rawHostname = components.host,
              isLocalServiceHost(host) else { return [] }
        let scheme = components.scheme ?? "http"
        let hostname = rawHostname.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let formattedHostname = hostname.contains(":") ? "[\(hostname)]" : hostname
        let startingPort = components.port ?? 11_434
        return (0..<maximumAttempts).compactMap { offset in
            let port = startingPort + offset
            guard port <= Int(UInt16.max) else { return nil }
            return "\(scheme)://\(formattedHostname):\(port)"
        }
    }

    nonisolated static func firstAvailableLocalHost(
        startingAt host: String,
        maximumAttempts: Int = 20,
        portIsAvailable: (String, UInt16) -> Bool = localPortIsAvailable
    ) -> String? {
        localHostCandidates(startingAt: host, maximumAttempts: maximumAttempts).first { candidate in
            guard let components = URLComponents(string: candidate),
                  let hostname = components.host,
                  let port = components.port.flatMap(UInt16.init(exactly:)) else { return false }
            return portIsAvailable(hostname, port)
        }
    }

    nonisolated private static func localPortIsAvailable(hostname: String, port: UInt16) -> Bool {
        let normalized = hostname.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch normalized {
        case "::1":
            return canBindIPv6Loopback(port: port)
        case "localhost":
            return canBindIPv4(address: in_addr(s_addr: inet_addr("127.0.0.1")), port: port)
                && canBindIPv6Loopback(port: port)
        case "0.0.0.0":
            return canBindIPv4(address: in_addr(s_addr: INADDR_ANY), port: port)
        default:
            return canBindIPv4(address: in_addr(s_addr: inet_addr("127.0.0.1")), port: port)
        }
    }

    nonisolated private static func canBindIPv4(address: in_addr, port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var socketAddress = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: port.bigEndian,
            sin_addr: address,
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        return withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    nonisolated private static func canBindIPv6Loopback(port: UInt16) -> Bool {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var socketAddress = sockaddr_in6(
            sin6_len: UInt8(MemoryLayout<sockaddr_in6>.size),
            sin6_family: sa_family_t(AF_INET6),
            sin6_port: port.bigEndian,
            sin6_flowinfo: 0,
            sin6_addr: in6addr_loopback,
            sin6_scope_id: 0
        )
        return withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
            }
        }
    }
}

private struct TagsResponse: Decodable {
    let models: [OllamaModelInfo]
}

private struct PullUpdate: Decodable {
    let status: String?
    let completed: Int64?
    let total: Int64?
    let error: String?
}

private enum OllamaManagerError: LocalizedError {
    case invalidHost
    case badResponse
    case server(String)
    case invalidDiskImage
    case applicationMissing
    case executableMissing
    case invalidSignature
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "The Ollama address is invalid"
        case .badResponse: return "Ollama returned an error response"
        case let .server(message): return message
        case .invalidDiskImage: return "Could not mount the Ollama installer image"
        case .applicationMissing: return "Ollama.app was not found in the installer image"
        case .executableMissing: return "The Ollama command was not found after installation"
        case .invalidSignature: return "Ollama code-signature verification failed"
        case let .commandFailed(message): return message
        }
    }
}
