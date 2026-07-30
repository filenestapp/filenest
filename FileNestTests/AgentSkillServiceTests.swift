import XCTest
@testable import FileNest

final class AgentSkillServiceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var store: SQLiteStore!
    private var bundledDirectory: URL!
    private var sharedDirectory: URL!
    private var managedDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        bundledDirectory = temporaryDirectory.appendingPathComponent("bundled", isDirectory: true)
        sharedDirectory = temporaryDirectory.appendingPathComponent("shared", isDirectory: true)
        managedDirectory = temporaryDirectory.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundledDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sharedDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: managedDirectory,
            withIntermediateDirectories: true
        )
        store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testDiscoveryKeepsBodyOutOfCatalogAndLoadsItOnActivation() throws {
        let skillDirectory = sharedDirectory.appendingPathComponent("invoice-review")
        try write(
            """
            ---
            name: invoice-review
            description: Review invoices and payment evidence. Use for invoice questions.
            ---

            # Review Invoices

            Follow the invoice reconciliation workflow.
            See [policy](references/policy.md).
            """,
            to: skillDirectory.appendingPathComponent("SKILL.md")
        )
        try write(
            "Require an invoice number and matching payment reference.",
            to: skillDirectory.appendingPathComponent("references/policy.md")
        )
        let service = makeService()

        let skills = service.refresh()
        let skill = try XCTUnwrap(skills.first)
        service.setEnabled(skill, enabled: true)
        XCTAssertEqual(skill.name, "invoice-review")
        XCTAssertFalse(service.catalogPrompt().contains("reconciliation workflow"))

        let activation = service.activate(names: ["invoice-review"])
        XCTAssertTrue(activation.context.contains("reconciliation workflow"))
        XCTAssertTrue(activation.context.contains("matching payment reference"))
        XCTAssertTrue(activation.context.contains("<skill_content name=\"invoice-review\">"))
    }

    func testManagedSkillOverridesSharedSkillWithSameName() throws {
        try writeSkill(
            name: "rank-contracts",
            description: "Shared description",
            body: "Shared instructions",
            root: sharedDirectory
        )
        try writeSkill(
            name: "rank-contracts",
            description: "Managed description",
            body: "Managed instructions",
            root: managedDirectory
        )
        let service = makeService()

        let skill = try XCTUnwrap(service.refresh().first)
        service.setEnabled(skill, enabled: true)
        XCTAssertEqual(skill.origin, .managed)
        XCTAssertEqual(skill.description, "Managed description")
        XCTAssertTrue(service.activate(names: [skill.name]).context.contains("Managed instructions"))
        XCTAssertTrue(service.diagnostics().contains { $0.message.contains("higher-precedence") })
    }

    func testExplicitActivationOnlyAcceptsInstalledEnabledSkills() throws {
        try writeSkill(
            name: "travel-documents",
            description: "Handle travel document questions.",
            body: "Use travel evidence.",
            root: sharedDirectory
        )
        let service = makeService()
        let skill = try XCTUnwrap(service.refresh().first)
        service.setEnabled(skill, enabled: true)

        XCTAssertEqual(
            service.explicitSkillNames(in: "Use $travel-documents but not $missing-skill"),
            ["travel-documents"]
        )
        service.setEnabled(skill, enabled: false)
        XCTAssertTrue(service.explicitSkillNames(in: "$travel-documents").isEmpty)
    }

    func testDynamicRoutingExcludesCapabilityBoundSkillsAndRejectsUnlistedNames() throws {
        try write(
            """
            ---
            name: filenest-single-file-chat
            description: Answer questions about one attached file.
            metadata:
              filenest-auto-activate: "attached-file-answer"
            ---

            Use only the attached file.
            """,
            to: bundledDirectory
                .appendingPathComponent("filenest-single-file-chat")
                .appendingPathComponent("SKILL.md")
        )
        try writeSkill(
            name: "invoice-review",
            description: "Review invoices when the request concerns billing evidence.",
            body: "Validate invoice evidence.",
            root: sharedDirectory
        )
        try write(
            """
            ---
            name: search-ranking
            description: Refine local retrieval ranking.
            metadata:
              filenest-scope: "search"
            ---

            Refine retrieval ranking.
            """,
            to: managedDirectory
                .appendingPathComponent("search-ranking")
                .appendingPathComponent("SKILL.md")
        )
        let service = makeService()
        let skills = service.refresh()
        skills.filter { $0.origin != .bundled }.forEach {
            service.setEnabled($0, enabled: true)
        }

        let candidates = service.dynamicSkillNames(for: .attachedFileAnswer)

        XCTAssertEqual(candidates, ["invoice-review"])
        XCTAssertFalse(
            service.selectionSystemPrompt(candidateNames: candidates)
                .contains("filenest-single-file-chat")
        )
        XCTAssertEqual(
            service.decodeSelectedSkillNames(
                #"{"skills":["filenest-single-file-chat","invoice-review"]}"#,
                allowedNames: candidates
            ),
            ["invoice-review"]
        )
    }

    func testBundledSkillsAreAlwaysEnabledAndCannotBeDisabled() throws {
        try writeSkill(
            name: "bundled-review",
            description: "Review bundled evidence.",
            body: "Bundled instructions",
            root: bundledDirectory
        )
        let service = makeService()
        let skill = try XCTUnwrap(service.refresh().first)
        XCTAssertTrue(skill.enabled)

        service.setEnabled(skill, enabled: false)
        XCTAssertTrue(service.refresh().first?.enabled == true)
    }

    func testUserSkillsRequireExplicitEnablement() throws {
        try writeSkill(
            name: "shared-review",
            description: "Review shared evidence.",
            body: "Shared instructions",
            root: sharedDirectory
        )
        let service = makeService()
        let skill = try XCTUnwrap(service.refresh().first)

        XCTAssertFalse(skill.enabled)
        service.setEnabled(skill, enabled: true)
        XCTAssertTrue(service.refresh().first?.enabled == true)
    }

    func testManagedSkillsAreEnabledByDefaultButCanBeDisabled() throws {
        try writeSkill(
            name: "managed-review",
            description: "Review FileNest-managed evidence.",
            body: "Managed instructions",
            root: managedDirectory
        )
        let service = makeService()
        let skill = try XCTUnwrap(service.refresh().first)

        XCTAssertEqual(skill.origin, .managed)
        XCTAssertTrue(skill.enabled)
        service.setEnabled(skill, enabled: false)
        XCTAssertFalse(service.refresh().first?.enabled == true)
        service.setEnabled(skill, enabled: true)
        XCTAssertTrue(service.refresh().first?.enabled == true)
    }

    func testImportCopiesEnabledSkillPackageIntoManagedDirectory() throws {
        try writeSkill(
            name: "imported-review",
            description: "Review imported evidence.",
            body: "Imported instructions",
            root: sharedDirectory
        )
        let service = makeService()
        let source = sharedDirectory.appendingPathComponent("imported-review/SKILL.md")

        let imported = try service.importSkillPackage(from: source)

        XCTAssertEqual(imported.origin, .managed)
        XCTAssertTrue(imported.enabled)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: managedDirectory.appendingPathComponent("imported-review/SKILL.md").path
        ))
    }

    func testFeedbackEvolutionCreatesManagedStandardOverride() throws {
        let baseDirectory = bundledDirectory.appendingPathComponent("filenest-search-planning")
        try write(
            """
            ---
            name: filenest-search-planning
            description: Plan FileNest searches.
            metadata:
              filenest-auto-activate: "search"
              filenest-version: "1"
            ---

            # Plan Search

            Preserve exact identifiers.
            """,
            to: baseDirectory.appendingPathComponent("SKILL.md")
        )
        let service = makeService()
        _ = service.refresh()

        let evolved = try XCTUnwrap(service.evolveSkill(
            named: "filenest-search-planning",
            description: "Plan FileNest searches with learned phrase evidence.",
            instruction: "Require complete core phrase evidence for very high confidence.",
            rationale: "Generic token overlap produced a false positive."
        ))

        XCTAssertEqual(evolved.origin, .managed)
        XCTAssertEqual(
            evolved.description,
            "Plan FileNest searches with learned phrase evidence."
        )
        XCTAssertEqual(evolved.metadata["filenest-auto-activate"], "search")
        XCTAssertEqual(evolved.metadata["filenest-version"], "2")
        XCTAssertTrue(evolved.enabled)
        let context = service.activate(names: [evolved.name]).context
        XCTAssertTrue(context.contains("## Learned Adjustments"))
        XCTAssertTrue(context.contains("complete core phrase evidence"))
    }

    func testDisabledManagedOverrideFallsBackToAlwaysEnabledBundledSkill() throws {
        try writeSkill(
            name: "shared-name",
            description: "Bundled baseline.",
            body: "Bundled instructions",
            root: bundledDirectory
        )
        try writeSkill(
            name: "shared-name",
            description: "Managed override.",
            body: "Managed instructions",
            root: managedDirectory
        )
        let service = makeService()
        let managed = try XCTUnwrap(service.refresh().first)
        XCTAssertEqual(managed.origin, .managed)
        service.setEnabled(managed, enabled: false)

        let active = try XCTUnwrap(service.refresh().first)
        XCTAssertEqual(active.origin, .bundled)
        XCTAssertTrue(active.enabled)
        XCTAssertTrue(service.activate(names: [active.name]).context.contains("Bundled instructions"))
        XCTAssertTrue(service.diagnostics().contains {
            $0.message.contains("does not shadow the enabled bundled skill")
        })
    }

    func testInvalidStandardPackageIsDiagnosedAndNotDiscovered() throws {
        try write(
            """
            ---
            name: Invalid_Name
            description: Invalid skill package.
            ---

            This package must not be activated.
            """,
            to: sharedDirectory
                .appendingPathComponent("different-folder")
                .appendingPathComponent("SKILL.md")
        )
        let service = makeService()

        XCTAssertTrue(service.refresh().isEmpty)
        XCTAssertTrue(service.diagnostics().contains { $0.severity == .error })
    }

    private func makeService() -> AgentSkillService {
        AgentSkillService(
            store: store,
            managedDirectory: managedDirectory,
            sharedUserDirectory: sharedDirectory,
            bundledDirectory: bundledDirectory
        )
    }

    private func writeSkill(
        name: String,
        description: String,
        body: String,
        root: URL
    ) throws {
        try write(
            """
            ---
            name: \(name)
            description: \(description)
            ---

            \(body)
            """,
            to: root.appendingPathComponent(name).appendingPathComponent("SKILL.md")
        )
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }
}
