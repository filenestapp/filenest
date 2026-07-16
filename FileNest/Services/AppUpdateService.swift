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
    static let ollamaLatestReleaseURL = URL(
        string: "https://api.github.com/repos/ollama/ollama/releases/latest"
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

    static func latestPyPIVersion(
        package: String,
        session: URLSession = .shared
    ) async throws -> String {
        let data = try await responseData(session: session, url: pypiURL(package: package))
        return try pypiVersion(from: data)
    }

    static func githubVersion(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(GitHubRelease.self, from: data)
        return normalized(response.tagName)
    }

    static func pypiVersion(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(PyPIRelease.self, from: data)
        return normalized(response.info.version)
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        normalized(candidate).compare(normalized(installed), options: .numeric) == .orderedDescending
    }

    static func normalized(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") { return String(trimmed.dropFirst()) }
        return trimmed
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

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    private struct PyPIRelease: Decodable {
        struct Info: Decodable { let version: String }
        let info: Info
    }
}

private enum ManagedServiceReleaseError: LocalizedError {
    case invalidResponse

    var errorDescription: String? { "Could not fetch the latest service version" }
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
    enum Status: Equatable {
        case notConfigured
        case ready
        case checking
        case upToDate
        case updateAvailable(version: String, build: String)
        case failed(String)
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
        if !settings.updateFeedURL.isEmpty { return settings.updateFeedURL }
        return Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
    }

    var hasValidFeedURL: Bool { validatedFeedURL != nil }

    var canCheckForUpdates: Bool {
        isEnabled && hasValidFeedURL && status != .checking
    }

    func setFeedURL(_ value: String) {
        settings.setUpdateFeedURL(value)
        status = validatedFeedURL == nil ? .notConfigured : .ready

        if updaterStarted {
            updaterController.updater.resetUpdateCycleAfterShortDelay()
        } else if settings.automaticUpdateChecks, validatedFeedURL != nil {
            startUpdaterIfNeeded()
        }
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
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        lastCheckedAt = Date()
        status = .upToDate
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        lastCheckedAt = Date()
        status = .failed(error.localizedDescription)
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
            return true
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }
}
