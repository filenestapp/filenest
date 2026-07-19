import Foundation

enum DoclingServiceState: Equatable {
    case unavailable
    case ready(String)
    case installing
    case failed(String)
}

@MainActor
final class DoclingServiceManager: ObservableObject {
    nonisolated static let pinnedVersion = "2.102.1"

    @Published private(set) var state: DoclingServiceState = .unavailable
    @Published private(set) var executablePath: String?
    @Published private(set) var isInstalling = false
    @Published private(set) var installProgress: Double?
    @Published private(set) var installStatus = ""
    @Published private(set) var lastError: String?
    @Published private(set) var installedVersion: String?
    @Published private(set) var latestVersion: String?
    @Published private(set) var updateStatus: ManagedServiceUpdateStatus = .idle

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        refresh()
    }

    nonisolated static var installRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("FileNest/Docling", isDirectory: true)
    }

    nonisolated static var installedPackageVersion: String? {
        guard FileManager.default.fileExists(atPath: installRoot.path) else { return nil }
        return readInstalledVersion() ?? pinnedVersion
    }

    func refresh() {
        if let executable = Self.resolveExecutable() {
            executablePath = executable.path
            let isManagedInstall = executable.path.hasPrefix(Self.installRoot.path + "/")
            installedVersion = isManagedInstall ? Self.installedPackageVersion : nil
            state = .ready(isManagedInstall ? "Docling \(installedVersion ?? Self.pinnedVersion)" : "Docling")
            lastError = nil
        } else {
            executablePath = nil
            installedVersion = nil
            state = .unavailable
        }
    }

    func install() async {
        await install(targetVersion: Self.pinnedVersion, isUpdate: false)
    }

    func checkForUpdates() async {
        guard installedVersion != nil else {
            updateStatus = .idle
            latestVersion = nil
            return
        }
        guard !updateStatus.isBusy else { return }

        updateStatus = .checking
        do {
            let latest = try await ManagedServiceReleaseAPI.latestPyPIVersion(
                package: "docling",
                session: session
            )
            latestVersion = latest
            updateStatus = ManagedServiceReleaseAPI.isNewer(
                latest,
                than: installedVersion ?? Self.pinnedVersion
            ) ? .updateAvailable(latest) : .upToDate
        } catch {
            updateStatus = .failed(error.localizedDescription)
        }
    }

    func update() async {
        guard installedVersion != nil, !updateStatus.isBusy else { return }
        if latestVersion == nil { await checkForUpdates() }
        guard let latestVersion else { return }
        await install(targetVersion: latestVersion, isUpdate: true)
    }

    private func install(targetVersion: String, isUpdate: Bool) async {
        guard !isInstalling else { return }
        guard let python = Self.resolvePython() else {
            let message = "Python 3.10 or later is required to install Docling."
            state = .failed(message)
            lastError = message
            if isUpdate { updateStatus = .failed(message) }
            return
        }

        isInstalling = true
        state = .installing
        if isUpdate { updateStatus = .updating }
        installProgress = 0.05
        installStatus = "Creating an isolated Docling environment…"
        lastError = nil
        defer { isInstalling = false }

        do {
            let stagingRoot = Self.stagingRoot()
            defer { try? FileManager.default.removeItem(at: stagingRoot) }
            let venv = try await Task.detached(priority: .userInitiated) {
                try Self.prepareEnvironment(using: python, root: stagingRoot)
            }.value
            installProgress = 0.25
            installStatus = "Downloading and installing Docling dependencies…"
            try await Task.detached(priority: .userInitiated) {
                try Self.installPackage(in: venv, version: targetVersion)
            }.value
            installProgress = 0.92
            installStatus = "Verifying the Docling installation…"
            try await Task.detached(priority: .userInitiated) {
                try Self.verifyInstallation(in: venv)
                try Self.writeInstalledVersion(targetVersion, root: stagingRoot)
                try Self.commitEnvironment(from: stagingRoot)
            }.value
            installProgress = 1
            installStatus = isUpdate ? "Docling update complete" : "Docling installation complete"
            refresh()
            if isUpdate {
                updateStatus = .idle
                await checkForUpdates()
            }
        } catch {
            let message = isUpdate
                ? "Docling update failed: \(error.localizedDescription)"
                : "Docling installation failed: \(error.localizedDescription)"
            if isUpdate {
                refresh()
            } else {
                state = .failed(message)
            }
            lastError = message
            installStatus = "Installation Failed"
            if isUpdate { updateStatus = .failed(message) }
        }
    }

    nonisolated static func resolveExecutable() -> URL? {
        let local = installRoot.appendingPathComponent("venv/bin/docling").path
        var candidates = [local, "/opt/homebrew/bin/docling", "/usr/local/bin/docling"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/docling" })
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    nonisolated private static func resolvePython() -> URL? {
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/python3" })
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if let version = commandOutput(executable: url, arguments: ["--version"]),
               supportsPython(version) { return url }
        }
        return nil
    }

    nonisolated private static func stagingRoot() -> URL {
        installRoot.deletingLastPathComponent()
            .appendingPathComponent("Docling.installing-\(UUID().uuidString)", isDirectory: true)
    }

    nonisolated private static func prepareEnvironment(using python: URL, root: URL) throws -> URL {
        let fileManager = FileManager.default
        let venv = root.appendingPathComponent("venv", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try run(executable: python, arguments: ["-m", "venv", venv.path])
        return venv
    }

    nonisolated private static func installPackage(in venv: URL, version: String) throws {
        let pip = venv.appendingPathComponent("bin/pip")
#if arch(x86_64)
        let package = "docling[mac_intel]==\(version)"
#else
        let package = "docling==\(version)"
#endif
        try run(executable: pip, arguments: ["install", "--disable-pip-version-check", package])
    }

    nonisolated private static func commitEnvironment(from stagingRoot: URL) throws {
        let fileManager = FileManager.default
        let backupRoot = installRoot.deletingLastPathComponent()
            .appendingPathComponent("Docling.backup-\(UUID().uuidString)", isDirectory: true)
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

    nonisolated private static func writeInstalledVersion(_ version: String, root: URL) throws {
        try Data(version.utf8).write(
            to: root.appendingPathComponent("version.txt"),
            options: .atomic
        )
    }

    nonisolated private static func readInstalledVersion() -> String? {
        let url = installRoot.appendingPathComponent("version.txt")
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let version = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }

    nonisolated private static func verifyInstallation(in venv: URL) throws {
        let fileManager = FileManager.default
        let executable = venv.appendingPathComponent("bin/docling")
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw DoclingManagerError.executableMissing
        }
        // Prefetch the qwen3-embedding tokenizer during installation; runtime access uses only the local cache.
        let python = venv.appendingPathComponent("bin/python")
        try run(executable: python, arguments: [
            "-c",
            "from transformers import AutoTokenizer; AutoTokenizer.from_pretrained('Qwen/Qwen3-Embedding-0.6B')",
        ])
    }

    nonisolated private static func run(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DoclingManagerError.commandFailed }
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
            .first(where: { $0.contains(".") })?
            .split(separator: ".") ?? []
        guard components.count >= 2,
              let major = Int(components[0]), let minor = Int(components[1]) else { return false }
        return major > 3 || (major == 3 && minor >= 10)
    }
}

private enum DoclingManagerError: LocalizedError {
    case commandFailed
    case executableMissing

    var errorDescription: String? {
        switch self {
        case .commandFailed: return "The installation command failed"
        case .executableMissing: return "The Docling command was not found after installation"
        }
    }
}

struct WhisperModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let parameters: String
    let approximateSize: String
    let detail: String
}

enum WhisperModelCatalog {
    static let defaultModel = "base"
    static let models: [WhisperModelOption] = [
        .init(id: "tiny", parameters: "39M", approximateSize: "~75 MB", detail: "Fastest; suitable for clear speech"),
        .init(id: "base", parameters: "74M", approximateSize: "~145 MB", detail: "Recommended multilingual default"),
        .init(id: "small", parameters: "244M", approximateSize: "~466 MB", detail: "Higher accuracy on 16 GB or more"),
        .init(id: "medium", parameters: "769M", approximateSize: "~1.5 GB", detail: "High accuracy; slower locally"),
        .init(id: "turbo", parameters: "809M", approximateSize: "~1.6 GB", detail: "Fast large-model transcription"),
    ]

    static func normalizedModel(_ value: String?) -> String {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return models.contains(where: { $0.id == normalized }) ? normalized : defaultModel
    }

    static func option(_ model: String) -> WhisperModelOption {
        models.first(where: { $0.id == normalizedModel(model) })
            ?? models.first(where: { $0.id == defaultModel })!
    }
}

enum ManagedMediaServiceState: Equatable {
    case unavailable
    case ready(String)
    case installing
    case failed(String)
}

@MainActor
final class FFmpegServiceManager: ObservableObject {
    @Published private(set) var state: ManagedMediaServiceState = .unavailable
    @Published private(set) var executablePath: String?
    @Published private(set) var version: String?
    @Published private(set) var isInstalling = false
    @Published private(set) var installProgress: Double?
    @Published private(set) var installStatus = ""
    @Published private(set) var lastError: String?

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        refresh()
    }

    nonisolated static var installRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("FileNest/MediaTools", isDirectory: true)
    }

    nonisolated static var managedExecutable: URL {
        installRoot.appendingPathComponent("ffmpeg")
    }

    func refresh() {
        guard let executable = Self.resolveExecutable() else {
            executablePath = nil
            version = nil
            state = .unavailable
            return
        }
        executablePath = executable.path
        version = Self.version(at: executable)
        state = .ready(version.map { "FFmpeg \($0)" } ?? "FFmpeg")
        lastError = nil
    }

    func install() async {
        guard !isInstalling else { return }
        isInstalling = true
        state = .installing
        installProgress = 0.05
        installStatus = "Preparing the FFmpeg download…"
        lastError = nil
        defer { isInstalling = false }

        do {
            if let brew = Self.resolveHomebrew() {
                installProgress = nil
                installStatus = "Installing FFmpeg with Homebrew…"
                try await Task.detached(priority: .userInitiated) {
                    try Self.run(executable: brew, arguments: ["install", "ffmpeg"])
                }.value
            } else {
                installProgress = nil
                installStatus = "Downloading FFmpeg…"
                let source = URL(string: "https://evermeet.cx/ffmpeg/getrelease/zip")!
                let (downloaded, _) = try await session.download(from: source)
                installProgress = 0.75
                installStatus = "Installing FFmpeg…"
                try await Task.detached(priority: .userInitiated) {
                    try Self.installManagedArchive(downloaded)
                }.value
            }
            installProgress = 1
            installStatus = "FFmpeg installation complete"
            refresh()
        } catch {
            let message = "FFmpeg installation failed: \(error.localizedDescription)"
            lastError = message
            installStatus = "Installation failed"
            state = .failed(message)
        }
    }

    nonisolated static func resolveExecutable() -> URL? {
        var candidates = [managedExecutable.path, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/ffmpeg" })
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    nonisolated private static func resolveHomebrew() -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    nonisolated private static func version(at executable: URL) -> String? {
        guard let output = commandOutput(executable: executable, arguments: ["-version"]) else { return nil }
        let firstLine = output.split(separator: "\n").first.map(String.init) ?? ""
        let prefix = "ffmpeg version "
        guard let range = firstLine.range(of: prefix) else { return nil }
        return firstLine[range.upperBound...].split(separator: " ").first.map(String.init)
    }

    nonisolated private static func installManagedArchive(_ archive: URL) throws {
        let manager = FileManager.default
        let staging = installRoot.deletingLastPathComponent()
            .appendingPathComponent("MediaTools.installing-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archive.path, staging.path])
        let files = (try? manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        guard let binary = files.first(where: { $0.lastPathComponent == "ffmpeg" }) else {
            throw MediaServiceError.executableMissing
        }
        try manager.createDirectory(at: installRoot, withIntermediateDirectories: true)
        if manager.fileExists(atPath: managedExecutable.path) {
            try manager.removeItem(at: managedExecutable)
        }
        try manager.moveItem(at: binary, to: managedExecutable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: managedExecutable.path)
    }

    nonisolated fileprivate static func run(executable: URL, arguments: [String], environment: [String: String]? = nil) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MediaServiceError.commandFailed }
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
}

@MainActor
final class WhisperServiceManager: ObservableObject {
    nonisolated static let pinnedVersion = "20250625"

    @Published private(set) var state: ManagedMediaServiceState = .unavailable
    @Published private(set) var installedVersion: String?
    @Published private(set) var installedModels = Set<String>()
    @Published private(set) var isInstalling = false
    @Published private(set) var installingModel: String?
    @Published private(set) var installProgress: Double?
    @Published private(set) var installStatus = ""
    @Published private(set) var lastError: String?

    init() { refresh() }

    nonisolated static var installRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("FileNest/Whisper", isDirectory: true)
    }

    nonisolated static var pythonExecutable: URL { installRoot.appendingPathComponent("venv/bin/python") }
    nonisolated static var modelRoot: URL { installRoot.appendingPathComponent("models", isDirectory: true) }
    nonisolated static var installedPackageVersion: String? {
        guard FileManager.default.isExecutableFile(atPath: pythonExecutable.path) else { return nil }
        let url = installRoot.appendingPathComponent("version.txt")
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func refresh() {
        installedVersion = Self.installedPackageVersion
        installedModels = Self.detectInstalledModels()
        if let installedVersion {
            state = .ready("Whisper \(installedVersion)")
            lastError = nil
        } else {
            state = .unavailable
        }
    }

    func installRuntime() async {
        guard !isInstalling else { return }
        guard let python = Self.resolvePython() else {
            let message = "Python 3.10 or later is required to install Whisper."
            state = .failed(message)
            lastError = message
            return
        }
        isInstalling = true
        state = .installing
        installProgress = 0.05
        installStatus = "Creating an isolated Whisper environment…"
        lastError = nil
        defer { isInstalling = false }

        do {
            let staging = Self.installRoot.deletingLastPathComponent()
                .appendingPathComponent("Whisper.installing-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            installProgress = 0.2
            installStatus = "Downloading and installing OpenAI Whisper…"
            try await Task.detached(priority: .userInitiated) {
                try Self.prepareRuntime(using: python, at: staging)
            }.value
            installProgress = 0.9
            installStatus = "Verifying the Whisper installation…"
            try await Task.detached(priority: .userInitiated) {
                try Self.commitRuntime(from: staging)
            }.value
            installProgress = 1
            installStatus = "Whisper installation complete"
            refresh()
        } catch {
            let message = "Whisper installation failed: \(error.localizedDescription)"
            state = .failed(message)
            lastError = message
            installStatus = "Installation failed"
        }
    }

    func downloadModel(_ requestedModel: String) async {
        let model = WhisperModelCatalog.normalizedModel(requestedModel)
        if installedVersion == nil { await installRuntime() }
        guard installedVersion != nil, !isInstalling else { return }
        isInstalling = true
        installingModel = model
        installProgress = nil
        installStatus = "Downloading the Whisper \(model) model…"
        lastError = nil
        defer {
            isInstalling = false
            installingModel = nil
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: Self.modelRoot, withIntermediateDirectories: true)
                var environment = ProcessInfo.processInfo.environment
                if let ffmpeg = FFmpegServiceManager.resolveExecutable() {
                    let path = environment["PATH"] ?? ""
                    environment["PATH"] = "\(ffmpeg.deletingLastPathComponent().path):\(path)"
                }
                try FFmpegServiceManager.run(
                    executable: Self.pythonExecutable,
                    arguments: [
                        "-c",
                        "import sys, whisper; whisper.load_model(sys.argv[1], download_root=sys.argv[2])",
                        model,
                        Self.modelRoot.path,
                    ],
                    environment: environment
                )
            }.value
            installProgress = 1
            installStatus = "Whisper model download complete"
            refresh()
        } catch {
            let message = "Whisper model download failed: \(error.localizedDescription)"
            lastError = message
            installStatus = "Download failed"
        }
    }

    func deleteModel(_ requestedModel: String) {
        let model = WhisperModelCatalog.normalizedModel(requestedModel)
        let candidates = ["\(model).pt", model == "turbo" ? "large-v3-turbo.pt" : ""]
        for file in candidates where !file.isEmpty {
            try? FileManager.default.removeItem(at: Self.modelRoot.appendingPathComponent(file))
        }
        refresh()
    }

    func isModelInstalled(_ model: String) -> Bool {
        installedModels.contains(WhisperModelCatalog.normalizedModel(model))
    }

    nonisolated static func isRuntimeAndModelAvailable(_ model: String) -> Bool {
        installedPackageVersion != nil && detectInstalledModels().contains(WhisperModelCatalog.normalizedModel(model))
    }

    nonisolated private static func detectInstalledModels() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: modelRoot.path)) ?? []
        var result = Set(files.filter { $0.hasSuffix(".pt") }.map { String($0.dropLast(3)) })
        if result.contains("large-v3-turbo") { result.insert("turbo") }
        return result
    }

    nonisolated private static func resolvePython() -> URL? {
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/python3" })
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    nonisolated private static func prepareRuntime(using python: URL, at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let venv = root.appendingPathComponent("venv", isDirectory: true)
        try FFmpegServiceManager.run(executable: python, arguments: ["-m", "venv", venv.path])
        let pip = venv.appendingPathComponent("bin/pip")
        try FFmpegServiceManager.run(executable: pip, arguments: [
            "install", "--disable-pip-version-check", "openai-whisper==\(pinnedVersion)",
        ])
        try FFmpegServiceManager.run(executable: venv.appendingPathComponent("bin/python"),
                                     arguments: ["-c", "import whisper"])
        try Data(pinnedVersion.utf8).write(to: root.appendingPathComponent("version.txt"), options: .atomic)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"),
                                                withIntermediateDirectories: true)
    }

    nonisolated private static func commitRuntime(from staging: URL) throws {
        let manager = FileManager.default
        let backup = installRoot.deletingLastPathComponent()
            .appendingPathComponent("Whisper.backup-\(UUID().uuidString)", isDirectory: true)
        let hadExisting = manager.fileExists(atPath: installRoot.path)
        if hadExisting { try manager.moveItem(at: installRoot, to: backup) }
        do {
            try manager.moveItem(at: staging, to: installRoot)
            if hadExisting { try? manager.removeItem(at: backup) }
        } catch {
            if hadExisting, !manager.fileExists(atPath: installRoot.path) {
                try? manager.moveItem(at: backup, to: installRoot)
            }
            throw error
        }
    }
}

private enum MediaServiceError: LocalizedError {
    case commandFailed
    case executableMissing

    var errorDescription: String? {
        switch self {
        case .commandFailed: return "The installation command failed"
        case .executableMissing: return "The expected executable was not found after installation"
        }
    }
}
