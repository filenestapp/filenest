import Foundation

/// 规则分类器：基于 DB 规则表 + 内置扩展名大类。
/// hybrid 模式 = 先匹配规则，无命中则回退到扩展名大类。
final class RuleClassifier: Classifier {
    private let rules: [Rule]
    private let strategy: ClassificationStrategy

    init(rules: [Rule], strategy: String) {
        // 按优先级降序
        self.rules = rules.filter { $0.enabled }.sorted { $0.priority > $1.priority }
        self.strategy = ClassificationStrategy(storedValue: strategy)
    }

    func classify(_ file: FileRecord) -> ClassificationDecision? {
        let ext = file.ext.lowercased()

        // 规则匹配（rule 类型：pattern 是逗号分隔的扩展名列表）
        for rule in rules where rule.type == RuleType.rule.rawValue {
            let extensions = rule.pattern.split(separator: ",").map {
                let value = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return value.hasPrefix(".") ? String(value.dropFirst()) : value
            }
            if extensions.contains(ext),
               let targetFolder = OrganizationTarget.folderName(from: rule.targetFolder) {
                return ClassificationDecision(
                    category: FileCategory.from(extension: ext),
                    targetFolder: targetFolder,
                    matchedRuleID: rule.id
                )
            }
        }

        guard strategy == .hybrid else { return nil }
        let category = FileCategory.from(extension: ext)
        return ClassificationDecision(
            category: category,
            targetFolder: category.folderName,
            matchedRuleID: nil
        )
    }
}

/// 整理服务：执行文件移动到「目标根/分类子文件夹」，处理冲突 + 撤销记录。
final class OrganizerService {
    private let store: SQLiteStore
    private let settings: AppSettings
    private let organizeRootOverride: URL?
    private let strategyOverride: ClassificationStrategy?

    init(store: SQLiteStore,
         settings: AppSettings,
         organizeRoot: URL? = nil,
         strategy: ClassificationStrategy? = nil) {
        self.store = store
        self.settings = settings
        self.organizeRootOverride = organizeRoot
        self.strategyOverride = strategy
    }

    /// 目标根目录：默认在用户主目录建一个 FileNestOrganized 目录，按分类分子文件夹。
    var organizeRoot: URL {
        organizeRootOverride
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("FileNestOrganized")
    }

    /// 对一个已入 DB 的文件执行归类
    func organize(fileId: Int64) throws {
        guard var file = try store.file(id: fileId) else { return }
        let rules = (try? store.allRules()) ?? []
        let strategy = strategyOverride?.rawValue ?? settings.classifyStrategy
        let classifier = RuleClassifier(rules: rules, strategy: strategy)
        guard let decision = classifier.classify(file) else {
            NSLog("[Organizer] no matching rule for \(file.name); keeping file in place")
            return
        }

        let destDir = organizeRoot.appendingPathComponent(decision.targetFolder)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let src = URL(fileURLWithPath: file.path)
        let dst = destDir.appendingPathComponent(file.name)
        guard FileManager.default.fileExists(atPath: src.path) else { return }
        guard src.path != dst.path else { return }

        // 冲突处理：同名则追加编号
        let finalDst = resolveConflict(at: dst)

        do {
            try FileManager.default.moveItem(at: src, to: finalDst)
            file.path = finalDst.path
            file.category = decision.category.rawValue
            _ = try store.upsertFile(file)
            NSLog("[Organizer] moved \(src.lastPathComponent) → \(finalDst.path)")
        } catch {
            NSLog("[Organizer] move failed for \(file.name): \(error)")
        }
    }

    /// 手动触发：扫描所有监听目录下的文件入 DB 并归类一次
    func runOnce() {
        for dir in settings.watchDirs {
            let url = URL(fileURLWithPath: dir)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsSubdirectoryDescendants]
            ) else { continue }
            let enabledExts = Set(settings.enabledExtensions.map { $0.lowercased() })
            let now = Date()
            for entry in entries {
                let name = entry.lastPathComponent
                if settings.excludeHidden && name.hasPrefix(".") { continue }
                if name == ".DS_Store" { continue }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir)
                if isDir.boolValue { continue }
                let ext = entry.pathExtension.lowercased()
                if enabledExts.isNotEmpty && !enabledExts.contains(ext) { continue }
                let attrs = try? FileManager.default.attributesOfItem(atPath: entry.path)
                let mtime = (attrs?[.modificationDate] as? Date) ?? now
                let size = Int64((attrs?[.size] as? NSNumber)?.intValue ?? 0)
                let category = FileCategory.from(extension: ext)
                let existing = try? store.file(path: entry.path)
                let record = FileRecord(
                    id: existing?.id, path: entry.path, name: name, ext: ext,
                    size: size, mtime: mtime, category: category.rawValue,
                    sourceDir: entry.deletingLastPathComponent().path,
                    indexedAt: existing?.indexedAt, contentHash: existing?.contentHash,
                    title: existing?.title, contentText: existing?.contentText
                )
                if let id = try? store.upsertFile(record) {
                    // 先索引（文件在原位），再整理移动
                    Task {
                        guard await AppStateIndexerProxy.shared.indexer?.indexFile(id: id, overridePath: entry) == true else {
                            return
                        }
                        try? self.organize(fileId: id)
                    }
                }
            }
        }
    }

    private func resolveConflict(at url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 2
        while true {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(baseName) (\(i))")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}

private extension Collection {
    var isNotEmpty: Bool { !isEmpty }
}
