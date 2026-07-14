import XCTest
import CoreText
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

    func testPDFExtractionReadsTextAndMetadataTitle() throws {
        let url = temporaryDirectory.appendingPathComponent("contract.pdf")
        try writePDF(text: "Annual contract body", title: "Contract 2026", to: url)

        let extracted = ContentExtractor.extract(url: url, ext: "PDF")

        XCTAssertEqual(extracted.title, "Contract 2026")
        XCTAssertTrue(extracted.text.contains("Annual contract body"))
    }

    func testPDFExtractionFallsBackToFilenameForBlankMetadataTitle() throws {
        let url = temporaryDirectory.appendingPathComponent("untitled.pdf")
        try writePDF(text: "Searchable PDF text", title: "   ", to: url)

        let extracted = ContentExtractor.extract(url: url, ext: "pdf")

        XCTAssertEqual(extracted.title, "untitled")
        XCTAssertTrue(extracted.text.contains("Searchable PDF text"))
    }

    private func writePDF(text: String, title: String, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let metadata = [kCGPDFContextTitle as String: title] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, metadata) else {
            throw CocoaError(.fileWriteUnknown)
        }

        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 720)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributes = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
    }
}
