import AppKit
import Foundation
import ImageIO
import PDFKit

/// Content extraction: reads plain text from files for summaries, retrieval, and embeddings.
/// All parsing runs on this Mac; LocalArchiveDocumentExtractor handles compressed document containers.
enum ContentExtractor {
    /// Limits extracted characters per file so oversized files do not slow indexing.
    static let maxChars = 120_000

    struct Extracted {
        var title: String?
        var text: String
    }

    static func extract(url: URL, ext: String) -> Extracted {
        let e = ext.lowercased()
        switch e {
        case "pdf":
            return extractPDF(url)
        case "docx", "docm":
            return extractArchiveDocument(url, kind: .word)
        case "xlsx", "xlsm":
            return extractArchiveDocument(url, kind: .spreadsheet)
        case "pptx", "ppsx":
            return extractArchiveDocument(url, kind: .presentation)
        case "epub":
            return extractArchiveDocument(url, kind: .ebook)
        case "odt", "ods", "odp":
            return extractArchiveDocument(url, kind: .openDocument)
        case "doc", "xls", "ppt", "pages", "numbers", "key", "keynote":
            return extractLegacyDocument(url, richTextFirst: e == "doc")
        case "rtf", "rtfd":
            return extractRichText(url)
        case "txt", "md", "markdown", "json", "yaml", "yml", "csv", "log", "xml", "html":
            return extractPlainText(url)
        default:
            if imageExts.contains(e) {
                return extractImageMetadata(url)
            }
            // Read source-code formats as text.
            if isCodeLike(e) {
                return extractPlainText(url)
            }
            // For binary images, videos, audio, and archives, use the file name as indexable text.
            return Extracted(title: url.deletingPathExtension().lastPathComponent,
                             text: url.lastPathComponent)
        }
    }

    private static func extractPDF(_ url: URL) -> Extracted {
        guard let doc = PDFDocument(url: url) else {
            return Extracted(title: url.deletingPathExtension().lastPathComponent, text: url.lastPathComponent)
        }
        var text = ""
        let pageCount = doc.pageCount
        let maxPages = min(pageCount, 200)
        for i in 0..<maxPages {
            if let page = doc.page(at: i), let s = page.string {
                text += s + "\n"
                if text.count >= maxChars { break }
            }
        }
        if text.count > maxChars { text = String(text.prefix(maxChars)) }
        let metadataTitle = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = metadataTitle.flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        return Extracted(title: title, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func extractPlainText(_ url: URL) -> Extracted {
        do {
            var enc = String.Encoding.utf8
            let raw = try String(contentsOf: url, usedEncoding: &enc)
            let title = url.deletingPathExtension().lastPathComponent
            let text = String(raw.prefix(maxChars))
            return Extracted(title: title, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return Extracted(title: url.lastPathComponent, text: url.lastPathComponent)
        }
    }

    private static func extractRichText(_ url: URL) -> Extracted {
        do {
            let attributed = try NSAttributedString(
                url: url,
                options: [:],
                documentAttributes: nil
            )
            let text = String(attributed.string.prefix(maxChars))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Extracted(
                title: url.deletingPathExtension().lastPathComponent,
                text: text.isEmpty ? url.lastPathComponent : text
            )
        } catch {
            return Extracted(title: url.lastPathComponent, text: url.lastPathComponent)
        }
    }

    private static func extractArchiveDocument(
        _ url: URL,
        kind: LocalArchiveDocumentExtractor.Kind
    ) -> Extracted {
        if let extracted = LocalArchiveDocumentExtractor.extract(url: url, kind: kind),
           !extracted.text.isEmpty {
            return extracted
        }
        return extractLegacyDocument(url, richTextFirst: kind == .word)
    }

    /// Legacy binary Office and iWork formats lack stable public parsing APIs, so prefer local system extraction,
    /// then fall back to the file name. This path starts no external process and uploads no file.
    private static func extractLegacyDocument(_ url: URL, richTextFirst: Bool) -> Extracted {
        if richTextFirst {
            let rich = extractRichText(url)
            if rich.text != url.lastPathComponent { return rich }
        }

        guard let metadata = NSMetadataItem(url: url) else { return filenameFallback(url) }
        let metadataTitle = (metadata.value(forAttribute: "kMDItemTitle") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataText = (metadata.value(forAttribute: "kMDItemTextContent") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let metadataText, !metadataText.isEmpty {
            return Extracted(
                title: metadataTitle.flatMap { $0.isEmpty ? nil : $0 }
                    ?? url.deletingPathExtension().lastPathComponent,
                text: String(metadataText.prefix(maxChars))
            )
        }
        return filenameFallback(url)
    }

    static func filenameFallback(_ url: URL) -> Extracted {
        Extracted(
            title: url.deletingPathExtension().lastPathComponent,
            text: url.lastPathComponent
        )
    }

    /// Extracts image metadata suitable for local retrieval. GPS coordinates are intentionally excluded so location data cannot enter cloud context.
    private static func extractImageMetadata(_ url: URL) -> Extracted {
        let title = url.deletingPathExtension().lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return Extracted(title: title, text: url.lastPathComponent)
        }

        var lines = ["File name: \(url.lastPathComponent)"]
        let width = integer(raw[kCGImagePropertyPixelWidth])
        let height = integer(raw[kCGImagePropertyPixelHeight])
        if let width, let height { lines.append("Dimensions: \(width) × \(height) pixels") }
        if let depth = integer(raw[kCGImagePropertyDepth]) { lines.append("Bit depth: \(depth) bit") }
        if let colorModel = raw[kCGImagePropertyColorModel] as? String, !colorModel.isEmpty {
            lines.append("Color model: \(colorModel)")
        }
        if let dpiWidth = number(raw[kCGImagePropertyDPIWidth]),
           let dpiHeight = number(raw[kCGImagePropertyDPIHeight]) {
            lines.append("Resolution: \(format(dpiWidth)) × \(format(dpiHeight)) DPI")
        }
        if let orientation = integer(raw[kCGImagePropertyOrientation]) {
            lines.append("Orientation: \(orientation)")
        }

        if let tiff = raw[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            append(tiff[kCGImagePropertyTIFFMake], label: "Camera make", to: &lines)
            append(tiff[kCGImagePropertyTIFFModel], label: "Camera model", to: &lines)
            append(tiff[kCGImagePropertyTIFFSoftware], label: "Software", to: &lines)
            append(tiff[kCGImagePropertyTIFFDateTime], label: "Capture time", to: &lines)
            append(tiff[kCGImagePropertyTIFFArtist], label: "Author", to: &lines)
            append(tiff[kCGImagePropertyTIFFCopyright], label: "Copyright", to: &lines)
        }
        if let exif = raw[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            append(exif[kCGImagePropertyExifLensModel], label: "Lens", to: &lines)
            append(exif[kCGImagePropertyExifDateTimeOriginal], label: "Original capture time", to: &lines)
            appendNumber(exif[kCGImagePropertyExifExposureTime], label: "Exposure time", suffix: " sec", to: &lines)
            appendNumber(exif[kCGImagePropertyExifFNumber], label: "Aperture", prefix: "f/", to: &lines)
            appendNumber(exif[kCGImagePropertyExifFocalLength], label: "Focal length", suffix: " mm", to: &lines)
            if let values = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber],
               let iso = values.first {
                lines.append("ISO：\(iso.intValue)")
            }
        }
        return Extracted(title: title, text: lines.joined(separator: "\n"))
    }

    private static func append(_ value: Any?, label: String, to lines: inout [String]) {
        guard let text = value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lines.append("\(label)：\(text)")
    }

    private static func appendNumber(_ value: Any?, label: String, prefix: String = "",
                                     suffix: String = "", to lines: inout [String]) {
        guard let value = number(value) else { return }
        lines.append("\(label)：\(prefix)\(format(value))\(suffix)")
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private static let codeExts: Set<String> = ["swift","py","js","ts","tsx","jsx","java","kt","go","rs","c","cpp","h","hpp","cs","rb","php","sh","sql","vue","lua","r","m","scala"]
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp", "bmp"]
    private static func isCodeLike(_ e: String) -> Bool { codeExts.contains(e) }
}
