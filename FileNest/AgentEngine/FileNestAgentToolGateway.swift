import Foundation

/// Exposes deterministic FileNest capabilities to an Agent Engine.
/// Attachment access is limited to an immutable snapshot prepared by the existing chat pipeline.
actor FileNestAgentToolGateway: AgentHostToolExecuting {
    private let runtime: SkillToolRuntime
    private let attachedDocument: AgentAttachedDocument?

    init(
        runtime: SkillToolRuntime = .shared,
        attachedDocument: AgentAttachedDocument? = nil
    ) {
        self.runtime = runtime
        self.attachedDocument = attachedDocument
    }

    var definitions: [AgentHostToolDefinition] {
        get async {
            var tools = [
                AgentHostToolDefinition(
                    name: "filenest_normalize_chunk_manifest",
                    label: "Normalize Document Manifest",
                    description: "Normalize an ordered FileNest source-chunk manifest and reject duplicate chunk IDs.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "chunks": .object([
                                "type": .string("array"),
                                "items": .object([
                                    "type": .string("object"),
                                    "properties": .object([
                                        "id": .object(["type": .string("string")]),
                                        "order": .object(["type": .string("integer")]),
                                        "location": .object(["type": .string("string")]),
                                    ]),
                                    "required": .array([.string("id"), .string("order"), .string("location")]),
                                    "additionalProperties": .bool(false),
                                ]),
                            ]),
                        ]),
                        "required": .array([.string("chunks")]),
                        "additionalProperties": .bool(false),
                    ]),
                    loadMode: .discoverable
                ),
                AgentHostToolDefinition(
                    name: "filenest_validate_coverage",
                    label: "Validate Document Coverage",
                    description: "Verify that completed source IDs exactly cover an expected FileNest document manifest.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "expected_ids": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                            ]),
                            "completed_ids": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                            ]),
                        ]),
                        "required": .array([.string("expected_ids"), .string("completed_ids")]),
                        "additionalProperties": .bool(false),
                    ]),
                    loadMode: .essential
                ),
                AgentHostToolDefinition(
                    name: "filenest_validate_structured_output",
                    label: "Validate Structured Output",
                    description: "Validate that a JSON object contains the required top-level keys.",
                    parameters: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "json": .object(["type": .string("string")]),
                            "required_keys": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("string")]),
                            ]),
                        ]),
                        "required": .array([.string("json"), .string("required_keys")]),
                        "additionalProperties": .bool(false),
                    ]),
                    loadMode: .discoverable
                ),
            ]
            if attachedDocument != nil {
                tools.insert(contentsOf: Self.attachedFileToolDefinitions, at: 0)
            }
            return tools
        }
    }

    func execute(toolName: String, arguments: AgentJSONValue) async -> AgentHostToolResult {
        switch toolName {
        case "filenest_get_attached_file":
            return attachedFileMetadata()
        case "filenest_read_attached_chunks":
            return readAttachedChunks(arguments: arguments)
        default:
            break
        }

        let runtimeName: String
        switch toolName {
        case "filenest_normalize_chunk_manifest":
            runtimeName = "chunk-manifest"
        case "filenest_validate_coverage":
            runtimeName = "coverage-validator"
        case "filenest_validate_structured_output":
            runtimeName = "structured-output-validator"
        default:
            return .text("The FileNest Agent tool '\(toolName)' is not registered.", isError: true)
        }

        do {
            let data = try arguments.encodedData()
            let input = try JSONDecoder().decode(SkillToolJSONValue.self, from: data)
            let result = try runtime.run(SkillToolInvocation(tool: runtimeName, input: input))
            var outputValue = result.output
            if runtimeName == "coverage-validator",
               case var .object(object) = outputValue {
                let coverage = try outputValue.decode(SkillToolCoverageOutput.self)
                object["is_complete"] = .bool(coverage.isComplete)
                outputValue = .object(object)
            }
            let output = try JSONEncoder().encode(outputValue)
            guard let text = String(data: output, encoding: .utf8) else {
                return .text("The FileNest Agent tool returned invalid UTF-8.", isError: true)
            }
            return .text(text)
        } catch {
            return .text(error.localizedDescription, isError: true)
        }
    }

    private func attachedFileMetadata() -> AgentHostToolResult {
        guard let attachedDocument else {
            return .text("No attached document is available to this Agent session.", isError: true)
        }
        let value = AgentJSONValue.object([
            "file": .object([
                "id": attachedDocument.fileID.map { .number(Double($0)) } ?? .null,
                "name": .string(attachedDocument.name),
                "extension": .string(attachedDocument.fileExtension),
                "size_bytes": .number(Double(attachedDocument.size)),
                "chunk_ids": .array(attachedDocument.chunks.map { .string($0.id) }),
                "citation_instruction": .string(
                    "Preserve source markers such as [F1:P2] from chunk content when citing evidence."
                ),
            ]),
        ])
        return encodedResult(value)
    }

    private func readAttachedChunks(arguments: AgentJSONValue) -> AgentHostToolResult {
        guard let attachedDocument else {
            return .text("No attached document is available to this Agent session.", isError: true)
        }
        guard let requestedValues = arguments["chunk_ids"]?.arrayValue,
              !requestedValues.isEmpty,
              requestedValues.count <= 8 else {
            return .text("chunk_ids must contain between 1 and 8 chunk IDs.", isError: true)
        }
        let requestedIDs = requestedValues.compactMap(\.stringValue)
        guard requestedIDs.count == requestedValues.count,
              Set(requestedIDs).count == requestedIDs.count else {
            return .text("chunk_ids must contain unique string values.", isError: true)
        }

        let chunksByID = Dictionary(uniqueKeysWithValues: attachedDocument.chunks.map { ($0.id, $0) })
        let unknownIDs = requestedIDs.filter { chunksByID[$0] == nil }
        guard unknownIDs.isEmpty else {
            return .text(
                "Unknown attached-document chunk IDs: \(unknownIDs.joined(separator: ", ")).",
                isError: true
            )
        }
        let chunks = requestedIDs.compactMap { id -> AgentJSONValue? in
            guard let chunk = chunksByID[id] else { return nil }
            return .object([
                "id": .string(chunk.id),
                "content": .string(chunk.content),
            ])
        }
        return encodedResult(.object(["chunks": .array(chunks)]))
    }

    private func encodedResult(_ value: AgentJSONValue) -> AgentHostToolResult {
        do {
            let data = try value.encodedData()
            guard let text = String(data: data, encoding: .utf8) else {
                return .text("The FileNest Agent tool returned invalid UTF-8.", isError: true)
            }
            return .text(text)
        } catch {
            return .text(error.localizedDescription, isError: true)
        }
    }

    private static let attachedFileToolDefinitions = [
        AgentHostToolDefinition(
            name: "filenest_get_attached_file",
            label: "Inspect Attached File",
            description: "Return metadata and the allowed chunk IDs for the file attached to this FileNest chat.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]),
            loadMode: .essential
        ),
        AgentHostToolDefinition(
            name: "filenest_read_attached_chunks",
            label: "Read Attached File Chunks",
            description: "Read selected prepared text chunks from the file attached to this FileNest chat. Only IDs returned by filenest_get_attached_file are allowed.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "chunk_ids": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "minItems": .number(1),
                        "maxItems": .number(8),
                    ]),
                ]),
                "required": .array([.string("chunk_ids")]),
                "additionalProperties": .bool(false),
            ]),
            loadMode: .essential
        ),
    ]
}
