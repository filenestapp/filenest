import Foundation

enum AgentHostToolLoadMode: String, Codable, Sendable {
    case essential
    case discoverable
}

struct AgentHostToolDefinition: Equatable, Sendable {
    let name: String
    let label: String
    let description: String
    let parameters: AgentJSONValue
    var hidden = false
    var loadMode: AgentHostToolLoadMode = .discoverable

    var jsonValue: AgentJSONValue {
        .object([
            "name": .string(name),
            "label": .string(label),
            "description": .string(description),
            "parameters": parameters,
            "hidden": .bool(hidden),
            "loadMode": .string(loadMode.rawValue),
        ])
    }
}

struct AgentHostToolResult: Equatable, Sendable {
    let content: [AgentJSONValue]
    var isError = false

    static func text(_ value: String, isError: Bool = false) -> AgentHostToolResult {
        AgentHostToolResult(
            content: [.object(["type": .string("text"), "text": .string(value)])],
            isError: isError
        )
    }

    var jsonValue: AgentJSONValue {
        .object(["content": .array(content)])
    }
}

protocol AgentHostToolExecuting: Sendable {
    var definitions: [AgentHostToolDefinition] { get async }
    func execute(toolName: String, arguments: AgentJSONValue) async -> AgentHostToolResult
}
