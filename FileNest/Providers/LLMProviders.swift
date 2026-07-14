import Foundation

// MARK: - LLM Providers

/// Ollama 本地（默认）：调用 /api/chat
final class OllamaLLMProvider: LLMProvider {
    let name = "ollama"
    private let host: String
    private let model: String
    private let session: URLSession
    init(host: String, model: String, session: URLSession = .shared) {
        self.host = host; self.model = model; self.session = session
    }

    func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
        guard let url = URL(string: "\(host)/api/chat") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        var msgs: [[String: String]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        // 若有检索 context，以 system 角色前置注入
        if let context, !context.isEmpty {
            msgs.insert(["role": "system", "content": context], at: 0)
        }
        let body: [String: Any] = ["model": model, "messages": msgs, "stream": false]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = obj["message"] as? [String: Any],
           let content = m["content"] as? String {
            return content
        }
        throw URLError(.cannotParseResponse)
    }
}

/// OpenAI 兼容 API（云端，可选）
final class OpenAICompatibleLLMProvider: LLMProvider {
    let name = "openai-compatible"
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let session: URLSession
    init(baseURL: String, apiKey: String, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.model = model; self.session = session
    }

    func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
        guard !apiKey.isEmpty else { throw NSError(domain: "filenest", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "未配置云端 API Key"]) }
        guard let url = URL(string: "\(baseURL)/chat/completions") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60

        var msgs: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        if let context, !context.isEmpty {
            msgs.insert(["role": "system", "content": context], at: 0)
        }
        let body: [String: Any] = ["model": model, "messages": msgs, "stream": false]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = obj["choices"] as? [[String: Any]],
           let msg = choices.first?["message"] as? [String: Any],
           let content = msg["content"] as? String {
            return content
        }
        throw URLError(.cannotParseResponse)
    }
}

/// 未配置/降级：返回提示，不抛错
final class NoopLLMProvider: LLMProvider {
    let name = "none"
    func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
        if let last = messages.last { return "（聊天功能已禁用）\n你的问题：\(last.content)" }
        return "（聊天功能已禁用，请在设置中启用本地 Ollama 或云端 API）"
    }
}
