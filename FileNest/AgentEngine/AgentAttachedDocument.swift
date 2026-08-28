import Foundation

/// A bounded, immutable view of one attachment that can be exposed to an Agent Engine.
/// It intentionally omits the file-system path and contains only text already prepared by FileNest.
struct AgentAttachedDocument: Equatable, Sendable {
    struct Chunk: Equatable, Sendable {
        let id: String
        let content: String
    }

    let fileID: Int64?
    let name: String
    let fileExtension: String
    let size: Int64
    let chunks: [Chunk]

    init(
        file: FileRecord,
        preparedContext: String,
        maximumChunkCharacters: Int = 4_000
    ) {
        fileID = file.id
        name = file.name
        fileExtension = file.ext
        size = file.size
        chunks = Self.makeChunks(
            from: preparedContext,
            maximumCharacters: maximumChunkCharacters
        )
    }

    private static func makeChunks(
        from text: String,
        maximumCharacters: Int
    ) -> [Chunk] {
        let limit = max(512, maximumCharacters)
        let sections = text.components(separatedBy: "\n\n")
        var values = [String]()
        var current = ""

        func flushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { values.append(trimmed) }
            current = ""
        }

        for section in sections {
            let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.count > limit {
                flushCurrent()
                var start = trimmed.startIndex
                while start < trimmed.endIndex {
                    let end = trimmed.index(
                        start,
                        offsetBy: limit,
                        limitedBy: trimmed.endIndex
                    ) ?? trimmed.endIndex
                    values.append(String(trimmed[start..<end]))
                    start = end
                }
                continue
            }

            let candidate = current.isEmpty ? trimmed : current + "\n\n" + trimmed
            if candidate.count > limit {
                flushCurrent()
                current = trimmed
            } else {
                current = candidate
            }
        }
        flushCurrent()

        return values.enumerated().map { index, value in
            Chunk(id: String(format: "A%04d", index + 1), content: value)
        }
    }
}
