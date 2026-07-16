import AppKit
import Foundation
import ImageIO
import PDFKit

enum PDFContentMode: String, Equatable, Sendable {
    case text
    case scanned
    case mixed
}

struct PDFContentAnalysis: Equatable, Sendable {
    struct Page: Equatable, Sendable {
        let number: Int
        let embeddedCharacterCount: Int
        var requiresOCR: Bool { embeddedCharacterCount < PDFContentAnalysis.minimumTextCharacters }
    }

    static let minimumTextCharacters = 24
    let pages: [Page]
    let mode: PDFContentMode

    var scannedPageNumbers: [Int] { pages.filter(\.requiresOCR).map(\.number) }
    var textRatio: Double {
        guard !pages.isEmpty else { return 0 }
        return Double(pages.filter { !$0.requiresOCR }.count) / Double(pages.count)
    }
    var scannedRatio: Double { 1 - textRatio }
}

/// Resizes images or scanned PDF pages before sending them to the configured OCR provider.
/// Skips OCR for text-based PDFs to avoid duplicate work and unnecessary model cost.
enum OCRDocumentProcessor {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp", "bmp"
    ]
    private static let maxPDFPages = 200
    private static let maxOCRCharacters = 60_000
    private static let failureCooldown: TimeInterval = 10 * 60
    private static let stateLock = NSLock()
    private static var failedUntil = [String: Date]()
    private static var providerFailedUntil = [String: Date]()
    private static let executionLane = AsyncPermitPool(limit: 1)

    static func isRasterImage(extension ext: String) -> Bool {
        imageExtensions.contains(ext.lowercased())
    }

    static func requiresRecognition(ext: String, pdfAnalysis: PDFContentAnalysis?) -> Bool {
        let normalized = ext.lowercased()
        if imageExtensions.contains(normalized) { return true }
        return normalized == "pdf" && pdfAnalysis?.mode != .text
    }

    static func recognizeIfNeeded(
        url: URL,
        ext: String,
        provider: OCRProvider?,
        forceImageOCR _: Bool = false,
        checkpoint: (@Sendable () async -> Bool)? = nil
    ) async -> String? {
        guard let provider else { return nil }
        guard !isCoolingDown(url: url, provider: provider) else { return nil }
        let normalizedExtension = ext.lowercased()

        if imageExtensions.contains(normalizedExtension) {
            // Raster images always go through the configured OCR provider. A Vision fast-mode
            // preflight used to suppress OCR for stylized, curved, or low-contrast text (for
            // example company seals), which left the index with metadata only.
            guard await checkpoint?() ?? !Task.isCancelled else { return nil }
            guard let data = normalizedJPEGData(at: url) else { return nil }
            return await recognize(data: data, provider: provider, url: url)
        }

        guard normalizedExtension == "pdf", let document = PDFDocument(url: url),
              let analysis = analyze(document), analysis.mode != .text else { return nil }

        var pages = [String]()
        for pageNumber in analysis.scannedPageNumbers.prefix(maxPDFPages) {
            guard await checkpoint?() ?? !Task.isCancelled else { return nil }
            guard let page = document.page(at: pageNumber - 1),
                  let data = jpegData(from: page.thumbnail(
                    of: CGSize(width: 1_600, height: 2_200),
                    for: .mediaBox
                  )),
                  let text = await recognize(data: data, provider: provider, url: url),
                  !text.isEmpty else { continue }
            pages.append("[Page \(pageNumber)]\n\(text)")
            if pages.reduce(0, { $0 + $1.count }) >= maxOCRCharacters { break }
        }
        let result = String(pages.joined(separator: "\n\n").prefix(maxOCRCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func recognize(data: Data, provider: OCRProvider, url: URL) async -> String? {
        await executionLane.acquire()
        defer { Task { await executionLane.release() } }
        do {
            let text = try await provider.recognize(imageData: data, mimeType: "image/jpeg")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            clearFailure(url: url, provider: provider)
            return text.isEmpty ? nil : String(text.prefix(maxOCRCharacters))
        } catch {
            recordFailure(url: url, provider: provider)
            return nil
        }
    }

    private static func isCoolingDown(url: URL, provider: OCRProvider) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let now = Date()
        let path = url.standardizedFileURL.path
        if let deadline = providerFailedUntil[provider.name] {
            if deadline > now { return true }
            providerFailedUntil.removeValue(forKey: provider.name)
        }
        if let deadline = failedUntil[path] {
            if deadline > now { return true }
            failedUntil.removeValue(forKey: path)
        }
        return false
    }

    private static func recordFailure(url: URL, provider: OCRProvider) {
        stateLock.lock()
        let deadline = Date().addingTimeInterval(failureCooldown)
        failedUntil[url.standardizedFileURL.path] = deadline
        // Trip the provider circuit after OCR service or model failures so every file does not wait for another network timeout.
        providerFailedUntil[provider.name] = deadline
        stateLock.unlock()
    }

    private static func clearFailure(url: URL, provider: OCRProvider) {
        stateLock.lock()
        failedUntil.removeValue(forKey: url.standardizedFileURL.path)
        providerFailedUntil.removeValue(forKey: provider.name)
        stateLock.unlock()
    }

    static func analyzePDF(at url: URL) -> PDFContentAnalysis? {
        guard let document = PDFDocument(url: url) else { return nil }
        return analyze(document)
    }

    static func analyze(_ document: PDFDocument) -> PDFContentAnalysis? {
        guard document.pageCount > 0 else { return nil }
        let pages = (0..<document.pageCount).map { index in
            PDFContentAnalysis.Page(
                number: index + 1,
                embeddedCharacterCount: document.page(at: index)?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
            )
        }
        return classify(pages)
    }

    static func classify(_ pages: [PDFContentAnalysis.Page]) -> PDFContentAnalysis? {
        guard !pages.isEmpty else { return nil }
        let textPages = pages.filter { !$0.requiresOCR }.count
        let textRatio = Double(textPages) / Double(pages.count)
        let scannedRatio = 1 - textRatio
        let mode: PDFContentMode
        if textRatio >= 0.8 {
            mode = .text
        } else if scannedRatio >= 0.8 {
            mode = .scanned
        } else {
            mode = .mixed
        }
        return PDFContentAnalysis(pages: pages, mode: mode)
    }

    static func isScanned(_ document: PDFDocument) -> Bool {
        analyze(document)?.mode == .scanned
    }

    private static func normalizedJPEGData(at url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_000,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.82]
        )
    }

    private static func jpegData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

private actor AsyncPermitPool {
    private var permits: Int
    private var waiters = [CheckedContinuation<Void, Never>]()

    init(limit: Int) { permits = max(1, limit) }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
