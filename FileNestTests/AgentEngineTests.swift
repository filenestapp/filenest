import XCTest
import Foundation
@testable import FileNest

final class AgentEngineTests: XCTestCase {
    func testAgentJSONValueRoundTripsNestedObjects() throws {
        let value = AgentJSONValue.object([
            "name": .string("FileNest"),
            "enabled": .bool(true),
            "count": .number(3),
            "items": .array([.string("one"), .null]),
        ])

        let decoded = try JSONDecoder().decode(AgentJSONValue.self, from: value.encodedData())

        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded["count"]?.integerValue, 3)
    }

    func testRPCFrameDecoderReadsOrdinaryFrame() throws {
        let decoder = OMPRPCFrameDecoder()
        let data = Data(#"{"type":"ready","supportedProtocolVersions":[1,2]}"#.utf8)

        let frame = try XCTUnwrap(decoder.decode(line: data))

        XCTAssertEqual(frame.type, "ready")
        XCTAssertEqual(frame["supportedProtocolVersions"]?.arrayValue?.compactMap(\.integerValue), [1, 2])
    }

    func testRPCFrameDecoderReassemblesProtocolV2Chunks() throws {
        let decoder = OMPRPCFrameDecoder(maximumPhysicalFrameBytes: 4_096, maximumReassembledFrameBytes: 32_768)
        let logicalFrame = AgentJSONValue.object([
            "type": .string("message_update"),
            "assistantMessageEvent": .object([
                "type": .string("text_delta"),
                "delta": .string(String(repeating: "FileNest ", count: 120)),
            ]),
        ])
        let logicalData = try logicalFrame.encodedData()
        let midpoint = logicalData.count / 2
        let chunks = [
            logicalData.subdata(in: 0..<midpoint),
            logicalData.subdata(in: midpoint..<logicalData.count),
        ]

        let first = try decoder.decode(line: try chunkLine(
            id: "rpc-1",
            index: 0,
            count: 2,
            byteLength: logicalData.count,
            data: chunks[0]
        ))
        let second = try decoder.decode(line: try chunkLine(
            id: "rpc-1",
            index: 1,
            count: 2,
            byteLength: logicalData.count,
            data: chunks[1]
        ))

        XCTAssertNil(first)
        XCTAssertEqual(second?.type, "message_update")
        XCTAssertEqual(
            second?["assistantMessageEvent"]?["delta"]?.stringValue,
            String(repeating: "FileNest ", count: 120)
        )
    }

    func testRPCFrameDecoderRejectsInterruptedChunkSequence() throws {
        let decoder = OMPRPCFrameDecoder(maximumPhysicalFrameBytes: 4_096, maximumReassembledFrameBytes: 32_768)
        _ = try decoder.decode(line: try chunkLine(
            id: "rpc-1",
            index: 0,
            count: 2,
            byteLength: 4,
            data: Data("ab".utf8)
        ))

        XCTAssertThrowsError(try decoder.decode(line: Data(#"{"type":"notice"}"#.utf8))) { error in
            XCTAssertEqual(error as? OMPRPCFrameDecoderError, .interruptedChunkSequence)
        }
    }

    func testFileNestAgentToolGatewayValidatesCoverage() async throws {
        let gateway = FileNestAgentToolGateway(runtime: SkillToolRuntime())

        let result = await gateway.execute(
            toolName: "filenest_validate_coverage",
            arguments: .object([
                "expected_ids": .array([.string("C00001"), .string("C00002")]),
                "completed_ids": .array([.string("C00001"), .string("C00002")]),
            ])
        )

        XCTAssertFalse(result.isError)
        let text = try XCTUnwrap(result.content.first?["text"]?.stringValue)
        XCTAssertTrue(text.contains(#""is_complete":true"#))
    }

    func testAttachedDocumentCreatesBoundedDeterministicChunks() {
        let document = AgentAttachedDocument(
            file: makeFileRecord(),
            preparedContext: String(repeating: "FileNest evidence. ", count: 90),
            maximumChunkCharacters: 600
        )

        XCTAssertGreaterThan(document.chunks.count, 1)
        XCTAssertEqual(document.chunks.first?.id, "A0001")
        XCTAssertTrue(document.chunks.allSatisfy { $0.content.count <= 600 })
    }

    func testAttachedFileToolsExposeOnlyPreparedSnapshot() async throws {
        let document = AgentAttachedDocument(
            file: makeFileRecord(),
            preparedContext: "[F42:P1] First prepared section.\n\n[F42:P2] Second prepared section."
        )
        let gateway = FileNestAgentToolGateway(
            runtime: SkillToolRuntime(),
            attachedDocument: document
        )

        let definitions = await gateway.definitions
        XCTAssertTrue(definitions.contains { $0.name == "filenest_get_attached_file" })
        XCTAssertTrue(definitions.contains { $0.name == "filenest_read_attached_chunks" })

        let metadata = await gateway.execute(
            toolName: "filenest_get_attached_file",
            arguments: .object([:])
        )
        let metadataText = try XCTUnwrap(metadata.content.first?["text"]?.stringValue)
        XCTAssertFalse(metadata.isError)
        XCTAssertTrue(metadataText.contains("report.txt"))
        XCTAssertTrue(metadataText.contains("A0001"))
        XCTAssertFalse(metadataText.contains("/private/attachments"))

        let read = await gateway.execute(
            toolName: "filenest_read_attached_chunks",
            arguments: .object(["chunk_ids": .array([.string("A0001")])])
        )
        let readText = try XCTUnwrap(read.content.first?["text"]?.stringValue)
        XCTAssertFalse(read.isError)
        XCTAssertTrue(readText.contains("[F42:P1]"))

        let rejected = await gateway.execute(
            toolName: "filenest_read_attached_chunks",
            arguments: .object(["chunk_ids": .array([.string("A9999")])])
        )
        XCTAssertTrue(rejected.isError)
    }

    func testChatAgentEngineChoicePersistsAndNormalizes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteStore(path: directory.appendingPathComponent("settings.sqlite").path)
        let settings = AppSettings(store: store)

        settings.setChatAgentEngine(AppSettings.ChatAgentEngineChoice.omp.rawValue)

        XCTAssertEqual(AppSettings(store: store).chatAgentEngine, "omp")
        settings.setAgentHarness(.custom("example"))
        XCTAssertEqual(AppSettings(store: store).selectedAgentHarnessKind, .custom("example"))
        settings.setChatAgentEngine("")
        XCTAssertEqual(settings.chatAgentEngine, "legacy")
    }

    func testAgentHarnessRegistryCanSelectNonOMPAdapter() {
        let adapter = TestAgentHarnessAdapter(
            kind: .custom("example"),
            displayName: "Test Harness",
            isAvailable: true
        )
        let registry = AgentHarnessRegistry(adapters: [adapter])

        XCTAssertEqual(registry.adapter(for: .custom("example"))?.displayName, "Test Harness")
        XCTAssertTrue(registry.isAvailable(for: .custom("example")))
        XCTAssertFalse(registry.isAvailable(for: .omp))
        XCTAssertEqual(registry.selectableKinds, [.classic, .custom("example")])
        XCTAssertEqual(registry.displayName(for: .classic), "Classic")
    }

    func testWorkspaceSnapshotIsBounded() {
        let snapshot = AgentWorkspaceSnapshot(
            identifier: "workspace-1",
            title: "Research",
            summary: String(repeating: "summary ", count: 1_000),
            resources: (0..<40).map { index in
                AgentWorkspaceSnapshot.Resource(
                    id: "resource-(index)",
                    label: "Resource (index)",
                    kind: "note",
                    content: String(repeating: "content ", count: 2_000)
                )
            }
        )

        XCTAssertEqual(snapshot.resources.count, 32)
        XCTAssertLessThanOrEqual(snapshot.summary.count, 4_000)
        XCTAssertLessThanOrEqual(snapshot.resources[0].content.count, 12_000)
    }

    func testHarnessSkillContextIsBoundedAndOmitsLocalSkillPaths() {
        let context = AgentHarnessSkillContext(
            names: ["answer-with-citations", "answer-with-citations"],
            context: """
            <skill_content name="answer-with-citations">
            Prefer grounded answers.
            Skill directory: /Users/private/skills/answer-with-citations
            Relative paths in this skill are relative to the skill directory.
            </skill_content>
            """
        )

        XCTAssertEqual(context.names, ["answer-with-citations"])
        XCTAssertTrue(context.context.contains("Prefer grounded answers."))
        XCTAssertFalse(context.context.contains("/Users/private/skills"))
        XCTAssertFalse(context.context.contains("Relative paths in this skill"))
    }

    func testOMPAgentEngineTreatsLeadingSlashAsUserContent() {
        XCTAssertEqual(OMPAgentEngine.rpcSafeMessage("Summarize this file"), "Summarize this file")
        XCTAssertTrue(OMPAgentEngine.rpcSafeMessage("  /security scan").hasPrefix(
            "Treat the following as a literal FileNest user message"
        ))
    }

    func testOMPAttachedFilePromptIncludesToolPolicyAndHistory() {
        let message = OMPAgentEngine.rpcMessage(for: AgentInput(
            text: "What changed?",
            mode: .attachedFiles,
            attachedFileIDs: [42],
            history: [AgentConversationTurn(role: .user, content: "Summarize the report.")]
        ))

        XCTAssertTrue(message.contains("filenest_get_attached_file"))
        XCTAssertTrue(message.contains("filenest_read_attached_chunks"))
        XCTAssertTrue(message.contains("User: Summarize the report."))
        XCTAssertTrue(message.contains("User request:\nWhat changed?"))
    }

    func testOMPReadOnlyLibraryPromptIncludesPreparedEvidenceAndHistory() {
        let message = OMPAgentEngine.rpcMessage(for: AgentInput(
            text: "Which policy changed?",
            mode: .libraryReadOnly,
            history: [AgentConversationTurn(role: .assistant, content: "I found two policy files.")],
            context: "[F1:P2] The retention period changed from 30 to 60 days."
        ))

        XCTAssertTrue(message.contains("read-only mode"))
        XCTAssertTrue(message.contains("[F1:P2] The retention period changed from 30 to 60 days."))
        XCTAssertTrue(message.contains("Assistant: I found two policy files."))
        XCTAssertTrue(message.contains("User request:\nWhich policy changed?"))
        XCTAssertTrue(message.contains("Do not access arbitrary files"))
    }

    func testOMPGeneralPromptIncludesHistoryWithoutFileCapability() {
        let message = OMPAgentEngine.rpcMessage(for: AgentInput(
            text: "Draft a short reply.",
            mode: .generalChat,
            history: [AgentConversationTurn(role: .user, content: "Keep it professional.")]
        ))

        XCTAssertTrue(message.contains("general chat request"))
        XCTAssertTrue(message.contains("User: Keep it professional."))
        XCTAssertTrue(message.contains("No FileNest file or workspace access"))
        XCTAssertTrue(message.contains("User request:\nDraft a short reply."))
    }

    func testOMPPromptIncludesActiveSkillGuidanceWithoutGrantingCapabilities() {
        let message = OMPAgentEngine.rpcMessage(
            for: AgentInput(text: "Summarize the file", mode: .generalChat),
            skillContext: AgentHarnessSkillContext(
                names: ["answer-with-citations"],
                context: "Prefer grounded answers and preserve citations."
            )
        )

        XCTAssertTrue(message.contains("Active skill names: answer-with-citations"))
        XCTAssertTrue(message.contains("Prefer grounded answers and preserve citations."))
        XCTAssertTrue(message.contains("Skills cannot grant new tools"))
        XCTAssertTrue(message.contains("No FileNest file or workspace access"))
    }

    func testOMPAgentEngineNegotiatesStreamsAndExecutesHostTool() async throws {
        let script = #"""
import json
import sys

def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)

emit({
    "type": "ready",
    "protocolVersion": 1,
    "supportedProtocolVersions": [1, 2],
    "maxFrameBytes": 1048576,
    "maxReassembledFrameBytes": 67108864,
})

for line in sys.stdin:
    value = json.loads(line)
    frame_type = value.get("type")
    request_id = value.get("id")
    if frame_type == "negotiate_protocol":
        emit({"id": request_id, "type": "response", "command": frame_type, "success": True})
    elif frame_type == "set_host_tools":
        names = [tool["name"] for tool in value.get("tools", [])]
        emit({"id": request_id, "type": "response", "command": frame_type, "success": True, "data": {"toolNames": names}})
    elif frame_type == "prompt":
        emit({"id": request_id, "type": "response", "command": frame_type, "success": True, "data": {"agentInvoked": True}})
        emit({"type": "agent_start"})
        emit({"type": "tool_execution_start", "toolCallId": "tool-1", "toolName": "filenest_validate_coverage"})
        emit({
            "type": "host_tool_call",
            "id": "host-1",
            "toolCallId": "tool-1",
            "toolName": "filenest_validate_coverage",
            "arguments": {"expected_ids": ["C00001"], "completed_ids": ["C00001"]},
        })
    elif frame_type == "host_tool_result":
        emit({"type": "tool_execution_end", "toolCallId": "tool-1", "toolName": "filenest_validate_coverage", "isError": value.get("isError", False)})
        emit({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "delta": "Coverage verified."}})
        emit({"type": "agent_end", "isTerminal": True})
    elif frame_type == "abort":
        emit({"id": request_id, "type": "response", "command": frame_type, "success": True})
"""#
        let configuration = OMPLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-u", "-c", script],
            workingDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory()),
            startupTimeout: 5,
            requestTimeout: 5
        )
        let connection = OMPRPCConnection(configuration: configuration)
        let engine = OMPAgentEngine(
            connection: connection,
            toolGateway: FileNestAgentToolGateway(runtime: SkillToolRuntime())
        )
        try await engine.start()

        let stream = await engine.send(AgentInput(text: "Verify coverage", mode: .attachedFiles))
        var events: [AgentEngineEvent] = []
        for try await event in stream {
            events.append(event)
        }
        await engine.shutdown()

        XCTAssertTrue(events.contains(.started))
        XCTAssertTrue(events.contains(.toolStarted(AgentToolCall(
            id: "tool-1",
            name: "filenest_validate_coverage"
        ))))
        XCTAssertTrue(events.contains(.textDelta("Coverage verified.")))
        XCTAssertEqual(events.last, .completed(AgentCompletion(terminal: true)))
    }

    func testOMPAgentHostManifestDecodesAndNormalizesArtifact() throws {
        let checksum = String(repeating: "A", count: 64)
        let data = Data(
            "{\"version\":\" 17.3.0 \",\"artifacts\":{\"arm64\":{\"url\":\"https://github.com/can1357/oh-my-pi/releases/download/v17.3.0/omp-darwin-arm64\",\"sha256\":\"\(checksum)\"}}}".utf8
        )

        let manifest = try JSONDecoder().decode(
            OMPAgentHostReleaseManifest.self,
            from: data
        )

        XCTAssertEqual(manifest.version, "17.3.0")
        XCTAssertEqual(
            manifest.artifact(for: "arm64")?.sha256,
            checksum.lowercased()
        )
        XCTAssertEqual(
            manifest.artifact(for: "arm64")?.url.absoluteString,
            "https://github.com/can1357/oh-my-pi/releases/download/v17.3.0/omp-darwin-arm64"
        )
    }

    func testOMPAgentHostManifestRejectsInsecureOrMalformedArtifacts() {
        let checksum = String(repeating: "a", count: 64)
        let invalidManifests = [
            "{\"version\":\"17.3.0\",\"artifacts\":{\"arm64\":{\"url\":\"http://updates.example.test/omp\",\"sha256\":\"\(checksum)\"}}}",
            "{\"version\":\"17.3.0\",\"artifacts\":{\"arm64\":{\"url\":\"https://updates.example.test/omp\",\"sha256\":\"not-a-checksum\"}}}",
        ]

        for payload in invalidManifests {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    OMPAgentHostReleaseManifest.self,
                    from: Data(payload.utf8)
                )
            ) { error in
                XCTAssertEqual(error as? OMPAgentHostUpdateError, .invalidManifest)
            }
        }
    }

    func testOMPAgentHostGitHubReleaseManifestDecodesAssets() async throws {
        let digest = String(repeating: "a", count: 64)
        TestURLProtocol.requestHandler = { request in
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(
                    """
                    {"tag_name":"v18.0.8","draft":false,"prerelease":false,"assets":[
                      {"name":"omp-darwin-arm64","browser_download_url":"https://github.com/can1357/oh-my-pi/releases/download/v18.0.8/omp-darwin-arm64","digest":"sha256:\(digest)"},
                      {"name":"omp-darwin-x64","browser_download_url":"https://github.com/can1357/oh-my-pi/releases/download/v18.0.8/omp-darwin-x64","digest":"sha256:\(digest)"}
                    ]}
                    """.utf8
                )
            )
        }
        defer { TestURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let manifest = try await OMPAgentHostServiceManager.fetchGitHubReleaseManifest(
            session: session
        )

        XCTAssertEqual(manifest.version, "18.0.8")
        XCTAssertEqual(manifest.artifact(for: "arm64")?.sha256, digest)
        XCTAssertEqual(
            manifest.artifact(for: "x86_64")?.url.absoluteString,
            "https://github.com/can1357/oh-my-pi/releases/download/v18.0.8/omp-darwin-x64"
        )
    }

    func testOMPAgentHostGitHubReleaseManifestRequiresHTTPSAndDigests() async throws {
        let payload = Data(
            #"{"tag_name":"v18.0.8","draft":false,"prerelease":false,"assets":[{"name":"omp-darwin-arm64","browser_download_url":"http://github.com/can1357/oh-my-pi/releases/download/v18.0.8/omp-darwin-arm64","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}"#.utf8
        )
        TestURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                payload
            )
        }
        defer { TestURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)

        do {
            _ = try await OMPAgentHostServiceManager.fetchGitHubReleaseManifest(
                session: session
            )
            XCTFail("Expected the insecure artifact to be rejected")
        } catch {
            XCTAssertEqual(error as? OMPAgentHostUpdateError, .releaseNotPublished)
        }
    }

    func testOMPAgentHostRejectsUntrustedOfficialRuntimeAsset() {
        XCTAssertFalse(OMPAgentHostServiceManager.isTrustedReleaseURL(
            URL(string: "https://example.com/omp-darwin-arm64")!
        ))
        XCTAssertTrue(OMPAgentHostServiceManager.isTrustedReleaseURL(
            URL(string: "https://github.com/can1357/oh-my-pi/releases/download/v18.0.8/omp-darwin-arm64")!
        ))
    }

    func testOMPAgentHostBundledExecutableRequiresAnExecutableFile() throws {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let hostDirectory = resources.appendingPathComponent("AgentHost", isDirectory: true)
        try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resources) }

        let executable = hostDirectory.appendingPathComponent("filenest-agent-host")
        try Data("#!/bin/sh\n".utf8).write(to: executable)

        XCTAssertNil(OMPAgentEngineBootstrap.bundledExecutableURL(in: resources))

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        XCTAssertEqual(
            OMPAgentEngineBootstrap.bundledExecutableURL(in: resources)?.path,
            executable.standardizedFileURL.path
        )
    }

    private func chunkLine(
        id: String,
        index: Int,
        count: Int,
        byteLength: Int,
        data: Data
    ) throws -> Data {
        try AgentJSONValue.object([
            "type": .string("rpc_chunk"),
            "chunkId": .string(id),
            "index": .number(Double(index)),
            "count": .number(Double(count)),
            "byteLength": .number(Double(byteLength)),
            "data": .string(data.base64EncodedString()),
        ]).encodedData()
    }

    private func makeFileRecord() -> FileRecord {
        FileRecord(
            id: 42,
            path: "/private/attachments/report.txt",
            name: "report.txt",
            ext: "txt",
            size: 1_024,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            category: FileCategory.documents.rawValue,
            sourceDir: "/private/attachments",
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        )
    }
}

private final class TestURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler,
              let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badURL)
            )
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
        _ = url
    }

    override func stopLoading() {}
}

private struct TestAgentHarnessAdapter: AgentHarnessAdapter {
    let kind: AgentHarnessKind
    let displayName: String
    let isAvailable: Bool

    func makeEngine(for request: AgentHarnessRequest) throws -> any AgentEngine {
        throw AgentEngineError.unavailable("Test adapter does not create a process.")
    }
}
