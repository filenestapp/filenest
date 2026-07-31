import Combine
import Foundation
import Sparkle

enum ManagedServiceUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(String)
    case updating
    case failed(String)

    var isBusy: Bool {
        self == .checking || self == .updating
    }
}

enum ManagedServiceReleaseAPI {
    struct GitHubReleaseMetadata: Equatable {
        let version: String
        let macOSDMGURL: URL
    }

    struct GitHubAssetReleaseMetadata: Equatable {
        let version: String
        let downloadURL: URL
        let sha256: String
    }

    static let ollamaLatestReleaseURL = URL(
        string: "https://api.github.com/repos/ollama/ollama/releases/latest"
    )!
    static let ffmpegLatestReleaseURL = URL(
        string: "https://api.github.com/repos/eugeneware/ffmpeg-static/releases/latest"
    )!

    static func pypiURL(package: String) -> URL {
        URL(string: "https://pypi.org/pypi/\(package)/json")!
    }

    static func latestGitHubVersion(
        session: URLSession = .shared,
        url: URL = ollamaLatestReleaseURL
    ) async throws -> String {
        let data = try await responseData(session: session, url: url)
        return try githubVersion(from: data)
    }

    static func latestGitHubRelease(
        session: URLSession = .shared,
        url: URL = ollamaLatestReleaseURL
    ) async throws -> GitHubReleaseMetadata {
        let data = try await responseData(session: session, url: url)
        return try githubRelease(from: data)
    }

    static func latestPyPIVersion(
        package: String,
        session: URLSession = .shared
    ) async throws -> String {
        let data = try await responseData(session: session, url: pypiURL(package: package))
        return try pypiVersion(from: data)
    }

    static func latestFFmpegRelease(
        machine: String,
        session: URLSession = .shared,
        url: URL = ffmpegLatestReleaseURL
    ) async throws -> GitHubAssetReleaseMetadata {
        let data = try await responseData(session: session, url: url)
        return try ffmpegRelease(from: data, machine: machine)
    }

    static func githubVersion(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return normalized(response.tagName)
    }

    static func githubRelease(from data: Data) throws -> GitHubReleaseMetadata {
        let response = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let downloadURL = response.assets?
            .first(where: { $0.name.caseInsensitiveCompare("Ollama.dmg") == .orderedSame })?
            .browserDownloadURL else {
            throw ManagedServiceReleaseError.invalidResponse
        }
        return GitHubReleaseMetadata(
            version: normalized(response.tagName),
            macOSDMGURL: downloadURL
        )
    }

    static func pypiVersion(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(PyPIRelease.self, from: data)
        return normalized(response.info.version)
    }

    static func ffmpegRelease(
        from data: Data,
        machine: String
    ) throws -> GitHubAssetReleaseMetadata {
        let assetName: String
        switch machine {
        case "arm64":
            assetName = "ffmpeg-darwin-arm64"
        case "x86_64":
            assetName = "ffmpeg-darwin-x64"
        default:
            throw ManagedServiceReleaseError.unsupportedArchitecture
        }

        let response = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = response.assets?.first(where: {
            $0.name.caseInsensitiveCompare(assetName) == .orderedSame
        }),
        let digest = asset.digest,
        digest.lowercased().hasPrefix("sha256:") else {
            throw ManagedServiceReleaseError.invalidResponse
        }
        let sha256 = String(digest.dropFirst("sha256:".count))
        guard sha256.count == 64 else {
            throw ManagedServiceReleaseError.invalidResponse
        }

        return GitHubAssetReleaseMetadata(
            version: normalizedFFmpegVersion(response.tagName),
            downloadURL: asset.browserDownloadURL,
            sha256: sha256
        )
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        normalized(candidate).compare(normalized(installed), options: .numeric) == .orderedDescending
    }

    static func normalized(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") { return String(trimmed.dropFirst()) }
        return trimmed
    }

    private static func normalizedFFmpegVersion(_ version: String) -> String {
        let normalizedVersion = normalized(version)
        guard normalizedVersion.lowercased().hasPrefix("b"),
              normalizedVersion.dropFirst().first?.isNumber == true else {
            return normalizedVersion
        }
        return String(normalizedVersion.dropFirst())
    }

    private static func responseData(session: URLSession, url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw ManagedServiceReleaseError.invalidResponse
        }
        return data
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [GitHubReleaseAsset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct GitHubReleaseAsset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }
    }

    private struct PyPIRelease: Decodable {
        struct Info: Decodable { let version: String }
        let info: Info
    }
}

private enum ManagedServiceReleaseError: LocalizedError {
    case invalidResponse
    case unsupportedArchitecture

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Could not fetch the latest service version"
        case .unsupportedArchitecture:
            return "This Mac architecture is not supported by the FileNest runtime."
        }
    }
}

struct AppBuildInfo: Equatable, Sendable {
    let version: String
    let buildNumber: String
    let buildDate: Date?

    var displayVersion: String { "\(version) (\(buildNumber))" }

    init(bundle: Bundle = .main) {
        let dictionary = bundle.infoDictionary ?? [:]
        version = dictionary["CFBundleShortVersionString"] as? String ?? "0.0.0"
        buildNumber = dictionary["CFBundleVersion"] as? String ?? "0"

        if let metadataURL = bundle.url(forResource: "FileNestBuildInfo", withExtension: "plist"),
           let metadata = NSDictionary(contentsOf: metadataURL),
           let rawDate = metadata["BuildDate"] as? String {
            buildDate = ISO8601DateFormatter().date(from: rawDate)
        } else {
            buildDate = try? bundle.executableURL?
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        }
    }
}

@MainActor
final class AppUpdateService: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let productionFeedURLString =
        "https://updates.filenestapp.com/appcast/stable.xml?arch=universal"

    enum Status: Equatable {
        case notConfigured
        case ready
        case checking
        case upToDate
        case updateAvailable(version: String, build: String)
        case downloading(version: String)
        case preparingToInstall(version: String)
        case installing(version: String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .preparingToInstall, .installing:
                return true
            default:
                return false
            }
        }
    }

    @Published private(set) var status: Status = .notConfigured
    @Published private(set) var lastCheckedAt: Date?

    let buildInfo: AppBuildInfo

    private let settings: AppSettings
    private let isEnabled: Bool
    private var updaterStarted = false
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    init(
        settings: AppSettings,
        bundle: Bundle = .main,
        enabled: Bool = true
    ) {
        self.settings = settings
        self.buildInfo = AppBuildInfo(bundle: bundle)
        self.isEnabled = enabled
        super.init()
        status = validatedFeedURL == nil ? .notConfigured : .ready

        if enabled, validatedFeedURL != nil, settings.automaticUpdateChecks {
            startUpdaterIfNeeded()
        }
    }

    var feedURLString: String {
        Self.productionFeedURLString
    }

    var hasValidFeedURL: Bool { validatedFeedURL != nil }

    var canCheckForUpdates: Bool {
        isEnabled && hasValidFeedURL && !status.isBusy
    }

    func setAutomaticChecks(_ value: Bool) {
        settings.setAutomaticUpdateChecks(value)
        guard value else {
            if updaterStarted {
                updaterController.updater.automaticallyChecksForUpdates = false
            }
            return
        }

        guard startUpdaterIfNeeded() else { return }
        updaterController.updater.automaticallyChecksForUpdates = true
    }

    func setAutomaticallyDownloadsUpdates(_ value: Bool) {
        settings.setAutomaticallyDownloadsUpdates(value)
        guard startUpdaterIfNeeded() else { return }
        updaterController.updater.automaticallyDownloadsUpdates = value
        updaterController.updater.resetUpdateCycleAfterShortDelay()
    }

    func checkForUpdates() {
        guard hasValidFeedURL else {
            status = .failed("Configure a valid HTTPS update URL first")
            return
        }
        guard startUpdaterIfNeeded() else { return }
        guard updaterController.updater.canCheckForUpdates else { return }

        status = .checking
        updaterController.updater.checkForUpdates()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        validatedFeedURL?.absoluteString
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        lastCheckedAt = Date()
        status = .updateAvailable(
            version: item.displayVersionString,
            build: item.versionString
        )
        Self.log(
            "Application update found",
            metadata: [
                "version": item.displayVersionString,
                "build": item.versionString,
                "automaticInstall": String(settings.automaticallyDownloadsUpdates),
            ]
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        lastCheckedAt = Date()
        status = .upToDate
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        lastCheckedAt = Date()
        status = .failed(error.localizedDescription)
        Self.log(
            "Application update cycle failed",
            level: .error,
            metadata: ["error": error.localizedDescription]
        )
    }

    func updater(
        _ updater: SPUUpdater,
        willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        status = .downloading(version: item.displayVersionString)
        Self.log(
            "Application update download started",
            metadata: ["version": item.displayVersionString]
        )
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        status = .preparingToInstall(version: item.displayVersionString)
        Self.log(
            "Application update download completed",
            metadata: ["version": item.displayVersionString]
        )
    }

    func updater(
        _ updater: SPUUpdater,
        failedToDownloadUpdate item: SUAppcastItem,
        error: Error
    ) {
        status = .failed(error.localizedDescription)
        Self.log(
            "Application update download failed",
            level: .error,
            metadata: [
                "version": item.displayVersionString,
                "error": error.localizedDescription,
            ]
        )
    }

    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        status = .preparingToInstall(version: item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        status = .installing(version: item.displayVersionString)
        Self.log(
            "Application update installation started",
            metadata: ["version": item.displayVersionString]
        )
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        guard Self.shouldInstallImmediately(
            automaticChecksEnabled: settings.automaticUpdateChecks,
            automaticInstallationEnabled: settings.automaticallyDownloadsUpdates
        ) else {
            return false
        }

        status = .installing(version: item.displayVersionString)
        Self.log(
            "Application update will install immediately and relaunch",
            metadata: ["version": item.displayVersionString]
        )
        Task { @MainActor in
            // Yield one run-loop turn so SwiftUI can render the restart state before
            // Sparkle requests application termination.
            await Task.yield()
            immediateInstallHandler()
        }
        return true
    }

    private var validatedFeedURL: URL? {
        let value = feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    @discardableResult
    private func startUpdaterIfNeeded() -> Bool {
        guard isEnabled, validatedFeedURL != nil else { return false }
        guard !updaterStarted else { return true }

        do {
            try updaterController.updater.start()
            updaterStarted = true
            updaterController.updater.automaticallyChecksForUpdates = settings.automaticUpdateChecks
            updaterController.updater.automaticallyDownloadsUpdates = settings.automaticallyDownloadsUpdates
            status = .ready
            if settings.automaticUpdateChecks {
                status = .checking
                updaterController.updater.checkForUpdatesInBackground()
            }
            return true
        } catch {
            status = .failed(error.localizedDescription)
            Self.log(
                "Application update service failed to start",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            return false
        }
    }

    nonisolated static func shouldInstallImmediately(
        automaticChecksEnabled: Bool,
        automaticInstallationEnabled: Bool
    ) -> Bool {
        automaticChecksEnabled && automaticInstallationEnabled
    }

    private static func log(
        _ message: String,
        level: AppLogLevel = .notice,
        metadata: [String: String] = [:]
    ) {
        AppLogService.shared.write(
            message,
            category: .appLifecycle,
            level: level,
            metadata: metadata
        )
    }
}
