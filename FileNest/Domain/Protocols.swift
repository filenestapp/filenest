import Foundation

// MARK: - Provider 协议（可插拔：默认实现 + 可切换）

/// 文本向量化
protocol EmbeddingProvider {
    var name: String { get }
    var dimension: Int { get }
    func embed(_ text: String) async throws -> [Float]
}

/// 对话大模型
protocol LLMProvider {
    var name: String { get }
    func chat(_ messages: [ChatTurn], context: String?) async throws -> String
}

/// 对话轮次（传输用，不依赖 DB 模型）
struct ChatTurn {
    let role: ChatRole
    let content: String
}

/// 向量存储与检索
struct EmbeddingChunk {
    let vector: [Float]
    let text: String?
}

protocol VectorStore {
    /// 原子替换一个文件的全部分块，避免持久化与内存索引出现半更新状态。
    @discardableResult
    func replace(fileId: Int64, chunks: [EmbeddingChunk], model: String) async -> Bool
    func remove(fileId: Int64) async
    func search(_ query: [Float], k: Int) async -> [(fileId: Int64, score: Float)]
    func loadAll() async  // 启动时载入内存索引
    var count: Int { get }
}

/// 分类器
protocol Classifier {
    func classify(_ file: FileRecord) -> ClassificationDecision?
}
