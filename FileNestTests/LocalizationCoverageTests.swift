import XCTest

final class LocalizationCoverageTests: XCTestCase {
    func testUserInterfaceSourceUsesEnglishStringLiterals() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "FileNest/UI/ChatView.swift",
            "FileNest/UI/MainView.swift",
            "FileNest/UI/MenuBarView.swift",
            "FileNest/UI/LibraryView.swift",
            "FileNest/UI/FilePreviewView.swift",
            "FileNest/UI/OnboardingView.swift",
            "FileNest/UI/RulesView.swift",
            "FileNest/UI/SettingsView.swift",
            "FileNest/UI/StatisticsView.swift",
        ]
        var nonEnglishSourceStrings = Set<String>()
        for path in files {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(path),
                encoding: .utf8
            )
            nonEnglishSourceStrings.formUnion(chineseStringLiterals(in: source))
        }

        XCTAssertTrue(
            nonEnglishSourceStrings.isEmpty,
            "UI source contains non-English string literals: \(nonEnglishSourceStrings.sorted())"
        )
    }

    func testVersionAndUpdateControlsHaveEnglishTranslations() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let localizedURL = repositoryRoot.appendingPathComponent("FileNest/en.lproj/Localizable.strings")
        let localizedSource = try String(contentsOf: localizedURL, encoding: .utf8)
        let localizedKeys = stringKeys(in: localizedSource)
        let expectedKeys: Set<String> = [
            "Version & Updates",
            "Build %@ · %@",
            "Update source not configured",
            "Update service ready",
            "Checking for updates…",
            "Check for Updates…",
            "You're up to date",
            "Update Source",
            "Only HTTPS Sparkle appcast URLs are supported",
            "Save URL",
            "Automatically check for updates",
            "Automatically download available updates",
            "Current Version",
            "Check for Updates",
            "Update Service",
            "Update available:",
            "Updating…",
        ]

        XCTAssertTrue(
            expectedKeys.isSubset(of: localizedKeys),
            "Missing update localization keys: \(expectedKeys.subtracting(localizedKeys).sorted())"
        )
    }

    func testMenuBarStatusBadgesHaveEnglishTranslations() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let localizedURL = repositoryRoot.appendingPathComponent("FileNest/en.lproj/Localizable.strings")
        let localizedSource = try String(contentsOf: localizedURL, encoding: .utf8)
        let localizedKeys = stringKeys(in: localizedSource)
        let expectedKeys: Set<String> = [
            "Watching and indexing",
            "Watching",
            "Indexing",
            "Paused",
            "Watching %d folders",
            "Watching %d of %d folders",
            "Watched Folder Access Required",
            "Watched Folder Missing",
            "%d folders need access restored",
            "%d folders are missing or were moved",
            "Check Again",
            "Restore Access…",
            "Access Denied",
            "Folder Missing",
            "Temporarily Unavailable",
        ]

        XCTAssertTrue(
            expectedKeys.isSubset(of: localizedKeys),
            "Missing menu-bar status localization keys: \(expectedKeys.subtracting(localizedKeys).sorted())"
        )
    }

    private func stringKeys(in source: String) -> Set<String> {
        let pattern = #"(?m)^\"((?:\\.|[^\"\\])*)\"\s*="#
        return captures(pattern: pattern, in: source)
    }

    private func chineseStringLiterals(in source: String) -> Set<String> {
        let literals = captures(pattern: #"\"((?:\\.|[^\"\\])*)\""#, in: source)
        return Set(literals.filter { literal in
            literal.unicodeScalars.contains { scalar in
                (0x4E00...0x9FFF).contains(Int(scalar.value))
            }
        })
    }

    private func captures(pattern: String, in source: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return Set(regex.matches(in: source, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        })
    }
}
