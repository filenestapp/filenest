import Foundation

/// 索引服务：对单个文件 抽取内容 -> 分块 -> 向量化 -> 入库。
/// 持有 EmbeddingProvider 与 VectorStore 实例。
final class IndexerService {
    private let store: SQLiteStore
    private let settings: AppSettings
    private let providedEmbedder: EmbeddingProvider?
    let vectorStore: AccelerateVectorStore
    private lazy var embedder: EmbeddingProvider = providedEmbedder ?? settings.makeEmbeddingProvider()

    init(store: SQLiteStore, settings: AppSettings, embedder: EmbeddingProvider? = nil) {
        self.store = store
        self.settings = settings
        self.providedEmbedder = embedder
        self.vectorStore = AccelerateVectorStore(store: store)
    }

    /// 启动时载入向量索引
    func warmup() async {
        await vectorStore.loadAll()
    }

    /// 对单个文件建立/重建索引
    /// - Parameter overridePath: 可选的文件实际路径（用于文件尚未移动到 DB 记录路径时的索引）
    @discardableResult
    func indexFile(id: Int64, overridePath: URL? = nil, force: Bool = false) async -> Bool {
        guard let file = try? store.file(id: id) else {
            Self.log("indexFile: file \(id) not found"); return false
        }
        let url = overridePath ?? URL(fileURLWithPath: file.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Self.log("indexFile: \(file.name) not found at \(url.path)"); return false
        }
        Self.log("indexFile START: \(file.name) (.\(file.ext))")

        let contentHash = try? FileContentHasher.sha256(of: url)
        if !force,
           file.indexedAt != nil,
           let contentHash,
           file.contentHash == contentHash {
            Self.log("skip \(file.name): content unchanged")
            return true
        }

        let extracted = ContentExtractor.extract(url: url, ext: file.ext)
        // 更新 files 表的内容字段
        var updated = file
        updated.title = extracted.title
        updated.contentText = extracted.text
        updated.contentHash = contentHash
        updated.indexedAt = nil
        do {
            _ = try store.upsertFile(updated)
        } catch {
            Self.log("update metadata failed for \(file.name): \(error)")
            return false
        }

        // 向量化（仅对有实质文本的）
        guard !extracted.text.isEmpty else {
            guard Self.contentIsUnchanged(at: url, expectedHash: contentHash) else {
                Self.log("index aborted \(file.name): file changed during extraction")
                return false
            }
            await vectorStore.remove(fileId: id)
            updated.indexedAt = Date()
            do {
                _ = try store.upsertFile(updated)
            } catch {
                Self.log("mark indexed failed for \(file.name): \(error)")
                return false
            }
            Self.log("skip vectorize \(file.name): no text")
            return true
        }
        let chunks = Self.chunk(text: extracted.text, maxWords: 200, overlap: 30)
        // 把标题也作为一段参与向量化，提升「按主题找」的召回
        var texts = [String]()
        if let t = extracted.title { texts.append(t) }
        texts.append(contentsOf: chunks)

        Self.log("vectorizing \(file.name): \(texts.count) segments, textLen=\(extracted.text.count)")
        var embeddings: [EmbeddingChunk] = []
        for (i, text) in texts.enumerated() {
            // NLEmbedding 句向量在中文长文本上表现一般，取每段前若干句
            let piece = String(text.prefix(800))
            if let vec = try? await embedder.embed(piece), !vec.isEmpty {
                embeddings.append(EmbeddingChunk(vector: vec, text: text))
                Self.log("  segment \(i): embedded dim=\(vec.count)")
            } else {
                Self.log("  segment \(i): embed FAILED/empty for piece(\(piece.count) chars)")
            }
        }
        guard !embeddings.isEmpty else {
            Self.log("index failed \(file.name): no embeddings generated")
            return false
        }
        guard Self.contentIsUnchanged(at: url, expectedHash: contentHash) else {
            Self.log("index aborted \(file.name): file changed during embedding")
            return false
        }
        guard await vectorStore.replace(fileId: id, chunks: embeddings, model: embedder.name) else {
            Self.log("index failed \(file.name): vector store rejected replacement")
            return false
        }
        updated.indexedAt = Date()
        do {
            _ = try store.upsertFile(updated)
        } catch {
            Self.log("mark indexed failed for \(file.name): \(error)")
            return false
        }
        Self.log("done \(file.name): \(embeddings.count)/\(texts.count) embedded")
        return true
    }

    private static func contentIsUnchanged(at url: URL, expectedHash: String?) -> Bool {
        guard let expectedHash else { return true }
        return (try? FileContentHasher.sha256(of: url)) == expectedHash
    }

    /// 重新索引全部文件
    func reindexAll() {
        let files = (try? store.allFiles()) ?? []
        Task {
            await vectorStore.loadAll()
            for f in files {
                await indexFile(id: f.id!, force: true)
            }
        }
    }

    /// 简单滑动窗口分块（按词/按字符近似）
    static func chunk(text: String, maxWords: Int, overlap: Int) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard maxWords > 0, !words.isEmpty else { return [] }

        let boundedOverlap = min(max(overlap, 0), maxWords - 1)
        let maxChars = maxWords * 4
        if words.count <= maxWords {
            guard text.count > maxChars else { return [text] }

            let characters = Array(text)
            let overlapChars = min(boundedOverlap * 4, maxChars - 1)
            let step = maxChars - overlapChars
            var chunks: [String] = []
            var start = 0
            while start < characters.count {
                let end = min(start + maxChars, characters.count)
                chunks.append(String(characters[start..<end]))
                if end >= characters.count { break }
                start += step
            }
            return chunks
        }

        var result: [String] = []
        var i = 0
        let step = maxWords - boundedOverlap
        while i < words.count {
            let end = min(i + maxWords, words.count)
            let chunk = words[i..<end].joined(separator: " ")
            result.append(chunk)
            if end >= words.count { break }
            i += step
        }
        return result
    }

    // MARK: - 文件日志（调试用，绕过统一日志系统的隐私过滤）
    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("FileNestLogs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("indexer.log")
    }()

    static func log(_ msg: String) {
        let line = "[\(Date().formatted(.dateTime))] \(msg)\n"
        NSLog("[Indexer] \(msg)")
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let h = FileHandle(forWritingAtPath: logURL.path) {
                    h.seekToEndOfFile(); h.write(data); h.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}
