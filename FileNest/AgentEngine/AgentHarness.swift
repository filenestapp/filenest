import Foundation

/// The application-level harness selection is intentionally independent from any
/// particular agent runtime. A future harness can implement this contract without
/// changing ChatService or the FileNest UI routing.
enum AgentHarnessKind: Hashable, Codable, CaseIterable, Identifiable, Sendable {
    case classic
    case omp
    case custom(String)

    static var allCases: [AgentHarnessKind] { [.classic, .omp] }

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .classic: return "classic"
        case .omp: return "omp"
        case let .custom(value): return value
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "legacy", AgentHarnessKind.classic.rawValue: self = .classic
        case AgentHarnessKind.omp.rawValue: self = .omp
        default: self = .custom(rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .omp: return "OMP Preview"
        case let .custom(value): return value
        }
    }
}

/// A bounded, read-only workspace projection. It contains labels and prepared text,
/// never file URLs, writable handles, or ambient process capabilities.
struct AgentWorkspaceSnapshot: Equatable, Sendable {
    struct Resource: Equatable, Sendable {
        let id: String
        let label: String
        let kind: String
        let content: String

        init(id: String, label: String, kind: String, content: String) {
            self.id = id
            self.label = label
            self.kind = kind
            self.content = String(content.prefix(12_000))
        }
    }

    let identifier: String
    let title: String
    let summary: String
    let resources: [Resource]

    init(
        identifier: String,
        title: String,
        summary: String,
        resources: [Resource]
    ) {
        self.identifier = identifier
        self.title = title
        self.summary = String(summary.prefix(4_000))
        self.resources = Array(resources.prefix(32))
    }
}

/// A bounded, read-only projection of the active FileNest skills for a harness.
/// Skill content is guidance only; it never grants tools or ambient capabilities.
struct AgentHarnessSkillContext: Equatable, Sendable {
    static let maximumNames = 32
    static let maximumContextCharacters = 16_000

    let names: [String]
    let context: String

    init(names: [String], context: String) {
        var seen = Set<String>()
        self.names = names.compactMap { name in
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }.prefix(Self.maximumNames).map { $0 }

        let normalizedContext = context
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !value.hasPrefix("Skill directory:")
                    && !value.hasPrefix("Relative paths in this skill are relative")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.context = String(normalizedContext.prefix(Self.maximumContextCharacters))
    }

    var isEmpty: Bool {
        names.isEmpty && context.isEmpty
    }
}

/// Input supplied to a harness adapter. The adapter owns how it creates a process,
/// workspace, session, and tool bridge. FileNest only supplies capability-bounded data.
struct AgentHarnessRequest: Sendable {
    let input: AgentInput
    let attachedDocument: AgentAttachedDocument?
    let workspaceSnapshot: AgentWorkspaceSnapshot?
    let skillContext: AgentHarnessSkillContext?
    let generationConfiguration: AgentGenerationConfiguration?

    init(
        input: AgentInput,
        attachedDocument: AgentAttachedDocument? = nil,
        workspaceSnapshot: AgentWorkspaceSnapshot? = nil,
        skillContext: AgentHarnessSkillContext? = nil,
        generationConfiguration: AgentGenerationConfiguration? = nil
    ) {
        self.input = input
        self.attachedDocument = attachedDocument
        self.workspaceSnapshot = workspaceSnapshot
        self.skillContext = skillContext?.isEmpty == true ? nil : skillContext
        self.generationConfiguration = generationConfiguration
    }
}

/// Adapter boundary between FileNest chat orchestration and a concrete agent harness.
/// Implementations must not obtain ambient file-system or network access implicitly.
protocol AgentHarnessAdapter {
    var kind: AgentHarnessKind { get }
    var displayName: String { get }
    var isAvailable: Bool { get }
    var supportedModes: Set<AgentInteractionMode> { get }

    func makeEngine(for request: AgentHarnessRequest) throws -> any AgentEngine
}

extension AgentHarnessAdapter {
    var supportedModes: Set<AgentInteractionMode> {
        Set(AgentInteractionMode.allCases)
    }
}

/// Runtime registry for swappable harness implementations. The classic provider path
/// remains owned by ChatService; registered adapters are opt-in agent harnesses.
struct AgentHarnessRegistry {
    let adapters: [any AgentHarnessAdapter]

    init(adapters: [any AgentHarnessAdapter]) {
        self.adapters = adapters
    }

    static var builtIn: AgentHarnessRegistry {
        AgentHarnessRegistry(adapters: [OMPAgentHarnessAdapter()])
    }

    func adapter(for kind: AgentHarnessKind) -> (any AgentHarnessAdapter)? {
        adapters.first { $0.kind == kind }
    }

    func isAvailable(for kind: AgentHarnessKind) -> Bool {
        adapter(for: kind)?.isAvailable == true
    }

    var availableKinds: [AgentHarnessKind] {
        adapters.filter(\.isAvailable).map(\.kind)
    }

    /// Returns every harness that can be selected in settings, including adapters
    /// that are currently unavailable and can be installed later.
    var selectableKinds: [AgentHarnessKind] {
        var kinds: [AgentHarnessKind] = [.classic]
        for kind in adapters.map(\.kind) where !kinds.contains(kind) {
            kinds.append(kind)
        }
        return kinds
    }

    func displayName(for kind: AgentHarnessKind) -> String {
        if kind == .classic { return AgentHarnessKind.classic.displayName }
        return adapter(for: kind)?.displayName ?? kind.displayName
    }
}

/// The OMP implementation is deliberately kept behind the generic adapter boundary.
/// Replacing OMP does not require changing the chat pipeline or tool contract.
struct OMPAgentHarnessAdapter: AgentHarnessAdapter {
    let kind: AgentHarnessKind = .omp
    let displayName = AgentHarnessKind.omp.displayName
    let supportedModes: Set<AgentInteractionMode> = Set(AgentInteractionMode.allCases)

    var isAvailable: Bool {
        OMPAgentEngineBootstrap.isAvailableForDeveloperUse
    }

    func makeEngine(for request: AgentHarnessRequest) throws -> any AgentEngine {
        guard let generationConfiguration = request.generationConfiguration else {
            throw AgentEngineError.unavailable("FileNest has no active global LLM configuration.")
        }
        let workspaceURL = try OMPAgentEngineBootstrap.makeDeveloperWorkspaceURL()
        return try OMPAgentEngineBootstrap.makeDeveloperEngine(
            workingDirectoryURL: workspaceURL,
            generationConfiguration: generationConfiguration,
            toolGateway: FileNestAgentToolGateway(attachedDocument: request.attachedDocument),
            skillContext: request.skillContext
        )
    }
}
