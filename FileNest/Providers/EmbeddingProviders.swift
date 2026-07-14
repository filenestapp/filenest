import Foundation
import NaturalLanguage

// MARK: - Embedding Providers

/// Apple 内置 NLEmbedding：默认 Provider。离线、隐私、零配置、零依赖。
/// 统一使用英文模型（512 维），保证所有向量维度一致，避免中英文模型维度不同(640 vs 512)导致索引冲突。
/// 英文模型对中英混合文本也有基本支持。
///
/// 重要：NLEmbedding 及其底层 CoreNLP/BNNS 推理引擎不是线程安全的，
/// 并发调用会导致 BNNS 崩溃。因此用一个串行队列锁住所有 vector(for:) 调用。
final class NLEmbeddingProvider: EmbeddingProvider {
    let name = "nlembedding"
    let dimension = 512
    private let embedding: NLEmbedding?
    /// 串行队列：序列化所有 NLEmbedding 调用（BNNS 非线程安全）
    private let embedQueue = DispatchQueue(label: "filenest.nlembed")

    init?() {
        // 固定用英文模型，保证维度一致（中文模型是 640 维）
        if let e = NLEmbedding.sentenceEmbedding(for: .english) { self.embedding = e; return }
        // 极少数机器上找不到模型文件，返回 nil 由调用方回退到 Ollama
        self.embedding = nil
        return nil
    }

    func embed(_ text: String) async throws -> [Float] {
        guard let embedding else { return [] }
        // 在串行队列上同步执行，保证 BNNS 不会被并发调用
        let vec: [Double]? = embedQueue.sync {
            embedding.vector(for: text)
        }
        // 转成 Float 并归一化（后续 cosine）
        guard let vec, !vec.isEmpty else { return [] }
        let f = vec.map { Float($0) }
        return AccelerateVectorStore.normalize(f)
    }
}

/// Ollama embedding（可选，需本地装 nomic-embed-text 等模型）
final class OllamaEmbeddingProvider: EmbeddingProvider {
    let name: String
    let dimension = 768
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
        guard let url = URL(string: "\(host)/api/embeddings") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = ["model": model, "prompt": text]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let emb = obj["embedding"] as? [Double] {
            return emb.map { Float($0) }
        }
        throw URLError(.cannotParseResponse)
    }
}
