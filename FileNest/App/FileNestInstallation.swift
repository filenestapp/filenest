import Foundation

enum FileNestInstallation {
    private static let developmentBundleIdentifier = "com.local.filenest.dev"

    nonisolated static var isDevelopment: Bool {
        Bundle.main.bundleIdentifier == developmentBundleIdentifier
    }

    nonisolated static var displayName: String {
        infoValue(for: "CFBundleDisplayName") ?? (isDevelopment ? "FileNest Dev" : "FileNest")
    }

    nonisolated static var applicationSupportDirectoryName: String {
        isDevelopment ? "FileNest Dev" : "FileNest"
    }

    private static func infoValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
