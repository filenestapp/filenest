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
                : "Docling Installation Failed：\(error.localizedDescription)"
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
