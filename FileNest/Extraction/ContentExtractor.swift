import Foundation
import PDFKit

/// 内容抽取：从文件中提取纯文本用于摘要/检索/向量化。
/// 支持：PDF(PDFKit)、txt/md/json/yaml/code(直读)、其他(用元数据占位)。
enum ContentExtractor {
    /// 限制单文件最大抽取字符数，防止超大文件拖慢索引
    static let maxChars = 20_000

    struct Extracted {
        var title: String?
        var text: String
    }

    static func extract(url: URL, ext: String) -> Extracted {
        let e = ext.lowercased()
        switch e {
        case "pdf":
            return extractPDF(url)
        case "txt", "md", "markdown", "json", "yaml", "yml", "csv", "log", "xml", "html", "rtf":
            return extractPlainText(url)
        default:
            // 代码类按文本读
            if isCodeLike(e) {
                return extractPlainText(url)
            }
            // 二进制（图片/视频/音频/压缩包）：用文件名作为可索引文本
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
        let maxPages = min(pageCount, 50)
        for i in 0..<maxPages {
            if let page = doc.page(at: i), let s = page.string {
                text += s + "\n"
                if text.count >= maxChars { break }
            }
        }
        if text.count > maxChars { text = String(text.prefix(maxChars)) }
        let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
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

    private static let codeExts: Set<String> = ["swift","py","js","ts","tsx","jsx","java","kt","go","rs","c","cpp","h","hpp","cs","rb","php","sh","sql","vue","lua","r","m","scala"]
    private static func isCodeLike(_ e: String) -> Bool { codeExts.contains(e) }
}
