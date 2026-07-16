import XCTest
import AppKit
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
        try Data(String(repeating: "x", count: ContentExtractor.maxChars + 100).utf8).write(to: url)

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

    func testImageExtractionIncludesDimensionsWithoutLocationMetadata() throws {
        let url = temporaryDirectory.appendingPathComponent("sample.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 3,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)

        let extracted = ContentExtractor.extract(url: url, ext: "PNG")

        XCTAssertEqual(extracted.title, "sample")
        XCTAssertTrue(extracted.text.contains("Dimensions: 2 × 3 pixels"))
        XCTAssertFalse(extracted.text.localizedCaseInsensitiveContains("GPS"))
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

    func testDOCXExtractionReadsBodyHeadersAndMetadataTitleLocally() throws {
        let url = temporaryDirectory.appendingPathComponent("proposal.docx")
        try ArchiveTestSupport.write(entries: [
            "docProps/core.xml": xml("<dc:title>2026 Proposal</dc:title>", namespaces: true),
            "word/document.xml": xml("<w:p><w:r><w:t>Project North Star</w:t></w:r></w:p>", namespaces: true),
            "word/header1.xml": xml("<w:p><w:r><w:t>Confidential Header</w:t></w:r></w:p>", namespaces: true),
        ], to: url)

        let extracted = ContentExtractor.extract(url: url, ext: "DOCX")

        XCTAssertEqual(extracted.title, "2026 Proposal")
        XCTAssertTrue(extracted.text.contains("Project North Star"))
        XCTAssertTrue(extracted.text.contains("Confidential Header"))
    }

    func testXLSXExtractionReadsSharedStringsAndCellValues() throws {
        let url = temporaryDirectory.appendingPathComponent("forecast.xlsx")
        try ArchiveTestSupport.write(entries: [
            "xl/sharedStrings.xml": xml("<si><t>Revenue forecast</t></si>"),
            "xl/worksheets/sheet1.xml": xml("<row><c><v>4200</v></c></row>"),
        ], to: url)

        let extracted = ContentExtractor.extract(url: url, ext: "xlsx")

        XCTAssertTrue(extracted.text.contains("Revenue forecast"))
        XCTAssertTrue(extracted.text.contains("4200"))
    }

    func testPPTXExtractionReadsSlidesAndSpeakerNotesInOrder() throws {
        let url = temporaryDirectory.appendingPathComponent("launch.pptx")
        try ArchiveTestSupport.write(entries: [
            "ppt/slides/slide1.xml": xml("<a:p><a:r><a:t>Launch strategy</a:t></a:r></a:p>", namespaces: true),
            "ppt/notesSlides/notesSlide1.xml": xml("<a:p><a:r><a:t>Discuss APAC rollout</a:t></a:r></a:p>", namespaces: true),
        ], to: url)

        let extracted = ContentExtractor.extract(url: url, ext: "pptx")

        XCTAssertTrue(extracted.text.contains("Launch strategy"))
        XCTAssertTrue(extracted.text.contains("Discuss APAC rollout"))
    }

    func testEPUBExtractionReadsChaptersButSkipsScriptAndStyleText() throws {
        let url = temporaryDirectory.appendingPathComponent("guide.epub")
        try ArchiveTestSupport.write(entries: [
            "OEBPS/content.opf": xml("<dc:title>Offline Guide</dc:title>", namespaces: true),
            "OEBPS/chapter1.xhtml": "<html><head><style>hidden style</style></head><body><h1>Local search</h1><script>hidden script</script><p>Private document indexing</p></body></html>",
        ], to: url)

        let extracted = ContentExtractor.extract(url: url, ext: "epub")

        XCTAssertEqual(extracted.title, "Offline Guide")
        XCTAssertTrue(extracted.text.contains("Private document indexing"))
        XCTAssertFalse(extracted.text.contains("hidden script"))
        XCTAssertFalse(extracted.text.contains("hidden style"))
    }

    func testOpenDocumentExtractionReadsContentAndTitle() throws {
        let url = temporaryDirectory.appendingPathComponent("meeting.odt")
        try ArchiveTestSupport.write(entries: [
            "meta.xml": xml("<dc:title>Weekly Meeting</dc:title>", namespaces: true),
            "content.xml": xml("<text:p>Decision: ship the local index</text:p>", namespaces: true),
        ], to: url)

        let extracted = ContentExtractor.extract(url: url, ext: "odt")

        XCTAssertEqual(extracted.title, "Weekly Meeting")
        XCTAssertTrue(extracted.text.contains("Decision: ship the local index"))
    }

    func testMalformedArchiveUsesLocalRichTextFallbackWhenReadable() throws {
        let url = temporaryDirectory.appendingPathComponent("broken.docx")
        try Data("not a zip".utf8).write(to: url)

        let extracted = ContentExtractor.extract(url: url, ext: "docx")

        XCTAssertEqual(extracted.title, "broken")
        XCTAssertEqual(extracted.text, "not a zip")
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

    private func xml(_ body: String, namespaces: Bool = false) -> String {
        let declarations = namespaces
            ? " xmlns:w=\"urn:w\" xmlns:a=\"urn:a\" xmlns:text=\"urn:text\" xmlns:dc=\"urn:dc\""
            : ""
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><root\(declarations)>\(body)</root>"
    }
}
