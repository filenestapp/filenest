import Foundation

final class AIRuleGenerator {
    private let provider: LLMProvider

    init(provider: LLMProvider) {
        self.provider = provider
    }

    func generate(from request: String) async throws -> Rule {
        guard provider.name != "none" else { throw AIRuleGeneratorError.modelDisabled }
        let description = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { throw AIRuleGeneratorError.emptyRequest }

        let response = try await provider.chat([
            ChatTurn(role: .system, content: PromptCatalog.Organization.ruleSystem),
            ChatTurn(role: .user, content: description),
        ], context: nil)
        return try parse(response: response)
    }

    func parse(response: String) throws -> Rule {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start <= end,
              let data = String(response[start...end]).data(using: .utf8) else {
            throw AIRuleGeneratorError.invalidResponse
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw AIRuleGeneratorError.invalidResponse
        }

        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let extensions = payload.extensions.compactMap(Self.normalizeExtension)
        guard !name.isEmpty, !extensions.isEmpty else { throw AIRuleGeneratorError.invalidResponse }
        guard let target = OrganizationTarget.folderName(from: payload.targetFolder) else {
            throw AIRuleGeneratorError.unsafeTargetFolder
        }

        return Rule(
            id: nil,
            name: name,
            type: RuleType.ai.rawValue,
            pattern: Array(Set(extensions)).sorted().joined(separator: ","),
            targetFolder: target,
            priority: min(max(payload.priority ?? 70, 0), 100),
            enabled: true
        )
    }

    private static func normalizeExtension(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix(".") { value.removeFirst() }
        guard !value.isEmpty,
              value.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil else { return nil }
        return value
    }

    private struct Payload: Decodable {
        let name: String
        let extensions: [String]
        let targetFolder: String
        let priority: Int?
    }
}

enum AIRuleGeneratorError: LocalizedError, Equatable {
    case emptyRequest
    case modelDisabled
    case invalidResponse
    case unsafeTargetFolder

    var errorDescription: String? {
        switch self {
        case .emptyRequest: return "Describe the organization rule you want to generate first."
        case .modelDisabled: return "AI models are disabled. Enable a local or cloud model in Settings first."
        case .invalidResponse: return "The model did not return a usable rule. Rephrase your request and try again."
        case .unsafeTargetFolder: return "The model returned an unsafe destination folder name."
        }
    }
}
