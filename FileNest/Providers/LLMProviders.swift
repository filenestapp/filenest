import Foundation

// MARK: - LLM Providers

/// Local Ollama provider, enabled by default, using /api/chat.
final class OllamaLLMProvider: LLMProvider {
    let name = "ollama"
    private let host: String
    private let model: String
    private let thinkingEnabled: Bool
    private let session: URLSession
    init(host: String, model: String, thinkingEnabled: Bool = false, session: URLSession = .shared) {
        self.host = host
        self.model = model
        self.thinkingEnabled = thinkingEnabled
        self.session = session
    }

    func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
        guard let url = URL(string: "\(host)/api/chat") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        var msgs: [[String: String]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        // Prepend retrieval context as a system message when present.
        if let context, !context.isEmpty {
            msgs.insert(["role": "system", "content": context], at: 0)
        }
        var body: [String: Any] = ["model": model, "messages": msgs, "stream": false]
        if thinkingEnabled { body["think"] = true }
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

    func chatWithImage(
        prompt: String,
        imageData: Data,
        mimeType: String,
        context: String?
    ) async throws -> String {
        guard let url = URL(string: "\(host)/api/chat") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var messages = [[String: Any]]()
        if let context, !context.isEmpty {
            messages.append(["role": "system", "content": context])
        }
        messages.append([
            "role": "user",
            "content": prompt,
            "images": [imageData.base64EncodedString()],
        ])
        var body: [String: Any] = ["model": model, "messages": messages, "stream": false]
        if thinkingEnabled { body["think"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateLLMResponse(response)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        throw URLError(.cannotParseResponse)
    }

    func streamChatWithImage(
        prompt: String,
        imageData: Data,
        mimeType: String,
        context: String?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "\(host)/api/chat") else { throw URLError(.badURL) }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 120

                    var messages = [[String: Any]]()
                    if let context, !context.isEmpty {
                        messages.append(["role": "system", "content": context])
                    }
                    messages.append([
                        "role": "user",
                        "content": prompt,
                        "images": [imageData.base64EncodedString()],
                    ])
                    var body: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "stream": true,
                    ]
                    if self.thinkingEnabled { body["think"] = true }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    try validateLLMResponse(response)
                    for try await line in bytes.lines where !line.isEmpty {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if let serverError = object["error"] as? String {
                            throw providerError(serverError)
                        }
                        if let message = object["message"] as? [String: Any],
                           let content = message["content"] as? String,
                           !content.isEmpty {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func streamChat(_ messages: [ChatTurn], context: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = URL(string: "\(host)/api/chat") else { throw URLError(.badURL) }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 120

                    var payload = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
                    if let context, !context.isEmpty {
                        payload.insert(["role": "system", "content": context], at: 0)
                    }
                    var body: [String: Any] = [
                        "model": model,
                        "messages": payload,
                        "stream": true,
                    ]
                    if self.thinkingEnabled { body["think"] = true }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    try validateLLMResponse(response)
                    for try await line in bytes.lines where !line.isEmpty {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if let serverError = object["error"] as? String {
                            throw providerError(serverError)
                        }
                        if let message = object["message"] as? [String: Any],
                           let content = message["content"] as? String,
                           !content.isEmpty {
                            continuation.yield(content)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Optional cloud provider for OpenAI-compatible APIs.
final class OpenAICompatibleLLMProvider: LLMProvider {
    let name = "openai-compatible"
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let thinkingEnabled: Bool
    private let session: URLSession
    init(baseURL: String, apiKey: String, model: String,
         thinkingEnabled: Bool = false, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.thinkingEnabled = thinkingEnabled
        self.session = session
    }

    func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
        guard !apiKey.isEmpty else { throw NSError(domain: "filenest", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Cloud API key is not configured"]) }
        guard let url = providerEndpoint(baseURL: baseURL, path: "chat/completions") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 60

        var msgs: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        if let context, !context.isEmpty {
            msgs.insert(["role": "system", "content": context], at: 0)
        }
        var body: [String: Any] = ["model": model, "messages": msgs, "stream": false]
        if thinkingEnabled { body["reasoning_effort"] = "medium" }
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

    func chatWithImage(
        prompt: String,
        imageData: Data,
        mimeType: String,
        context: String?
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw providerError("Cloud API key is not configured") }
        guard let url = providerEndpoint(baseURL: baseURL, path: "chat/completions") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let dataURL = "data:\(mimeType);base64,\(imageData.base64EncodedString())"
        var messages = [[String: Any]]()
        if let context, !context.isEmpty {
            messages.append(["role": "system", "content": context])
        }
        messages.append([
            "role": "user",
            "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": dataURL]],
            ],
        ])
        var body: [String: Any] = ["model": model, "messages": messages, "stream": false]
        if thinkingEnabled { body["reasoning_effort"] = "medium" }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateLLMResponse(response)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = object["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        throw URLError(.cannotParseResponse)
    }

    func streamChatWithImage(
        prompt: String,
        imageData: Data,
        mimeType: String,
        context: String?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw providerError("Cloud API key is not configured") }
                    guard let url = providerEndpoint(baseURL: baseURL, path: "chat/completions") else {
                        throw URLError(.badURL)
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.timeoutInterval = 120

                    let dataURL = "data:\(mimeType);base64,\(imageData.base64EncodedString())"
                    var messages = [[String: Any]]()
                    if let context, !context.isEmpty {
                        messages.append(["role": "system", "content": context])
                    }
                    messages.append([
                        "role": "user",
                        "content": [
                            ["type": "text", "text": prompt],
                            ["type": "image_url", "image_url": ["url": dataURL]],
                        ],
                    ])
                    var body: [String: Any] = [
                        "model": model,
                        "messages": messages,
                        "stream": true,
                    ]
                    if self.thinkingEnabled { body["reasoning_effort"] = "medium" }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    try validateLLMResponse(response)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if raw == "[DONE]" { break }
                        guard let data = raw.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = object["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String,
                              !content.isEmpty else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func streamChat(_ messages: [ChatTurn], context: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw providerError("Cloud API key is not configured") }
                    guard let url = providerEndpoint(baseURL: baseURL, path: "chat/completions") else {
                        throw URLError(.badURL)
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.timeoutInterval = 120

                    var payload = messages.map { ["role": $0.role.rawValue, "content": $0.content] }
                    if let context, !context.isEmpty {
                        payload.insert(["role": "system", "content": context], at: 0)
                    }
                    var body: [String: Any] = [
                        "model": model,
                        "messages": payload,
                        "stream": true,
                    ]
                    if self.thinkingEnabled { body["reasoning_effort"] = "medium" }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    try validateLLMResponse(response)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if raw == "[DONE]" { break }
                        guard let data = raw.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = object["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String,
                              !content.isEmpty else { continue }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Optional cloud provider for the Anthropic Messages API.
final class AnthropicLLMProvider: LLMProvider {
    let name = "anthropic"
    private let baseURL: String
    private let apiKey: String
    private let model: String
    private let thinkingEnabled: Bool
    private let session: URLSession

    init(baseURL: String, apiKey: String, model: String,
         thinkingEnabled: Bool = false, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.thinkingEnabled = thinkingEnabled
        self.session = session
    }

    func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
        guard !apiKey.isEmpty else {
            throw NSError(
                domain: "filenest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cloud API key is not configured"]
            )
        }
        guard let url = providerEndpoint(baseURL: baseURL, path: "messages") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 60

        let systemParts = ([context].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        } + messages.filter { $0.role == .system }.map(\.content))
        let messagePayload: [[String: String]] = messages.compactMap { turn in
            guard turn.role != .system else { return nil }
            return ["role": turn.role.rawValue, "content": turn.content]
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4_096,
            "messages": messagePayload,
        ]
        if !systemParts.isEmpty {
            body["system"] = systemParts.joined(separator: "\n\n")
        }
        if thinkingEnabled {
            body["thinking"] = ["type": "enabled", "budget_tokens": 1_024]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let blocks = object["content"] as? [[String: Any]] {
            let text = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined()
            if !text.isEmpty { return text }
        }
        throw URLError(.cannotParseResponse)
    }

    func chatWithImage(
        prompt: String,
        imageData: Data,
        mimeType: String,
        context: String?
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw providerError("Cloud API key is not configured") }
        guard let url = providerEndpoint(baseURL: baseURL, path: "messages") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1_024,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": [
                        "type": "base64",
                        "media_type": mimeType,
                        "data": imageData.base64EncodedString(),
                    ]],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]
        if let context, !context.isEmpty { body["system"] = context }
        if thinkingEnabled {
            body["thinking"] = ["type": "enabled", "budget_tokens": 1_024]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try validateLLMResponse(response)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let blocks = object["content"] as? [[String: Any]] {
            let text = blocks.compactMap { block -> String? in
                block["type"] as? String == "text" ? block["text"] as? String : nil
            }.joined()
            if !text.isEmpty { return text }
        }
        throw URLError(.cannotParseResponse)
    }

    func streamChatWithImage(
        prompt: String,
        imageData: Data,
        mimeType: String,
        context: String?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw providerError("Cloud API key is not configured") }
                    guard let url = providerEndpoint(baseURL: baseURL, path: "messages") else {
                        throw URLError(.badURL)
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.timeoutInterval = 120

                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": 1_024,
                        "messages": [[
                            "role": "user",
                            "content": [
                                ["type": "image", "source": [
                                    "type": "base64",
                                    "media_type": mimeType,
                                    "data": imageData.base64EncodedString(),
                                ]],
                                ["type": "text", "text": prompt],
                            ],
                        ]],
                        "stream": true,
                    ]
                    if let context, !context.isEmpty { body["system"] = context }
                    if self.thinkingEnabled {
                        body["thinking"] = ["type": "enabled", "budget_tokens": 1_024]
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    try validateLLMResponse(response)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard let data = raw.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if object["type"] as? String == "error",
                           let error = object["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            throw providerError(message)
                        }
                        guard object["type"] as? String == "content_block_delta",
                              let delta = object["delta"] as? [String: Any],
                              delta["type"] as? String == "text_delta",
                              let text = delta["text"] as? String,
                              !text.isEmpty else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func streamChat(_ messages: [ChatTurn], context: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw providerError("Cloud API key is not configured") }
                    guard let url = providerEndpoint(baseURL: baseURL, path: "messages") else {
                        throw URLError(.badURL)
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.timeoutInterval = 120

                    let systemParts = ([context].compactMap { value in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    } + messages.filter { $0.role == .system }.map(\.content))
                    let messagePayload = messages.compactMap { turn -> [String: String]? in
                        guard turn.role != .system else { return nil }
                        return ["role": turn.role.rawValue, "content": turn.content]
                    }
                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": 4_096,
                        "messages": messagePayload,
                        "stream": true,
                    ]
                    if !systemParts.isEmpty { body["system"] = systemParts.joined(separator: "\n\n") }
                    if self.thinkingEnabled {
                        body["thinking"] = ["type": "enabled", "budget_tokens": 1_024]
                    }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: request)
                    try validateLLMResponse(response)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let raw = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        guard let data = raw.data(using: .utf8),
                              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        if object["type"] as? String == "error",
                           let error = object["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            throw providerError(message)
                        }
                        guard object["type"] as? String == "content_block_delta",
                              let delta = object["delta"] as? [String: Any],
                              delta["type"] as? String == "text_delta",
                              let text = delta["text"] as? String,
                              !text.isEmpty else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private func providerEndpoint(baseURL: String, path: String) -> URL? {
    let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !base.isEmpty else { return nil }
    return URL(string: "\(base)/\(path)")
}

private func validateLLMResponse(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
    }
}

private func providerError(_ message: String) -> NSError {
    NSError(domain: "filenest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

/// Unconfigured fallback that returns guidance instead of throwing.
final class NoopLLMProvider: LLMProvider {
    let name = "none"
    private let questionFormat: String
    private let disabledMessage: String

    init(questionFormat: String = "Chat is disabled.\nYour question: %@",
         disabledMessage: String = "Chat is disabled. Enable local Ollama or a cloud API in Settings.") {
        self.questionFormat = questionFormat
        self.disabledMessage = disabledMessage
    }

    func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
        if let last = messages.last {
            return String(format: questionFormat, last.content)
        }
        return disabledMessage
    }
}

struct AIConnectivityCheck: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case chat
        case embedding
        case ocr
    }

    var id: String { kind.rawValue }
    let kind: Kind
    let succeeded: Bool
    let detail: String?
}

enum AIConnectivityTester {
    static func run(llm: LLMProvider,
                    embedding: EmbeddingProvider?,
                    ocr: OCRProvider?) async -> [AIConnectivityCheck] {
        var checks = [await checkChat(llm)]
        if let embedding { checks.append(await checkEmbedding(embedding)) }
        if let ocr { checks.append(await checkOCR(ocr)) }
        return checks
    }

    private static func checkChat(_ provider: LLMProvider) async -> AIConnectivityCheck {
        do {
            let reply = try await provider.chat(
                [ChatTurn(role: .user, content: "Reply with OK only.")],
                context: nil
            )
            guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw URLError(.cannotParseResponse)
            }
            return AIConnectivityCheck(kind: .chat, succeeded: true, detail: nil)
        } catch {
            return AIConnectivityCheck(kind: .chat, succeeded: false, detail: error.localizedDescription)
        }
    }

    private static func checkEmbedding(_ provider: EmbeddingProvider) async -> AIConnectivityCheck {
        do {
            let vector = try await provider.embed("FileNest connectivity test")
            guard !vector.isEmpty else { throw URLError(.cannotParseResponse) }
            return AIConnectivityCheck(kind: .embedding, succeeded: true, detail: nil)
        } catch {
            return AIConnectivityCheck(kind: .embedding, succeeded: false, detail: error.localizedDescription)
        }
    }

    private static func checkOCR(_ provider: OCRProvider) async -> AIConnectivityCheck {
        do {
            let image = Data(base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2ZQAAAABJRU5ErkJggg=="
            ) ?? Data()
            _ = try await provider.recognize(imageData: image, mimeType: "image/png")
            return AIConnectivityCheck(kind: .ocr, succeeded: true, detail: nil)
        } catch {
            return AIConnectivityCheck(kind: .ocr, succeeded: false, detail: error.localizedDescription)
        }
    }
}
