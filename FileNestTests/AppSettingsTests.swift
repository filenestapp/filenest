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
        settings.setCloudKey("test-key")
        settings.setCloudBaseURL("https://example.test/v1")
        settings.setCloudModel("test-cloud")
        settings.setAutoOrganize(false)

        let reloaded = AppSettings(store: store)

        XCTAssertEqual(reloaded.watchDirs, ["/tmp/Downloads", "/tmp/Desktop"])
        XCTAssertEqual(reloaded.enabledExtensions, ["pdf", "md"])
        XCTAssertFalse(reloaded.excludeHidden)
        XCTAssertEqual(reloaded.classifyStrategy, ClassificationStrategy.rule.rawValue)
        XCTAssertEqual(reloaded.llmChoice, AppSettings.LLMChoice.cloud.rawValue)
        XCTAssertEqual(reloaded.ollamaHost, "http://localhost:11434")
        XCTAssertEqual(reloaded.ollamaModel, "test-ollama")
        XCTAssertEqual(reloaded.cloudAPIKey, "test-key")
        XCTAssertEqual(reloaded.cloudBaseURL, "https://example.test/v1")
        XCTAssertEqual(reloaded.cloudModel, "test-cloud")
        XCTAssertFalse(reloaded.autoOrganize)
    }

    func testInvalidStoredChoicesNormalizeToSafeDefaults() {
        store.setSetting("classify_strategy", "ai")
        store.setSetting("llm_choice", "legacy-provider")

        let settings = AppSettings(store: store)

        XCTAssertEqual(settings.classifyStrategy, ClassificationStrategy.hybrid.rawValue)
        XCTAssertEqual(settings.llmChoice, AppSettings.LLMChoice.ollama.rawValue)
    }

    func testInvalidLLMChoiceSetterNormalizesAndPersistsDefault() {
        let settings = AppSettings(store: store)

        settings.setLLMChoice("unknown")

        XCTAssertEqual(settings.llmChoice, AppSettings.LLMChoice.ollama.rawValue)
        XCTAssertEqual(store.getSetting("llm_choice"), AppSettings.LLMChoice.ollama.rawValue)
    }

    func testProviderFactoryFollowsLLMChoice() {
        let settings = AppSettings(store: store)

        settings.setLLMChoice(AppSettings.LLMChoice.none.rawValue)
        XCTAssertEqual(settings.makeLLMProvider().name, "none")

        settings.setLLMChoice(AppSettings.LLMChoice.cloud.rawValue)
        XCTAssertEqual(settings.makeLLMProvider().name, "openai-compatible")

        settings.setLLMChoice(AppSettings.LLMChoice.ollama.rawValue)
        XCTAssertEqual(settings.makeLLMProvider().name, "ollama")
    }
}
