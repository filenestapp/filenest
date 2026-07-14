import Foundation

/// 聊天服务：用户问题 -> 向量检索相关文件 -> 拼 context -> LLM -> 引用文件。
/// RAG 检索 + 文件引用。
final class ChatService {
    private let store: SQLiteStore
    private let settings: AppSettings
    private lazy var embedder: EmbeddingProvider = settings.makeEmbeddingProvider()

    init(store: SQLiteStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    func loadHistory() -> [ChatMessage] {
        var msgs = (try? store.allChatMessages()) ?? []
        // 附带 relatedFiles
        for i in msgs.indices {
            msgs[i].relatedFiles = resolveRelated(from: msgs[i])
        }
        return msgs
    }

    private func resolveRelated(from msg: ChatMessage) -> [FileRecord] {
        guard let json = msg.relatedFileIds,
              let ids = try? JSONDecoder().decode([Int64].self, from: Data(json.utf8)) else { return [] }
        return ids.compactMap { try? store.file(id: $0) }
    }

    /// 一次问答：保存用户消息 -> 检索 -> 调 LLM -> 保存回复
    func ask(_ question: String) async -> ChatMessage {
        // 1. 保存用户消息
        let userMsg = ChatMessage(id: nil, role: ChatRole.user.rawValue, content: question,
                                  ts: Date(), relatedFileIds: nil)
        _ = try? store.addChatMessage(userMsg)

        // 2. 向量检索相关文件（RAG）
        let related: [FileRecord]
        let context: String
        if let qvec = try? await embedder.embed(question), !qvec.isEmpty {
            // 用 IndexerService 的向量库检索；这里复用 AppState 中的实例
            let store = AppStateIndexerProxy.shared.vectorStore
            let hits = await store.search(qvec, k: 5)
            related = hits.compactMap { (id, score) in
                try? self.store.file(id: id)
            }
        } else {
            // embedding 不可用：退化为关键词检索
            related = (try? self.store.files(matching: question)) ?? []
        }

        context = buildContext(from: related)

        // 3. 构造对话 + 调 LLM
        let history = (try? self.store.allChatMessages())?
            .filter { $0.role != ChatRole.system.rawValue }
            .map { ChatTurn(role: ChatRole(rawValue: $0.role) ?? .user, content: $0.content) }
            ?? []
        // 截断历史，避免 token 爆炸（最近 8 轮）
        let turns = Array(history.suffix(16))
        let provider = settings.makeLLMProvider()

        let reply: String
        do {
            reply = try await provider.chat(turns, context: context)
        } catch {
            reply = "⚠️ 调用 LLM 失败：\(error.localizedDescription)\n\n如果是本地 Ollama，请确认已安装并启动，模型 \(settings.ollamaModel) 已拉取（终端运行 `ollama pull \(settings.ollamaModel)`）。"
        }

        // 4. 保存回复（带引用）
        let ids = related.map { $0.id ?? -1 }.filter { $0 > 0 }
        let idJSON = (try? JSONEncoder().encode(ids)).flatMap { String(data: $0, encoding: .utf8) }
        var assistantMsg = ChatMessage(id: nil, role: ChatRole.assistant.rawValue, content: reply,
                                       ts: Date(), relatedFileIds: idJSON)
        assistantMsg.relatedFiles = related
        _ = try? store.addChatMessage(assistantMsg)
        return assistantMsg
    }

    /// 把检索到的文件拼成给 LLM 的上下文
    private func buildContext(from files: [FileRecord]) -> String {
        guard !files.isEmpty else {
            return "你是一个文件助手。用户本地文件库中未找到高度相关的内容，请如实告知，并可建议用户用更具体的关键词描述文件。"
        }
        var lines = ["以下是用户本地文件库中与本问题相关的文件信息（供参考，回答时请引用对应文件名）：\n"]
        for (i, f) in files.enumerated() {
            var line = "[\(i+1)] 文件名：\(f.name)"
            if let t = f.title, !t.isEmpty { line += "；标题：\(t)" }
            line += "；类别：\(f.categoryEnum.label)"
            line += "；路径：\(f.path)"
            if let c = f.contentText, !c.isEmpty {
                line += "\n   摘要：\(String(c.prefix(300)))"
            }
            lines.append(line)
        }
        lines.append("\n请基于以上信息回答用户问题，并在适用时指明引用了哪个文件。如果信息不足以回答，请说明。")
        return lines.joined(separator: "\n")
    }

    func clearHistory() {
        _ = try? store.dbPool.write { db in
            try db.execute(sql: "DELETE FROM chat_messages")
        }
    }
}

/// 轻量代理，用于访问 IndexerService 的向量库（避免 ChatService 持有 IndexerService 形成循环）
/// 由 AppState 在启动时注入。
final class AppStateIndexerProxy {
    static let shared = AppStateIndexerProxy()
    weak var indexer: IndexerService?
    var vectorStore: AccelerateVectorStore {
        indexer?.vectorStore ?? AccelerateVectorStore(store: SQLiteStore.shared)
    }
}
