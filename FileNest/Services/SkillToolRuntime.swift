import Foundation

/// A JSON-safe request envelope shared by FileNest workflows and the `filenest` CLI.
/// Only registered built-in tools are executable; a Skill cannot run an arbitrary script.
struct SkillToolInvocation: Codable, Equatable {
    let tool: String
    let input: SkillToolJSONValue
}

struct SkillToolResult: Codable, Equatable {
    let tool: String
    let output: SkillToolJSONValue
}

enum SkillToolJSONValue: Codable, Equatable {
    case object([String: SkillToolJSONValue])
    case array([SkillToolJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: SkillToolJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([SkillToolJSONValue].self) {
            self = .array(value)
        } else {
            throw SkillToolRuntimeError.invalidJSON
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    static func make<T: Encodable>(_ value: T) throws -> SkillToolJSONValue {
        try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

enum SkillToolAccess: String, Codable, CaseIterable {
    case inMemoryReadOnly = "in-memory-read-only"
}

struct SkillToolDefinition: Codable, Equatable, Identifiable {
    let name: String
    let description: String
    let access: SkillToolAccess

    var id: String { name }
}

struct SkillToolManifestEntry: Codable, Equatable {
    let id: String
    let order: Int
    let location: String?
}

struct SkillToolManifestInput: Codable, Equatable {
    let chunks: [SkillToolManifestEntry]
}

struct SkillToolManifestOutput: Codable, Equatable {
    let chunks: [SkillToolManifestEntry]
    let total: Int
}

struct SkillToolCoverageInput: Codable, Equatable {
    let expectedIDs: [String]
    let completedIDs: [String]

    enum CodingKeys: String, CodingKey {
        case expectedIDs = "expected_ids"
        case completedIDs = "completed_ids"
    }
}

struct SkillToolCoverageOutput: Codable, Equatable {
    let expectedCount: Int
    let completedCount: Int
    let missingIDs: [String]
    let unexpectedIDs: [String]
    let duplicateCompletedIDs: [String]

    enum CodingKeys: String, CodingKey {
        case expectedCount = "expected_count"
        case completedCount = "completed_count"
        case missingIDs = "missing_ids"
        case unexpectedIDs = "unexpected_ids"
        case duplicateCompletedIDs = "duplicate_completed_ids"
    }

    var isComplete: Bool {
        missingIDs.isEmpty && unexpectedIDs.isEmpty && duplicateCompletedIDs.isEmpty
    }
}

struct SkillToolStructuredOutputInput: Codable, Equatable {
    let json: String
    let requiredKeys: [String]

    enum CodingKeys: String, CodingKey {
        case json
        case requiredKeys = "required_keys"
    }
}

struct SkillToolStructuredOutput: Codable, Equatable {
    let isValidObject: Bool
    let missingKeys: [String]

    enum CodingKeys: String, CodingKey {
        case isValidObject = "is_valid_object"
        case missingKeys = "missing_keys"
    }
}

enum SkillToolRuntimeError: LocalizedError, Equatable {
    case unknownTool(String)
    case invalidInput(String)
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case let .unknownTool(tool): return "The Skill tool '\(tool)' is not registered."
        case let .invalidInput(reason): return "Invalid Skill tool input: \(reason)"
        case .invalidJSON: return "The Skill tool input is not valid JSON."
        }
    }
}

/// The controlled execution boundary for reusable Skill capabilities.
///
/// It intentionally accepts only in-memory, registered tools. Future file- or network-capable
/// tools must declare a separate access scope and be explicitly authorized by the caller.
final class SkillToolRuntime {
    static let shared = SkillToolRuntime()

    private let definitions: [String: SkillToolDefinition] = [
        "chunk-manifest": SkillToolDefinition(
            name: "chunk-manifest",
            description: "Normalize an ordered source-chunk manifest and reject duplicate IDs.",
            access: .inMemoryReadOnly
        ),
        "coverage-validator": SkillToolDefinition(
            name: "coverage-validator",
            description: "Verify that completed source IDs exactly cover an expected manifest.",
            access: .inMemoryReadOnly
        ),
        "structured-output-validator": SkillToolDefinition(
            name: "structured-output-validator",
            description: "Validate that a JSON object contains required top-level keys.",
            access: .inMemoryReadOnly
        ),
    ]

    func registeredTools() -> [SkillToolDefinition] {
        definitions.values.sorted { $0.name < $1.name }
    }

    func run(_ invocation: SkillToolInvocation) throws -> SkillToolResult {
        guard definitions[invocation.tool] != nil else {
            throw SkillToolRuntimeError.unknownTool(invocation.tool)
        }
        let output: SkillToolJSONValue
        switch invocation.tool {
        case "chunk-manifest":
            output = try .make(normalizeManifest(try invocation.input.decode(SkillToolManifestInput.self)))
        case "coverage-validator":
            output = try .make(validateCoverage(try invocation.input.decode(SkillToolCoverageInput.self)))
        case "structured-output-validator":
            output = try .make(validateStructuredOutput(try invocation.input.decode(SkillToolStructuredOutputInput.self)))
        default:
            throw SkillToolRuntimeError.unknownTool(invocation.tool)
        }
        return SkillToolResult(tool: invocation.tool, output: output)
    }

    func validateCoverage(expectedIDs: [String], completedIDs: [String]) throws -> SkillToolCoverageOutput {
        let input = SkillToolCoverageInput(expectedIDs: expectedIDs, completedIDs: completedIDs)
        let result = try run(SkillToolInvocation(tool: "coverage-validator", input: .make(input)))
        return try result.output.decode(SkillToolCoverageOutput.self)
    }

    private func normalizeManifest(_ input: SkillToolManifestInput) throws -> SkillToolManifestOutput {
        let chunks = input.chunks.sorted {
            $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order
        }
        guard chunks.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw SkillToolRuntimeError.invalidInput("Chunk IDs must not be empty.")
        }
        let uniqueCount = Set(chunks.map(\.id)).count
        guard uniqueCount == chunks.count else {
            throw SkillToolRuntimeError.invalidInput("Chunk IDs must be unique.")
        }
        return SkillToolManifestOutput(chunks: chunks, total: chunks.count)
    }

    private func validateCoverage(_ input: SkillToolCoverageInput) -> SkillToolCoverageOutput {
        let expected = input.expectedIDs
        let expectedSet = Set(expected)
        let completed = input.completedIDs
        let completedSet = Set(completed)
        var seen = Set<String>()
        let duplicates = completed.filter { !seen.insert($0).inserted }
        return SkillToolCoverageOutput(
            expectedCount: expected.count,
            completedCount: completed.count,
            missingIDs: expected.filter { !completedSet.contains($0) },
            unexpectedIDs: completed.filter { !expectedSet.contains($0) },
            duplicateCompletedIDs: Array(Set(duplicates)).sorted()
        )
    }

    private func validateStructuredOutput(_ input: SkillToolStructuredOutputInput) -> SkillToolStructuredOutput {
        guard let data = input.json.data(using: .utf8),
              let value = try? JSONDecoder().decode(SkillToolJSONValue.self, from: data),
              case let .object(object) = value else {
            return SkillToolStructuredOutput(
                isValidObject: false,
                missingKeys: input.requiredKeys.sorted()
            )
        }
        return SkillToolStructuredOutput(
            isValidObject: true,
            missingKeys: input.requiredKeys.filter { object[$0] == nil }.sorted()
        )
    }
}

enum SkillToolCommandLine {
    static let usage = """
    Usage:
      filenest skill list
      filenest skill run <tool> [--json <input-json> | --input <input-file>]

    When neither --json nor --input is supplied, `skill run` reads JSON input from stdin.
    """

    static func execute(
        arguments: [String],
        standardInput: Data = Data(),
        runtime: SkillToolRuntime = .shared
    ) throws -> Data {
        // CommandLine.arguments always begins with the executable path. Tests may pass a
        // short executable name instead, so discard the first argument unconditionally.
        var args = Array(arguments.dropFirst())
        guard args.first == "skill" else {
            throw SkillToolRuntimeError.invalidInput(usage)
        }
        guard args.count >= 2 else {
            throw SkillToolRuntimeError.invalidInput(usage)
        }
        switch args[1] {
        case "list":
            return try JSONEncoder.pretty.encode(runtime.registeredTools())
        case "run":
            guard args.count >= 3 else {
                throw SkillToolRuntimeError.invalidInput(usage)
            }
            let tool = args[2]
            let input = try inputData(arguments: Array(args.dropFirst(3)), standardInput: standardInput)
            let payload = try JSONDecoder().decode(SkillToolJSONValue.self, from: input)
            return try JSONEncoder.pretty.encode(
                runtime.run(SkillToolInvocation(tool: tool, input: payload))
            )
        default:
            throw SkillToolRuntimeError.invalidInput(usage)
        }
    }

    private static func inputData(arguments: [String], standardInput: Data) throws -> Data {
        guard !arguments.isEmpty else {
            guard !standardInput.isEmpty else {
                throw SkillToolRuntimeError.invalidInput("Provide JSON with --json, --input, or stdin.")
            }
            return standardInput
        }
        guard arguments.count == 2 else {
            throw SkillToolRuntimeError.invalidInput(usage)
        }
        switch arguments[0] {
        case "--json":
            return Data(arguments[1].utf8)
        case "--input":
            return try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        default:
            throw SkillToolRuntimeError.invalidInput(usage)
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
