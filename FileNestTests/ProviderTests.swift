import XCTest
@testable import FileNest

final class ProviderTests: XCTestCase {
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
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(messages.map { $0["content"] }, ["local context", "question"])
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

    func testOllamaEmbeddingParsesResponseAndBuildsRequest() async throws {
        let endpoint = "https://embedding-success.test/api/embeddings"
        registerJSON(endpoint, status: 200, object: ["embedding": [0.25, -0.5]])
        let provider = OllamaEmbeddingProvider(host: "https://embedding-success.test",
                                               model: "embed-model", session: session)

        let vector = try await provider.embed("document text")

        XCTAssertEqual(vector, [0.25, -0.5])
        let request = try XCTUnwrap(URLProtocolStub.request(for: endpoint))
        XCTAssertEqual(request.timeoutInterval, 60)
        let body = try requestJSON(request)
        XCTAssertEqual(body["model"] as? String, "embed-model")
        XCTAssertEqual(body["prompt"] as? String, "document text")
    }

    func testEmbeddingRejectsNonSuccessfulHTTPStatus() async throws {
        let endpoint = "https://embedding-error.test/api/embeddings"
        registerJSON(endpoint, status: 500, object: ["embedding": [1.0, 0.0]])
        let provider = OllamaEmbeddingProvider(host: "https://embedding-error.test",
                                               model: "embed-model", session: session)

        await assertURLError(.badServerResponse) {
            _ = try await provider.embed("text")
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
        let endpoint = "https://embedding-timeout.test/api/embeddings"
        URLProtocolStub.register(endpoint) { _ in throw URLError(.timedOut) }
        let provider = OllamaEmbeddingProvider(host: "https://embedding-timeout.test",
                                               model: "model", session: session)

        await assertURLError(.timedOut) {
            _ = try await provider.embed("text")
        }
    }

    func testInvalidProviderURLThrowsInsteadOfCrashing() async {
        let provider = OllamaLLMProvider(host: "http://[", model: "model", session: session)

        await assertURLError(.badURL) {
            _ = try await provider.chat([ChatTurn(role: .user, content: "question")], context: nil)
        }
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
}
