import Darwin
import Foundation

struct ManagedRuntimeArtifact: Equatable, Sendable {
    let version: String
    let downloadURL: URL
    let sha256: String
}

enum ManagedRuntimePaths {
    nonisolated static var applicationSupportRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("FileNest", isDirectory: true)
    }

    nonisolated static var cacheRoot: URL {
        applicationSupportRoot.appendingPathComponent("Caches", isDirectory: true)
    }

    nonisolated static var huggingFaceRoot: URL {
        cacheRoot.appendingPathComponent("HuggingFace", isDirectory: true)
    }

    nonisolated static var paddleRoot: URL {
        cacheRoot.appendingPathComponent("Paddle", isDirectory: true)
    }

    nonisolated static var paddleXRoot: URL {
        cacheRoot.appendingPathComponent("PaddleX", isDirectory: true)
    }

    nonisolated static var ollamaModelsRoot: URL {
        applicationSupportRoot.appendingPathComponent("Ollama/models", isDirectory: true)
    }

    nonisolated static func managedEnvironment(
        merging additions: [String: String] = [:]
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            ManagedPythonRuntime.executable.deletingLastPathComponent().path,
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
        environment.removeValue(forKey: "PYTHONHOME")
        environment.removeValue(forKey: "PYTHONPATH")
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        environment["HF_HOME"] = huggingFaceRoot.path
        environment["HUGGINGFACE_HUB_CACHE"] = huggingFaceRoot.appendingPathComponent("hub").path
        environment["TRANSFORMERS_CACHE"] = huggingFaceRoot.appendingPathComponent("transformers").path
        environment["XDG_CACHE_HOME"] = cacheRoot.path
        environment["PADDLE_HOME"] = paddleRoot.path
        environment["PADDLEX_HOME"] = paddleXRoot.path
        additions.forEach { environment[$0.key] = $0.value }
        return environment
    }

    nonisolated static func prepareCacheDirectories() throws {
        for directory in [cacheRoot, huggingFaceRoot, paddleRoot, paddleXRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

enum ManagedPythonRuntime {
    nonisolated static let version = "3.13.14+20260728"

    nonisolated static var installRoot: URL {
        ManagedRuntimePaths.applicationSupportRoot
            .appendingPathComponent("Runtime/Python", isDirectory: true)
    }

    nonisolated static var executable: URL {
        installRoot.appendingPathComponent("python/bin/python3")
    }

    nonisolated static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
            && (try? String(
                contentsOf: installRoot.appendingPathComponent("version.txt"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)) == version
    }

    nonisolated static func artifact(machine: String = ProcessInfo.processInfo.machineHardwareName)
        -> ManagedRuntimeArtifact? {
        switch machine {
        case "arm64":
            return ManagedRuntimeArtifact(
                version: version,
                downloadURL: URL(string:
                    "https://github.com/astral-sh/python-build-standalone/releases/download/20260728/" +
                    "cpython-3.13.14%2B20260728-aarch64-apple-darwin-install_only_stripped.tar.gz"
                )!,
                sha256: "aa2a054f5e04bde63ae199e3bb6bbb634e457423efd294842deeb1299e7e5932"
            )
        case "x86_64":
            return ManagedRuntimeArtifact(
                version: version,
                downloadURL: URL(string:
                    "https://github.com/astral-sh/python-build-standalone/releases/download/20260728/" +
                    "cpython-3.13.14%2B20260728-x86_64-apple-darwin-install_only_stripped.tar.gz"
                )!,
                sha256: "aa73c37aebebe3b7264dce1e49923719ab0ac0fc590353adf393eee3e2041c18"
            )
        default:
            return nil
        }
    }

    nonisolated static func virtualEnvironmentUsesManagedPython(at venv: URL) -> Bool {
        let interpreter = venv.appendingPathComponent("bin/python")
        guard FileManager.default.isExecutableFile(atPath: interpreter.path) else { return false }
        let resolved = interpreter.resolvingSymlinksInPath().standardizedFileURL.path
        let managedRoot = installRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return resolved.hasPrefix(managedRoot)
    }

    nonisolated static func relocateVirtualEnvironment(
        at venv: URL,
        from oldRoot: URL,
        to newRoot: URL
    ) throws {
        let bin = venv.appendingPathComponent("bin", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: bin,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: file),
                  data.count <= 2_000_000,
                  var text = String(data: data, encoding: .utf8),
                  text.contains(oldRoot.path) else { continue }
            text = text.replacingOccurrences(of: oldRoot.path, with: newRoot.path)
            try Data(text.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: file.path
            )
        }
    }

    nonisolated fileprivate static func install(downloadedArchive: URL) throws -> URL {
        guard let artifact = artifact() else { throw ManagedRuntimeError.unsupportedArchitecture }
        let actualHash = try FileContentHasher.sha256(of: downloadedArchive)
        guard actualHash.caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
            throw ManagedRuntimeError.checksumMismatch
        }

        let manager = FileManager.default
        let parent = installRoot.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            "Python.installing-\(UUID().uuidString)",
            isDirectory: true
        )
        let backup = parent.appendingPathComponent(
            "Python.backup-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? manager.removeItem(at: staging)
            try? manager.removeItem(at: backup)
        }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        try ManagedProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", downloadedArchive.path, "-C", staging.path]
        )
        let stagedExecutable = staging.appendingPathComponent("python/bin/python3")
        guard manager.isExecutableFile(atPath: stagedExecutable.path) else {
            throw ManagedRuntimeError.executableMissing
        }
        try Data(version.utf8).write(
            to: staging.appendingPathComponent("version.txt"),
            options: .atomic
        )
        try? ManagedProcess.run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-dr", "com.apple.quarantine", staging.path]
        )

        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
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
        try ManagedRuntimePaths.prepareCacheDirectories()
        return executable
    }
}

@MainActor
final class ManagedPythonRuntimeInstaller {
    static let shared = ManagedPythonRuntimeInstaller()
    private var activeTask: Task<URL, Error>?

    func ensureInstalled() async throws -> URL {
        if ManagedPythonRuntime.isInstalled { return ManagedPythonRuntime.executable }
        if let activeTask { return try await activeTask.value }
        guard let artifact = ManagedPythonRuntime.artifact() else {
            throw ManagedRuntimeError.unsupportedArchitecture
        }
        let task = Task<URL, Error> {
            let archive = try await DownloadCoordinator.shared.download(
                ManagedDownloadRequest(
                    identifier: "managed-python-\(artifact.version)-\(ProcessInfo.processInfo.machineHardwareName)",
                    displayName: "FileNest Python Runtime",
                    sourceURL: artifact.downloadURL,
                    expectedSHA256: artifact.sha256
                )
            )
            defer { try? FileManager.default.removeItem(at: archive) }
            return try ManagedPythonRuntime.install(downloadedArchive: archive)
        }
        activeTask = task
        defer { activeTask = nil }
        return try await task.value
    }
}

enum ManagedProcess {
    nonisolated static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ManagedRuntimePaths.managedEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ManagedRuntimeError.commandFailed }
    }
}

private enum ManagedRuntimeError: LocalizedError {
    case unsupportedArchitecture
    case downloadFailed
    case checksumMismatch
    case executableMissing
    case commandFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "This Mac architecture is not supported by the FileNest runtime."
        case .downloadFailed:
            return "The managed runtime download failed."
        case .checksumMismatch:
            return "The managed runtime checksum did not match the trusted release."
        case .executableMissing:
            return "The managed runtime executable was not found after installation."
        case .commandFailed:
            return "A managed runtime command failed."
        }
    }
}

private extension ProcessInfo {
    nonisolated var machineHardwareName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }
}

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

        isInstalling = true
        state = .installing
        if isUpdate { updateStatus = .updating }
        installProgress = 0.05
        installStatus = "Installing the FileNest Python runtime…"
        lastError = nil
        defer { isInstalling = false }

        do {
            let python = try await ManagedPythonRuntimeInstaller.shared.ensureInstalled()
            installProgress = 0.15
            installStatus = "Creating an isolated Docling environment…"
            let stagingRoot = Self.stagingRoot()
            defer { try? FileManager.default.removeItem(at: stagingRoot) }
            let venv = try await Task.detached(priority: .userInitiated) {
                try Self.prepareEnvironment(using: python, root: stagingRoot)
            }.value
            installProgress = 0.25
            installStatus = "Downloading and installing Docling dependencies…"
            try await DownloadCoordinator.shared.performExternalDownload(
                identifier: "python-package-docling-\(targetVersion)",
                displayName: "Docling \(targetVersion)",
                sourceURL: ManagedServiceReleaseAPI.pypiURL(package: "docling")
            ) {
                try await Task.detached(priority: .userInitiated) {
                    try Self.installPackage(in: venv, version: targetVersion)
                }.value
            }
            installProgress = 0.92
            installStatus = "Verifying the Docling installation…"
            try await Task.detached(priority: .userInitiated) {
                try Self.verifyInstallation(in: venv)
                try Self.writeInstalledVersion(targetVersion, root: stagingRoot)
                try ManagedPythonRuntime.relocateVirtualEnvironment(
                    at: venv,
                    from: stagingRoot,
                    to: Self.installRoot
                )
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
        let venv = installRoot.appendingPathComponent("venv", isDirectory: true)
        let local = venv.appendingPathComponent("bin/docling")
        guard ManagedPythonRuntime.virtualEnvironmentUsesManagedPython(at: venv),
              FileManager.default.isExecutableFile(atPath: local.path) else { return nil }
        return local
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
        process.environment = ManagedRuntimePaths.managedEnvironment()
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
    nonisolated static let pinnedVersion = "6.1.1"

    @Published private(set) var state: ManagedMediaServiceState = .unavailable
    @Published private(set) var executablePath: String?
    @Published private(set) var version: String?
    @Published private(set) var latestVersion: String?
    @Published private(set) var updateStatus: ManagedServiceUpdateStatus = .idle
    @Published private(set) var isInstalling = false
    @Published private(set) var installProgress: Double?
    @Published private(set) var installStatus = ""
    @Published private(set) var lastError: String?

    private let session: URLSession
    private var latestArtifact: ManagedRuntimeArtifact?

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
        guard let artifact = Self.artifact() else {
            let message = MediaServiceError.unsupportedArchitecture.localizedDescription
            state = .failed(message)
            lastError = message
            return
        }
        await install(artifact: artifact, isUpdate: false)
    }

    func checkForUpdates() async {
        guard executablePath != nil else {
            latestVersion = nil
            latestArtifact = nil
            updateStatus = .idle
            return
        }
        guard !updateStatus.isBusy else { return }

        updateStatus = .checking
        do {
            let release = try await ManagedServiceReleaseAPI.latestFFmpegRelease(
                machine: ProcessInfo.processInfo.machineHardwareName,
                session: session
            )
            latestVersion = release.version
            latestArtifact = ManagedRuntimeArtifact(
                version: release.version,
                downloadURL: release.downloadURL,
                sha256: release.sha256
            )
            guard let version else {
                updateStatus = .failed("Could not read the installed FFmpeg version")
                return
            }
            updateStatus = ManagedServiceReleaseAPI.isNewer(release.version, than: version)
                ? .updateAvailable(release.version)
                : .upToDate
        } catch {
            latestVersion = nil
            latestArtifact = nil
            updateStatus = .failed(error.localizedDescription)
        }
    }

    func update() async {
        guard case let .updateAvailable(targetVersion) = updateStatus,
              let latestArtifact else { return }
        updateStatus = .updating
        await install(artifact: latestArtifact, isUpdate: true)
        if case .failed = updateStatus { return }
        guard lastError == nil,
              let installedVersion = version,
              !ManagedServiceReleaseAPI.isNewer(targetVersion, than: installedVersion) else {
            updateStatus = .failed(lastError ?? "FFmpeg update verification failed")
            return
        }
        updateStatus = .upToDate
    }

    private func install(artifact: ManagedRuntimeArtifact, isUpdate: Bool) async {
        guard !isInstalling else { return }
        isInstalling = true
        state = .installing
        installProgress = 0.05
        installStatus = isUpdate
            ? "Preparing the FFmpeg update…"
            : "Preparing the FFmpeg download…"
        lastError = nil
        defer { isInstalling = false }

        do {
            installProgress = nil
            installStatus = isUpdate
                ? "Downloading the FFmpeg update…"
                : "Downloading the FileNest-managed FFmpeg runtime…"
            let downloaded = try await DownloadCoordinator.shared.download(
                ManagedDownloadRequest(
                    identifier: "ffmpeg-\(artifact.version)-\(ProcessInfo.processInfo.machineHardwareName)",
                    displayName: "FFmpeg \(artifact.version)",
                    sourceURL: artifact.downloadURL,
                    expectedSHA256: artifact.sha256
                )
            ) { [weak self] snapshot in
                guard let fraction = snapshot.fractionCompleted else { return }
                self?.installProgress = 0.05 + (fraction * 0.70)
            }
            defer { try? FileManager.default.removeItem(at: downloaded) }
            installProgress = 0.75
            installStatus = "Verifying and installing FFmpeg…"
            try await Task.detached(priority: .userInitiated) {
                try Self.installManagedBinary(downloaded, artifact: artifact)
            }.value
            installProgress = 1
            installStatus = isUpdate ? "FFmpeg update complete" : "FFmpeg installation complete"
            refresh()
        } catch {
            let message = isUpdate
                ? "FFmpeg update failed: \(error.localizedDescription)"
                : "FFmpeg installation failed: \(error.localizedDescription)"
            lastError = message
            installStatus = isUpdate ? "Update failed" : "Installation failed"
            if isUpdate {
                refresh()
                updateStatus = .failed(message)
            } else {
                state = .failed(message)
            }
        }
    }

    nonisolated static func resolveExecutable() -> URL? {
        FileManager.default.isExecutableFile(atPath: managedExecutable.path)
            ? managedExecutable
            : nil
    }

    nonisolated private static func version(at executable: URL) -> String? {
        guard let output = commandOutput(executable: executable, arguments: ["-version"]) else { return nil }
        let firstLine = output.split(separator: "\n").first.map(String.init) ?? ""
        let prefix = "ffmpeg version "
        guard let range = firstLine.range(of: prefix) else { return nil }
        return firstLine[range.upperBound...].split(separator: " ").first.map(String.init)
    }

    nonisolated static func artifact(
        machine: String = ProcessInfo.processInfo.machineHardwareName
    ) -> ManagedRuntimeArtifact? {
        switch machine {
        case "arm64":
            return ManagedRuntimeArtifact(
                version: pinnedVersion,
                downloadURL: URL(string:
                    "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/" +
                    "ffmpeg-darwin-arm64"
                )!,
                sha256: "a90e3db6a3fd35f6074b013f948b1aa45b31c6375489d39e572bea3f18336584"
            )
        case "x86_64":
            return ManagedRuntimeArtifact(
                version: pinnedVersion,
                downloadURL: URL(string:
                    "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/" +
                    "ffmpeg-darwin-x64"
                )!,
                sha256: "ebdddc936f61e14049a2d4b549a412b8a40deeff6540e58a9f2a2da9e6b18894"
            )
        default:
            return nil
        }
    }

    nonisolated private static func installManagedBinary(
        _ downloadedBinary: URL,
        artifact: ManagedRuntimeArtifact
    ) throws {
        let actualHash = try FileContentHasher.sha256(of: downloadedBinary)
        guard actualHash.caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
            throw MediaServiceError.checksumMismatch
        }
        let manager = FileManager.default
        let staging = installRoot.deletingLastPathComponent()
            .appendingPathComponent("MediaTools.installing-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let binary = staging.appendingPathComponent("ffmpeg")
        try manager.copyItem(at: downloadedBinary, to: binary)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try? run(
            executable: URL(fileURLWithPath: "/usr/bin/xattr"),
            arguments: ["-d", "com.apple.quarantine", binary.path]
        )
        guard manager.isExecutableFile(atPath: binary.path) else {
            throw MediaServiceError.executableMissing
        }
        try manager.createDirectory(at: installRoot, withIntermediateDirectories: true)
        if manager.fileExists(atPath: managedExecutable.path) {
            try manager.removeItem(at: managedExecutable)
        }
        try manager.moveItem(at: binary, to: managedExecutable)
        try Data(artifact.version.utf8).write(
            to: installRoot.appendingPathComponent("version.txt"),
            options: .atomic
        )
    }

    nonisolated fileprivate static func run(executable: URL, arguments: [String], environment: [String: String]? = nil) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ManagedRuntimePaths.managedEnvironment()
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
        let venv = installRoot.appendingPathComponent("venv", isDirectory: true)
        guard ManagedPythonRuntime.virtualEnvironmentUsesManagedPython(at: venv) else { return nil }
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
        isInstalling = true
        state = .installing
        installProgress = 0.05
        installStatus = "Installing the FileNest Python runtime…"
        lastError = nil
        defer { isInstalling = false }

        do {
            let python = try await ManagedPythonRuntimeInstaller.shared.ensureInstalled()
            let staging = Self.installRoot.deletingLastPathComponent()
                .appendingPathComponent("Whisper.installing-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            installProgress = 0.15
            installStatus = "Downloading and installing OpenAI Whisper…"
            try await DownloadCoordinator.shared.performExternalDownload(
                identifier: "python-package-openai-whisper-\(Self.pinnedVersion)",
                displayName: "OpenAI Whisper",
                sourceURL: ManagedServiceReleaseAPI.pypiURL(package: "openai-whisper")
            ) {
                try await Task.detached(priority: .userInitiated) {
                    try Self.prepareRuntime(using: python, at: staging)
                }.value
            }
            installProgress = 0.9
            installStatus = "Verifying the Whisper installation…"
            try await Task.detached(priority: .userInitiated) {
                try Self.preserveInstalledModels(in: staging)
                try ManagedPythonRuntime.relocateVirtualEnvironment(
                    at: staging.appendingPathComponent("venv", isDirectory: true),
                    from: staging,
                    to: Self.installRoot
                )
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
            try await DownloadCoordinator.shared.performExternalDownload(
                identifier: "whisper-model-\(model)",
                displayName: "Whisper \(model)",
                sourceURL: URL(string: "https://openaipublic.azureedge.net/main/whisper/models/")!
            ) {
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: Self.modelRoot, withIntermediateDirectories: true)
                    var environment = ManagedRuntimePaths.managedEnvironment()
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
            }
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

    nonisolated private static func preserveInstalledModels(in staging: URL) throws {
        guard FileManager.default.fileExists(atPath: modelRoot.path) else { return }
        let destination = staging.appendingPathComponent("models", isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: modelRoot, to: destination)
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
    case unsupportedArchitecture
    case downloadFailed
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .commandFailed: return "The installation command failed"
        case .executableMissing: return "The expected executable was not found after installation"
        case .unsupportedArchitecture: return "This Mac architecture is not supported"
        case .downloadFailed: return "The runtime download failed"
        case .checksumMismatch: return "The downloaded runtime failed checksum verification"
        }
    }
}
