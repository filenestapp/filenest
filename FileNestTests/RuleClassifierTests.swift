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

    func testSpecificDirectoryRuleWinsOverHigherPriorityGlobalRule() throws {
        let globalRule = makeRule(
            id: 1,
            pattern: "pdf",
            target: "Global Contracts",
            priority: 100
        )
        let directoryRule = makeRule(
            id: 2,
            pattern: "pdf",
            target: "Desktop Contracts",
            priority: 1,
            sourceDirectories: ["/Users/example/Desktop"]
        )
        let file = makeFile(
            path: "/Users/example/Desktop/Incoming/agreement.pdf",
            ext: "pdf"
        )

        let decision = try XCTUnwrap(
            RuleClassifier(rules: [globalRule, directoryRule], strategy: "hybrid")
                .classify(file)
        )

        XCTAssertEqual(decision.matchedRuleID, 2)
        XCTAssertEqual(decision.targetFolder, "Desktop Contracts")
    }

    func testSpecificDirectoryRuleDoesNotApplyOutsideItsDirectory() throws {
        let globalRule = makeRule(
            id: 1,
            pattern: "pdf",
            target: "Global Contracts",
            priority: 10
        )
        let directoryRule = makeRule(
            id: 2,
            pattern: "pdf",
            target: "Desktop Contracts",
            priority: 100,
            sourceDirectories: [
                "/Users/example/Desktop",
                "/Users/example/Downloads",
            ]
        )
        let file = makeFile(
            path: "/Users/example/Documents/agreement.pdf",
            ext: "pdf"
        )

        let decision = try XCTUnwrap(
            RuleClassifier(rules: [globalRule, directoryRule], strategy: "hybrid")
                .classify(file)
        )

        XCTAssertEqual(decision.matchedRuleID, 1)
        XCTAssertEqual(decision.targetFolder, "Global Contracts")
    }

    func testPriorityBreaksTiesBetweenSpecificDirectoryRules() throws {
        let lowerPriority = makeRule(
            id: 1,
            pattern: "pdf",
            target: "Lower Priority",
            priority: 10,
            sourceDirectories: ["/Users/example/Downloads"]
        )
        let higherPriority = makeRule(
            id: 2,
            pattern: "pdf",
            target: "Higher Priority",
            priority: 20,
            sourceDirectories: ["/Users/example/Downloads"]
        )

        let decision = try XCTUnwrap(
            RuleClassifier(rules: [lowerPriority, higherPriority], strategy: "hybrid")
                .classify(makeFile(path: "/Users/example/Downloads/agreement.pdf", ext: "pdf"))
        )

        XCTAssertEqual(decision.matchedRuleID, 2)
        XCTAssertEqual(decision.targetFolder, "Higher Priority")
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
                          priority: Int = 0,
                          sourceDirectories: [String] = []) -> Rule {
        var rule = Rule(
            id: id,
            name: "Rule \(id)",
            type: type,
            pattern: pattern,
            targetFolder: target,
            priority: priority,
            enabled: true
        )
        rule.sourceDirectories = sourceDirectories
        return rule
    }

    private func makeFile(path: String? = nil, ext: String) -> FileRecord {
        let filePath = path ?? "/tmp/file.\(ext)"
        return FileRecord(
            id: 1,
            path: filePath,
            name: URL(fileURLWithPath: filePath).lastPathComponent,
            ext: ext,
            size: 1,
            mtime: Date(),
            category: FileCategory.from(extension: ext).rawValue,
            sourceDir: URL(fileURLWithPath: filePath).deletingLastPathComponent().path,
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        )
    }
}
