import Foundation

struct FileSnapshot: Equatable {
    let size: Int64
    let modificationDate: Date
}

/// 文件的大小和修改时间保持一段时间不变后，才允许进入索引/移动流程。
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
