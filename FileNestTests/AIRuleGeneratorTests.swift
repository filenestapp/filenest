import XCTest
@testable import FileNest

final class AIRuleGeneratorTests: XCTestCase {
    func testParseNormalizesGeneratedRuleAndClampsPriority() throws {
        let response = """
        ```json
        {"name":" Customer Contracts ","extensions":[".PDF","docx","PDF","bad value"],"targetFolder":" Contracts ","priority":120}
        ```
        """

        let rule = try AIRuleGenerator(provider: StubProvider(response: response)).parse(response: response)

        XCTAssertEqual(rule.name, "Customer Contracts")
        XCTAssertEqual(rule.type, RuleType.ai.rawValue)
        XCTAssertEqual(rule.pattern, "docx,pdf")
        XCTAssertEqual(rule.targetFolder, "Contracts")
        XCTAssertEqual(rule.priority, 100)
        XCTAssertTrue(rule.enabled)
    }

    func testGenerateUsesProviderResponse() async throws {
        let provider = StubProvider(response: """
        {"name":"Image Archive","extensions":["jpg","png"],"targetFolder":"Image Assets","priority":75}
        """)

        let rule = try await AIRuleGenerator(provider: provider).generate(from: "Organize images")

        XCTAssertEqual(rule.name, "Image Archive")
        XCTAssertEqual(rule.pattern, "jpg,png")
        XCTAssertEqual(provider.receivedMessages.map(\.role), [.system, .user])
    }

    func testUnsafeTargetFolderIsRejected() {
        let response = """
        {"name":"Bad","extensions":["pdf"],"targetFolder":"../Outside","priority":1}
        """

        XCTAssertThrowsError(try AIRuleGenerator(provider: StubProvider(response: response)).parse(response: response)) {
            XCTAssertEqual($0 as? AIRuleGeneratorError, .unsafeTargetFolder)
        }
    }

    func testOllamaModelInfoDecodesTagsPayloadShape() throws {
        let data = try XCTUnwrap("""
        {"name":"qwen2.5:7b","size":4680000000,"modified_at":"2026-07-14T00:00:00Z","details":{"family":"qwen2","parameter_size":"7.6B","quantization_level":"Q4_K_M"}}
        """.data(using: .utf8))

        let model = try JSONDecoder().decode(OllamaModelInfo.self, from: data)

        XCTAssertEqual(model.name, "qwen2.5:7b")
        XCTAssertEqual(model.size, 4_680_000_000)
        XCTAssertEqual(model.modifiedAt, "2026-07-14T00:00:00Z")
        XCTAssertEqual(model.details?.family, "qwen2")
        XCTAssertEqual(model.details?.parameterSize, "7.6B")
        XCTAssertEqual(model.details?.quantizationLevel, "Q4_K_M")
    }

    func testOllamaShowMetadataParsesModelDetailsAndExplicitContext() throws {
        let data = try XCTUnwrap("""
        {
          "details":{"format":"gguf","family":"qwen3","parameter_size":"9.2B","quantization_level":"Q4_K_M"},
          "model_info":{"general.architecture":"qwen3","qwen3.context_length":262144,"qwen3.embedding_length":4096},
          "parameters":"temperature 0.6\\nnum_ctx 32768"
        }
        """.data(using: .utf8))

        let details = try XCTUnwrap(OllamaModelMetadataParser.details(from: data))

        XCTAssertEqual(details.parameterSize, "9.2B")
        XCTAssertEqual(details.architecture, "qwen3")
        XCTAssertEqual(details.contextLength, 32_768)
        XCTAssertEqual(details.embeddingLength, 4_096)
        XCTAssertTrue(details.contextLengthIsExplicit)
    }

    func testOllamaMetadataCacheUsesModelModificationVersion() async {
        let host = "http://cache-\(UUID().uuidString).test"
        let details = OllamaModelDetails(parameterSize: "9B", contextLength: 32_768)
        await OllamaModelMetadataCache.shared.store(
            details,
            host: host,
            model: "qwen3.5:9b",
            modifiedAt: "v1"
        )

        let cached = await OllamaModelMetadataCache.shared.details(
            host: host,
            model: "qwen3.5:9b",
            modifiedAt: "v1"
        )
        let stale = await OllamaModelMetadataCache.shared.details(
            host: host,
            model: "qwen3.5:9b",
            modifiedAt: "v2"
        )

        XCTAssertEqual(cached, details)
        XCTAssertNil(stale)
    }

    func testOllamaInstalledModelMatchingTreatsLatestAsDefaultTag() {
        XCTAssertTrue(OllamaServiceManager.modelNamesMatch("glm-ocr:latest", "glm-ocr"))
        XCTAssertTrue(OllamaServiceManager.modelNamesMatch(
            "QWEN3-EMBEDDING:0.6B",
            "qwen3-embedding:0.6b"
        ))
        XCTAssertFalse(OllamaServiceManager.modelNamesMatch(
            "qwen3-embedding:4b",
            "qwen3-embedding:0.6b"
        ))
    }

    func testSubfolderClassifierAcceptsSafeJSONAndRejectsPaths() {
        XCTAssertEqual(
            FileSubfolderClassifier.parse("```json\n{\"folder\":\"Project Materials\"}\n```"),
            "Project Materials"
        )
        XCTAssertNil(FileSubfolderClassifier.parse("{\"folder\":\"../Outside\"}"))
        XCTAssertNil(FileSubfolderClassifier.parse("{\"folder\":\"A\"}"))
    }
}

private final class StubProvider: LLMProvider {
    let name = "stub"
    let response: String
    private(set) var receivedMessages: [ChatTurn] = []

    init(response: String) {
        self.response = response
    }

    func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
        receivedMessages = messages
        return response
    }
}
