import Foundation
import CryptoKit

struct FileSnapshot: Equatable {
    let size: Int64
    let modificationDate: Date
}

/// Allows indexing or moving only after a file's size and modification time remain unchanged for a stabilization interval.
struct FileStabilityTracker {
    private struct Observation {
        let snapshot: FileSnapshot
        let stableSince: Date
    }

    private var observations: [String: Observation] = [:]

    mutating func isStable(path: String,
                           snapshot: FileSnapshot,
                           observedAt: Date,
                           minimumStableDuration: TimeInterval) -> Bool {
        guard let previous = observations[path], previous.snapshot == snapshot else {
            observations[path] = Observation(snapshot: snapshot, stableSince: observedAt)
            return false
        }

        guard observedAt.timeIntervalSince(previous.stableSince) >= minimumStableDuration else {
            return false
        }

        observations.removeValue(forKey: path)
        return true
    }

    mutating func retainExistingPaths(_ paths: Set<String>, in directoryPath: String) {
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        observations = observations.filter { path, _ in
            !path.hasPrefix(prefix) || paths.contains(path)
        }
    }
}

struct DirectorySnapshot: Equatable {
    let fileCount: Int
    let totalSize: Int64
    let latestModificationDate: Date
    let signature: String
}

struct DirectoryInspection {
    let snapshot: DirectorySnapshot
    let referenceFile: URL?
    let category: FileCategory
    let topLevelNames: [String]
}

struct DirectoryInspectionBudget: Sendable {
    let maximumEntries: Int
    let maximumDuration: TimeInterval

    static let watcher = DirectoryInspectionBudget(maximumEntries: 10_000, maximumDuration: 0.35)
    static let indexing = DirectoryInspectionBudget(maximumEntries: 50_000, maximumDuration: 2)
}

/// Creates a recursive snapshot for an added folder. Hidden content, especially .git, participates in stability checks,
/// preventing premature processing while a git clone is still updating its object database.
enum DirectoryInspector {
    private static let referenceStems = [
        "readme", "overview", "about", "description", "project", "getting-started", "getting_started"
    ]
    private static let manifestNames: Set<String> = [
        "package.json", "pyproject.toml", "cargo.toml", "package.swift", "go.mod",
        "pom.xml", "build.gradle", "build.gradle.kts", "composer.json", "gemfile"
    ]

    static func inspect(
        _ root: URL,
        budget: DirectoryInspectionBudget = .indexing
    ) -> DirectoryInspection? {
        let fm = FileManager.default
        let startedAt = Date()
        let maximumEntries = max(1, budget.maximumEntries)
        let maximumDuration = max(0.05, budget.maximumDuration)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey
        ]
        guard let topLevel = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ), let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return nil }

        var entries: [(relativePath: String, size: Int64, mtime: Date, isDirectory: Bool)] = []
        var categoryCounts: [FileCategory: Int] = [:]
        var containsCodeProjectMarker = fm.fileExists(
            atPath: root.appendingPathComponent(".git", isDirectory: true).path
        )

        while let url = enumerator.nextObject() as? URL {
            guard entries.count < maximumEntries else { return nil }
            if entries.count.isMultiple(of: 128),
               Date().timeIntervalSince(startedAt) >= maximumDuration {
                return nil
            }
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { enumerator.skipDescendants() }
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            let isDirectory = values.isDirectory == true
            let size = isDirectory ? 0 : Int64(values.fileSize ?? 0)
            let mtime = values.contentModificationDate ?? .distantPast
            entries.append((relativePath, size, mtime, isDirectory))

            guard values.isRegularFile == true else { continue }
            let lowerName = url.lastPathComponent.lowercased()
            if manifestNames.contains(lowerName) { containsCodeProjectMarker = true }
            if !FileEligibilityPolicy.shouldIgnoreFile(named: lowerName) {
                categoryCounts[FileCategory.from(extension: url.pathExtension), default: 0] += 1
            }
        }

        entries.sort { $0.relativePath < $1.relativePath }
        var hasher = SHA256()
        var totalSize: Int64 = 0
        var latestModificationDate = (try? root.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate) ?? .distantPast
        for entry in entries {
            totalSize += entry.size
            latestModificationDate = max(latestModificationDate, entry.mtime)
            let value = "\(entry.relativePath)\u{0}\(entry.isDirectory ? "d" : "f")\u{0}\(entry.size)\u{0}\(entry.mtime.timeIntervalSinceReferenceDate)\n"
            hasher.update(data: Data(value.utf8))
        }
        let signature = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let category = containsCodeProjectMarker
            ? FileCategory.code
            : categoryCounts.max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.rawValue > rhs.key.rawValue
            }?.key ?? .other

        return DirectoryInspection(
            snapshot: DirectorySnapshot(
                fileCount: entries.filter { !$0.isDirectory }.count,
                totalSize: totalSize,
                latestModificationDate: latestModificationDate,
                signature: signature
            ),
            referenceFile: referenceFile(in: root, topLevel: topLevel),
            category: category,
            topLevelNames: topLevel.map(\.lastPathComponent).sorted()
        )
    }

    private static func referenceFile(in root: URL, topLevel: [URL]) -> URL? {
        if let reference = bestReference(in: topLevel) { return reference }
        for folderName in ["docs", "doc", ".github"] {
            let directory = root.appendingPathComponent(folderName, isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ) else { continue }
            if let reference = bestReference(in: entries) { return reference }
        }
        return topLevel.first { manifestNames.contains($0.lastPathComponent.lowercased()) }
    }

    private static func bestReference(in entries: [URL]) -> URL? {
        entries
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                return values?.isRegularFile == true && referenceStemRank(stem) != nil
            }
            .min { lhs, rhs in
                referenceRank(lhs) < referenceRank(rhs)
            }
    }

    private static func referenceRank(_ url: URL) -> Int {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let stemRank = referenceStemRank(stem) ?? referenceStems.count
        let extRank = ["md", "markdown", "rst", "txt", "adoc", "html", ""].firstIndex(
            of: url.pathExtension.lowercased()
        ) ?? 20
        return stemRank * 100 + extRank
    }

    private static func referenceStemRank(_ stem: String) -> Int? {
        referenceStems.firstIndex { candidate in
            stem == candidate || stem.hasPrefix(candidate + ".") ||
                stem.hasPrefix(candidate + "-") || stem.hasPrefix(candidate + "_")
        }
    }
}

struct DirectoryStabilityTracker {
    private struct Observation {
        let snapshot: DirectorySnapshot
        let stableSince: Date
    }

    private var observations: [String: Observation] = [:]

    mutating func isStable(path: String,
                           snapshot: DirectorySnapshot,
                           observedAt: Date,
                           minimumStableDuration: TimeInterval) -> Bool {
        guard let previous = observations[path], previous.snapshot == snapshot else {
            observations[path] = Observation(snapshot: snapshot, stableSince: observedAt)
            return false
        }
        guard observedAt.timeIntervalSince(previous.stableSince) >= minimumStableDuration else {
            return false
        }
        observations.removeValue(forKey: path)
        return true
    }

    mutating func retainExistingPaths(_ paths: Set<String>, in directoryPath: String) {
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        observations = observations.filter { path, _ in
            !path.hasPrefix(prefix) || paths.contains(path)
        }
    }
}
