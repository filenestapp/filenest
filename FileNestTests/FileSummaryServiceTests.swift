import XCTest
@testable import FileNest

final class FileSummaryServiceTests: XCTestCase {
    private final class StubProvider: LLMProvider, @unchecked Sendable {
        let name = "stub"
        private(set) var lastPrompt = ""

        func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
            lastPrompt = messages.last?.content ?? ""
            return "This project delivery note covers goals, schedule, and acceptance criteria."
        }
    }

    private final class VisionStubProvider: LLMProvider, @unchecked Sendable {
        let name = "vision-stub"
        private(set) var imageRequestCount = 0
        private(set) var lastImagePrompt = ""

        func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
            "Text summary"
        }

        func chatWithImage(
            prompt: String,
            imageData: Data,
            mimeType: String,
            context: String?
        ) async throws -> String {
            imageRequestCount += 1
            lastImagePrompt = prompt
            XCTAssertFalse(imageData.isEmpty)
            XCTAssertEqual(mimeType, "image/jpeg")
            return "The image shows a blue company seal with the company name and registration number."
        }
    }

    private struct OCRStubProvider: OCRProvider {
        let name = "ocr-stub"
        let text: String

        func recognize(imageData: Data, mimeType: String) async throws -> String {
            text
        }
    }

    private final class StreamingStubProvider: LLMProvider, @unchecked Sendable {
        let name = "streaming-stub"
        private(set) var lastPrompt = ""

        func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
            "First sentence. Second sentence. Third sentence. The fourth sentence should not appear."
        }

        func streamChat(
            _ messages: [ChatTurn],
            context: String?
        ) -> AsyncThrowingStream<String, Error> {
            lastPrompt = messages.last?.content ?? ""
            return AsyncThrowingStream { continuation in
                continuation.yield("First sentence. Second")
                continuation.yield(" sentence. Third sentence.")
                continuation.yield(" The fourth sentence should not appear.")
                continuation.finish()
            }
        }
    }

    func testSummaryUsesExtractedFileContentAndReturnsEditableNote() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("brief.md")
        try Data("Q4 release acceptance checklist".utf8).write(to: url)
        let store = SQLiteStore(path: directory.appendingPathComponent("test.sqlite").path)
        let provider = StubProvider()
        let service = FileSummaryService(settings: AppSettings(store: store), provider: provider)
        let file = FileRecord(
            id: 1,
            path: url.path,
            name: url.lastPathComponent,
            ext: "md",
            size: 32,
            mtime: Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: directory.path,
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        )

        let summary = try await service.summarize(file: file)

        XCTAssertEqual(summary, "This project delivery note covers goals, schedule, and acceptance criteria.")
        XCTAssertTrue(provider.lastPrompt.contains("Q4 release acceptance checklist"))
        XCTAssertTrue(provider.lastPrompt.contains("brief.md"))
    }

    func testSummaryPrefersAlreadyIndexedContentOverParsingFileAgain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("indexed.md")
        try Data("stale source text".utf8).write(to: url)
        let store = SQLiteStore(path: directory.appendingPathComponent("test.sqlite").path)
        let provider = StubProvider()
        let service = FileSummaryService(settings: AppSettings(store: store), provider: provider)
        let file = FileRecord(
            id: 1,
            path: url.path,
            name: url.lastPathComponent,
            ext: "md",
            size: 32,
            mtime: Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: directory.path,
            indexedAt: Date(),
            contentHash: "hash",
            title: "Indexed title",
            contentText: "DOCLING INDEXED CONTENT"
        )

        _ = try await service.summarize(file: file)

        XCTAssertTrue(provider.lastPrompt.contains("DOCLING INDEXED CONTENT"))
        XCTAssertFalse(provider.lastPrompt.contains("stale source text"))
    }

    func testImageWithoutIndexedOCRUsesActualImageInput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stamp.png")
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2ZQAAAABJRU5ErkJggg=="
        ) ?? Data()
        try png.write(to: url)
        let store = SQLiteStore(path: directory.appendingPathComponent("test.sqlite").path)
        let provider = VisionStubProvider()
        let service = FileSummaryService(settings: AppSettings(store: store), provider: provider)
        let metadata = ContentExtractor.extract(url: url, ext: "png").text
        let file = FileRecord(
            id: 1,
            path: url.path,
            name: url.lastPathComponent,
            ext: "png",
            size: Int64(png.count),
            mtime: Date(),
            category: FileCategory.images.rawValue,
            sourceDir: directory.path,
            indexedAt: Date(),
            contentHash: "hash",
            title: "stamp",
            contentText: metadata
        )

        let summary = try await service.summarize(file: file)

        XCTAssertEqual(summary, "The image shows a blue company seal with the company name and registration number.")
        XCTAssertEqual(provider.imageRequestCount, 1)
        XCTAssertTrue(provider.lastImagePrompt.contains("stamp.png"))
    }

    func testImageWithIndexedOCRReusesTextWithoutSendingImage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("receipt.png")
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2ZQAAAABJRU5ErkJggg=="
        ) ?? Data()
        try png.write(to: url)
        let store = SQLiteStore(path: directory.appendingPathComponent("test.sqlite").path)
        let provider = VisionStubProvider()
        let service = FileSummaryService(settings: AppSettings(store: store), provider: provider)
        let file = FileRecord(
            id: 1,
            path: url.path,
            name: url.lastPathComponent,
            ext: "png",
            size: Int64(png.count),
            mtime: Date(),
            category: FileCategory.images.rawValue,
            sourceDir: directory.path,
            indexedAt: Date(),
            contentHash: "hash",
            title: "Receipt",
            contentText: "OCR: Invoice total SGD 128.40, paid on 16 July 2026."
        )

        _ = try await service.summarize(file: file)

        XCTAssertEqual(provider.imageRequestCount, 0)
    }

    func testImageFallsBackToOCRWhenTextModelHasNoVisionCapability() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scan.png")
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2ZQAAAABJRU5ErkJggg=="
        ) ?? Data()
        try png.write(to: url)
        let store = SQLiteStore(path: directory.appendingPathComponent("test.sqlite").path)
        let provider = StubProvider()
        let service = FileSummaryService(
            settings: AppSettings(store: store),
            provider: provider,
            ocrProvider: OCRStubProvider(text: "BRITECH CLOUD PTE. LTD. UEN 202344212C")
        )
        let file = FileRecord(
            id: 1,
            path: url.path,
            name: url.lastPathComponent,
            ext: "png",
            size: Int64(png.count),
            mtime: Date(),
            category: FileCategory.images.rawValue,
            sourceDir: directory.path,
            indexedAt: Date(),
            contentHash: "hash",
            title: "scan",
            contentText: ContentExtractor.extract(url: url, ext: "png").text
        )

        _ = try await service.summarize(file: file)

        XCTAssertTrue(provider.lastPrompt.contains("BRITECH CLOUD PTE. LTD. UEN 202344212C"))
    }

    func testSummaryStreamsCumulativeTypewriterUpdatesAndLimitsOutputToThreeSentences() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stream.md")
        try Data("streaming summary source".utf8).write(to: url)
        let store = SQLiteStore(path: directory.appendingPathComponent("test.sqlite").path)
        let provider = StreamingStubProvider()
        let service = FileSummaryService(
            settings: AppSettings(store: store),
            provider: provider,
            typingDelayNanoseconds: 0
        )
        let file = FileRecord(
            id: 1,
            path: url.path,
            name: url.lastPathComponent,
            ext: "md",
            size: 24,
            mtime: Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: directory.path,
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        )

        var updates = [String]()
        for try await update in service.streamSummary(file: file) {
            updates.append(update)
        }

        XCTAssertGreaterThan(updates.count, 10)
        XCTAssertEqual(updates.last, "First sentence. Second sentence. Third sentence.")
        XCTAssertFalse(updates.contains { $0.contains("fourth sentence") })
        XCTAssertTrue(zip(updates, updates.dropFirst()).allSatisfy { $0.count <= $1.count })
        XCTAssertTrue(
            provider.lastPrompt.contains("1–3 sentences")
                || provider.lastPrompt.contains("1–3 sentences")
        )
        XCTAssertFalse(provider.lastPrompt.contains("2–4"))
    }
}
