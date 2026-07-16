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

/// OCR for images or scanned documents. The caller converts pages into size-limited image data.
protocol OCRProvider {
    var name: String { get }
    func recognize(imageData: Data, mimeType: String) async throws -> String
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
    case note
    case metadata
}

struct StructuredDocumentChunk: Equatable, Codable, Sendable {
    let text: String
    let contextualText: String
    let sectionPath: [String]
    let pageStart: Int?
    let pageEnd: Int?
    let kind: DocumentChunkKind

    init(text: String,
         contextualText: String? = nil,
         sectionPath: [String] = [],
         pageStart: Int? = nil,
         pageEnd: Int? = nil,
         kind: DocumentChunkKind = .text) {
        self.text = text
        self.contextualText = contextualText ?? text
        self.sectionPath = sectionPath
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.kind = kind
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

    init(vector: [Float],
         text: String?,
         contextualText: String? = nil,
         sectionPath: [String] = [],
         pageStart: Int? = nil,
         pageEnd: Int? = nil,
         kind: DocumentChunkKind = .text) {
        self.vector = vector
        self.text = text
        self.contextualText = contextualText ?? text
        self.sectionPath = sectionPath
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.kind = kind
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

    init(fileId: Int64,
         score: Float,
         chunkText: String?,
         chunkIndex: Int? = nil,
         sectionPath: [String] = [],
         pageStart: Int? = nil,
         pageEnd: Int? = nil,
         kind: DocumentChunkKind = .text) {
        self.fileId = fileId
        self.score = score
        self.chunkText = chunkText
        self.chunkIndex = chunkIndex
        self.sectionPath = sectionPath
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.kind = kind
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
