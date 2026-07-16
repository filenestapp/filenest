import Foundation

/// Uses the active AI configuration to place a file in a stable topic subfolder under its primary type folder.
final class FileSubfolderClassifier {
    private let provider: LLMProvider

    init(provider: LLMProvider) {
        self.provider = provider
    }

    func classify(_ file: FileRecord) async -> String? {
        guard provider.name != "none" else { return nil }
        let title = (file.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (file.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let content = String((file.contentText ?? "").prefix(2_000))
        guard !title.isEmpty || !note.isEmpty || !content.isEmpty else { return nil }

        let instructions = """
        You are a local file topic classifier. The file is already in a primary folder based on its extension. Choose a short, stable, reusable topic subfolder based on its title, user note, and content.
        Return JSON only: {"folder":"subfolder name"}. Use 2 to 20 characters. Do not include /, \\, :, a file type, or an extension. Do not explain.
        Prefer reusable topics such as Contracts, Invoices, Project Materials, Meeting Notes, Learning Materials, Product Design, Travel, or Finance. Do not copy the complete file name.
        """
        let context = """
        File name: \(file.name)
        Title: \(title)
        User note: \(note)
        Content: \(content)
        """
        guard let response = try? await provider.chat([
            ChatTurn(role: .system, content: instructions),
            ChatTurn(role: .user, content: context),
        ], context: nil) else { return nil }
        return Self.parse(response)
    }

    static func parse(_ response: String) -> String? {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start <= end,
              let data = String(response[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let safeName = OrganizationTarget.folderName(from: payload.folder) else { return nil }
        let trimmed = safeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...40).contains(trimmed.count) else { return nil }
        return trimmed
    }

    private struct Payload: Decodable {
        let folder: String
    }
}
