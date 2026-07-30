import XCTest
@testable import FileNest

final class DoclingDocumentProcessorTests: XCTestCase {
    func testParseChunksReadsDoclingJSONLAndSkipsMalformedLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("document.chunks.jsonl")
        try Data("""
        {"text":"Heading\\nFirst paragraph","meta":{"headings":["Heading"]}}
        not-json
        {"text":"  Second table row  "}

        """.utf8).write(to: output)

        let chunks = DoclingDocumentProcessor.parseChunks(in: directory)

        XCTAssertEqual(chunks, ["Heading\nFirst paragraph", "Second table row"])
    }

    func testProcessUsesDoclingChunksOutputWhenExecutableIsAvailable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-docling")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let source = directory.appendingPathComponent("sample.docx")
        try Data().write(to: source)
        let worker = """
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps({"id": request["id"], "ok": True, "title": "sample", "chunks": [{
                "text": "Docling hybrid chunk",
                "contextual_text": "Install > Setup\\nDocling hybrid chunk",
                "headings": ["Install", "Setup"],
                "page_start": 2,
                "page_end": 3,
                "kind": "table"
            }]}), flush=True)
        """
        let processor = DoclingDocumentProcessor(
            executableURL: executable,
            pythonExecutableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerScript: worker
        )

        let result = await processor.process(url: source, ext: "docx", maxTokens: 256)

        XCTAssertEqual(result?.chunks.map(\.text), ["Docling hybrid chunk"])
        XCTAssertEqual(result?.chunks.first?.contextualText, "Install > Setup\nDocling hybrid chunk")
        XCTAssertEqual(result?.chunks.first?.sectionPath, ["Install", "Setup"])
        XCTAssertEqual(result?.chunks.first?.pageStart, 2)
        XCTAssertEqual(result?.chunks.first?.pageEnd, 3)
        XCTAssertEqual(result?.chunks.first?.kind, .table)
        XCTAssertEqual(result?.extracted.text, "Install > Setup\nDocling hybrid chunk")
        XCTAssertEqual(result?.extracted.title, "sample")
    }

    func testRasterImagesAreReservedForDedicatedOCRPipeline() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-docling")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let source = directory.appendingPathComponent("seal.png")
        try Data([0, 1, 2]).write(to: source)
        let processor = DoclingDocumentProcessor(
            executableURL: executable,
            pythonExecutableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerScript: "fatalError('image should not enter Docling')"
        )

        let result = await processor.process(url: source, ext: "png", maxTokens: 600)

        XCTAssertNil(result)
    }

    func testPDFContentClassifierUsesEightyPercentThresholds() throws {
        func pages(text: Int, scanned: Int) -> [PDFContentAnalysis.Page] {
            (0..<(text + scanned)).map { index in
                PDFContentAnalysis.Page(
                    number: index + 1,
                    embeddedCharacterCount: index < text ? 100 : 0
                )
            }
        }

        XCTAssertEqual(OCRDocumentProcessor.classify(pages(text: 8, scanned: 2))?.mode, .text)
        XCTAssertEqual(OCRDocumentProcessor.classify(pages(text: 2, scanned: 8))?.mode, .scanned)
        XCTAssertEqual(OCRDocumentProcessor.classify(pages(text: 5, scanned: 5))?.mode, .mixed)
        XCTAssertNil(OCRDocumentProcessor.classify([]))
    }

    func testCorruptedEmbeddedTextIsRemovedWhenOCRHasRecoveredReadableContent() {
        let corrupted = StructuredDocumentChunk(
            text: "!%&!#$%&!#%&!#$%&!#%&!#$%&!#%&!#$%&!#%&!#$%&!#%&!#$%&!#"
        )
        let recovered = StructuredDocumentChunk(
            text: "RE-ENTRY PERMIT. This permit allows the holder to re-enter Singapore during its validity and must be presented to an Immigration Officer on arrival and departure."
        )

        let result = DoclingDocumentProcessor.removingCorruptedTextLayerChunks(
            from: [corrupted, recovered]
        )

        XCTAssertEqual(result, [recovered])
    }

    func testPotentiallySymbolHeavyTextIsRetainedWithoutReadableRecovery() {
        let source = StructuredDocumentChunk(
            text: "!%&!#$%&!#%&!#$%&!#%&!#$%&!#%&!#$%&!#%&!#$%&!#%&!#$%&!#"
        )

        let result = DoclingDocumentProcessor.removingCorruptedTextLayerChunks(from: [source])

        XCTAssertEqual(result, [source])
    }

    func testCorruptedTextLayerIsRemovedBeforeChunkingWhenExternalOCRRecoveredText() {
        let corrupted = StructuredDocumentChunk(
            text: "- $\" !//%1 2 %/$ % 3 & &4!2% %&  % % $# &4 .!/ $ 56 2 %. $"
        )
        let recovered = """
        FORM 7
        IMMIGRATION ACT 1959
        RE-ENTRY PERMIT
        This permit allows the holder to re-enter Singapore during its validity.
        """

        let result = DoclingDocumentProcessor.removingCorruptedTextLayerChunks(
            from: [corrupted],
            readableRecovery: recovered
        )

        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(DoclingDocumentProcessor.isLikelyCorruptedTextLayer(corrupted.text))
        XCTAssertTrue(DoclingDocumentProcessor.isLikelyReadableText(recovered))
    }
}
