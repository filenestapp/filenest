import AppKit
import Foundation
import ImageIO
import NaturalLanguage

/// Generates short, editable notes for documents and images; results are returned to the editor and never overwrite user content automatically.
final class FileSummaryService {
    private let settings: AppSettings
    private let providedProvider: LLMProvider?
    private let providedOCRProvider: OCRProvider?
    private let typingDelayNanoseconds: UInt64

    init(
        settings: AppSettings,
        provider: LLMProvider? = nil,
        ocrProvider: OCRProvider? = nil,
        typingDelayNanoseconds: UInt64? = nil
    ) {
        self.settings = settings
        self.providedProvider = provider
        self.providedOCRProvider = ocrProvider
        self.typingDelayNanoseconds = typingDelayNanoseconds
            ?? (AppState.isRunningTests ? 0 : 8_000_000)
    }

    func summarize(file: FileRecord) async throws -> String {
        var latest = ""
        for try await partial in streamSummary(file: file) { latest = partial }
        guard !latest.isEmpty else { throw FileSummaryError.emptyResponse }
        return latest
    }

    /// Streams cumulative, display-ready note text. Native provider chunks are further
    /// paced character-by-character so every provider has the same typewriter experience.
    func streamSummary(file: FileRecord) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let provider = providedProvider ?? settings.makeLLMProvider()
                    guard provider.name != "none" else { throw FileSummaryError.modelDisabled }
                    let url = URL(fileURLWithPath: file.path)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw FileSummaryError.fileMissing
                    }

                    let accumulator = StreamAccumulator(
                        continuation: continuation,
                        typingDelayNanoseconds: typingDelayNanoseconds
                    )
                    if file.categoryEnum == .images {
                        try await streamImage(
                            file: file,
                            url: url,
                            provider: provider,
                            emit: accumulator.append
                        )
                    } else {
                        let indexedText = normalized(file.contentText)
                        let extracted = indexedText.isEmpty
                            ? ContentExtractor.extract(url: url, ext: file.ext)
                            : nil
                        try await streamText(
                            file: file,
                            title: file.title ?? extracted?.title ?? file.name,
                            source: indexedText.isEmpty ? (extracted?.text ?? "") : indexedText,
                            provider: provider,
                            emit: accumulator.append
                        )
                    }
                    try accumulator.finish()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamImage(
        file: FileRecord,
        url: URL,
        provider: LLMProvider,
        emit: @escaping (String) async throws -> Void
    ) async throws {
        let metadata = ContentExtractor.extract(url: url, ext: file.ext)
        let indexedText = normalized(file.contentText)

        // Reuse OCR or structured text produced during indexing to avoid processing images again.
        if !indexedText.isEmpty, indexedText != normalized(metadata.text) {
            try await streamText(
                file: file,
                title: file.title ?? metadata.title ?? file.name,
                source: indexedText,
                provider: provider,
                emit: emit
            )
            return
        }

        if let image = normalizedImageData(at: url) {
            do {
                let prompt = settings.localizedFormat(
                    "Examine the image itself and write a concise note for the file. Summarize the visible subject, text, key information, and likely purpose in 1–3 sentences and no more than 180 words. Return only the note text without a Markdown heading.\n\nFile: %@\nImage metadata:\n%@\n\nAnswer in the current interface language.",
                    file.name,
                    metadata.text
                )
                let stream = provider.streamChatWithImage(
                    prompt: prompt,
                    imageData: image.data,
                    mimeType: image.mimeType,
                    context: settings.localized(
                        "You are FileNest’s image summary assistant. Base the note on content actually visible in the image. Do not merely repeat dimensions, color, or DPI, and do not invent information that is not visible."
                    )
                )
                for try await fragment in stream {
                    try await emit(fragment)
                }
                return
            } catch {
                logFallback(
                    "image understanding failed",
                    file: file,
                    providerName: provider.name,
                    error: error
                )
            }

            if let ocrProvider = providedOCRProvider ?? settings.makeOCRProvider() {
                do {
                    let ocrText = normalized(try await ocrProvider.recognize(
                        imageData: image.data,
                        mimeType: image.mimeType
                    ))
                    if !ocrText.isEmpty {
                        try await streamText(
                            file: file,
                            title: file.title ?? metadata.title ?? file.name,
                            source: [metadata.text, ocrText].joined(separator: "\n\n"),
                            provider: provider,
                            emit: emit
                        )
                        return
                    }
                } catch {
                    logFallback(
                        "image OCR fallback failed",
                        file: file,
                        providerName: ocrProvider.name,
                        error: error
                    )
                }
            }
        }

        let fallbackSource = settings.localizedFormat(
            "The image itself could not be read. The following details come only from file metadata. Clearly state this limitation in the note.\n\n%@",
            metadata.text
        )
        try await streamText(
            file: file,
            title: file.title ?? metadata.title ?? file.name,
            source: fallbackSource,
            provider: provider,
            emit: emit
        )
    }

    private func streamText(
        file: FileRecord,
        title: String,
        source: String,
        provider: LLMProvider,
        emit: @escaping (String) async throws -> Void
    ) async throws {
        let prompt = settings.localizedFormat(
            "Write a concise note for this file. In 1–3 sentences, summarize its topic, key information, and purpose in no more than 180 words. Return only the note text without a Markdown heading.\n\nFile: %@\nTitle: %@\nContent or metadata:\n%@\n\nAnswer in the current interface language.",
            file.name,
            title,
            String(source.prefix(8_000))
        )
        for try await fragment in provider.streamChat(
            [ChatTurn(role: .user, content: prompt)],
            context: settings.localized("You are FileNest’s file summary assistant. Do not invent information that is not present in the source file.")
        ) {
            try await emit(fragment)
        }
    }

    private static func normalizedForDisplay(_ result: String) -> String {
        let cleaned = result
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        return String(limitToThreeSentences(cleaned).prefix(600))
    }

    private static func limitToThreeSentences(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var ranges = [Range<String.Index>]()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            ranges.append(range)
            return ranges.count < 4
        }
        guard ranges.count > 3, let end = ranges.prefix(3).last?.upperBound else { return text }
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func normalizedImageData(at url: URL) -> (data: Data, mimeType: String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_000,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.85]
        ) else { return nil }
        return (data, "image/jpeg")
    }

    private func logFallback(
        _ message: String,
        file: FileRecord,
        providerName: String,
        error: Error
    ) {
        AppLogService.shared.write(
            "\(message): \(error.localizedDescription)",
            category: .indexExtraction,
            level: .warning,
            metadata: ["file": file.name, "provider": providerName]
        )
    }

    private final class StreamAccumulator {
        private let continuation: AsyncThrowingStream<String, Error>.Continuation
        private let typingDelayNanoseconds: UInt64
        private var rawResult = ""
        private var lastDisplayed = ""

        init(
            continuation: AsyncThrowingStream<String, Error>.Continuation,
            typingDelayNanoseconds: UInt64
        ) {
            self.continuation = continuation
            self.typingDelayNanoseconds = typingDelayNanoseconds
        }

        func append(_ fragment: String) async throws {
            for character in fragment {
                try Task.checkCancellation()
                rawResult.append(character)
                let displayed = FileSummaryService.normalizedForDisplay(rawResult)
                if !displayed.isEmpty, displayed != lastDisplayed {
                    lastDisplayed = displayed
                    continuation.yield(displayed)
                }
                if typingDelayNanoseconds > 0 {
                    try await Task.sleep(nanoseconds: typingDelayNanoseconds)
                }
            }
        }

        func finish() throws {
            let final = FileSummaryService.normalizedForDisplay(rawResult)
            guard !final.isEmpty else { throw FileSummaryError.emptyResponse }
            if final != lastDisplayed { continuation.yield(final) }
        }
    }
}

enum FileSummaryError: LocalizedError {
    case modelDisabled
    case fileMissing
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .modelDisabled: return "Enable a local model or cloud API in AI Model settings first."
        case .fileMissing: return "The file is missing, so a summary cannot be generated."
        case .emptyResponse: return "The AI returned no summary. Please try again later."
        }
    }
}
