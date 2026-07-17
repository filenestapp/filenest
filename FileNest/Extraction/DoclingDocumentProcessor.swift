import Foundation

struct DoclingProcessedDocument {
    let extracted: ContentExtractor.Extracted
    let chunks: [StructuredDocumentChunk]
}

/// Uses one persistent Python worker to reuse the Docling converter and tokenizer.
/// Terminates the worker after errors, timeouts, or cancellation and recreates it on the next request; callers may still fall back to the native parser.
final class DoclingDocumentProcessor: @unchecked Sendable {
    private static let supportedExtensions: Set<String> = [
        "pdf", "docx", "docm", "xlsx", "xlsm", "pptx", "ppsx",
        "html", "htm", "epub", "odt", "ods", "odp", "md", "markdown", "txt"
    ]
    private let executableURL: URL?
    private let pythonExecutableOverride: URL?
    private let workerSource: String
    private let queue = DispatchQueue(label: "filenest.docling", qos: .userInitiated)
    private let processLock = NSLock()
    private var workerProcess: Process?
    private var workerInput: FileHandle?
    private var workerOutput: FileHandle?
    private var readBuffer = Data()
    private var activeRequestID: String?

    init(executableURL: URL? = nil,
         pythonExecutableURL: URL? = nil,
         workerScript: String? = nil) {
        self.executableURL = executableURL ?? (Self.isRunningTests ? nil : DoclingServiceManager.resolveExecutable())
        self.pythonExecutableOverride = pythonExecutableURL
        self.workerSource = workerScript ?? Self.workerScript
    }

    deinit { terminateWorker() }

    func process(url: URL, ext: String, maxTokens: Int,
                 pdfAnalysis: PDFContentAnalysis? = nil,
                 disableBuiltInOCR: Bool = false) async -> DoclingProcessedDocument? {
        let resolvedExecutable = executableURL ?? (Self.isRunningTests ? nil : DoclingServiceManager.resolveExecutable())
        guard Self.supportedExtensions.contains(ext.lowercased()),
              let python = pythonExecutableOverride ?? resolvedExecutable.map(Self.pythonExecutable(for:)),
              FileManager.default.isExecutableFile(atPath: python.path),
              !Task.isCancelled else { return nil }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    guard let self else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: self.run(
                        python: python,
                        source: url,
                        maxTokens: max(600, min(maxTokens, 1_000)),
                        pdfAnalysis: pdfAnalysis,
                        disableBuiltInOCR: disableBuiltInOCR
                    ))
                }
            }
        } onCancel: { [weak self] in
            self?.terminateWorker()
        }
    }

    private func run(python: URL, source: URL, maxTokens: Int,
                     pdfAnalysis: PDFContentAnalysis?,
                     disableBuiltInOCR: Bool) -> DoclingProcessedDocument? {
        guard let input = ensureWorker(python: python) else { return nil }
        let requestID = UUID().uuidString
        let payload: [String: Any] = [
            "id": requestID,
            "path": source.path,
            "max_tokens": maxTokens,
            "pdf_mode": disableBuiltInOCR
                ? PDFContentMode.text.rawValue
                : (pdfAnalysis?.mode.rawValue ?? "automatic"),
            "scanned_pages": pdfAnalysis?.scannedPageNumbers ?? [],
            "page_count": pdfAnalysis?.pages.count ?? 0,
            "disable_ocr": disableBuiltInOCR,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8)?.data(using: .utf8) else { return nil }
        line.append(0x0A)

        processLock.lock()
        activeRequestID = requestID
        processLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 330) { [weak self] in
            self?.terminateWorker(requestID: requestID)
        }

        do {
            try input.write(contentsOf: line)
            guard let responseData = readResponseLine() else {
                clearActiveRequest(requestID)
                terminateWorker()
                AppLogService.shared.write(
                    "Docling worker exited before returning a response",
                    category: .indexExtraction,
                    level: .warning,
                    metadata: ["file": source.lastPathComponent]
                )
                return nil
            }
            guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  object["id"] as? String == requestID,
                  object["ok"] as? Bool == true,
                  let rawChunks = object["chunks"] as? [Any] else {
                clearActiveRequest(requestID)
                AppLogService.shared.write(
                    "Docling returned an invalid or failed response",
                    category: .indexExtraction,
                    level: .warning,
                    metadata: ["file": source.lastPathComponent]
                )
                return nil
            }
            clearActiveRequest(requestID)
            let chunks = rawChunks.compactMap { value -> StructuredDocumentChunk? in
                if let object = value as? [String: Any] { return Self.decodeChunk(object) }
                if let text = value as? String {
                    return StructuredDocumentChunk(text: text)
                }
                return nil
            }
            guard !chunks.isEmpty else { return nil }
            let text = String(chunks.map(\.contextualText).joined(separator: "\n\n")
                .prefix(ContentExtractor.maxChars))
            return DoclingProcessedDocument(
                extracted: ContentExtractor.Extracted(
                    title: (object["title"] as? String) ?? source.deletingPathExtension().lastPathComponent,
                    text: text
                ),
                chunks: chunks
            )
        } catch {
            clearActiveRequest(requestID)
            terminateWorker()
            return nil
        }
    }

    private static func decodeChunk(_ object: [String: Any]) -> StructuredDocumentChunk? {
        guard let text = (object["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let contextual = ((object["contextual_text"] as? String) ?? text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sectionPath = (object["headings"] as? [String]) ?? []
        let pageStart = object["page_start"] as? Int
        let pageEnd = object["page_end"] as? Int
        let kind = DocumentChunkKind(rawValue: object["kind"] as? String ?? "") ?? .text
        let tokenCount = object["token_count"] as? Int
        let tokenizerProfile = object["tokenizer_profile"] as? String
        let tokenizerVersion = object["tokenizer_version"] as? String
        let tokenCountAccuracy = (object["token_count_accuracy"] as? String)
            .flatMap(TokenCountAccuracy.init(rawValue:))
        return StructuredDocumentChunk(
            text: text,
            contextualText: contextual.isEmpty ? text : contextual,
            sectionPath: sectionPath,
            pageStart: pageStart,
            pageEnd: pageEnd,
            kind: kind,
            tokenCount: tokenCount,
            tokenizerProfile: tokenizerProfile,
            tokenizerVersion: tokenizerVersion,
            tokenCountAccuracy: tokenCountAccuracy
        )
    }

    private func ensureWorker(python: URL) -> FileHandle? {
        processLock.lock()
        if let process = workerProcess, process.isRunning, let input = workerInput {
            processLock.unlock()
            return input
        }
        processLock.unlock()

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = python
        process.arguments = ["-u", "-c", workerSource]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { terminated in
            guard terminated.terminationStatus != 0 else { return }
            AppLogService.shared.write(
                "Docling worker terminated unexpectedly",
                category: .indexExtraction,
                level: .warning,
                metadata: [
                    "reason": "\(terminated.terminationReason.rawValue)",
                    "status": "\(terminated.terminationStatus)",
                ]
            )
        }
        do {
            try process.run()
        } catch {
            return nil
        }

        processLock.lock()
        workerProcess = process
        workerInput = input.fileHandleForWriting
        workerOutput = output.fileHandleForReading
        readBuffer.removeAll(keepingCapacity: true)
        processLock.unlock()
        return input.fileHandleForWriting
    }

    private func readResponseLine() -> Data? {
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.prefix(upTo: newline)
                readBuffer.removeSubrange(...newline)
                return Data(line)
            }
            processLock.lock()
            let output = workerOutput
            processLock.unlock()
            guard let output else { return nil }
            let data = output.availableData
            guard !data.isEmpty else { return nil }
            readBuffer.append(data)
        }
    }

    private func clearActiveRequest(_ requestID: String) {
        processLock.lock()
        if activeRequestID == requestID { activeRequestID = nil }
        processLock.unlock()
    }

    private func terminateWorker(requestID: String? = nil) {
        processLock.lock()
        if let requestID, activeRequestID != requestID {
            processLock.unlock()
            return
        }
        let process = workerProcess
        workerProcess = nil
        workerInput = nil
        workerOutput = nil
        activeRequestID = nil
        processLock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private static func pythonExecutable(for doclingExecutable: URL) -> URL {
        doclingExecutable.deletingLastPathComponent().appendingPathComponent("python")
    }

    static func parseChunks(in directory: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "jsonl" }
            .sorted { $0.path < $1.path }
            .flatMap { file -> [String] in
                guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return [] }
                return contents.split(whereSeparator: \.isNewline).compactMap { line in
                    guard let data = String(line).data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let text = object["text"] as? String else { return nil }
                    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return normalized.isEmpty ? nil : normalized
                }
            }
    }

    private static let workerScript = #"""
import json
import sys
from pathlib import Path
try:
    import cv2
    cv2.setNumThreads(1)
except Exception:
    pass
from docling.chunking import HybridChunker
from docling_core.transforms.chunker.tokenizer.huggingface import HuggingFaceTokenizer
from docling.datamodel.base_models import InputFormat
from docling.datamodel.pipeline_options import PdfPipelineOptions
from docling.document_converter import DocumentConverter, PdfFormatOption

converters = {}
chunkers = {}
tokenizers = {}
tokenizer_profiles = {}
TOKENIZER_MODEL = "Qwen/Qwen3-Embedding-0.6B"

def converter(do_ocr):
    key = bool(do_ocr)
    if key not in converters:
        options = PdfPipelineOptions()
        options.do_ocr = key
        options.do_table_structure = True
        converters[key] = DocumentConverter(format_options={
            InputFormat.PDF: PdfFormatOption(pipeline_options=options)
        })
    return converters[key]

def chunker(max_tokens):
    if max_tokens not in chunkers:
        try:
            model_name = TOKENIZER_MODEL
            tokenizer_profile = "qwen3-embedding:0.6b"
            tokenizer = HuggingFaceTokenizer.from_pretrained(
                model_name=model_name,
                max_tokens=max_tokens,
                local_files_only=True,
            )
        except Exception:
            # Support users with a legacy FileNest Docling environment; new installations prefetch the Qwen tokenizer.
            model_name = "sentence-transformers/all-MiniLM-L6-v2"
            tokenizer_profile = model_name
            tokenizer = HuggingFaceTokenizer.from_pretrained(
                model_name=model_name,
                max_tokens=max_tokens,
                local_files_only=True,
            )
        tokenizers[max_tokens] = tokenizer
        tokenizer_profiles[max_tokens] = tokenizer_profile
        chunkers[max_tokens] = HybridChunker(tokenizer=tokenizer)
    return chunkers[max_tokens]

def exact_token_count(max_tokens, text):
    tokenizer = tokenizers.get(max_tokens)
    if tokenizer is None:
        return None
    try:
        if hasattr(tokenizer, "count_tokens"):
            return int(tokenizer.count_tokens(text))
        inner = getattr(tokenizer, "tokenizer", None) or getattr(tokenizer, "_tokenizer", None)
        if inner is not None:
            encoded = inner.encode(text, add_special_tokens=False)
            return len(getattr(encoded, "ids", encoded))
    except Exception:
        return None
    return None

def chunk_kind(items):
    labels = {str(getattr(item, "label", "")).split(".")[-1].lower() for item in items}
    if "table" in labels or "document_index" in labels:
        return "table"
    if labels & {"title", "section_header"}:
        return "title"
    if labels & {"list_item", "checkbox_selected", "checkbox_unselected"}:
        return "list"
    if "picture" in labels:
        return "picture"
    return "text"

def serialize_chunks(document, active_chunker, max_tokens, forced_page=None):
    serialized = []
    for part in active_chunker.chunk(dl_doc=document):
        text = (part.text or "").strip()
        contextual = active_chunker.contextualize(chunk=part).strip()
        if not text and not contextual:
            continue
        items = list(getattr(part.meta, "doc_items", None) or [])
        pages = sorted({
            int(prov.page_no)
            for item in items
            for prov in (getattr(item, "prov", None) or [])
            if getattr(prov, "page_no", None) is not None
        })
        if not pages and forced_page is not None:
            pages = [forced_page]
        embedded_text = contextual or text
        token_count = exact_token_count(max_tokens, embedded_text)
        serialized_chunk = {
            "text": text or contextual,
            "contextual_text": embedded_text,
            "headings": list(getattr(part.meta, "headings", None) or []),
            "page_start": min(pages) if pages else None,
            "page_end": max(pages) if pages else None,
            "kind": chunk_kind(items),
        }
        if token_count is not None:
            serialized_chunk.update({
                "token_count": token_count,
                "tokenizer_profile": tokenizer_profiles.get(max_tokens, TOKENIZER_MODEL),
                "tokenizer_version": "huggingface-tokenizer-v1",
                "token_count_accuracy": "exact",
            })
        serialized.append(serialized_chunk)
    return serialized

for line in sys.stdin:
    request = None
    try:
        request = json.loads(line)
        result = None
        max_tokens = int(request.get("max_tokens", 600))
        active_chunker = chunker(max_tokens)
        mode = request.get("pdf_mode", "automatic")
        suffix = Path(request["path"]).suffix.lower()
        chunks = []
        if suffix == ".pdf" and mode == "mixed":
            scanned = set(int(page) for page in request.get("scanned_pages", []))
            page_count = int(request.get("page_count") or max(scanned | {1}))
            try:
                from pypdfium2 import PdfDocument
                page_count = len(PdfDocument(request["path"]))
            except Exception:
                pass
            for page in range(1, page_count + 1):
                result = converter(page in scanned and not bool(request.get("disable_ocr", False))).convert(
                    request["path"], page_range=(page, page), raises_on_error=True
                )
                chunks.extend(serialize_chunks(result.document, active_chunker, max_tokens, forced_page=page))
        else:
            do_ocr = not bool(request.get("disable_ocr", False)) and (
                mode in ("scanned", "automatic") or suffix in {
                ".png", ".jpg", ".jpeg", ".tiff", ".tif", ".bmp", ".webp"
                }
            )
            result = converter(do_ocr).convert(request["path"], raises_on_error=True)
            chunks = serialize_chunks(result.document, active_chunker, max_tokens)
        if not chunks and result is not None:
            text = result.document.export_to_text().strip()
            if text:
                chunks = [{
                    "text": text,
                    "contextual_text": text,
                    "headings": [],
                    "page_start": None,
                    "page_end": None,
                    "kind": "text",
                }]
        response = {
            "id": request.get("id"),
            "ok": bool(chunks),
            "title": Path(request["path"]).stem,
            "chunks": chunks,
        }
    except Exception as error:
        response = {
            "id": request.get("id") if isinstance(request, dict) else None,
            "ok": False,
            "error": str(error),
            "chunks": [],
        }
    print(json.dumps(response, ensure_ascii=False), flush=True)
"""#

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
