import Foundation

enum AgentEngineKind: String, Codable, Sendable {
    case legacy
    case omp
}

enum AgentInteractionMode: String, Codable, CaseIterable, Sendable {
    case generalChat = "general-chat"
    case attachedFiles = "attached-files"
    case libraryReadOnly = "library-read-only"
    case workspace = "workspace"
}

/// The application-level generation provider selected in FileNest settings.
/// Harnesses consume this projection instead of maintaining their own model settings.
enum AgentGenerationProvider: String, Codable, Equatable, Sendable {
    case ollama
    case openAICompatible = "openai-compatible"
    case anthropic
}

/// A short-lived projection of FileNest's global LLM settings for a harness.
/// API keys are retained in memory and may only be passed to an isolated child
/// process for the duration of a request; they are never persisted by the harness.
struct AgentGenerationConfiguration: Codable, Equatable, Sendable {
    let provider: AgentGenerationProvider
    let model: String
    let baseURL: String
    let apiKey: String?
    let thinkingEnabled: Bool
}

struct AgentConversationTurn: Equatable, Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    let role: Role
    let content: String
}

struct AgentInput: Equatable, Sendable {
    let text: String
    let mode: AgentInteractionMode
    var attachedFileIDs: [Int64] = []
    var history: [AgentConversationTurn] = []
    /// Capability-bounded, prepared evidence supplied by FileNest for read-only modes.
    /// This is never a file-system path and must be treated as untrusted content by a harness.
    var context: String? = nil
}

struct AgentToolCall: Equatable, Sendable {
    let id: String
    let name: String
}

struct AgentCompletion: Equatable, Sendable {
    let terminal: Bool
}

enum AgentEngineEvent: Equatable, Sendable {
    case started
    case textDelta(String)
    case toolStarted(AgentToolCall)
    case toolUpdated(AgentToolCall)
    case toolCompleted(AgentToolCall, succeeded: Bool)
    case notice(String)
    case completed(AgentCompletion)
}

protocol AgentEngine: AnyObject {
    var kind: AgentEngineKind { get }
    func start() async throws
    func send(_ input: AgentInput) async -> AsyncThrowingStream<AgentEngineEvent, Error>
    func cancel() async
    func shutdown() async
}

enum AgentEngineError: LocalizedError, Equatable {
    case unavailable(String)
    case invalidResponse(String)
    case busy

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason):
            return "The Agent Engine is unavailable: \(reason)"
        case let .invalidResponse(reason):
            return "The Agent Engine returned an invalid response: \(reason)"
        case .busy:
            return "The Agent Engine is already processing another request."
        }
    }
}
