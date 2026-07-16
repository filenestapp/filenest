import Foundation
import NaturalLanguage

// MARK: - Embedding Providers

enum EmbeddingProviderError: LocalizedError, Equatable {
    case httpStatus(code: Int, body: String)
    case responseCount(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case let .httpStatus(code, body):
            return body.isEmpty
                ? "Embedding request failed with HTTP \(code)"
                : "Embedding request failed with HTTP \(code): \(body)"
        case let .responseCount(expected, actual):
            return "Embedding response returned \(actual) vectors; expected \(expected)"
        }
    }
}

private actor OllamaEmbeddingRequestGate {
    static let shared = OllamaEmbeddingRequestGate()

    private var isBusy = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isBusy = false
            return
        }
        waiters.removeFirst().resume()
    }
}

/// Apple's built-in NLEmbedding default provider: offline, private, zero-configuration, and dependency-free.
/// Uses the 512-dimensional English model consistently, avoiding index conflicts with the 640-dimensional Chinese model.
/// The English model also provides basic support for mixed English and Chinese text.
///
/// Important: NLEmbedding and its underlying CoreNLP and BNNS inference engines are not thread-safe,
/// and concurrent calls can crash BNNS. A serial queue therefore protects every vector(for:) call.
final class NLEmbeddingProvider: EmbeddingProvider {
    let name = "nlembedding"
    let dimension = 512
    private let embedding: NLEmbedding?
    /// Serial queue for all NLEmbedding calls because BNNS is not thread-safe.
    private let embedQueue = DispatchQueue(label: "filenest.nlembed")

    init?() {
        // Use the English model consistently for matching dimensions; the Chinese model has 640 dimensions.
        if let e = NLEmbedding.sentenceEmbedding(for: .english) { self.embedding = e; return }
        // Return nil on the rare machine where the model file is missing so the caller can fall back to Ollama.
        self.embedding = nil
        return nil
    }

    func embed(_ text: String) async throws -> [Float] {
        guard let embedding else { return [] }
        // Execute synchronously on the serial queue so BNNS is never called concurrently.
        let vec: [Double]? = embedQueue.sync {
            embedding.vector(for: text)
        }
        // Convert to Float and normalize for later cosine similarity.
        guard let vec, !vec.isEmpty else { return [] }
        let f = vec.map { Float($0) }
        return AccelerateVectorStore.normalize(f)
    }
}

/// Ollama embeddings through the current official `/api/embed` endpoint; settings default to qwen3-embedding.
final class OllamaEmbeddingProvider: EmbeddingProvider {
    let name: String
    let dimension = 0
    let maximumBatchSize = 2
    private let host: String
    private let model: String
    private let session: URLSession
    init(host: String, model: String, session: URLSession = .shared) {
        self.host = host
        self.model = model
        self.session = session
        self.name = "ollama:\(model)"
    }

    func embed(_ text: String) async throws -> [Float] {
        guard let first = try await embedBatch([text]).first else {
            throw URLError(.cannotParseResponse)
        }
        return first
    }

    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        await OllamaEmbeddingRequestGate.shared.acquire()
        do {
            let result = try await performEmbedBatch(texts)
            await OllamaEmbeddingRequestGate.shared.release()
            return result
        } catch {
            await OllamaEmbeddingRequestGate.shared.release()
            throw error
        }
    }

    private func performEmbedBatch(_ texts: [String]) async throws -> [[Float]] {
        let base = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/embed") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = ["model": model, "input": texts, "truncate": true]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw EmbeddingProviderError.httpStatus(
                code: http.statusCode,
                body: Self.responsePreview(data)
            )
        }
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let embeddings = obj["embeddings"] as? [[Double]] {
            guard embeddings.count == texts.count else {
                throw EmbeddingProviderError.responseCount(
                    expected: texts.count,
                    actual: embeddings.count
                )
            }
            return embeddings.map { $0.map(Float.init) }
        }
        throw URLError(.cannotParseResponse)
    }

    private static func responsePreview(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String {
            return String(message.prefix(1_000))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(decoding: data.prefix(1_000), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// OpenAI-compatible cloud embeddings (`POST /embeddings`).
final class OpenAICompatibleEmbeddingProvider: EmbeddingProvider {
    let name: String
    let dimension = 0
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let session: URLSession

    init(baseURL: String, apiKey: String, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.name = "cloud-embedding:\(model)"
    }

    func embed(_ text: String) async throws -> [Float] {
        guard let first = try await embedBatch([text]).first else {
            throw URLError(.cannotParseResponse)
        }
        return first
    }

    func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/embeddings") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": texts,
            "encoding_format": "float",
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["data"] as? [[String: Any]],
              results.count == texts.count else { throw URLError(.cannotParseResponse) }
        let ordered = results.sorted {
            ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0)
        }
        let embeddings = ordered.compactMap { $0["embedding"] as? [Double] }
        guard embeddings.count == texts.count else { throw URLError(.cannotParseResponse) }
        return embeddings.map { $0.map(Float.init) }
    }
}
