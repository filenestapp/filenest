import XCTest
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

    func testSettingsPersistAcrossInstances() {
        let settings = AppSettings(store: store)
        settings.setWatchDirs(["/tmp/Downloads", "/tmp/Desktop"])
        settings.setEnabledExtensions(["pdf", "md"])
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
        settings.setOnboardingCompleted(true)
        settings.setUpdateFeedURL("https://updates.example.com/appcast.xml")
        settings.setAutomaticUpdateChecks(false)
        settings.setAutomaticallyDownloadsUpdates(true)

        let reloaded = AppSettings(store: store)

        XCTAssertEqual(reloaded.watchDirs, ["/tmp/Downloads", "/tmp/Desktop"])
        XCTAssertEqual(reloaded.enabledExtensions, ["pdf", "md"])
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
        XCTAssertEqual(reloaded.vectorChunkOverlap, 50)
        XCTAssertFalse(reloaded.doclingEnabled)
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
        XCTAssertTrue(reloaded.onboardingCompleted)
        XCTAssertEqual(reloaded.updateFeedURL, "https://updates.example.com/appcast.xml")
        XCTAssertFalse(reloaded.automaticUpdateChecks)
        XCTAssertTrue(reloaded.automaticallyDownloadsUpdates)
    }

    @MainActor
    func testUpdateServiceRequiresSecureAppcastURL() {
        let settings = AppSettings(store: store)
        let updates = AppUpdateService(settings: settings, enabled: false)

        updates.setFeedURL("http://updates.example.com/appcast.xml")
        XCTAssertFalse(updates.hasValidFeedURL)
        XCTAssertEqual(updates.status, .notConfigured)

        updates.setFeedURL("https://updates.example.com/appcast.xml")
        XCTAssertTrue(updates.hasValidFeedURL)
        XCTAssertEqual(updates.status, .ready)
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

    func testOnboardingIsIncompleteUntilExplicitlyFinished() {
        let settings = AppSettings(store: store)
        XCTAssertFalse(settings.onboardingCompleted)

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
        settings.setAutoVectorize(false)
        XCTAssertFalse(settings.shouldVectorize(extension: "pdf"))
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
}
