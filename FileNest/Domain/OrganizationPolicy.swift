import Foundation

enum ClassificationStrategy: String {
    case hybrid
    case rule

    init(storedValue: String) {
        self = ClassificationStrategy(rawValue: storedValue) ?? .hybrid
    }
}

struct ClassificationDecision: Equatable {
    let category: FileCategory
    let targetFolder: String
    let matchedRuleID: Int64?
    let action: RuleAction

    init(category: FileCategory,
         targetFolder: String,
         matchedRuleID: Int64?,
         action: RuleAction = .organize) {
        self.category = category
        self.targetFolder = targetFolder
        self.matchedRuleID = matchedRuleID
        self.action = action
    }
}

enum OrganizationTarget {
    static func folderName(from rawValue: String) -> String? {
        let name = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              !name.contains("/"),
              !name.contains("\\"),
              !name.contains(":") else {
            return nil
        }
        return name
    }
}
