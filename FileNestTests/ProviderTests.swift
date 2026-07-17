import XCTest
@testable import FileNest

final class ProviderTests: XCTestCase {
    private struct ConnectivityLLMStub: LLMProvider {
        let name = "connectivity-llm"
        var reply = "OK"
        var error: Error?

        func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
            if let error { throw error }
            return reply
        }
    }

    private struct ConnectivityEmbeddingStub: EmbeddingProvider {
        let name = "connectivity-embedding"
        let dimension = 2
        var vector: [Float] = [1, 0]
        var error: Error?

        func embed(_ text: String) async throws -> [Float] {
            if let error { throw error }
            return vector
        }
    }

    private struct ConnectivityOCRStub: OCRProvider {
        let name = "connectivity-ocr"
        var error: Error?

        func recognize(imageData: Data, mimeType: String) async throws -> String {
            if let error { throw error }
            return "FileNest"
        }
    }

    private struct OCRResultStub: OCRProvider {
        let name: String
        var text: String = ""
        var error: Error?

        func recognize(imageData: Data, mimeType: String) async throws -> String {
            if let error { throw error }
            return text
        }
    }

    private struct StructuredOCRResultStub: OCRProvider {
        let name: String
        let result: OCRRecognitionResult

        func recognize(imageData: Data, mimeType: String) async throws -> String {
            result.text
        }

        func recognizeResult(imageData: Data, mimeType: String) async throws -> OCRRecognitionResult {
            result
        }
    }

    private final class RequestConcurrencyProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var maximum = 0

        var maximumConcurrentRequests: Int { lock.withLock { maximum } }

        func begin() {
            lock.withLock {
                active += 1
                maximum = max(maximum, active)
            }
        }

        func end() {
            lock.withLock { active -= 1 }
        }
    }

    private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
        typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

        private static let lock = NSLock()
        private static var handlers: [String: Handler] = [:]
        private static var requests: [String: URLRequest] = [:]
        private static var requestBodies: [String: Data] = [:]

        static func register(_ url: String, handler: @escaping Handler) {
            lock.lock()
            handlers[url] = handler
            requests[url] = nil
            requestBodies[url] = nil
            lock.unlock()
        }

        static func request(for url: String) -> URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return requests[url]
        }

        static func requestBody(for url: String) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return requestBodies[url]
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url?.absoluteString else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let body = request.httpBody ?? readBodyStream(request.httpBodyStream)
            Self.lock.lock()
            let handler = Self.handlers[url]
            Self.requests[url] = request
            Self.requestBodies[url] = body
            Self.lock.unlock()

            guard let handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        private func readBodyStream(_ stream: InputStream?) -> Data? {
            guard let stream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else { return nil }
                if count == 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }()

    override func tearDown() {
        session.invalidateAndCancel()
        super.tearDown()
    }

    func testAIConnectivityTesterChecksEveryConfiguredCloudCapability() async {
        let checks = await AIConnectivityTester.run(
            llm: ConnectivityLLMStub(),
            embedding: ConnectivityEmbeddingStub(),
            ocr: ConnectivityOCRStub()
        )

        XCTAssertEqual(checks.map(\.kind), [.chat, .embedding, .ocr])
        XCTAssertTrue(checks.allSatisfy(\.succeeded))
    }

    func testAIConnectivityTesterReportsProviderFailures() async {
        let error = URLError(.cannotConnectToHost)
        let checks = await AIConnectivityTester.run(
            llm: ConnectivityLLMStub(error: error),
            embedding: ConnectivityEmbeddingStub(vector: [], error: nil),
            ocr: ConnectivityOCRStub(error: error)
        )

        XCTAssertEqual(checks.map(\.kind), [.chat, .embedding, .ocr])
        XCTAssertTrue(checks.allSatisfy { !$0.succeeded && !($0.detail ?? "").isEmpty })
    }

    func testOllamaLLMParsesResponseAndBuildsContextRequest() async throws {
        let endpoint = "https://ollama-success.test/api/chat"
        registerJSON(endpoint, status: 200, object: ["message": ["content": "answer"]])
        let provider = OllamaLLMProvider(host: "https://ollama-success.test",
                                         model: "qwen", session: session)

        let reply = try await provider.chat(
            [ChatTurn(role: .user, content: "question")],
            context: "local context"
        )

        XCTAssertEqual(reply, "answer")
        let request = try XCTUnwrap(URLProtocolStub.request(for: endpoint))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 120)
        let body = try requestJSON(request)
        XCTAssertEqual(body["model"] as? String, "qwen")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["think"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.map { $0["content"] }, ["local context", "question"])
    }

    func testOllamaLLMSendsImageDataWithVisionPrompt() async throws {
        let endpoint = "https://ollama-vision.test/api/chat"
        registerJSON(endpoint, status: 200, object: ["message": ["content": "image note"]])
        let provider = OllamaLLMProvider(
            host: "https://ollama-vision.test",
            model: "qwen-vision",
            session: session
        )

        let reply = try await provider.chatWithImage(
            prompt: "describe",
            imageData: Data([1, 2, 3]),
            mimeType: "image/jpeg",
            context: "vision context"
        )

        XCTAssertEqual(reply, "image note")
        let body = try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: endpoint)))
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["content"] as? String, "vision context")
        XCTAssertEqual(messages[1]["content"] as? String, "describe")
        XCTAssertEqual(messages[1]["images"] as? [String], [Data([1, 2, 3]).base64EncodedString()])
    }

    func testOpenAIProviderParsesResponseAndAddsAuthorization() async throws {
        let endpoint = "https://openai-success.test/v1/chat/completions"
        registerJSON(endpoint, status: 200, object: [
            "choices": [["message": ["content": "cloud answer"]]],
        ])
        let provider = OpenAICompatibleLLMProvider(
            baseURL: "https://openai-success.test/v1",
            apiKey: "secret",
            model: "test-model",
            session: session
        )

        let reply = try await provider.chat(
            [ChatTurn(role: .user, content: "question")],
            context: nil
        )

        XCTAssertEqual(reply, "cloud answer")
        let request = try XCTUnwrap(URLProtocolStub.request(for: endpoint))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.timeoutInterval, 60)
        XCTAssertEqual(try requestJSON(request)["model"] as? String, "test-model")
    }

    func testOpenAIProviderBuildsImageURLContent() async throws {
        let endpoint = "https://openai-vision.test/v1/chat/completions"
        registerJSON(endpoint, status: 200, object: [
            "choices": [["message": ["content": "vision answer"]]],
        ])
        let provider = OpenAICompatibleLLMProvider(
            baseURL: "https://openai-vision.test/v1",
            apiKey: "secret",
            model: "vision-model",
            session: session
        )

        _ = try await provider.chatWithImage(
            prompt: "describe",
            imageData: Data([4, 5, 6]),
            mimeType: "image/jpeg",
            context: "context"
        )

        let body = try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: endpoint)))
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "describe")
        let imageURL = try XCTUnwrap(content.last?["image_url"] as? [String: String])
        XCTAssertEqual(imageURL["url"], "data:image/jpeg;base64,BAUG")
    }

    func testAnthropicProviderUsesMessagesFormatAndHeaders() async throws {
        let endpoint = "https://anthropic-success.test/v1/messages"
        registerJSON(endpoint, status: 200, object: [
            "content": [
                ["type": "thinking", "thinking": "hidden"],
                ["type": "text", "text": "Claude answer"],
            ],
        ])
        let provider = AnthropicLLMProvider(
            baseURL: "https://anthropic-success.test/v1/",
            apiKey: "anthropic-secret",
            model: "claude-test",
            session: session
        )

        let reply = try await provider.chat(
            [
                ChatTurn(role: .system, content: "system instruction"),
                ChatTurn(role: .user, content: "question"),
            ],
            context: "local context"
        )

        XCTAssertEqual(reply, "Claude answer")
        let request = try XCTUnwrap(URLProtocolStub.request(for: endpoint))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try requestJSON(request)
        XCTAssertEqual(body["model"] as? String, "claude-test")
        XCTAssertEqual(body["max_tokens"] as? Int, 4_096)
        XCTAssertEqual(body["system"] as? String, "local context\n\nsystem instruction")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["user"])
        XCTAssertEqual(messages.map { $0["content"] }, ["question"])
    }

    func testAnthropicProviderBuildsBase64ImageBlock() async throws {
        let endpoint = "https://anthropic-vision.test/v1/messages"
        registerJSON(endpoint, status: 200, object: [
            "content": [["type": "text", "text": "vision answer"]],
        ])
        let provider = AnthropicLLMProvider(
            baseURL: "https://anthropic-vision.test/v1",
            apiKey: "secret",
            model: "claude-vision",
            session: session
        )

        _ = try await provider.chatWithImage(
            prompt: "describe",
            imageData: Data([7, 8, 9]),
            mimeType: "image/jpeg",
            context: "context"
        )

        let body = try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: endpoint)))
        XCTAssertEqual(body["system"] as? String, "context")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let source = try XCTUnwrap(content.first?["source"] as? [String: String])
        XCTAssertEqual(source["media_type"], "image/jpeg")
        XCTAssertEqual(source["data"], "BwgJ")
        XCTAssertEqual(content.last?["text"] as? String, "describe")
    }

    func testThinkingModeAddsProviderSpecificRequestOptions() async throws {
        let ollamaEndpoint = "https://ollama-thinking.test/api/chat"
        registerJSON(ollamaEndpoint, status: 200, object: ["message": ["content": "ok"]])
        let ollama = OllamaLLMProvider(
            host: "https://ollama-thinking.test",
            model: "qwen",
            thinkingEnabled: true,
            session: session
        )
        _ = try await ollama.chat([ChatTurn(role: .user, content: "question")], context: nil)
        XCTAssertEqual(
            try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: ollamaEndpoint)))["think"] as? Bool,
            true
        )

        let openAIEndpoint = "https://openai-thinking.test/v1/chat/completions"
        registerJSON(openAIEndpoint, status: 200, object: [
            "choices": [["message": ["content": "ok"]]],
        ])
        let openAI = OpenAICompatibleLLMProvider(
            baseURL: "https://openai-thinking.test/v1",
            apiKey: "secret",
            model: "reasoning-model",
            thinkingEnabled: true,
            session: session
        )
        _ = try await openAI.chat([ChatTurn(role: .user, content: "question")], context: nil)
        XCTAssertEqual(
            try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: openAIEndpoint)))["reasoning_effort"] as? String,
            "medium"
        )

        let anthropicEndpoint = "https://anthropic-thinking.test/v1/messages"
        registerJSON(anthropicEndpoint, status: 200, object: [
            "content": [["type": "text", "text": "ok"]],
        ])
        let anthropic = AnthropicLLMProvider(
            baseURL: "https://anthropic-thinking.test/v1",
            apiKey: "secret",
            model: "claude",
            thinkingEnabled: true,
            session: session
        )
        _ = try await anthropic.chat([ChatTurn(role: .user, content: "question")], context: nil)
        let anthropicBody = try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: anthropicEndpoint)))
        let thinking = try XCTUnwrap(anthropicBody["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertEqual(thinking["budget_tokens"] as? Int, 1_024)
    }

    func testOllamaStreamingYieldsChunksAndEnablesStreamRequest() async throws {
        let endpoint = "https://ollama-stream.test/api/chat"
        let lines = [
            "{\"message\":{\"content\":\"You\"},\"done\":false}",
            "{\"message\":{\"content\":\"OK\"},\"done\":true}",
        ].joined(separator: "\n") + "\n"
        URLProtocolStub.register(endpoint) { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/x-ndjson"]
            ))
            return (response, Data(lines.utf8))
        }
        let provider = OllamaLLMProvider(
            host: "https://ollama-stream.test", model: "qwen", session: session
        )

        let chunks = try await collect(provider.streamChat(
            [ChatTurn(role: .user, content: "hello")], context: nil
        ))

        XCTAssertEqual(chunks, ["You", "OK"])
        XCTAssertEqual(try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: endpoint)))["stream"] as? Bool, true)
    }

    func testOllamaVisionStreamingYieldsChunksAndIncludesImage() async throws {
        let endpoint = "https://ollama-vision-stream.test/api/chat"
        let payload = [
            "{\"message\":{\"content\":\"blue \"},\"done\":false}",
            "{\"message\":{\"content\":\"seal\"},\"done\":true}",
        ].joined(separator: "\n") + "\n"
        URLProtocolStub.register(endpoint) { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/x-ndjson"]
            ))
            return (response, Data(payload.utf8))
        }
        let provider = OllamaLLMProvider(
            host: "https://ollama-vision-stream.test", model: "vision", session: session
        )

        let chunks = try await collect(provider.streamChatWithImage(
            prompt: "describe",
            imageData: Data([1, 2, 3]),
            mimeType: "image/png",
            context: nil
        ))

        XCTAssertEqual(chunks.joined(), "blue seal")
        let body = try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: endpoint)))
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.last?["images"] as? [String], ["AQID"])
    }

    func testOpenAIStreamingParsesServerSentEvents() async throws {
        let endpoint = "https://openai-stream.test/v1/chat/completions"
        let payload = """
        data: {"choices":[{"delta":{"content":"hello "}}]}

        data: {"choices":[{"delta":{"content":"world"}}]}

        data: [DONE]

        """
        URLProtocolStub.register(endpoint) { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            ))
            return (response, Data(payload.utf8))
        }
        let provider = OpenAICompatibleLLMProvider(
            baseURL: "https://openai-stream.test/v1", apiKey: "secret",
            model: "model", session: session
        )

        let chunks = try await collect(provider.streamChat(
            [ChatTurn(role: .user, content: "hello")], context: nil
        ))

        XCTAssertEqual(chunks.joined(), "hello world")
        XCTAssertEqual(try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: endpoint)))["stream"] as? Bool, true)
    }

    func testOpenAIVisionStreamingParsesEventsAndIncludesImage() async throws {
        let endpoint = "https://openai-vision-stream.test/v1/chat/completions"
        let payload = """
        data: {"choices":[{"delta":{"content":"blue "}}]}

        data: {"choices":[{"delta":{"content":"seal"}}]}

        data: [DONE]

        """
        URLProtocolStub.register(endpoint) { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            ))
            return (response, Data(payload.utf8))
        }
        let provider = OpenAICompatibleLLMProvider(
            baseURL: "https://openai-vision-stream.test/v1", apiKey: "secret",
            model: "vision", session: session
        )

        let chunks = try await collect(provider.streamChatWithImage(
            prompt: "describe",
            imageData: Data([1, 2, 3]),
            mimeType: "image/png",
            context: nil
        ))

        XCTAssertEqual(chunks.joined(), "blue seal")
        let body = try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: endpoint)))
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let imageURL = try XCTUnwrap(content.last?["image_url"] as? [String: String])
        XCTAssertEqual(imageURL["url"], "data:image/png;base64,AQID")
    }

    func testAnthropicStreamingParsesTextDeltaEvents() async throws {
        let endpoint = "https://anthropic-stream.test/v1/messages"
        let payload = """
        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Claude "}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"stream"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        URLProtocolStub.register(endpoint) { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            ))
            return (response, Data(payload.utf8))
        }
        let provider = AnthropicLLMProvider(
            baseURL: "https://anthropic-stream.test/v1", apiKey: "secret",
            model: "claude", session: session
        )

        let chunks = try await collect(provider.streamChat(
            [ChatTurn(role: .user, content: "hello")], context: nil
        ))

        XCTAssertEqual(chunks.joined(), "Claude stream")
        XCTAssertEqual(try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: endpoint)))["stream"] as? Bool, true)
    }

    func testAnthropicVisionStreamingParsesEventsAndIncludesImage() async throws {
        let endpoint = "https://anthropic-vision-stream.test/v1/messages"
        let payload = """
        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"blue "}}

        event: content_block_delta
        data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"seal"}}

        event: message_stop
        data: {"type":"message_stop"}

        """
        URLProtocolStub.register(endpoint) { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            ))
            return (response, Data(payload.utf8))
        }
        let provider = AnthropicLLMProvider(
            baseURL: "https://anthropic-vision-stream.test/v1", apiKey: "secret",
            model: "vision", session: session
        )

        let chunks = try await collect(provider.streamChatWithImage(
            prompt: "describe",
            imageData: Data([1, 2, 3]),
            mimeType: "image/png",
            context: nil
        ))

        XCTAssertEqual(chunks.joined(), "blue seal")
        let body = try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: endpoint)))
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        let source = try XCTUnwrap(content.first?["source"] as? [String: String])
        XCTAssertEqual(source["data"], "AQID")
    }

    func testOllamaEmbeddingParsesResponseAndBuildsRequest() async throws {
        let endpoint = "https://embedding-success.test/api/embed"
        registerJSON(endpoint, status: 200, object: ["embeddings": [[0.25, -0.5]]])
        let provider = OllamaEmbeddingProvider(host: "https://embedding-success.test",
                                               model: "embed-model", session: session)

        let vector = try await provider.embed("document text")

        XCTAssertEqual(vector, [0.25, -0.5])
        let request = try XCTUnwrap(URLProtocolStub.request(for: endpoint))
        XCTAssertEqual(request.timeoutInterval, 60)
        let body = try requestJSON(request)
        XCTAssertEqual(body["model"] as? String, "embed-model")
        XCTAssertEqual(body["input"] as? [String], ["document text"])
        XCTAssertEqual(body["truncate"] as? Bool, true)
    }

    func testOllamaEmbeddingSendsMultipleChunksInOneRequest() async throws {
        let endpoint = "https://embedding-batch.test/api/embed"
        registerJSON(endpoint, status: 200, object: [
            "embeddings": [[0.1, 0.2], [0.3, 0.4]],
        ])
        let provider = OllamaEmbeddingProvider(
            host: "https://embedding-batch.test", model: "embed-model", session: session
        )

        let vectors = try await provider.embedBatch(["first", "second"])

        XCTAssertEqual(vectors, [[0.1, 0.2], [0.3, 0.4]])
        let body = try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: endpoint)))
        XCTAssertEqual(body["input"] as? [String], ["first", "second"])
        XCTAssertEqual(provider.maximumBatchSize, 2)
    }

    func testOllamaEmbeddingSerializesConcurrentRequests() async throws {
        let endpoint = "https://embedding-serial.test/api/embed"
        let probe = RequestConcurrencyProbe()
        URLProtocolStub.register(endpoint) { request in
            probe.begin()
            defer { probe.end() }
            Thread.sleep(forTimeInterval: 0.05)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, try JSONSerialization.data(withJSONObject: [
                "embeddings": [[0.1, 0.2]],
            ]))
        }
        let provider = OllamaEmbeddingProvider(
            host: "https://embedding-serial.test",
            model: "embed-model",
            session: session
        )

        async let first = provider.embed("first")
        async let second = provider.embed("second")
        _ = try await (first, second)

        XCTAssertEqual(probe.maximumConcurrentRequests, 1)
    }

    func testEmbeddingRejectsNonSuccessfulHTTPStatus() async throws {
        let endpoint = "https://embedding-error.test/api/embed"
        registerJSON(endpoint, status: 400, object: [
            "error": "do embedding request: Post /v1/embeddings: EOF",
        ])
        let provider = OllamaEmbeddingProvider(host: "https://embedding-error.test",
                                               model: "embed-model", session: session)

        do {
            _ = try await provider.embed("text")
            XCTFail("Expected detailed embedding HTTP error")
        } catch let error as EmbeddingProviderError {
            guard case let .httpStatus(code, body) = error else {
                return XCTFail("Expected HTTP status error, got \(error)")
            }
            XCTAssertEqual(code, 400)
            XCTAssertTrue(body.contains("/v1/embeddings: EOF"))
            XCTAssertTrue(error.localizedDescription.contains("EOF"))
        } catch {
            XCTFail("Expected EmbeddingProviderError, got \(error)")
        }
    }

    func testLLMProvidersRejectSuccessfulButMalformedResponses() async throws {
        let ollamaEndpoint = "https://ollama-malformed.test/api/chat"
        registerJSON(ollamaEndpoint, status: 200, object: ["message": [:]])
        let ollama = OllamaLLMProvider(host: "https://ollama-malformed.test",
                                      model: "qwen", session: session)
        await assertURLError(.cannotParseResponse) {
            _ = try await ollama.chat([ChatTurn(role: .user, content: "question")], context: nil)
        }

        let openAIEndpoint = "https://openai-malformed.test/chat/completions"
        registerJSON(openAIEndpoint, status: 200, object: ["choices": []])
        let openAI = OpenAICompatibleLLMProvider(baseURL: "https://openai-malformed.test",
                                                 apiKey: "secret", model: "model", session: session)
        await assertURLError(.cannotParseResponse) {
            _ = try await openAI.chat([ChatTurn(role: .user, content: "question")], context: nil)
        }
    }

    func testTransportTimeoutIsPropagated() async throws {
        let endpoint = "https://embedding-timeout.test/api/embed"
        URLProtocolStub.register(endpoint) { _ in throw URLError(.timedOut) }
        let provider = OllamaEmbeddingProvider(host: "https://embedding-timeout.test",
                                               model: "model", session: session)

        await assertURLError(.timedOut) {
            _ = try await provider.embed("text")
        }
    }

    func testOpenAICompatibleEmbeddingUsesConfiguredCloudEndpoint() async throws {
        let endpoint = "https://cloud-embedding.test/v1/embeddings"
        registerJSON(endpoint, status: 200, object: [
            "data": [["embedding": [0.1, 0.2, 0.3]]],
        ])
        let provider = OpenAICompatibleEmbeddingProvider(
            baseURL: "https://cloud-embedding.test/v1/",
            apiKey: "cloud-secret",
            model: "embedding-model",
            session: session
        )

        let vector = try await provider.embed("cloud text")

        XCTAssertEqual(vector, [0.1, 0.2, 0.3])
        let request = try XCTUnwrap(URLProtocolStub.request(for: endpoint))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cloud-secret")
        let body = try requestJSON(request)
        XCTAssertEqual(body["input"] as? [String], ["cloud text"])
        XCTAssertEqual(body["model"] as? String, "embedding-model")
    }

    func testOllamaOCRSendsBase64ImageToGLMOCR() async throws {
        let endpoint = "https://ocr-local.test/api/chat"
        registerJSON(endpoint, status: 200, object: ["message": ["content": "recognized text"]])
        let provider = OllamaOCRProvider(
            host: "https://ocr-local.test",
            model: "glm-ocr",
            session: session
        )

        let text = try await provider.recognize(imageData: Data([1, 2, 3]), mimeType: "image/jpeg")

        XCTAssertEqual(text, "recognized text")
        let body = try requestJSON(try XCTUnwrap(URLProtocolStub.request(for: endpoint)))
        XCTAssertEqual(body["model"] as? String, "glm-ocr")
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["images"] as? [String], [Data([1, 2, 3]).base64EncodedString()])
    }

    func testPaddleOCRFallbackUsesGLMWhenPrimaryFailsOrReturnsEmptyText() async throws {
        let fallback = OCRResultStub(name: "glm", text: "recognized by GLM")
        let failedPrimary = FallbackOCRProvider(
            primary: OCRResultStub(name: "paddle", error: URLError(.cannotLoadFromNetwork)),
            fallback: fallback
        )
        let emptyPrimary = FallbackOCRProvider(
            primary: OCRResultStub(name: "paddle", text: "  \n"),
            fallback: fallback
        )

        let failedResult = try await failedPrimary.recognize(
            imageData: Data([1]), mimeType: "image/png"
        )
        let emptyResult = try await emptyPrimary.recognize(
            imageData: Data([1]), mimeType: "image/png"
        )

        XCTAssertEqual(failedResult, "recognized by GLM")
        XCTAssertEqual(emptyResult, "recognized by GLM")
    }

    func testPaddleOCRFallbackUsesGLMForLowConfidenceNonemptyResult() async throws {
        let weakPrimary = StructuredOCRResultStub(
            name: "paddle",
            result: OCRRecognitionResult(
                text: "Groue CTO",
                observations: [OCRTextObservation(
                    text: "Groue CTO",
                    confidence: 0.41,
                    bounds: OCRBoundingBox(x: 10, y: 10, width: 80, height: 20)
                )]
            )
        )
        let provider = FallbackOCRProvider(
            primary: weakPrimary,
            fallback: OCRResultStub(name: "glm", text: "Group CTO")
        )

        let result = try await provider.recognizeResult(
            imageData: Data([1]),
            mimeType: "image/png"
        )

        XCTAssertEqual(result.text, "Group CTO")
    }

    func testPaddleOCRProviderKeepsWorkerProtocolIndependentFromPythonPipeline() async throws {
        let script = #"""
import json
import sys
for line in sys.stdin:
    request = json.loads(line)
    print(json.dumps({
        "id": request["id"],
        "ok": True,
        "text": "Paddle text",
        "observations": [{
            "text": "Paddle text",
            "confidence": 0.93,
            "box": [10, 20, 110, 50]
        }]
    }), flush=True)
"""#
        let provider = PaddleOCRProvider(
            pythonExecutableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerScript: script
        )

        let result = try await provider.recognizeResult(
            imageData: Data([1, 2, 3]),
            mimeType: "image/png"
        )

        XCTAssertEqual(result.text, "Paddle text")
        XCTAssertEqual(result.observations, [OCRTextObservation(
            text: "Paddle text",
            confidence: 0.93,
            bounds: OCRBoundingBox(x: 10, y: 20, width: 100, height: 30)
        )])
    }

    func testCloudOCROpenAIFormatUsesVisionContent() async throws {
        let endpoint = "https://ocr-cloud.test/v1/chat/completions"
        registerJSON(endpoint, status: 200, object: [
            "choices": [["message": ["content": "cloud OCR"]]],
        ])
        let provider = CloudOCRProvider(
            format: .openAI,
            baseURL: "https://ocr-cloud.test/v1",
            apiKey: "ocr-secret",
            model: "vision-model",
            session: session
        )

        let text = try await provider.recognize(imageData: Data([4, 5]), mimeType: "image/jpeg")

        XCTAssertEqual(text, "cloud OCR")
        let request = try XCTUnwrap(URLProtocolStub.request(for: endpoint))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ocr-secret")
        XCTAssertEqual(try requestJSON(request)["model"] as? String, "vision-model")
    }

    func testCloudOCRAnthropicFormatUsesBase64ImageBlock() async throws {
        let endpoint = "https://ocr-anthropic.test/v1/messages"
        registerJSON(endpoint, status: 200, object: [
            "content": [["type": "text", "text": "anthropic OCR"]],
        ])
        let provider = CloudOCRProvider(
            format: .anthropic,
            baseURL: "https://ocr-anthropic.test/v1",
            apiKey: "anthropic-key",
            model: "claude-vision",
            session: session
        )

        let text = try await provider.recognize(imageData: Data([7, 8]), mimeType: "image/png")

        XCTAssertEqual(text, "anthropic OCR")
        let request = try XCTUnwrap(URLProtocolStub.request(for: endpoint))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(try requestJSON(request)["model"] as? String, "claude-vision")
    }

    func testInvalidProviderURLThrowsInsteadOfCrashing() async {
        let provider = OllamaLLMProvider(host: "http://[", model: "model", session: session)

        await assertURLError(.badURL) {
            _ = try await provider.chat([ChatTurn(role: .user, content: "question")], context: nil)
        }
    }

    func testCompatibleRerankerBuildsV1EndpointAndParsesScores() async throws {
        let endpoint = "https://reranker.test/v1/rerank"
        registerJSON(endpoint, status: 200, object: [
            "results": [
                ["index": 1, "relevance_score": 0.91],
                ["index": 0, "relevance_score": 0.62],
            ],
        ])
        let provider = CompatibleRerankingProvider(
            baseURL: "https://reranker.test",
            apiKey: "secret",
            model: "Qwen/Qwen3-Reranker-0.6B",
            name: "test-reranker",
            session: session
        )

        let results = try await provider.rerank(
            query: "invoice",
            documents: ["first", "second"],
            topN: 2
        )

        XCTAssertEqual(results.map(\.index), [1, 0])
        XCTAssertEqual(results.first?.score ?? 0, 0.91, accuracy: 0.0001)
        let request = try XCTUnwrap(URLProtocolStub.request(for: endpoint))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try requestJSON(request)
        XCTAssertEqual(body["query"] as? String, "invoice")
        XCTAssertEqual(body["top_n"] as? Int, 2)
    }

    private func registerJSON(_ url: String, status: Int, object: Any) {
        URLProtocolStub.register(url) { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            return (response, try JSONSerialization.data(withJSONObject: object))
        }
    }

    private func requestJSON(_ request: URLRequest) throws -> [String: Any] {
        let url = try XCTUnwrap(request.url?.absoluteString)
        let data = try XCTUnwrap(request.httpBody ?? URLProtocolStub.requestBody(for: url))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func assertURLError(_ expectedCode: URLError.Code,
                                operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected URLError \(expectedCode)")
        } catch let error as URLError {
            XCTAssertEqual(error.code, expectedCode)
        } catch {
            XCTFail("Expected URLError, got \(error)")
        }
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var chunks: [String] = []
        for try await chunk in stream { chunks.append(chunk) }
        return chunks
    }
}
