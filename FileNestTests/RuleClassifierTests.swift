import XCTest
@testable import FileNest

final class RuleClassifierTests: XCTestCase {
    func testHighestPriorityRuleUsesCustomFolderAndKeepsFileCategory() throws {
        let rules = [
            makeRule(id: 1, pattern: "pdf", target: "Documents", priority: 1),
            makeRule(id: 2, pattern: ".PDF, docx", target: " Contracts ", priority: 10),
        ]

        let decision = try XCTUnwrap(
            RuleClassifier(rules: rules, strategy: "hybrid").classify(makeFile(ext: "pdf"))
        )

        XCTAssertEqual(decision.targetFolder, "Contracts")
        XCTAssertEqual(decision.category, .documents)
        XCTAssertEqual(decision.matchedRuleID, 2)
    }

    func testRuleOnlyLeavesUnmatchedFileInPlace() {
        let classifier = RuleClassifier(
            rules: [makeRule(id: 1, pattern: "pdf", target: "Documents")],
            strategy: "rule"
        )

        XCTAssertNil(classifier.classify(makeFile(ext: "jpg")))
    }

    func testHybridFallsBackToDefaultCategoryFolder() throws {
        let decision = try XCTUnwrap(
            RuleClassifier(rules: [], strategy: "hybrid").classify(makeFile(ext: "jpg"))
        )

        XCTAssertEqual(decision.targetFolder, FileCategory.images.folderName)
        XCTAssertEqual(decision.category, .images)
        XCTAssertNil(decision.matchedRuleID)
    }

    func testAIGeneratedRuleUsesSameDeterministicMatchingPath() throws {
        let rules = [
            makeRule(id: 1, type: "ai", pattern: "pdf", target: "AI Contracts", priority: 20),
            makeRule(id: 2, pattern: "pdf", target: "../Outside", priority: 10),
            makeRule(id: 3, pattern: "pdf", target: "Contracts", priority: 1),
        ]

        let decision = try XCTUnwrap(
            RuleClassifier(rules: rules, strategy: "hybrid").classify(makeFile(ext: "pdf"))
        )

        XCTAssertEqual(decision.targetFolder, "AI Contracts")
        XCTAssertEqual(decision.matchedRuleID, 1)
    }

    func testIgnoreRuleWinsByPriorityAndStopsProcessing() throws {
        var ignore = makeRule(id: 2, pattern: "dmg,pkg", target: "Ignored", priority: 100)
        ignore.action = RuleAction.ignore.rawValue
        let classifier = RuleClassifier(
            rules: [makeRule(id: 1, pattern: "dmg", target: "Archives", priority: 10), ignore],
            strategy: "hybrid"
        )

        let decision = try XCTUnwrap(classifier.classify(makeFile(ext: "dmg")))

        XCTAssertEqual(decision.matchedRuleID, 2)
        XCTAssertEqual(decision.action, .ignore)
    }

    func testOrganizationTargetAcceptsOnlySingleSafeFolderName() {
        XCTAssertEqual(OrganizationTarget.folderName(from: " Contracts "), "Contracts")
        XCTAssertNil(OrganizationTarget.folderName(from: ""))
        XCTAssertNil(OrganizationTarget.folderName(from: "."))
        XCTAssertNil(OrganizationTarget.folderName(from: ".."))
        XCTAssertNil(OrganizationTarget.folderName(from: "Contracts/2026"))
        XCTAssertNil(OrganizationTarget.folderName(from: "Contracts\\2026"))
        XCTAssertNil(OrganizationTarget.folderName(from: "Contracts:2026"))
        XCTAssertNil(OrganizationTarget.folderName(from: "Contracts\n2026"))
    }

    private func makeRule(id: Int64,
                          type: String = "rule",
                          pattern: String,
                          target: String,
                          priority: Int = 0) -> Rule {
        Rule(id: id, name: "Rule \(id)", type: type, pattern: pattern,
             targetFolder: target, priority: priority, enabled: true)
    }

    private func makeFile(ext: String) -> FileRecord {
        FileRecord(
            id: 1,
            path: "/tmp/file.\(ext)",
            name: "file.\(ext)",
            ext: ext,
            size: 1,
            mtime: Date(),
            category: FileCategory.from(extension: ext).rawValue,
            sourceDir: "/tmp",
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        )
    }
}
