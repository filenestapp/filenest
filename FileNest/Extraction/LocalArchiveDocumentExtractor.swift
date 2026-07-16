import Foundation
import ZIPFoundation

/// Reads common ZIP/XML office documents, loading only allowlisted entries in memory and never expanding archives to disk.
enum LocalArchiveDocumentExtractor {
    enum Kind {
        case word
        case spreadsheet
        case presentation
        case ebook
        case openDocument
    }

    private static let maxEntryBytes: UInt64 = 8 * 1_024 * 1_024
    private static let maxEntries = 300

    static func extract(url: URL, kind: Kind) -> ContentExtractor.Extracted? {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        } catch {
            return nil
        }

        let paths = selectedPaths(in: archive, kind: kind)
        guard !paths.isEmpty else { return nil }

        var sections = [String]()
        var extractedCharacters = 0
        for path in paths.prefix(maxEntries) {
            guard let data = read(path: path, from: archive),
                  let text = XMLTextExtractor.text(from: data),
                  !text.isEmpty else { continue }
            sections.append(text)
            extractedCharacters += text.count
            if extractedCharacters >= ContentExtractor.maxChars { break }
        }

        let body = String(sections.joined(separator: "\n").prefix(ContentExtractor.maxChars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        let title = documentTitle(in: archive, kind: kind)
            ?? url.deletingPathExtension().lastPathComponent
        return ContentExtractor.Extracted(title: title, text: body)
    }

    private static func selectedPaths(in archive: Archive, kind: Kind) -> [String] {
        archive.compactMap { entry -> String? in
            guard entry.type == .file, entry.uncompressedSize <= maxEntryBytes else { return nil }
            let path = entry.path
            let lower = path.lowercased()
            switch kind {
            case .word:
                guard lower == "word/document.xml"
                        || lower.hasPrefix("word/header")
                        || lower.hasPrefix("word/footer")
                        || lower == "word/footnotes.xml"
                        || lower == "word/endnotes.xml"
                        || lower == "word/comments.xml" else { return nil }
            case .spreadsheet:
                guard lower == "xl/sharedstrings.xml"
                        || (lower.hasPrefix("xl/worksheets/") && lower.hasSuffix(".xml")) else { return nil }
            case .presentation:
                guard (lower.hasPrefix("ppt/slides/slide") || lower.hasPrefix("ppt/notesslides/notesslide")),
                      lower.hasSuffix(".xml") else { return nil }
            case .ebook:
                guard lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".htm") else {
                    return nil
                }
            case .openDocument:
                guard lower == "content.xml" else { return nil }
            }
            return path
        }
        .sorted(by: naturalPathOrder)
    }

    private static func naturalPathOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func documentTitle(in archive: Archive, kind: Kind) -> String? {
        let candidatePaths: [String]
        switch kind {
        case .word, .spreadsheet, .presentation:
            candidatePaths = ["docProps/core.xml"]
        case .ebook:
            candidatePaths = archive.compactMap { entry in
                entry.path.lowercased().hasSuffix(".opf") ? entry.path : nil
            }.sorted(by: naturalPathOrder)
        case .openDocument:
            candidatePaths = ["meta.xml"]
        }

        for path in candidatePaths {
            guard let data = read(path: path, from: archive),
                  let title = XMLTextExtractor.value(named: "title", from: data),
                  !title.isEmpty else { continue }
            return String(title.prefix(500))
        }
        return nil
    }

    private static func read(path: String, from archive: Archive) -> Data? {
        guard let entry = archive[path],
              entry.type == .file,
              entry.uncompressedSize <= maxEntryBytes else { return nil }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try archive.extract(entry, bufferSize: 32 * 1_024, skipCRC32: false) { chunk in
                data.append(chunk)
            }
            return data
        } catch {
            return nil
        }
    }
}

private enum XMLTextExtractor {
    static func text(from data: Data) -> String? {
        let delegate = AllTextDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return normalize(delegate.parts.joined(separator: " "))
    }

    static func value(named targetName: String, from data: Data) -> String? {
        let delegate = NamedValueDelegate(targetName: targetName)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return normalize(delegate.value)
    }

    private static func normalize(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private final class AllTextDelegate: NSObject, XMLParserDelegate {
        var parts = [String]()
        private var skippedDepth = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let name = Self.localName(elementName)
            if skippedDepth > 0 { skippedDepth += 1 }
            else if name == "script" || name == "style" { skippedDepth = 1 }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard skippedDepth == 0 else { return }
            let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { parts.append(value) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if skippedDepth > 0 { skippedDepth -= 1 }
        }

        private static func localName(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
        }
    }

    private final class NamedValueDelegate: NSObject, XMLParserDelegate {
        let targetName: String
        var value = ""
        private var targetDepth: Int?
        private var depth = 0

        init(targetName: String) {
            self.targetName = targetName.lowercased()
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            depth += 1
            let localName = elementName.split(separator: ":").last.map(String.init)?.lowercased()
                ?? elementName.lowercased()
            if targetDepth == nil, localName == targetName { targetDepth = depth }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if targetDepth != nil { value += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if targetDepth == depth { targetDepth = nil }
            depth -= 1
        }
    }
}
