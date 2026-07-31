import XCTest

final class LocalizationCoverageTests: XCTestCase {
    func testUserInterfaceSourceUsesEnglishStringLiterals() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let files = [
            "FileNest/UI/ChatView.swift",
            "FileNest/UI/DesignSystem.swift",
            "FileNest/UI/MainView.swift",
            "FileNest/UI/MenuBarView.swift",
            "FileNest/UI/LibraryView.swift",
            "FileNest/UI/FilePreviewView.swift",
            "FileNest/UI/OnboardingView.swift",
            "FileNest/UI/QuickSearchPanel.swift",
            "FileNest/UI/RAGFeedbackView.swift",
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

    func testEnglishAndSimplifiedChineseHaveIdenticalLocalizationKeys() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let folders = ["en.lproj", "zh-Hans.lproj"]
        let keys = try folders.map { folder in
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "FileNest/\(folder)/Localizable.strings"
                ),
                encoding: .utf8
            )
            return stringKeys(in: source)
        }

        XCTAssertEqual(
            keys[0],
            keys[1],
            "English and Simplified Chinese localization keys must stay in sync."
        )
    }

    func testLocalizationResourcesDoNotContainDuplicateKeys() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        for folder in ["en.lproj", "zh-Hans.lproj"] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "FileNest/\(folder)/Localizable.strings"
                ),
                encoding: .utf8
            )
            let keys = captureList(
                pattern: #"(?m)^\"((?:\\.|[^\"\\])*)\"\s*="#,
                in: source
            )
            let duplicates = Dictionary(grouping: keys, by: { $0 })
                .filter { $0.value.count > 1 }
                .map(\.key)
                .sorted()

            XCTAssertTrue(
                duplicates.isEmpty,
                "Duplicate localization keys in \(folder): \(duplicates)"
            )
        }
    }

    func testMediaTranscriptionAndReindexControlsHaveTranslations() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectedKeys: Set<String> = [
            "Limit Reindex to File Types",
            "Media transcription",
            "Audio or video transcription settings, model, or runtime changed",
            "Creating an isolated Whisper environment…",
            "Downloading FFmpeg…",
            "Downloading the Whisper %@ model…",
            "Whisper model download complete",
            "FFmpeg installation failed: %@",
            "FFmpeg update failed: %@",
            "Whisper installation failed: %@",
            "Whisper model download failed: %@",
        ]

        for folder in ["en.lproj", "zh-Hans.lproj"] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "FileNest/\(folder)/Localizable.strings"
                ),
                encoding: .utf8
            )
            let localizedKeys = stringKeys(in: source)
            XCTAssertTrue(
                expectedKeys.isSubset(of: localizedKeys),
                "Missing media localization keys in \(folder): \(expectedKeys.subtracting(localizedKeys).sorted())"
            )
        }
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
            "Automatically check for updates",
            "Automatically download available updates",
            "Automatically install updates and restart FileNest",
            "Downloading version %@…",
            "Preparing version %@…",
            "Installing version %@ and restarting…",
            "Signed updates are verified before installation. Automatic installation safely stops managed services, installs the update, and restarts FileNest.",
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

    func testChatEditAndResendControlsHaveTranslations() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let localizationFiles = ["en.lproj", "zh-Hans.lproj"].map {
            repositoryRoot.appendingPathComponent("FileNest/\($0)/Localizable.strings")
        }
        let expectedKeys: Set<String> = [
            "Edit and resend this question",
            "Editing your last question",
        ]

        for localizationFile in localizationFiles {
            let source = try String(contentsOf: localizationFile, encoding: .utf8)
            let localizedKeys = stringKeys(in: source)
            XCTAssertTrue(
                expectedKeys.isSubset(of: localizedKeys),
                "Missing chat edit localization keys in \(localizationFile.path): "
                    + "\(expectedKeys.subtracting(localizedKeys).sorted())"
            )
        }
    }

    func testDuplicateFileControlsHaveTranslations() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectedKeys: Set<String> = [
            "Find Duplicates",
            "Duplicate Files",
            "Rescan",
            "Scanning files for duplicates… %d of %d",
            "No duplicate files found",
            "Move %d Duplicates to Trash",
            "Move selected duplicates to Trash?",
            "The selected files will be moved to the macOS Trash. The kept original files are not changed.",
            "Keep",
            "Duplicate copy",
        ]

        for localizationFolder in ["en.lproj", "zh-Hans.lproj"] {
            let localizationURL = repositoryRoot.appendingPathComponent(
                "FileNest/\(localizationFolder)/Localizable.strings"
            )
            let source = try String(contentsOf: localizationURL, encoding: .utf8)
            let localizedKeys = stringKeys(in: source)
            XCTAssertTrue(
                expectedKeys.isSubset(of: localizedKeys),
                "Missing duplicate-file localization keys in \(localizationURL.path): "
                    + "\(expectedKeys.subtracting(localizedKeys).sorted())"
            )
        }
    }

    func testIndexConfigurationPromptUsesExplicitAppLocalization() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectedKeys: Set<String> = [
            "Index Processing Settings Changed",
            "Reindex Now",
            "Skip and Keep Existing Index",
            "Chunking, document parsing, OCR, indexing scope, or a service endpoint changed. The existing index remains usable. Reindex now, or skip and use the latest settings for new files.",
        ]

        for localizationFolder in ["en.lproj", "zh-Hans.lproj"] {
            let localizationURL = repositoryRoot.appendingPathComponent(
                "FileNest/\(localizationFolder)/Localizable.strings"
            )
            let source = try String(contentsOf: localizationURL, encoding: .utf8)
            let localizedKeys = stringKeys(in: source)
            XCTAssertTrue(
                expectedKeys.isSubset(of: localizedKeys),
                "Missing index prompt localization keys in \(localizationURL.path): "
                    + "\(expectedKeys.subtracting(localizedKeys).sorted())"
            )
        }

        let appSourceURL = repositoryRoot.appendingPathComponent("FileNest/App/FileNestApp.swift")
        let appSource = try String(contentsOf: appSourceURL, encoding: .utf8)
        for key in expectedKeys {
            XCTAssertTrue(
                appSource.contains("appState.settings.localized(\"\(key)\"")
                    || appSource.contains("appState.settings.localized(\n                    \"\(key)\""),
                "Index prompt does not explicitly localize: \(key)"
            )
        }
    }

    func testSystemNotificationMessagesHaveTranslations() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let expectedKeys: Set<String> = [
            "File Processing Complete",
            "File Processing Failed",
            "%@ finished indexing and processing.",
            "%d files finished indexing and processing.",
            "FileNest could not process %@. Open FileNest for details.",
            "Search Complete",
            "Search found %d related files.",
            "Smart Search found %d related files.",
        ]

        for localizationFolder in ["en.lproj", "zh-Hans.lproj"] {
            let localizationURL = repositoryRoot.appendingPathComponent(
                "FileNest/\(localizationFolder)/Localizable.strings"
            )
            let source = try String(contentsOf: localizationURL, encoding: .utf8)
            let localizedKeys = stringKeys(in: source)
            XCTAssertTrue(
                expectedKeys.isSubset(of: localizedKeys),
                "Missing notification localization keys in \(localizationURL.path): "
                    + "\(expectedKeys.subtracting(localizedKeys).sorted())"
            )
        }
    }

    func testUserFacingLocalizationLiteralsExistInEveryLocalizationResource() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("FileNest")
        let intentionallyVerbatim: Set<String> = [
            "",
            ": ",
            "·",
            "FileNest",
            "/Users/name/Folder",
            "612000",
            "Qwen/Qwen3-Reranker-0.6B",
            "Qwen3-Reranker-0.6B",
            "glm-ocr",
            "http://127.0.0.1:11435/v1",
            "https://api.example.com/v1",
            "https://api.openai.com/v1",
            "pdf, docx, txt, md, png, jpg",
            "qwen3-embedding:0.6b",
            "sk-…",
        ]
        let patterns = [
            #"\b(?:Text|Button|Label|Section|Picker|Toggle|GroupBox|TextField|SecureField|ProgressView|navigationTitle|alert|confirmationDialog)\(\s*"((?:\\.|[^"\\])*)""#,
            #"\.(?:help|accessibilityLabel|accessibilityHint)\(\s*"((?:\\.|[^"\\])*)""#,
            #"\b(?:localized|localizedFormat)\(\s*"((?:\\.|[^"\\])*)""#,
            #"LocalizedStringKey\(\s*"((?:\\.|[^"\\])*)""#,
        ]

        var requiredKeys = Set<String>()
        let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for pattern in patterns {
                requiredKeys.formUnion(captures(pattern: pattern, in: source))
            }
        }
        requiredKeys = requiredKeys.filter {
            !$0.contains(#"\("#) && !intentionallyVerbatim.contains($0)
        }

        for localizationFolder in ["en.lproj", "zh-Hans.lproj"] {
            let source = try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "FileNest/\(localizationFolder)/Localizable.strings"
                ),
                encoding: .utf8
            )
            let localizedKeys = stringKeys(in: source)
            XCTAssertTrue(
                requiredKeys.isSubset(of: localizedKeys),
                "Missing user-facing localization keys in \(localizationFolder): "
                    + "\(requiredKeys.subtracting(localizedKeys).sorted())"
            )
        }
    }

    func testSimplifiedChineseDoesNotSilentlyFallBackToEnglish() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let english = try localizationEntries(
            at: repositoryRoot.appendingPathComponent("FileNest/en.lproj/Localizable.strings")
        )
        let simplifiedChinese = try localizationEntries(
            at: repositoryRoot.appendingPathComponent("FileNest/zh-Hans.lproj/Localizable.strings")
        )
        let intentionallyLanguageNeutral: Set<String> = [
            "Ollama · %@",
            "Apple NLEmbedding",
            "FFmpeg",
            "OpenAI Whisper",
        ]
        let untranslated = english.compactMap { key, value -> String? in
            guard value.range(of: #"[A-Za-z]{3}"#, options: .regularExpression) != nil,
                  simplifiedChinese[key] == value,
                  !intentionallyLanguageNeutral.contains(key) else {
                return nil
            }
            return key
        }.sorted()

        XCTAssertTrue(
            untranslated.isEmpty,
            "Simplified Chinese values still fall back to English: \(untranslated)"
        )
    }

    private func localizationEntries(at url: URL) throws -> [String: String] {
        let source = try String(contentsOf: url, encoding: .utf8)
        let regex = try NSRegularExpression(
            pattern: #"(?m)^"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";"#
        )
        let range = NSRange(source.startIndex..., in: source)
        var entries = [String: String]()
        for match in regex.matches(in: source, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: source),
                  let valueRange = Range(match.range(at: 2), in: source) else {
                continue
            }
            entries[String(source[keyRange])] = String(source[valueRange])
        }
        return entries
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
        Set(captureList(pattern: pattern, in: source))
    }

    private func captureList(pattern: String, in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        }
    }
}
