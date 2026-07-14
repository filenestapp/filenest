import XCTest
@testable import FileNest

final class ContentExtractorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testPlainTextExtractionTruncatesToMaximumCharacterCount() throws {
        let url = temporaryDirectory.appendingPathComponent("notes.txt")
        try Data(String(repeating: "文", count: ContentExtractor.maxChars + 100).utf8).write(to: url)

        let extracted = ContentExtractor.extract(url: url, ext: "TXT")

        XCTAssertEqual(extracted.title, "notes")
        XCTAssertEqual(extracted.text.count, ContentExtractor.maxChars)
    }

    func testMissingTextFileFallsBackToFilename() {
        let url = temporaryDirectory.appendingPathComponent("missing.md")

        let extracted = ContentExtractor.extract(url: url, ext: "md")

        XCTAssertEqual(extracted.title, "missing.md")
        XCTAssertEqual(extracted.text, "missing.md")
    }

    func testBinaryFileUsesFilenameAsSearchableText() {
        let url = temporaryDirectory.appendingPathComponent("summer-photo.jpg")

        let extracted = ContentExtractor.extract(url: url, ext: "jpg")

        XCTAssertEqual(extracted.title, "summer-photo")
        XCTAssertEqual(extracted.text, "summer-photo.jpg")
    }
}
