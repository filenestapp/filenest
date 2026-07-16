import Foundation

/// Defines editor lock files, incomplete downloads, and system metadata that must not enter watching, indexing, or statistics.
enum FileEligibilityPolicy {
    private static let ignoredExtensions: Set<String> = [
        "crdownload", "download", "part", "partial", "tmp", "temp",
        "swp", "swo", "lock", "lck", "icloud"
    ]

    static func shouldIgnoreFile(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return true }
        let lowercase = name.lowercased()

        // Microsoft Office lock files, AppleDouble resource files, and common editor backups.
        if lowercase.hasPrefix("~$") || lowercase.hasPrefix("._") { return true }
        if lowercase.hasSuffix("~") { return true }

        // Hidden system files must never be indexed, regardless of the show-hidden-files preference.
        if [".ds_store", "thumbs.db", "desktop.ini"].contains(lowercase) { return true }

        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ignoredExtensions.contains(ext)
    }
}
