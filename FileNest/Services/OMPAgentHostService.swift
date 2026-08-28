import Combine
import Darwin
import Foundation

/// A GitHub Release asset for the official OMP runtime.
struct OMPAgentHostArtifact: Decodable, Equatable, Sendable {
    let url: URL
    let sha256: String

    init(url: URL, sha256: String) {
        self.url = url
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case url
        case sha256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try container.decode(URL.self, forKey: .url)
        let sha256 = try container.decode(String.self, forKey: .sha256)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard OMPAgentHostServiceManager.isTrustedReleaseURL(url),
              sha256.count == 64,
              sha256.allSatisfy(\.isHexDigit) else {
            throw OMPAgentHostUpdateError.invalidManifest
        }
        self.url = url
        self.sha256 = sha256
    }
}

struct OMPAgentHostReleaseManifest: Decodable, Equatable, Sendable {
    let version: String
    let artifacts: [String: OMPAgentHostArtifact]

    init(version: String, artifacts: [String: OMPAgentHostArtifact]) {
        self.version = ManagedServiceReleaseAPI.normalized(version)
        self.artifacts = artifacts
    }

    enum CodingKeys: String, CodingKey {
        case version
        case artifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(String.self, forKey: .version)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let artifacts = try container.decode([String: OMPAgentHostArtifact].self, forKey: .artifacts)
        guard !version.isEmpty, !artifacts.isEmpty else {
            throw OMPAgentHostUpdateError.invalidManifest
        }
        self.version = ManagedServiceReleaseAPI.normalized(version)
        self.artifacts = artifacts
    }

    func artifact(for machine: String) -> OMPAgentHostArtifact? {
        artifacts[machine]
    }
}

private struct OMPRuntimeInstallation: Codable, Equatable, Sendable {
    let version: String
    let sha256: String
    let sourceURL: URL
    let installedAt: Date
    let previousVersion: String?
}

enum OMPAgentHostUpdateError: LocalizedError, Equatable {
    case invalidManifest
    case unsupportedArchitecture
    case runtimeNotInstalled
    case checksumMismatch
    case executableMissing
    case downloadFailed
    case artifactDownloadFailed(statusCode: Int)
    case networkFailure
    case releaseNotPublished
    case noRollbackAvailable
    case runtimeValidationFailed

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            return "The official OMP release metadata is invalid."
        case .unsupportedArchitecture:
            return "This Mac architecture is not supported by the official OMP release."
        case .runtimeNotInstalled:
            return "The official OMP runtime is not installed for FileNest."
        case .checksumMismatch:
            return "The downloaded OMP runtime did not pass its checksum verification."
        case .executableMissing:
            return "The downloaded OMP runtime executable is missing."
        case .downloadFailed:
            return "The OMP runtime download failed."
        case let .artifactDownloadFailed(statusCode):
            return "The OMP runtime download failed: HTTP status \(statusCode)"
        case .networkFailure:
            return "Could not reach the official OMP release service."
        case .releaseNotPublished:
            return "No compatible official OMP runtime was published for this Mac."
        case .noRollbackAvailable:
            return "No earlier OMP runtime is available to restore."
        case .runtimeValidationFailed:
            return "The downloaded OMP runtime could not be started safely."
        }
    }
}

@MainActor
final class OMPAgentHostServiceManager: ObservableObject {
    nonisolated static let githubReleaseURL = URL(
        string: "https://api.github.com/repos/can1357/oh-my-pi/releases/latest"
    )!

    @Published private(set) var executablePath: String?
    @Published private(set) var installedVersion: String?
    @Published private(set) var latestVersion: String?
    @Published private(set) var updateStatus: ManagedServiceUpdateStatus = .idle
    @Published private(set) var isInstalling = false
    @Published private(set) var installStatus = ""
    @Published private(set) var lastError: String?

    private let session: URLSession
    private let machine: String
    private let releaseURL: URL
    private var latestArtifact: OMPAgentHostArtifact?

    init(
        session: URLSession = .shared,
        machine: String = OMPAgentHostServiceManager.currentMachineHardwareName,
        releaseURL: URL = OMPAgentHostServiceManager.githubReleaseURL
    ) {
        self.session = session
        self.machine = machine
        self.releaseURL = releaseURL
        refresh()
    }

    var isManagedInstall: Bool {
        Self.currentRuntimeExecutableURL != nil && executablePath != nil
    }

    var isBundledInstall: Bool { false }

    var isAvailable: Bool {
        executablePath.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
    }

    var canInstall: Bool {
        latestArtifact != nil && !isInstalling && !updateStatus.isBusy
    }

    var canRollback: Bool {
        guard let installation = Self.currentInstallation,
              let previousVersion = installation.previousVersion else {
            return false
        }
        return FileManager.default.isExecutableFile(
            atPath: Self.runtimeExecutableURL(for: previousVersion).path
        )
    }

    nonisolated static var managedRootURL: URL {
        ManagedRuntimePaths.applicationSupportRoot
            .appendingPathComponent("OMP", isDirectory: true)
    }

    nonisolated static var versionsRootURL: URL {
        managedRootURL.appendingPathComponent("versions", isDirectory: true)
    }

    nonisolated static var currentInstallationURL: URL {
        managedRootURL.appendingPathComponent("current.json")
    }

    nonisolated static var currentRuntimeExecutableURL: URL? {
        guard let installation = currentInstallation else { return nil }
        let executable = runtimeExecutableURL(for: installation.version)
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    nonisolated private static var currentInstallation: OMPRuntimeInstallation? {
        guard let data = try? Data(contentsOf: currentInstallationURL),
              let installation = try? JSONDecoder().decode(OMPRuntimeInstallation.self, from: data),
              isSafeVersion(installation.version) else {
            return nil
        }
        return installation
    }

    nonisolated static var currentMachineHardwareName: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 1 else { return "" }
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    nonisolated static func isTrustedReleaseURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        return url.host?.lowercased() == "github.com"
    }

    nonisolated static func runtimeExecutableURL(for version: String) -> URL {
        versionsRootURL
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("omp")
    }

    nonisolated private static func installationMetadataURL(for version: String) -> URL {
        versionsRootURL
            .appendingPathComponent(version, isDirectory: true)
            .appendingPathComponent("installation.json")
    }

    nonisolated private static func installationMetadata(
        for version: String
    ) -> OMPRuntimeInstallation? {
        guard isSafeVersion(version),
              let data = try? Data(contentsOf: installationMetadataURL(for: version)),
              let installation = try? JSONDecoder().decode(OMPRuntimeInstallation.self, from: data),
              installation.version == version else {
            return nil
        }
        return installation
    }

    func refresh() {
        let resolved = Self.currentRuntimeExecutableURL
        executablePath = resolved?.path
        installedVersion = Self.currentInstallation?.version
        if resolved == nil {
            latestVersion = nil
            latestArtifact = nil
            updateStatus = .idle
        }
    }

    func checkForUpdates() async {
        guard !updateStatus.isBusy else { return }
        updateStatus = .checking
        lastError = nil
        do {
            let manifest = try await Self.fetchGitHubReleaseManifest(
                session: session,
                url: releaseURL
            )
            latestVersion = manifest.version
            latestArtifact = try artifact(from: manifest)
            guard let installedVersion else {
                updateStatus = .updateAvailable(manifest.version)
                return
            }
            updateStatus = ManagedServiceReleaseAPI.isNewer(
                manifest.version,
                than: installedVersion
            ) ? .updateAvailable(manifest.version) : .upToDate
        } catch {
            latestArtifact = nil
            lastError = error.localizedDescription
            updateStatus = .failed(error.localizedDescription)
            AppLogService.shared.write(
                "Official OMP runtime update check failed",
                category: .appLifecycle,
                level: .error,
                metadata: ["releaseURL": releaseURL.absoluteString, "error": error.localizedDescription]
            )
        }
    }

    func update() async {
        if latestArtifact == nil { await checkForUpdates() }
        guard let latestVersion,
              let latestArtifact,
              case .updateAvailable = updateStatus else {
            return
        }
        await install(artifact: latestArtifact, version: latestVersion)
    }

    func installLatest() async {
        if latestArtifact == nil { await checkForUpdates() }
        guard let latestVersion, let latestArtifact else { return }
        await install(artifact: latestArtifact, version: latestVersion)
    }

    func rollback() {
        guard !isInstalling else { return }
        do {
            guard let current = Self.currentInstallation,
                  let previousVersion = current.previousVersion,
                  let previousInstallation = Self.installationMetadata(for: previousVersion),
                  FileManager.default.isExecutableFile(
                    atPath: Self.runtimeExecutableURL(for: previousVersion).path
                  ) else {
                throw OMPAgentHostUpdateError.noRollbackAvailable
            }
            let restored = OMPRuntimeInstallation(
                version: previousVersion,
                sha256: previousInstallation.sha256,
                sourceURL: previousInstallation.sourceURL,
                installedAt: previousInstallation.installedAt,
                previousVersion: current.version
            )
            try Self.writeCurrentInstallation(restored)
            refresh()
            updateStatus = .idle
            lastError = nil
            installStatus = "Restored OMP runtime \(previousVersion)"
        } catch {
            lastError = error.localizedDescription
            updateStatus = .failed(error.localizedDescription)
        }
    }

    private func artifact(from manifest: OMPAgentHostReleaseManifest) throws -> OMPAgentHostArtifact {
        guard let artifact = manifest.artifact(for: machine) else {
            throw OMPAgentHostUpdateError.unsupportedArchitecture
        }
        return artifact
    }

    private func install(artifact: OMPAgentHostArtifact, version: String) async {
        guard !isInstalling else { return }
        isInstalling = true
        updateStatus = .updating
        installStatus = "Downloading official OMP runtime…"
        lastError = nil
        defer { isInstalling = false }

        do {
            let cacheDirectory = ManagedRuntimePaths.cacheRoot
                .appendingPathComponent("OMP", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let downloaded = cacheDirectory.appendingPathComponent("omp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: downloaded) }

            try await Self.download(session: session, from: artifact.url, to: downloaded)
            guard try FileContentHasher.sha256(of: downloaded)
                .caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
                throw OMPAgentHostUpdateError.checksumMismatch
            }
            try Self.installRuntime(
                from: downloaded,
                version: version,
                artifact: artifact,
                previousVersion: Self.currentInstallation?.version
            )
            refresh()
            guard installedVersion == version else {
                throw OMPAgentHostUpdateError.executableMissing
            }
            installStatus = "Official OMP runtime \(version) is ready"
            updateStatus = .upToDate
        } catch {
            lastError = error.localizedDescription
            installStatus = "OMP runtime installation failed"
            updateStatus = .failed(error.localizedDescription)
        }
    }

    nonisolated private static func installRuntime(
        from downloaded: URL,
        version: String,
        artifact: OMPAgentHostArtifact,
        previousVersion: String?
    ) throws {
        guard isSafeVersion(version) else { throw OMPAgentHostUpdateError.invalidManifest }
        let manager = FileManager.default
        let staging = versionsRootURL.appendingPathComponent(".\(version)-\(UUID().uuidString)", isDirectory: true)
        let target = versionsRootURL.appendingPathComponent(version, isDirectory: true)
        try manager.createDirectory(at: versionsRootURL, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let executable = staging.appendingPathComponent("omp")
        try manager.copyItem(at: downloaded, to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        guard manager.isExecutableFile(atPath: executable.path),
              try executableCanReportVersion(executable) else {
            throw OMPAgentHostUpdateError.runtimeValidationFailed
        }

        let installation = OMPRuntimeInstallation(
            version: version,
            sha256: artifact.sha256,
            sourceURL: artifact.url,
            installedAt: Date(),
            previousVersion: previousVersion
        )
        let metadata = try JSONEncoder().encode(installation)
        try metadata.write(to: staging.appendingPathComponent("installation.json"), options: .atomic)
        if manager.fileExists(atPath: target.path) {
            try manager.removeItem(at: target)
        }
        try manager.moveItem(at: staging, to: target)
        try writeCurrentInstallation(installation)
    }

    nonisolated private static func executableCanReportVersion(_ executable: URL) throws -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }
        let outputText = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )
        let value = outputText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !value.isEmpty
    }

    nonisolated private static func writeCurrentInstallation(
        _ installation: OMPRuntimeInstallation
    ) throws {
        try FileManager.default.createDirectory(at: managedRootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(installation)
        try data.write(to: currentInstallationURL, options: .atomic)
    }

    nonisolated private static func isSafeVersion(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "." || character == "-"
        }
    }

    nonisolated static func fetchGitHubReleaseManifest(
        session: URLSession,
        url: URL = githubReleaseURL
    ) async throws -> OMPAgentHostReleaseManifest {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "api.github.com" else {
            throw OMPAgentHostUpdateError.invalidManifest
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FileNest-OMP-Runtime", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OMPAgentHostUpdateError.networkFailure
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw OMPAgentHostUpdateError.releaseNotPublished
        }

        struct Release: Decodable {
            let tagName: String
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case draft
                case prerelease
                case assets
            }
        }
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case digest
            }
        }

        let release: Release
        do {
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            throw OMPAgentHostUpdateError.releaseNotPublished
        }
        guard !release.draft, !release.prerelease else {
            throw OMPAgentHostUpdateError.releaseNotPublished
        }

        let assets = [
            ("arm64", "omp-darwin-arm64"),
            ("x86_64", "omp-darwin-x64"),
        ]
        let artifacts: [String: OMPAgentHostArtifact] = Dictionary(
            uniqueKeysWithValues: assets.compactMap { machine, assetName -> (String, OMPAgentHostArtifact)? in
            guard let asset = release.assets.first(where: { $0.name == assetName }),
                  isTrustedReleaseURL(asset.browserDownloadURL),
                  let digest = asset.digest?.split(separator: ":", maxSplits: 1).last,
                  digest.count == 64,
                  digest.allSatisfy(\.isHexDigit) else {
                return nil
            }
            return (
                machine,
                OMPAgentHostArtifact(
                    url: asset.browserDownloadURL,
                    sha256: String(digest).lowercased()
                )
            )
            }
        )
        let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard !artifacts.isEmpty, isSafeVersion(version) else {
            throw OMPAgentHostUpdateError.releaseNotPublished
        }
        return OMPAgentHostReleaseManifest(version: version, artifacts: artifacts)
    }

    nonisolated private static func download(
        session: URLSession,
        from url: URL,
        to destination: URL
    ) async throws {
        guard isTrustedReleaseURL(url) else { throw OMPAgentHostUpdateError.downloadFailed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 180
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw OMPAgentHostUpdateError.networkFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw OMPAgentHostUpdateError.downloadFailed
        }
        guard (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw OMPAgentHostUpdateError.artifactDownloadFailed(statusCode: http.statusCode)
        }
        try data.write(to: destination, options: .atomic)
    }
}
