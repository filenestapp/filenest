import Foundation

/// 规则分类器：基于 DB 规则表 + 内置扩展名大类。
/// hybrid 模式 = 先匹配规则，无命中则回退到扩展名大类。
final class RuleClassifier: Classifier {
    private let rules: [Rule]
    private let strategy: String

    init(rules: [Rule], strategy: String) {
        // 按优先级降序
        self.rules = rules.filter { $0.enabled }.sorted { $0.priority > $1.priority }
        self.strategy = strategy
    }

    func classify(_ file: FileRecord) -> FileCategory {
        let ext = file.ext.lowercased()

        // 规则匹配（rule 类型：pattern 是逗号分隔的扩展名列表）
        if strategy == "rule" || strategy == "hybrid" {
            for r in rules where r.type == "rule" {
                let exts = r.pattern.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if exts.contains(ext) {
                    // target_folder 映射回 FileCategory
                    return FileCategory.allCases.first { $0.folderName == r.targetFolder } ?? .other
                }
            }
        }
        // AI 分类留待后续迭代；hybrid 下回退到扩展名大类
        if strategy == "ai" {
            // MVP：AI 分类降级为扩展名大类
            return FileCategory.from(extension: ext)
        }
        return FileCategory.from(extension: ext)
    }
}

/// 整理服务：执行文件移动到「目标根/分类子文件夹」，处理冲突 + 撤销记录。
final class OrganizerService {
    private let store: SQLiteStore
    private let settings: AppSettings

    init(store: SQLiteStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
    }

    /// 目标根目录：默认在用户主目录建一个 FileNestOrganized 目录，按分类分子文件夹。
    var organizeRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("FileNestOrganized")
    }

    /// 对一个已入 DB 的文件执行归类
    func organize(fileId: Int64) throws {
        guard var file = try store.file(id: fileId) else { return }
        let rules = (try? store.allRules()) ?? []
        let classifier = RuleClassifier(rules: rules, strategy: settings.classifyStrategy)
        let category = classifier.classify(file)

        let destDir = organizeRoot.appendingPathComponent(category.folderName)
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
            file.category = category.rawValue
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
                let record = FileRecord(
                    id: nil, path: entry.path, name: name, ext: ext,
                    size: size, mtime: mtime, category: category.rawValue,
                    sourceDir: entry.deletingLastPathComponent().path,
                    indexedAt: Date(), contentHash: nil, title: nil, contentText: nil
                )
                if let id = try? store.upsertFile(record) {
                    // 先索引（文件在原位），再整理移动
                    Task {
                        await AppStateIndexerProxy.shared.indexer?.indexFile(id: id, overridePath: entry)
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
