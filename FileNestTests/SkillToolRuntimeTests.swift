import XCTest
@testable import FileNest

final class SkillToolRuntimeTests: XCTestCase {
    private let runtime = SkillToolRuntime()

    func testCoverageValidatorReportsMissingUnexpectedAndDuplicateIDs() throws {
        let result = try runtime.validateCoverage(
            expectedIDs: ["C00001", "C00002", "C00003"],
            completedIDs: ["C00001", "unexpected", "C00001"]
        )

        XCTAssertEqual(result.expectedCount, 3)
        XCTAssertEqual(result.completedCount, 3)
        XCTAssertEqual(result.missingIDs, ["C00002", "C00003"])
        XCTAssertEqual(result.unexpectedIDs, ["unexpected"])
        XCTAssertEqual(result.duplicateCompletedIDs, ["C00001"])
        XCTAssertFalse(result.isComplete)
    }

    func testChunkManifestNormalizesOrderAndRejectsDuplicates() throws {
        let input = SkillToolManifestInput(chunks: [
            SkillToolManifestEntry(id: "C00002", order: 2, location: "p.2"),
            SkillToolManifestEntry(id: "C00001", order: 1, location: "p.1"),
        ])
        let result = try runtime.run(SkillToolInvocation(
            tool: "chunk-manifest",
            input: .make(input)
        ))
        let manifest = try result.output.decode(SkillToolManifestOutput.self)

        XCTAssertEqual(manifest.chunks.map(\.id), ["C00001", "C00002"])
        XCTAssertEqual(manifest.total, 2)
    }

    func testStructuredOutputValidatorChecksRequiredTopLevelKeys() throws {
        let input = SkillToolStructuredOutputInput(
            json: #"{"summary":"done","chunks":[]}"#,
            requiredKeys: ["summary", "chunks", "warnings"]
        )
        let result = try runtime.run(SkillToolInvocation(
            tool: "structured-output-validator",
            input: .make(input)
        ))
        let validation = try result.output.decode(SkillToolStructuredOutput.self)

        XCTAssertTrue(validation.isValidObject)
        XCTAssertEqual(validation.missingKeys, ["warnings"])
    }

    func testCLIListsAndRunsRegisteredToolsWithTheSameRuntime() throws {
        let listData = try SkillToolCommandLine.execute(
            arguments: ["filenest", "skill", "list"],
            runtime: runtime
        )
        let tools = try JSONDecoder().decode([SkillToolDefinition].self, from: listData)
        XCTAssertEqual(tools.map(\.name), [
            "chunk-manifest",
            "coverage-validator",
            "structured-output-validator",
        ])

        let input = #"{"expected_ids":["C00001"],"completed_ids":["C00001"]}"#
        let runData = try SkillToolCommandLine.execute(
            arguments: ["filenest", "skill", "run", "coverage-validator", "--json", input],
            runtime: runtime
        )
        let result = try JSONDecoder().decode(SkillToolResult.self, from: runData)
        let coverage = try result.output.decode(SkillToolCoverageOutput.self)
        XCTAssertTrue(coverage.isComplete)
    }
}
