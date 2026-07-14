import XCTest
@testable import FileNest

final class ChatServiceTests: XCTestCase {
    private final class FailingEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name = "failing"
        let dimension = 2

        func embed(_ text: String) async throws -> [Float] {
            throw URLError(.cannotConnectToHost)
        }
    }

    private final class StubLLMProvider: LLMProvider, @unchecked Sendable {
        let name = "stub"

        func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
            "stub reply"
        }
    }

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

    func testEmbeddingFailureFallsBackToKeywordSearchAndPersistsReference() async throws {
        let matchingId = try insertFile(named: "agreement.pdf", title: "年度合同")
        _ = try insertFile(named: "photo.jpg", title: "旅行照片")
        let chat = makeChatService()

        let response = await chat.ask("合同")

        XCTAssertEqual(response.content, "stub reply")
        XCTAssertEqual(response.relatedFiles.map(\.id), [matchingId])
        let ids = try decodeRelatedIds(response)
        XCTAssertEqual(ids, [matchingId])

        let history = chat.loadHistory()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.last?.relatedFiles.map(\.id), [matchingId])
    }

    func testKeywordFallbackLimitsContextToFiveFiles() async throws {
        for index in 0..<7 {
            _ = try insertFile(named: "contract-\(index).txt", title: "合同 \(index)")
        }
        let chat = makeChatService()

        let response = await chat.ask("合同")

        XCTAssertEqual(response.relatedFiles.count, 5)
        XCTAssertEqual(try decodeRelatedIds(response).count, 5)
    }

    private func makeChatService() -> ChatService {
        ChatService(
            store: store,
            settings: .shared,
            embedder: FailingEmbedder(),
            llmProvider: StubLLMProvider()
        )
    }

    private func insertFile(named name: String, title: String) throws -> Int64 {
        try store.upsertFile(FileRecord(
            id: nil,
            path: temporaryDirectory.appendingPathComponent(name).path,
            name: name,
            ext: URL(fileURLWithPath: name).pathExtension,
            size: 1,
            mtime: Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: temporaryDirectory.path,
            indexedAt: Date(),
            contentHash: nil,
            title: title,
            contentText: title
        ))
    }

    private func decodeRelatedIds(_ message: ChatMessage) throws -> [Int64] {
        let json = try XCTUnwrap(message.relatedFileIds)
        return try JSONDecoder().decode([Int64].self, from: Data(json.utf8))
    }
}
