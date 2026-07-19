import Foundation

// MARK: - Provider Protocols (Pluggable Defaults and Alternatives)

/// Text embedding provider.
protocol EmbeddingProvider {
    var name: String { get }
    var dimension: Int { get }
    var maximumBatchSize: Int { get }
    func embed(_ text: String) async throws -> [Float]
    func embedBatch(_ texts: [String]) async throws -> [[Float]]
}

extension EmbeddingProvider {
    var maximumBatchSize: Int { 16 }

    /// Providers without a native batch endpoint keep the existing behavior.
    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        var result = [[Float]]()
        result.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            result.append(try await embed(text))
        }
        return result
    }
}

struct OCRBoundingBox: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var minX: Double { x }
    var minY: Double { y }
    var maxX: Double { x + width }
    var maxY: Double { y + height }
}

struct OCRTextObservation: Equatable, Sendable {
    let text: String
    let confidence: Double?
    let bounds: OCRBoundingBox?
}

struct OCRRecognitionResult: Equatable, Sendable {
    let text: String
    let observations: [OCRTextObservation]

    init(text: String, observations: [OCRTextObservation] = []) {
        self.text = text
        self.observations = observations
    }
}

/// OCR for images or scanned documents. Providers may return positioned observations
/// so large-image callers can merge overlapping tiles without losing reading order.
protocol OCRProvider {
    var name: String { get }
    func recognize(imageData: Data, mimeType: String) async throws -> String
    func recognizeResult(imageData: Data, mimeType: String) async throws -> OCRRecognitionResult
}

extension OCRProvider {
    func recognizeResult(imageData: Data, mimeType: String) async throws -> OCRRecognitionResult {
        OCRRecognitionResult(text: try await recognize(imageData: imageData, mimeType: mimeType))
    }
}

/// Large language model for conversations.
protocol LLMProvider {
    var name: String { get }
    func chat(_ messages: [ChatTurn], context: String?) async throws -> String
    func chatWithImage(
        prompt: String,
        imageData: Data,
        mimeType: String,
        context: String?
    ) async throws -> String
    func streamChatWithImage(
        prompt: String,
        imageData: Data,
        mimeType: String,
        context: String?
    ) -> AsyncThrowingStream<String, Error>
    func streamChat(_ messages: [ChatTurn], context: String?) -> AsyncThrowingStream<String, Error>
}

extension LLMProvider {
    func chatWithImage(
        prompt: String,
        imageData: Data,
        mimeType: String,
        context: String?
    ) async throws -> String {
        throw LLMProviderCapabilityError.imageInputUnsupported
    }

    /// Compatibility implementation for non-streaming vision providers; streaming providers override this method.
    func streamChatWithImage(
        prompt: String,
        imageData: Data,
        mimeType: String,
        context: String?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await chatWithImage(
                        prompt: prompt,
                        imageData: imageData,
                        mimeType: mimeType,
                        context: context
                    )
                    if !result.isEmpty { continuation.yield(result) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Compatibility implementation for non-streaming providers; native streaming providers override this method.
    func streamChat(_ messages: [ChatTurn], context: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await chat(messages, context: context)
                    if !result.isEmpty { continuation.yield(result) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

enum LLMProviderCapabilityError: LocalizedError {
    case imageInputUnsupported

    var errorDescription: String? {
        switch self {
        case .imageInputUnsupported:
            return "The current model does not support image input."
        }
    }
}

/// Conversation turn used for transport, independent of database models.
struct ChatTurn {
    let role: ChatRole
    let content: String
}

/// Vector storage and retrieval.
enum DocumentChunkKind: String, Codable, Sendable {
    case title
    case text
    case table
    case list
    case picture
    case transcript
    case note
    case metadata
}

enum TokenCountAccuracy: String, Codable, Sendable {
    case exact
    case estimated
}

struct TokenMeasurement: Equatable, Codable, Sendable {
    let count: Int
    let tokenizerProfile: String
    let tokenizerVersion: String
    let accuracy: TokenCountAccuracy
}

/// Canonical token accounting shared by native chunking, context planning, persistence,
/// previews, and usage fallbacks. Exact counts supplied by a model tokenizer always win.
enum TokenCounter {
    static let canonicalProfile = "qwen3-embedding:0.6b"
    static let canonicalVersion = "qwen3-embedding-0.6b-v1"
    static let generationFallbackProfile = "generation-fallback:qwen3-compatible"
    static let generationFallbackVersion = "filenest-unicode-v1"

    static func estimate(
        _ text: String,
        profile: String = canonicalProfile,
        version: String = canonicalVersion
    ) -> TokenMeasurement {
        let count = estimatedWeights(Array(text)).reduce(0, +)
        return TokenMeasurement(
            count: text.isEmpty ? 0 : max(1, Int(ceil(count))),
            tokenizerProfile: profile,
            tokenizerVersion: version,
            accuracy: .estimated
        )
    }

    static func exact(
        count: Int,
        profile: String = canonicalProfile,
        version: String = canonicalVersion
    ) -> TokenMeasurement {
        TokenMeasurement(
            count: max(0, count),
            tokenizerProfile: profile,
            tokenizerVersion: version,
            accuracy: .exact
        )
    }

    static func estimatedWeights(_ characters: [Character]) -> [Double] {
        var weights = Array(repeating: 0.0, count: characters.count)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if isCJKCharacter(character) {
                weights[index] = 2.0 / 3.0
                index += 1
            } else if isASCIIWordCharacter(character) {
                let start = index
                while index < characters.count, isASCIIWordCharacter(characters[index]) {
                    index += 1
                }
                let perCharacter = (4.0 / 3.0) / Double(index - start)
                for wordIndex in start..<index { weights[wordIndex] = perCharacter }
            } else {
                // Symbols often form individual tokens, so keeping a weight of one avoids
                // underestimating source code, identifiers, and dense tabular content.
                weights[index] = 1
                index += 1
            }
        }
        return weights
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            guard scalar.isASCII else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
                || scalar.value == 0x27
                || scalar.value == 0x2D
                || scalar.value == 0x5F
        }
    }

    private static func isCJKCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2A6DF, 0x2A700...0x2EBEF, 0x30000...0x323AF:
                return true
            default:
                return false
            }
        }
    }
}

struct StructuredDocumentChunk: Equatable, Codable, Sendable {
    let text: String
    let contextualText: String
    let sectionPath: [String]
    let pageStart: Int?
    let pageEnd: Int?
    let kind: DocumentChunkKind
    /// Stable source unit shown to the model after a smaller retrieval child matches.
    let parentIndex: Int?
    let parentText: String?
    /// Exact identifiers and business entities extracted without an LLM.
    let entityTerms: [String]
    let tokenCount: Int?
    let tokenizerProfile: String?
    let tokenizerVersion: String?
    let tokenCountAccuracy: TokenCountAccuracy?

    init(text: String,
         contextualText: String? = nil,
         sectionPath: [String] = [],
         pageStart: Int? = nil,
         pageEnd: Int? = nil,
         kind: DocumentChunkKind = .text,
         parentIndex: Int? = nil,
         parentText: String? = nil,
         entityTerms: [String] = [],
         tokenCount: Int? = nil,
         tokenizerProfile: String? = nil,
         tokenizerVersion: String? = nil,
         tokenCountAccuracy: TokenCountAccuracy? = nil) {
        let contextualText = contextualText ?? text
        let fallback = TokenCounter.estimate(contextualText)
        self.text = text
        self.contextualText = contextualText
        self.sectionPath = sectionPath
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.kind = kind
        self.parentIndex = parentIndex
        self.parentText = parentText
        self.entityTerms = entityTerms
        self.tokenCount = tokenCount ?? fallback.count
        self.tokenizerProfile = tokenizerProfile ?? fallback.tokenizerProfile
        self.tokenizerVersion = tokenizerVersion ?? fallback.tokenizerVersion
        self.tokenCountAccuracy = tokenCountAccuracy ?? fallback.accuracy
    }
}

struct EmbeddingChunk {
    let vector: [Float]
    let text: String?
    let contextualText: String?
    let sectionPath: [String]
    let pageStart: Int?
    let pageEnd: Int?
    let kind: DocumentChunkKind
    let parentIndex: Int?
    let parentText: String?
    let entityTerms: [String]
    let tokenCount: Int
    let tokenizerProfile: String
    let tokenizerVersion: String
    let tokenCountAccuracy: TokenCountAccuracy

    init(vector: [Float],
         text: String?,
         contextualText: String? = nil,
         sectionPath: [String] = [],
         pageStart: Int? = nil,
         pageEnd: Int? = nil,
         kind: DocumentChunkKind = .text,
         parentIndex: Int? = nil,
         parentText: String? = nil,
         entityTerms: [String] = [],
         tokenCount: Int? = nil,
         tokenizerProfile: String? = nil,
         tokenizerVersion: String? = nil,
         tokenCountAccuracy: TokenCountAccuracy? = nil) {
        let contextualText = contextualText ?? text ?? ""
        let fallback = TokenCounter.estimate(contextualText)
        self.vector = vector
        self.text = text
        self.contextualText = contextualText
        self.sectionPath = sectionPath
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.kind = kind
        self.parentIndex = parentIndex
        self.parentText = parentText
        self.entityTerms = entityTerms
        self.tokenCount = tokenCount ?? fallback.count
        self.tokenizerProfile = tokenizerProfile ?? fallback.tokenizerProfile
        self.tokenizerVersion = tokenizerVersion ?? fallback.tokenizerVersion
        self.tokenCountAccuracy = tokenCountAccuracy ?? fallback.accuracy
    }
}

struct VectorSearchHit {
    let fileId: Int64
    let score: Float
    let chunkText: String?
    let chunkIndex: Int?
    let sectionPath: [String]
    let pageStart: Int?
    let pageEnd: Int?
    let kind: DocumentChunkKind
    let parentIndex: Int?
    let parentText: String?
    let entityTerms: [String]

    init(fileId: Int64,
         score: Float,
         chunkText: String?,
         chunkIndex: Int? = nil,
         sectionPath: [String] = [],
         pageStart: Int? = nil,
         pageEnd: Int? = nil,
         kind: DocumentChunkKind = .text,
         parentIndex: Int? = nil,
         parentText: String? = nil,
         entityTerms: [String] = []) {
        self.fileId = fileId
        self.score = score
        self.chunkText = chunkText
        self.chunkIndex = chunkIndex
        self.sectionPath = sectionPath
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.kind = kind
        self.parentIndex = parentIndex
        self.parentText = parentText
        self.entityTerms = entityTerms
    }
}

protocol VectorStore {
    /// Atomically replaces every chunk for one file, preventing partially updated persistent and in-memory indexes.
    @discardableResult
    func replace(fileId: Int64, chunks: [EmbeddingChunk], model: String) async -> Bool
    func remove(fileId: Int64) async
    func search(_ query: [Float], k: Int) async -> [(fileId: Int64, score: Float)]
    func searchChunks(_ query: [Float], k: Int) async -> [VectorSearchHit]
    func searchChunks(_ query: [Float], fileId: Int64, k: Int) async -> [VectorSearchHit]
    func neighboringChunks(fileId: Int64, around chunkIndex: Int, radius: Int) async -> [VectorSearchHit]
    func loadAll() async  // Load the in-memory index at startup.
    var count: Int { get }
}

struct RerankItem: Sendable {
    let index: Int
    let score: Double
}

protocol RerankingProvider: Sendable {
    var name: String { get }
    func rerank(query: String, documents: [String], topN: Int) async throws -> [RerankItem]
}

extension VectorStore {
    func searchChunks(_ query: [Float], k: Int) async -> [VectorSearchHit] {
        await search(query, k: k).map {
            VectorSearchHit(fileId: $0.fileId, score: $0.score, chunkText: nil)
        }
    }

    func searchChunks(_ query: [Float], fileId: Int64, k: Int) async -> [VectorSearchHit] {
        guard k > 0 else { return [] }
        return Array(await searchChunks(query, k: max(k * 4, k))
            .filter { $0.fileId == fileId }
            .prefix(k))
    }

    func neighboringChunks(fileId: Int64, around chunkIndex: Int, radius: Int) async -> [VectorSearchHit] {
        []
    }
}

/// Classifier.
protocol Classifier {
    func classify(_ file: FileRecord) -> ClassificationDecision?
}
