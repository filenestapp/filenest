import XCTest
import AppKit
import Carbon
import ServiceManagement
@testable import FileNest

final class AppSettingsTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
        store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    @MainActor
    func testGlobalScrollerStyleUsesCompactLowContrastOverlayScrollers() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let scrollView = NSScrollView(frame: root.bounds)
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.hasVerticalScroller = true
        root.addSubview(scrollView)

        FileNestScrollerStyleCoordinator.shared.applyRecursively(to: root)

        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertTrue(scrollView.autohidesScrollers)
        XCTAssertEqual(scrollView.verticalScroller?.controlSize, .mini)
        XCTAssertEqual(scrollView.verticalScroller?.alphaValue ?? -1, 0.30, accuracy: 0.001)
    }

    @MainActor
    func testLaunchAtLoginServiceRegistersAndUnregistersTheMainApp() async {
        var systemStatus = SMAppService.Status.notRegistered
        var registerCount = 0
        var unregisterCount = 0
        let service = LaunchAtLoginService(
            statusProvider: { systemStatus },
            registerAction: {
                registerCount += 1
                systemStatus = .enabled
            },
            unregisterAction: {
                unregisterCount += 1
                systemStatus = .notRegistered
            }
        )

        XCTAssertEqual(service.status, .disabled)

        await service.setEnabled(true)

        XCTAssertEqual(registerCount, 1)
        XCTAssertEqual(service.status, .enabled)

        await service.setEnabled(false)

        XCTAssertEqual(unregisterCount, 1)
        XCTAssertEqual(service.status, .disabled)
    }

    @MainActor
    func testLaunchAtLoginServiceSurfacesSystemApprovalState() {
        let service = LaunchAtLoginService(
            statusProvider: { .requiresApproval },
            registerAction: {},
            unregisterAction: {}
        )

        XCTAssertEqual(service.status, .requiresApproval)
        XCTAssertFalse(service.isEnabled)
    }

    func testSettingsPersistAcrossInstances() {
        let settings = AppSettings(store: store)
        settings.setMediaTranscriptionEnabled(true)
        settings.setWhisperModel("small")
        settings.setWatchDirs(["/tmp/Downloads", "/tmp/Desktop"])
        settings.setEnabledExtensions(["pdf", "md"])
        settings.setCustomFileExtensions(["LOG", ".trace", "pdf", "log"])
        settings.setExcludeHidden(false)
        settings.setClassifyStrategy(ClassificationStrategy.rule.rawValue)
        settings.setLLMChoice(AppSettings.LLMChoice.cloud.rawValue)
        settings.setOllamaHost("http://localhost:11434")
        settings.setOllamaModel("test-ollama")
        settings.setOllamaFlashAttentionEnabled(false)
        settings.setCloudAPIFormat(AppSettings.CloudAPIFormat.anthropic.rawValue)
        settings.setCloudKey("test-key")
        settings.setCloudBaseURL("https://example.test/v1")
        settings.setCloudModel("test-cloud")
        settings.setCloudContextWindowTokens(612_000)
        settings.setAutoOrganize(false)
        settings.setAutoOrganizeMode(AppSettings.AutoOrganizeMode.batched.rawValue)
        settings.setAutoOrganizeIntervalSeconds(120)
        settings.setAutoOrganizeBatchSize(12)
        settings.setAutoVectorize(false)
        settings.setVectorizeExtensions(["PDF", ".md", "pdf"])
        settings.setVectorChunkWords(850)
        settings.setVectorRetrievalChunkTokens(320)
        settings.setVectorChunkOverlap(50)
        settings.setDoclingEnabled(false)
        settings.setEmbeddingSource(AppSettings.EmbeddingSource.cloud.rawValue)
        settings.setOllamaEmbeddingModel("qwen3-embedding:4b")
        settings.setCloudEmbeddingBaseURL("https://embed.example/v1")
        settings.setCloudEmbeddingAPIKey("embed-key")
        settings.setCloudEmbeddingModel("embed-model")
        settings.setCloudEmbeddingReuseChatCredentials(true)
        settings.setOCRSource(AppSettings.OCRSource.cloud.rawValue)
        settings.setOllamaOCRModel("glm-ocr:q8_0")
        settings.setCloudOCRFormat(AppSettings.CloudAPIFormat.anthropic.rawValue)
        settings.setCloudOCRBaseURL("https://ocr.example/v1")
        settings.setCloudOCRAPIKey("ocr-key")
        settings.setCloudOCRModel("ocr-model")
        settings.setCloudOCRReuseChatCredentials(true)
        settings.setThinkingMode(true)
        settings.setAppLanguage(AppSettings.AppLanguage.english.rawValue)
        settings.setAppearance(AppSettings.AppAppearance.dark.rawValue)
        settings.setQuickSearchShortcut(QuickSearchShortcut(
            keyCode: 11,
            modifiers: UInt32(cmdKey | shiftKey)
        ))
        settings.setOnboardingCompleted(true)
        settings.setAutomaticUpdateChecks(false)
        settings.setAutomaticallyDownloadsUpdates(true)
        let modelVersionCheckDate = Date(timeIntervalSince1970: 1_750_000_000)
        settings.setLastAIModelVersionCheckAt(modelVersionCheckDate)

        let reloaded = AppSettings(store: store)

        XCTAssertEqual(reloaded.watchDirs, ["/tmp/Downloads", "/tmp/Desktop"])
        XCTAssertEqual(reloaded.enabledExtensions, ["pdf", "md"])
        XCTAssertEqual(reloaded.customFileExtensions, ["log", "trace"])
        XCTAssertFalse(reloaded.excludeHidden)
        XCTAssertEqual(reloaded.classifyStrategy, ClassificationStrategy.rule.rawValue)
        XCTAssertEqual(reloaded.llmChoice, AppSettings.LLMChoice.cloud.rawValue)
        XCTAssertEqual(reloaded.ollamaHost, "http://localhost:11434")
        XCTAssertEqual(reloaded.ollamaModel, "test-ollama")
        XCTAssertFalse(reloaded.ollamaFlashAttentionEnabled)
        XCTAssertEqual(reloaded.cloudAPIFormat, AppSettings.CloudAPIFormat.anthropic.rawValue)
        XCTAssertEqual(reloaded.cloudAPIKey, "test-key")
        XCTAssertEqual(reloaded.cloudBaseURL, "https://example.test/v1")
        XCTAssertEqual(reloaded.cloudModel, "test-cloud")
        XCTAssertEqual(reloaded.cloudContextWindowTokens, 612_000)
        XCTAssertFalse(reloaded.autoOrganize)
        XCTAssertEqual(reloaded.autoOrganizeMode, AppSettings.AutoOrganizeMode.batched.rawValue)
        XCTAssertEqual(reloaded.autoOrganizeIntervalSeconds, 120)
        XCTAssertEqual(reloaded.autoOrganizeBatchSize, 12)
        XCTAssertFalse(reloaded.autoVectorize)
        XCTAssertEqual(reloaded.vectorizeExtensions, ["pdf", "md"])
        XCTAssertEqual(reloaded.vectorChunkWords, 850)
        XCTAssertEqual(reloaded.vectorRetrievalChunkTokens, 320)
        XCTAssertEqual(reloaded.vectorChunkOverlap, 50)
        XCTAssertFalse(reloaded.doclingEnabled)
        XCTAssertTrue(reloaded.mediaTranscriptionEnabled)
        XCTAssertEqual(reloaded.whisperModel, "small")
        XCTAssertEqual(reloaded.embeddingSource, AppSettings.EmbeddingSource.cloud.rawValue)
        XCTAssertEqual(reloaded.ollamaEmbeddingModel, "qwen3-embedding:4b")
        XCTAssertEqual(reloaded.cloudEmbeddingBaseURL, "https://embed.example/v1")
        XCTAssertEqual(reloaded.cloudEmbeddingAPIKey, "embed-key")
        XCTAssertEqual(reloaded.cloudEmbeddingModel, "embed-model")
        XCTAssertTrue(reloaded.cloudEmbeddingReuseChatCredentials)
        XCTAssertEqual(reloaded.ocrSource, AppSettings.OCRSource.cloud.rawValue)
        XCTAssertEqual(reloaded.ollamaOCRModel, "glm-ocr:q8_0")
        XCTAssertEqual(reloaded.cloudOCRFormat, AppSettings.CloudAPIFormat.anthropic.rawValue)
        XCTAssertEqual(reloaded.cloudOCRBaseURL, "https://ocr.example/v1")
        XCTAssertEqual(reloaded.cloudOCRAPIKey, "ocr-key")
        XCTAssertEqual(reloaded.cloudOCRModel, "ocr-model")
        XCTAssertTrue(reloaded.cloudOCRReuseChatCredentials)
        XCTAssertTrue(reloaded.thinkingMode)
        XCTAssertEqual(reloaded.appLanguage, AppSettings.AppLanguage.english.rawValue)
        XCTAssertEqual(reloaded.appearance, AppSettings.AppAppearance.dark.rawValue)
        XCTAssertEqual(reloaded.quickSearchShortcutKeyCode, 11)
        XCTAssertEqual(reloaded.quickSearchShortcutModifiers, UInt32(cmdKey | shiftKey))
        XCTAssertTrue(reloaded.onboardingCompleted)
        XCTAssertFalse(reloaded.automaticUpdateChecks)
        XCTAssertTrue(reloaded.automaticallyDownloadsUpdates)
        XCTAssertEqual(reloaded.lastAIModelVersionCheckAt, modelVersionCheckDate)
    }

    func testAgentGenerationConfigurationFollowsGlobalLocalSettings() {
        let settings = AppSettings(store: store)
        settings.setLLMChoice(AppSettings.LLMChoice.ollama.rawValue)
        settings.setOllamaHost("http://127.0.0.1:11434")
        settings.setOllamaModel("qwen3:8b")
        settings.setThinkingMode(true)

        XCTAssertEqual(
            settings.agentGenerationConfiguration(),
            AgentGenerationConfiguration(
                provider: .ollama,
                model: "qwen3:8b",
                baseURL: "http://127.0.0.1:11434",
                apiKey: nil,
                thinkingEnabled: true
            )
        )
    }

    func testAgentGenerationConfigurationFollowsGlobalCloudSettings() {
        let settings = AppSettings(store: store)
        settings.setLLMChoice(AppSettings.LLMChoice.cloud.rawValue)
        settings.setCloudAPIFormat(AppSettings.CloudAPIFormat.anthropic.rawValue)
        settings.setCloudBaseURL("https://api.example.test/v1")
        settings.setCloudModel("claude-sonnet")
        settings.setCloudKey("test-cloud-key")

        XCTAssertEqual(
            settings.agentGenerationConfiguration(),
            AgentGenerationConfiguration(
                provider: .anthropic,
                model: "claude-sonnet",
                baseURL: "https://api.example.test/v1",
                apiKey: "test-cloud-key",
                thinkingEnabled: false
            )
        )
    }

    func testAgentGenerationConfigurationIsNilWhenChatIsDisabled() {
        let settings = AppSettings(store: store)
        settings.setLLMChoice(AppSettings.LLMChoice.none.rawValue)

        XCTAssertNil(settings.agentGenerationConfiguration())
    }

    func testAIModelVersionCheckUsesPersistent24HourTTL() {
        let settings = AppSettings(store: store)
        let checkedAt = Date(timeIntervalSince1970: 1_750_000_000)

        XCTAssertTrue(settings.shouldCheckAIModelVersions(at: checkedAt))

        settings.setLastAIModelVersionCheckAt(checkedAt)

        XCTAssertFalse(settings.shouldCheckAIModelVersions(
            at: checkedAt.addingTimeInterval(23 * 60 * 60)
        ))
        XCTAssertTrue(settings.shouldCheckAIModelVersions(
            at: checkedAt.addingTimeInterval(24 * 60 * 60)
        ))
        XCTAssertEqual(AppSettings(store: store).lastAIModelVersionCheckAt, checkedAt)
    }

    func testQuickSearchShortcutRejectsModifierFreeCombinations() {
        let settings = AppSettings(store: store)

        settings.setQuickSearchShortcut(QuickSearchShortcut(keyCode: 0, modifiers: 0))

        XCTAssertEqual(settings.quickSearchShortcutKeyCode, QuickSearchShortcut.defaultValue.keyCode)
        XCTAssertEqual(settings.quickSearchShortcutModifiers, QuickSearchShortcut.defaultValue.modifiers)
    }

    @MainActor
    func testUpdateServiceUsesBuiltInProductionAppcastURL() {
        let settings = AppSettings(store: store)
        let updates = AppUpdateService(settings: settings, enabled: false)

        XCTAssertEqual(
            updates.feedURLString,
            "https://updates.filenestapp.com/appcast/stable.xml?arch=universal"
        )
        XCTAssertTrue(updates.hasValidFeedURL)
        XCTAssertEqual(updates.status, .ready)
    }

    @MainActor
    func testAppUpdatesDefaultToAutomaticCheckInstallAndRelaunch() {
        let settings = AppSettings(store: store)

        XCTAssertTrue(settings.automaticUpdateChecks)
        XCTAssertTrue(settings.automaticallyDownloadsUpdates)
        XCTAssertTrue(AppUpdateService.shouldInstallImmediately(
            automaticChecksEnabled: settings.automaticUpdateChecks,
            automaticInstallationEnabled: settings.automaticallyDownloadsUpdates
        ))
        XCTAssertFalse(AppUpdateService.shouldInstallImmediately(
            automaticChecksEnabled: false,
            automaticInstallationEnabled: true
        ))
        XCTAssertFalse(AppUpdateService.shouldInstallImmediately(
            automaticChecksEnabled: true,
            automaticInstallationEnabled: false
        ))
    }

    func testManagedServiceReleaseMetadataParsesOfficialFormats() throws {
        let github = Data(#"{"tag_name":"v0.32.0"}"#.utf8)
        let pypi = Data(#"{"info":{"version":"3.7.0"}}"#.utf8)

        XCTAssertEqual(try ManagedServiceReleaseAPI.githubVersion(from: github), "0.32.0")
        XCTAssertEqual(try ManagedServiceReleaseAPI.pypiVersion(from: pypi), "3.7.0")
    }

    func testManagedServiceReleaseMetadataSelectsVersionedOllamaDMG() throws {
        let github = Data(#"""
        {
          "tag_name":"v0.32.1",
          "assets":[
            {"name":"ollama-darwin.tgz","browser_download_url":"https://example.test/v0.32.1/ollama-darwin.tgz"},
            {"name":"Ollama.dmg","browser_download_url":"https://example.test/v0.32.1/Ollama.dmg"}
          ]
        }
        """#.utf8)

        let release = try ManagedServiceReleaseAPI.githubRelease(from: github)

        XCTAssertEqual(release.version, "0.32.1")
        XCTAssertEqual(
            release.macOSDMGURL,
            URL(string: "https://example.test/v0.32.1/Ollama.dmg")
        )
    }

    func testManagedServiceReleaseMetadataSelectsVerifiedFFmpegBinary() throws {
        let github = Data(#"""
        {
          "tag_name":"b7.1.0",
          "assets":[
            {
              "name":"ffmpeg-darwin-arm64",
              "browser_download_url":"https://example.test/b7.1.0/ffmpeg-darwin-arm64",
              "digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            },
            {
              "name":"ffmpeg-darwin-x64",
              "browser_download_url":"https://example.test/b7.1.0/ffmpeg-darwin-x64",
              "digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            }
          ]
        }
        """#.utf8)

        let armRelease = try ManagedServiceReleaseAPI.ffmpegRelease(from: github, machine: "arm64")
        let intelRelease = try ManagedServiceReleaseAPI.ffmpegRelease(from: github, machine: "x86_64")

        XCTAssertEqual(armRelease.version, "7.1.0")
        XCTAssertEqual(armRelease.downloadURL.lastPathComponent, "ffmpeg-darwin-arm64")
        XCTAssertEqual(armRelease.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(intelRelease.downloadURL.lastPathComponent, "ffmpeg-darwin-x64")
        XCTAssertEqual(intelRelease.sha256, String(repeating: "b", count: 64))
        XCTAssertThrowsError(
            try ManagedServiceReleaseAPI.ffmpegRelease(from: github, machine: "unsupported")
        )
    }

    func testManagedServiceReleaseMetadataRejectsUnverifiedFFmpegBinary() throws {
        let github = Data(#"""
        {
          "tag_name":"b7.1.0",
          "assets":[
            {
              "name":"ffmpeg-darwin-arm64",
              "browser_download_url":"https://example.test/b7.1.0/ffmpeg-darwin-arm64"
            }
          ]
        }
        """#.utf8)

        XCTAssertThrowsError(
            try ManagedServiceReleaseAPI.ffmpegRelease(from: github, machine: "arm64")
        )
    }

    func testManagedServiceVersionComparisonUsesNumericComponents() {
        XCTAssertTrue(ManagedServiceReleaseAPI.isNewer("v0.10.0", than: "0.9.9"))
        XCTAssertTrue(ManagedServiceReleaseAPI.isNewer("3.7.1", than: "3.7.0"))
        XCTAssertFalse(ManagedServiceReleaseAPI.isNewer("3.7.0", than: "3.7.0"))
        XCTAssertFalse(ManagedServiceReleaseAPI.isNewer("2.99.0", than: "3.0.0"))
    }

    func testOllamaCommandVersionParsingUsesInstalledBinaryOutput() {
        let output = Data("ollama version is 0.32.1\n".utf8)

        XCTAssertEqual(OllamaServiceManager.version(fromCommandOutput: output), "0.32.1")
    }

    func testOllamaModelsAreStoredOutsideTheReplaceableApplicationDirectory() {
        let installRoot = OllamaServiceManager.localApplicationURL.deletingLastPathComponent()
            .standardizedFileURL.path + "/"

        XCTAssertFalse(ManagedRuntimePaths.ollamaModelsRoot.standardizedFileURL.path.hasPrefix(installRoot))
    }

    func testOllamaModelDirectoryMigratesFromThePreviousManagedLocation() throws {
        let previousDirectory = temporaryDirectory
            .appendingPathComponent("Ollama/models", isDirectory: true)
        let managedDirectory = temporaryDirectory
            .appendingPathComponent("Models/Ollama", isDirectory: true)
        let manifest = previousDirectory
            .appendingPathComponent("manifests/qwen3-embedding", isDirectory: false)
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("model-manifest".utf8).write(to: manifest)

        try OllamaServiceManager.prepareManagedModelDirectory(
            managedDirectory: managedDirectory,
            migrationSources: [previousDirectory]
        )

        XCTAssertEqual(
            try Data(contentsOf: managedDirectory.appendingPathComponent("manifests/qwen3-embedding")),
            Data("model-manifest".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: previousDirectory.path))
    }

    func testOllamaModelMigrationPrefersPopulatedLegacyDirectory() throws {
        let emptyPreviousDirectory = temporaryDirectory
            .appendingPathComponent("Ollama/models", isDirectory: true)
        let populatedLegacyDirectory = temporaryDirectory
            .appendingPathComponent("UserOllama/models", isDirectory: true)
        let managedDirectory = temporaryDirectory
            .appendingPathComponent("Models/Ollama", isDirectory: true)
        let manifest = populatedLegacyDirectory
            .appendingPathComponent("manifests/qwen3-embedding", isDirectory: false)
        try FileManager.default.createDirectory(
            at: emptyPreviousDirectory.appendingPathComponent("manifests", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: managedDirectory.appendingPathComponent("blobs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("model-manifest".utf8).write(to: manifest)

        try OllamaServiceManager.prepareManagedModelDirectory(
            managedDirectory: managedDirectory,
            migrationSources: [emptyPreviousDirectory, populatedLegacyDirectory]
        )

        XCTAssertEqual(
            try Data(contentsOf: managedDirectory.appendingPathComponent("manifests/qwen3-embedding")),
            Data("model-manifest".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: populatedLegacyDirectory.path))
    }

    func testOllamaApplicationReplacementPreservesSiblingModels() throws {
        let installRoot = temporaryDirectory.appendingPathComponent("Ollama", isDirectory: true)
        let destinationApplication = installRoot.appendingPathComponent("Ollama.app", isDirectory: true)
        let stagedApplication = temporaryDirectory
            .appendingPathComponent("Ollama.staged.app", isDirectory: true)
        let modelBlob = installRoot.appendingPathComponent("models/blobs/model-data")
        let oldExecutable = destinationApplication.appendingPathComponent("Contents/Resources/ollama")
        let newExecutable = stagedApplication.appendingPathComponent("Contents/Resources/ollama")
        for file in [modelBlob, oldExecutable, newExecutable] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try Data("downloaded-model".utf8).write(to: modelBlob)
        try Data("old-runtime".utf8).write(to: oldExecutable)
        try Data("new-runtime".utf8).write(to: newExecutable)

        try OllamaServiceManager.replaceInstalledApplication(
            with: stagedApplication,
            at: destinationApplication
        )

        XCTAssertEqual(try Data(contentsOf: modelBlob), Data("downloaded-model".utf8))
        XCTAssertEqual(try Data(contentsOf: oldExecutable), Data("new-runtime".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApplication.path))
    }

    func testOllamaApplicationReplacementRestoresPreviousBundleOnFailure() throws {
        let installRoot = temporaryDirectory.appendingPathComponent("Ollama", isDirectory: true)
        let destinationApplication = installRoot.appendingPathComponent("Ollama.app", isDirectory: true)
        let oldExecutable = destinationApplication.appendingPathComponent("Contents/Resources/ollama")
        let modelBlob = installRoot.appendingPathComponent("models/blobs/model-data")
        for file in [oldExecutable, modelBlob] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try Data("old-runtime".utf8).write(to: oldExecutable)
        try Data("downloaded-model".utf8).write(to: modelBlob)

        XCTAssertThrowsError(
            try OllamaServiceManager.replaceInstalledApplication(
                with: temporaryDirectory.appendingPathComponent("missing.app"),
                at: destinationApplication
            )
        )

        XCTAssertEqual(try Data(contentsOf: oldExecutable), Data("old-runtime".utf8))
        XCTAssertEqual(try Data(contentsOf: modelBlob), Data("downloaded-model".utf8))
    }

    func testOllamaAutomaticStartupPolicyFollowsActiveProviders() {
        let settings = AppSettings(store: store)
        XCTAssertTrue(settings.requiresOllamaService)

        settings.setLLMChoice(AppSettings.LLMChoice.cloud.rawValue)
        settings.setEmbeddingSource(AppSettings.EmbeddingSource.cloud.rawValue)
        XCTAssertFalse(settings.requiresOllamaService)

        settings.setEmbeddingSource(AppSettings.EmbeddingSource.ollama.rawValue)
        XCTAssertTrue(settings.requiresOllamaService)
    }

    func testOllamaAutomaticStartupOnlyTargetsLocalHosts() {
        XCTAssertTrue(OllamaServiceManager.isLocalServiceHost("http://127.0.0.1:11434"))
        XCTAssertTrue(OllamaServiceManager.isLocalServiceHost("http://localhost:11434"))
        XCTAssertTrue(OllamaServiceManager.isLocalServiceHost("http://[::1]:11434"))
        XCTAssertFalse(OllamaServiceManager.isLocalServiceHost("https://ollama.example.com"))
        XCTAssertFalse(OllamaServiceManager.isLocalServiceHost("not a URL"))
    }

    func testOllamaFallbackCandidatesAdvanceFromTheConfiguredPort() {
        XCTAssertEqual(
            OllamaServiceManager.localHostCandidates(
                startingAt: "http://127.0.0.1:11434",
                maximumAttempts: 3
            ),
            [
                "http://127.0.0.1:11434",
                "http://127.0.0.1:11435",
                "http://127.0.0.1:11436"
            ]
        )
        XCTAssertEqual(
            OllamaServiceManager.localHostCandidates(
                startingAt: "http://[::1]:22468",
                maximumAttempts: 2
            ),
            ["http://[::1]:22468", "http://[::1]:22469"]
        )
        XCTAssertTrue(
            OllamaServiceManager.localHostCandidates(
                startingAt: "https://ollama.example.com",
                maximumAttempts: 3
            ).isEmpty
        )
    }

    func testOllamaFallbackSelectsTheFirstAvailablePort() {
        let selected = OllamaServiceManager.firstAvailableLocalHost(
            startingAt: "http://localhost:11434",
            maximumAttempts: 5
        ) { _, port in
            port == 11_436
        }

        XCTAssertEqual(selected, "http://localhost:11436")
    }

    func testOnboardingIsIncompleteUntilExplicitlyFinished() {
        let settings = AppSettings(store: store)
        XCTAssertFalse(settings.onboardingCompleted)
        XCTAssertTrue(settings.mediaTranscriptionEnabled)

        settings.setOnboardingCompleted(true)

        XCTAssertTrue(AppSettings(store: store).onboardingCompleted)
    }

    func testFreshInstallDefaultsToDesktopDownloadsAndLightweightEmbedding() {
        let settings = AppSettings(store: store)
        let defaults = AppSettings.defaultWatchDirectories()

        XCTAssertEqual(settings.watchDirs, defaults)
        XCTAssertEqual(defaults.count, 2)
        XCTAssertTrue(defaults[0].hasSuffix("/Desktop"))
        XCTAssertTrue(defaults[1].hasSuffix("/Downloads"))
        XCTAssertEqual(
            settings.ollamaEmbeddingModel,
            OllamaModelRecommendation.defaultEmbeddingModel
        )
        XCTAssertEqual(settings.ollamaModel, OllamaModelRecommendation.defaultGenerationModel)
        XCTAssertEqual(settings.ollamaModel, "qwen3.5:9b")
        XCTAssertEqual(settings.ollamaEmbeddingModel, "qwen3-embedding:0.6b")
        XCTAssertTrue(settings.ollamaFlashAttentionEnabled)
        XCTAssertEqual(settings.cloudContextWindowTokens, 0)
        XCTAssertEqual(settings.vectorChunkWords, 600)
        XCTAssertEqual(settings.vectorRetrievalChunkTokens, 300)
        XCTAssertEqual(settings.vectorChunkOverlap, 80)
        XCTAssertEqual(settings.ragResultLimit, 10)
        XCTAssertEqual(settings.ocrSource, AppSettings.OCRSource.local.rawValue)
        XCTAssertEqual(
            OllamaModelRecommendation.generationModels,
            ["qwen3.5:2b", "qwen3.5:4b", "qwen3.5:9b"]
        )
        XCTAssertEqual(
            OllamaModelRecommendation.embeddingModels,
            ["qwen3-embedding:0.6b", "qwen3-embedding:4b", "qwen3-embedding:8b"]
        )
    }

    func testChatContextWindowSupportsAutomaticModeAndClampsManualValues() {
        let settings = AppSettings(store: store)

        settings.setCloudContextWindowTokens(1)
        XCTAssertEqual(settings.cloudContextWindowTokens, 2_048)

        settings.setCloudContextWindowTokens(8_000_000)
        XCTAssertEqual(settings.cloudContextWindowTokens, 4_000_000)

        settings.setCloudContextWindowTokens(0)
        XCTAssertEqual(settings.cloudContextWindowTokens, 0)
        XCTAssertEqual(AppSettings(store: store).cloudContextWindowTokens, 0)
    }

    func testCloudContextWindowOverridesAreScopedToEachSelectedModel() {
        let settings = AppSettings(store: store)
        settings.setCloudBaseURL("https://gateway.example/v1")
        settings.setCloudModel("model-a")
        settings.setCloudContextWindowTokens(32_768)

        settings.setCloudModel("model-b")
        XCTAssertEqual(settings.cloudContextWindowTokens, 0)
        settings.setCloudContextWindowTokens(65_536)

        settings.setCloudModel("model-a")
        XCTAssertEqual(settings.cloudContextWindowTokens, 32_768)
        XCTAssertEqual(settings.cloudContextWindowOverride(), 32_768)
        XCTAssertEqual(settings.cloudContextWindowOverride(for: "model-b"), 65_536)

        let reloaded = AppSettings(store: store)
        XCTAssertEqual(reloaded.cloudContextWindowOverride(for: "model-a"), 32_768)
        XCTAssertEqual(reloaded.cloudContextWindowOverride(for: "model-b"), 65_536)
    }

    func testLegacyDefaultChunkSettingsMigrateTo600And80() {
        store.setSetting("vector_chunk_words", "800")
        store.setSetting("vector_chunk_overlap", "100")

        let settings = AppSettings(store: store)

        XCTAssertEqual(settings.vectorChunkWords, 600)
        XCTAssertEqual(settings.vectorChunkOverlap, 80)
    }

    func testCustomChunkSettingsAreNotChangedByDefaultMigration() {
        store.setSetting("vector_chunk_words", "800")
        store.setSetting("vector_chunk_overlap", "60")

        let settings = AppSettings(store: store)

        XCTAssertEqual(settings.vectorChunkWords, 800)
        XCTAssertEqual(settings.vectorChunkOverlap, 60)
    }

    func testRAGResultLimitPersistsAndClampsToSupportedRange() {
        let settings = AppSettings(store: store)

        settings.setRAGResultLimit(18)
        XCTAssertEqual(AppSettings(store: store).ragResultLimit, 18)

        settings.setRAGResultLimit(0)
        XCTAssertEqual(settings.ragResultLimit, 1)

        settings.setRAGResultLimit(100)
        XCTAssertEqual(settings.ragResultLimit, 30)
    }

    func testManagedOllamaProcessParsingOnlyMatchesFileNestExecutable() {
        let path = "/Users/test/Library/Application Support/FileNest/Ollama/Ollama.app/Contents/Resources/ollama"
        let processes = """
          101 \(path) serve
          102 /opt/homebrew/bin/ollama serve
          103 \(path) runner --model test
          104 \(path) serve --debug
        """

        XCTAssertEqual(
            OllamaServiceManager.managedServiceProcessIDs(from: processes, executablePath: path),
            [101, 104]
        )
    }

    func testManagedRerankerProcessParsingOnlyMatchesFileNestServer() {
        let scriptPath = "/Users/test/Library/Application Support/FileNest/Reranker/reranker_server.py"
        let processes = """
          201 /usr/bin/python3 \(scriptPath) --model /tmp/model --port 11435
          202 /usr/bin/python3 /tmp/reranker_server.py --model /tmp/model --port 11435
          203 /usr/bin/python3 \(scriptPath) --model /tmp/model --port 9999
          204 /usr/bin/python3 \(scriptPath) --port 11435 --model /tmp/model
        """

        XCTAssertEqual(
            RerankerServiceManager.managedServiceProcessIDs(
                from: processes,
                serverScriptPath: scriptPath
            ),
            [201, 204]
        )
    }

    func testOllamaCatalogProvidesDownloadSizesForRequiredModels() {
        XCTAssertEqual(
            OllamaModelCatalog.estimatedDownloadBytes(for: "qwen3-embedding:0.6b"),
            639_000_000
        )
        XCTAssertEqual(OllamaModelCatalog.estimatedDownloadBytes(for: "glm-ocr"), 2_200_000_000)
        XCTAssertEqual(OllamaModelCatalog.estimatedDownloadBytes(for: "qwen3.5:9b"), 6_600_000_000)
        XCTAssertNil(OllamaModelCatalog.estimatedDownloadBytes(for: "unknown:model"))
    }

    func testChatModelFilterExcludesEmbeddingAndOCRModels() {
        let chatModels = [
            "qwen3.5:9b",
            "qwen3-embedding:0.6b",
            "nomic-embed-text:latest",
            "glm-ocr:latest",
        ].filter {
            OllamaServiceManager.isChatModel(
                $0,
                embeddingModel: "qwen3-embedding:0.6b",
                ocrModel: "glm-ocr"
            )
        }

        XCTAssertEqual(chatModels, ["qwen3.5:9b"])
    }

    func testLegacyLocalOCRSourcesMigrateToUnifiedLocalSource() {
        store.setSetting("ocr_source", "ollama")
        store.setSetting("ollama_ocr_model", "glm-ocr")

        let migrated = AppSettings(store: store)

        XCTAssertEqual(migrated.ocrSource, AppSettings.OCRSource.local.rawValue)
        XCTAssertEqual(store.getSetting("ocr_source"), AppSettings.OCRSource.local.rawValue)
        XCTAssertEqual(store.getSetting("paddle_ocr_default_migration_v1"), "1")
    }

    func testFileTypeSelectorDefaultsCoverEveryBuiltInType() {
        let settings = AppSettings(store: store)
        let categorizedExtensions = Set(AppSettings.supportedFileExtensionCategories.flatMap(\.extensions))

        XCTAssertEqual(Set(settings.enabledExtensions), categorizedExtensions)
        XCTAssertEqual(Set(settings.vectorizeExtensions), Set(AppSettings.defaultVectorizeExtensions))
        XCTAssertTrue(Set(AppSettings.defaultVectorizeExtensions).isSubset(of: categorizedExtensions))
    }

    func testAutoOrganizeScheduleClampsUnsafeValues() {
        let settings = AppSettings(store: store)

        settings.setAutoOrganizeIntervalSeconds(5)
        settings.setAutoOrganizeBatchSize(1)

        XCTAssertEqual(settings.autoOrganizeIntervalSeconds, 30)
        XCTAssertEqual(settings.autoOrganizeBatchSize, 2)
        XCTAssertEqual(store.getSetting("auto_organize_interval_seconds"), "30")
        XCTAssertEqual(store.getSetting("auto_organize_batch_size"), "2")
    }

    func testVectorizationSettingsClampChunkAndOverlap() {
        let settings = AppSettings(store: store)

        settings.setVectorChunkWords(20)
        settings.setVectorChunkOverlap(200)

        XCTAssertEqual(settings.vectorChunkWords, 600)
        XCTAssertEqual(settings.vectorChunkOverlap, 200)
        XCTAssertTrue(settings.shouldVectorize(extension: "PDF"))
        XCTAssertTrue(settings.shouldVectorize(extension: "DOCX"))
        XCTAssertTrue(settings.shouldVectorize(extension: "xlsx"))
        XCTAssertTrue(settings.shouldVectorize(extension: "pptx"))
        XCTAssertTrue(settings.shouldVectorize(extension: "epub"))
        XCTAssertTrue(settings.shouldVectorize(extension: "odt"))
        settings.setMediaTranscriptionEnabled(false)
        XCTAssertFalse(settings.shouldVectorize(extension: "mp4"))
        settings.setMediaTranscriptionEnabled(true)
        XCTAssertTrue(settings.shouldTranscribeMedia(extension: "MP4"))
        XCTAssertTrue(settings.shouldVectorize(extension: "m4a"))
        settings.setAutoVectorize(false)
        XCTAssertFalse(settings.shouldVectorize(extension: "pdf"))
        XCTAssertFalse(settings.shouldVectorize(extension: "mp4"))
    }

    func testEmbeddingAndContentSignaturesTrackDifferentKindsOfChanges() {
        let settings = AppSettings(store: store)
        settings.setEmbeddingSource(AppSettings.EmbeddingSource.cloud.rawValue)
        settings.setCloudEmbeddingBaseURL("https://one.example/v1")
        settings.setCloudEmbeddingAPIKey("first-secret")
        let originalEmbedding = settings.embeddingSpaceSignature
        let originalContent = settings.contentProcessingSignature

        settings.setCloudEmbeddingAPIKey("rotated-secret")
        XCTAssertEqual(settings.embeddingSpaceSignature, originalEmbedding)
        XCTAssertEqual(settings.contentProcessingSignature, originalContent)

        settings.setCloudEmbeddingBaseURL("https://two.example/v1")
        XCTAssertEqual(settings.embeddingSpaceSignature, originalEmbedding)
        XCTAssertNotEqual(settings.contentProcessingSignature, originalContent)

        let endpointContent = settings.contentProcessingSignature
        settings.setVectorChunkWords(700)
        XCTAssertEqual(settings.embeddingSpaceSignature, originalEmbedding)
        XCTAssertNotEqual(settings.contentProcessingSignature, endpointContent)

        settings.setCloudEmbeddingModel("replacement-model")
        XCTAssertNotEqual(settings.embeddingSpaceSignature, originalEmbedding)
        XCTAssertEqual(settings.indexConfigurationSignature, settings.embeddingSpaceSignature)
    }

    func testInactiveCloudOCRSettingsDoNotInvalidateLocalContentProcessing() {
        let settings = AppSettings(store: store)
        XCTAssertEqual(settings.ocrSource, AppSettings.OCRSource.local.rawValue)
        let localSignature = settings.contentProcessingSignature

        settings.setCloudOCRFormat(AppSettings.CloudAPIFormat.anthropic.rawValue)
        settings.setCloudOCRBaseURL("https://unused.example/v1")
        settings.setCloudOCRModel("unused-model")

        XCTAssertEqual(settings.contentProcessingSignature, localSignature)

        settings.setOCRSource(AppSettings.OCRSource.cloud.rawValue)
        XCTAssertNotEqual(settings.contentProcessingSignature, localSignature)
    }

    func testContentChangeCategoriesIdentifyOnlyTheChangedConfigurationGroup() {
        let settings = AppSettings(store: store)
        let original = settings.indexContentCategorySignatures

        settings.setVectorChunkWords(700)
        XCTAssertEqual(
            changedCategories(from: original, to: settings.indexContentCategorySignatures),
            [.chunking]
        )

        let afterChunking = settings.indexContentCategorySignatures
        settings.setOllamaOCRModel("replacement-ocr")
        XCTAssertEqual(
            changedCategories(from: afterChunking, to: settings.indexContentCategorySignatures),
            [.ocr]
        )

        let afterOCR = settings.indexContentCategorySignatures
        settings.setOllamaHost("http://127.0.0.1:22468")
        XCTAssertEqual(
            changedCategories(from: afterOCR, to: settings.indexContentCategorySignatures),
            [.serviceEndpoint]
        )
    }

    private func changedCategories(
        from old: [IndexContentChangeCategory: String],
        to new: [IndexContentChangeCategory: String]
    ) -> Set<IndexContentChangeCategory> {
        Set(IndexContentChangeCategory.allCases.filter { old[$0] != new[$0] })
    }

    func testInvalidStoredChoicesNormalizeToSafeDefaults() {
        store.setSetting("classify_strategy", "ai")
        store.setSetting("llm_choice", "legacy-provider")
        store.setSetting("cloud_api_format", "legacy-format")
        store.setSetting("app_language", "legacy-language")
        store.setSetting("appearance", "legacy-appearance")

        let settings = AppSettings(store: store)

        XCTAssertEqual(settings.classifyStrategy, ClassificationStrategy.hybrid.rawValue)
        XCTAssertEqual(settings.llmChoice, AppSettings.LLMChoice.ollama.rawValue)
        XCTAssertEqual(settings.cloudAPIFormat, AppSettings.CloudAPIFormat.openAI.rawValue)
        XCTAssertEqual(settings.appLanguage, AppSettings.AppLanguage.system.rawValue)
        XCTAssertEqual(settings.appearance, AppSettings.AppAppearance.system.rawValue)
    }

    func testInvalidLLMChoiceSetterNormalizesAndPersistsDefault() {
        let settings = AppSettings(store: store)

        settings.setLLMChoice("unknown")

        XCTAssertEqual(settings.llmChoice, AppSettings.LLMChoice.ollama.rawValue)
        XCTAssertEqual(store.getSetting("llm_choice"), AppSettings.LLMChoice.ollama.rawValue)
    }

    func testInvalidLanguageAndAppearanceSettersNormalizeAndPersistDefaults() {
        let settings = AppSettings(store: store)

        settings.setAppLanguage("unknown-language")
        settings.setAppearance("unknown-appearance")

        XCTAssertEqual(settings.appLanguage, AppSettings.AppLanguage.system.rawValue)
        XCTAssertEqual(settings.appearance, AppSettings.AppAppearance.system.rawValue)
        XCTAssertEqual(store.getSetting("app_language"), AppSettings.AppLanguage.system.rawValue)
        XCTAssertEqual(store.getSetting("appearance"), AppSettings.AppAppearance.system.rawValue)
    }

    func testSelectedLanguageUsesRequestedLocale() {
        let settings = AppSettings(store: store)

        settings.setAppLanguage(AppSettings.AppLanguage.simplifiedChinese.rawValue)
        XCTAssertEqual(settings.selectedLocale.identifier, "zh-Hans")

        settings.setAppLanguage(AppSettings.AppLanguage.english.rawValue)
        XCTAssertEqual(settings.selectedLocale.identifier, "en")
    }

    func testSystemLanguageUsesSupportedLocaleAndFallsBackToEnglish() {
        XCTAssertEqual(
            AppSettings.AppLanguage.resolvedSystemLanguage(preferredLanguages: ["zh-Hans-CN"]),
            .simplifiedChinese
        )
        XCTAssertEqual(
            AppSettings.AppLanguage.resolvedSystemLanguage(preferredLanguages: ["en-SG"]),
            .english
        )
        XCTAssertEqual(
            AppSettings.AppLanguage.resolvedSystemLanguage(preferredLanguages: ["fr-FR"]),
            .english
        )
        XCTAssertEqual(
            AppSettings.AppLanguage.resolvedSystemLanguage(preferredLanguages: []),
            .english
        )
    }

    func testProviderFactoryFollowsLLMChoice() {
        let settings = AppSettings(store: store)

        settings.setLLMChoice(AppSettings.LLMChoice.none.rawValue)
        XCTAssertEqual(settings.makeLLMProvider().name, "none")

        settings.setLLMChoice(AppSettings.LLMChoice.cloud.rawValue)
        XCTAssertEqual(settings.makeLLMProvider().name, "openai-compatible")

        settings.setCloudAPIFormat(AppSettings.CloudAPIFormat.anthropic.rawValue)
        XCTAssertEqual(settings.makeLLMProvider().name, "anthropic")

        settings.setLLMChoice(AppSettings.LLMChoice.ollama.rawValue)
        XCTAssertEqual(settings.makeLLMProvider().name, "ollama")
    }

    func testEmbeddingAndOCRCanReuseChatCloudCredentials() {
        let settings = AppSettings(store: store)
        settings.setCloudBaseURL("https://chat.example/v1")
        settings.setCloudKey("chat-key")
        settings.setCloudEmbeddingBaseURL("https://embedding.example/v1")
        settings.setCloudEmbeddingAPIKey("embedding-key")
        settings.setCloudOCRBaseURL("https://ocr.example/v1")
        settings.setCloudOCRAPIKey("ocr-key")

        XCTAssertEqual(settings.effectiveCloudEmbeddingBaseURL, "https://embedding.example/v1")
        XCTAssertEqual(settings.effectiveCloudEmbeddingAPIKey, "embedding-key")
        XCTAssertEqual(settings.effectiveCloudOCRBaseURL, "https://ocr.example/v1")
        XCTAssertEqual(settings.effectiveCloudOCRAPIKey, "ocr-key")

        settings.setCloudEmbeddingReuseChatCredentials(true)
        settings.setCloudOCRReuseChatCredentials(true)

        XCTAssertEqual(settings.effectiveCloudEmbeddingBaseURL, "https://chat.example/v1")
        XCTAssertEqual(settings.effectiveCloudEmbeddingAPIKey, "chat-key")
        XCTAssertEqual(settings.effectiveCloudOCRBaseURL, "https://chat.example/v1")
        XCTAssertEqual(settings.effectiveCloudOCRAPIKey, "chat-key")
    }

    func testCloudServiceRootURLsAutomaticallyUseV1Endpoints() {
        let settings = AppSettings(store: store)

        settings.setCloudBaseURL("https://api.autogateway.cc")
        settings.setCloudEmbeddingBaseURL("https://embedding.example/")
        settings.setCloudOCRBaseURL("https://ocr.example")

        XCTAssertEqual(settings.cloudBaseURL, "https://api.autogateway.cc")
        XCTAssertEqual(settings.effectiveCloudBaseURL, "https://api.autogateway.cc/v1")
        XCTAssertEqual(settings.effectiveCloudEmbeddingBaseURL, "https://embedding.example/v1")
        XCTAssertEqual(settings.effectiveCloudOCRBaseURL, "https://ocr.example/v1")

        settings.setCloudBaseURL("https://gateway.example/custom-api")
        XCTAssertEqual(settings.effectiveCloudBaseURL, "https://gateway.example/custom-api")
    }

    func testSearchOnlyProviderUsesSelectedApplicationLanguage() async throws {
        let settings = AppSettings(store: store)
        settings.setLLMChoice(AppSettings.LLMChoice.none.rawValue)
        settings.setAppLanguage(AppSettings.AppLanguage.english.rawValue)

        let english = try await settings.makeLLMProvider().chat(
            [ChatTurn(role: .user, content: "Find my contract")],
            context: nil
        )

        XCTAssertEqual(english, "Chat is disabled.\nYour question: Find my contract")

        settings.setAppLanguage(AppSettings.AppLanguage.simplifiedChinese.rawValue)
        let chinese = try await settings.makeLLMProvider().chat(
            [ChatTurn(role: .user, content: "Find contracts")],
            context: nil
        )

        XCTAssertEqual(
            chinese,
            settings.localizedFormat("Chat is disabled.\nYour question: %@", "Find contracts")
        )
        XCTAssertNotEqual(chinese, english)
    }

    func testEmbeddingAndOCRFactoriesFollowIndependentSources() {
        let settings = AppSettings(store: store)
        settings.setOllamaEmbeddingModel("qwen3-embedding:4b")
        XCTAssertEqual(settings.makeEmbeddingProvider().name, "ollama:qwen3-embedding:4b")
        XCTAssertEqual(
            settings.makeOCRProvider()?.name,
            "paddleocr:PP-OCRv6->ollama-ocr:glm-ocr"
        )

        settings.setEmbeddingSource(AppSettings.EmbeddingSource.cloud.rawValue)
        settings.setCloudEmbeddingModel("cloud-embed")
        XCTAssertEqual(settings.makeEmbeddingProvider().name, "cloud-embedding:cloud-embed")

        settings.setOCRSource(AppSettings.OCRSource.cloud.rawValue)
        settings.setCloudOCRFormat(AppSettings.CloudAPIFormat.anthropic.rawValue)
        settings.setCloudOCRModel("cloud-vision")
        XCTAssertEqual(settings.makeOCRProvider()?.name, "cloud-ocr:anthropic:cloud-vision")

        settings.setOCRSource(AppSettings.OCRSource.disabled.rawValue)
        XCTAssertNil(settings.makeOCRProvider())
    }

    func testChangingCloudFormatUpdatesOnlyBuiltInDefaults() {
        let settings = AppSettings(store: store)

        settings.setCloudAPIFormat(AppSettings.CloudAPIFormat.anthropic.rawValue)
        XCTAssertEqual(settings.cloudBaseURL, "https://api.anthropic.com/v1")
        XCTAssertEqual(settings.cloudModel, "claude-sonnet-5")

        settings.setCloudBaseURL("https://gateway.example/v1")
        settings.setCloudModel("custom-model")
        settings.setCloudAPIFormat(AppSettings.CloudAPIFormat.openAI.rawValue)
        XCTAssertEqual(settings.cloudBaseURL, "https://gateway.example/v1")
        XCTAssertEqual(settings.cloudModel, "custom-model")
    }

    func testOllamaRecommendationUsesLargestSafeMemoryTier() {
        let cases: [(memory: Int, profileID: String)] = [
            (4, "memory-8"),
            (8, "memory-8"),
            (15, "memory-8"),
            (16, "memory-16"),
            (23, "memory-16"),
            (24, "memory-24"),
            (31, "memory-24"),
            (32, "memory-32"),
            (63, "memory-32"),
            (64, "memory-64"),
            (128, "memory-64"),
        ]

        for item in cases {
            XCTAssertEqual(
                OllamaModelRecommendation.recommended(forMemoryGB: item.memory).id,
                item.profileID,
                "Unexpected profile for \(item.memory)GB"
            )
        }
    }

    func testOllamaRecommendationIsAlwaysFirstWithoutDuplicates() {
        let ordered = OllamaModelRecommendation.orderedProfiles(forMemoryGB: 32)

        XCTAssertEqual(ordered.first?.id, "memory-32")
        XCTAssertEqual(ordered.count, OllamaModelRecommendation.profiles.count)
        XCTAssertEqual(Set(ordered.map(\.id)).count, ordered.count)
    }

    func testManagedPythonArtifactsAreArchitectureSpecificAndPinned() {
        let arm = ManagedPythonRuntime.artifact(machine: "arm64")
        let intel = ManagedPythonRuntime.artifact(machine: "x86_64")

        XCTAssertEqual(arm?.version, ManagedPythonRuntime.version)
        XCTAssertTrue(arm?.downloadURL.lastPathComponent.contains("aarch64-apple-darwin") == true)
        XCTAssertEqual(arm?.sha256.count, 64)
        XCTAssertTrue(intel?.downloadURL.lastPathComponent.contains("x86_64-apple-darwin") == true)
        XCTAssertEqual(intel?.sha256.count, 64)
        XCTAssertNil(ManagedPythonRuntime.artifact(machine: "unsupported"))
    }

    func testManagedFFmpegArtifactsAreArchitectureSpecificAndPinned() {
        let arm = FFmpegServiceManager.artifact(machine: "arm64")
        let intel = FFmpegServiceManager.artifact(machine: "x86_64")

        XCTAssertEqual(arm?.version, FFmpegServiceManager.pinnedVersion)
        XCTAssertEqual(arm?.downloadURL.lastPathComponent, "ffmpeg-darwin-arm64")
        XCTAssertEqual(arm?.sha256.count, 64)
        XCTAssertEqual(intel?.downloadURL.lastPathComponent, "ffmpeg-darwin-x64")
        XCTAssertEqual(intel?.sha256.count, 64)
        XCTAssertNil(FFmpegServiceManager.artifact(machine: "unsupported"))
    }

    func testFFmpegManagedArtifactVersionUsesVerifiedPackageManifest() throws {
        let root = temporaryDirectory.appendingPathComponent("MediaTools", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("6.1.1\n".utf8).write(to: root.appendingPathComponent("version.txt"))

        XCTAssertEqual(FFmpegServiceManager.installedArtifactVersion(at: root), "6.1.1")
    }

    func testManagedRuntimeEnvironmentKeepsCachesInsideFileNest() {
        let environment = ManagedRuntimePaths.managedEnvironment()
        let root = ManagedRuntimePaths.applicationSupportRoot.path

        XCTAssertEqual(environment["PYTHONNOUSERSITE"], "1")
        XCTAssertNil(environment["PYTHONHOME"])
        XCTAssertNil(environment["PYTHONPATH"])
        XCTAssertEqual(
            environment["PATH"],
            [
                ManagedPythonRuntime.executable.deletingLastPathComponent().path,
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin"
            ].joined(separator: ":")
        )
        XCTAssertTrue(environment["HF_HOME"]?.hasPrefix(root) == true)
        XCTAssertTrue(environment["PADDLE_HOME"]?.hasPrefix(root) == true)
        XCTAssertTrue(environment["PADDLEX_HOME"]?.hasPrefix(root) == true)
    }

    @MainActor
    func testDownloadCoordinatorTracksExternalDownloadsInOneQueue() {
        let coordinator = DownloadCoordinator(
            storageRoot: temporaryDirectory.appendingPathComponent("downloads", isDirectory: true)
        )
        let sourceURL = URL(string: "https://example.test/models/qwen3")!

        coordinator.beginExternalDownload(
            identifier: "ollama-model-qwen3",
            displayName: "qwen3",
            sourceURL: sourceURL
        )
        coordinator.updateExternalDownload(
            identifier: "ollama-model-qwen3",
            bytesReceived: 250,
            bytesExpected: 1_000
        )

        XCTAssertEqual(coordinator.downloads.count, 1)
        XCTAssertEqual(coordinator.downloads.first?.phase, .downloading)
        XCTAssertEqual(coordinator.downloads.first?.fractionCompleted, 0.25)
        XCTAssertTrue(coordinator.hasActiveDownloads)

        coordinator.finishExternalDownload(identifier: "ollama-model-qwen3")

        XCTAssertEqual(coordinator.downloads.first?.phase, .completed)
        XCTAssertFalse(coordinator.hasActiveDownloads)
        coordinator.clearFinishedDownloads()
        XCTAssertTrue(coordinator.downloads.isEmpty)
    }

    func testDownloadSnapshotClampsReportedProgress() {
        let snapshot = ManagedDownloadSnapshot(
            id: "test",
            displayName: "Test",
            sourceURL: URL(string: "https://example.test/file")!,
            phase: .downloading,
            bytesReceived: 1_500,
            bytesExpected: 1_000,
            updatedAt: Date()
        )

        XCTAssertEqual(snapshot.fractionCompleted, 1)
    }
}
