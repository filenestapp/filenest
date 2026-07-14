import Foundation
import Accelerate
import GRDB

/// 基于 Accelerate (vDSP) 的内存向量检索：向量以 BLOB 持久化于 SQLite，启动时载入内存做暴力 cosine。
/// 完全 App Sandbox 友好，零依赖。规模到几十万向量内足够快（M 系列 chip）。
final class AccelerateVectorStore: VectorStore, @unchecked Sendable {
    private let store: SQLiteStore
    /// SQLite 与内存索引必须按相同顺序更新，因此所有状态变更都在同一串行队列执行。
    private let queue = DispatchQueue(label: "filenest.vectorstore")

    /// 内存索引：fileId -> (向量 Float 数组，块文本)
    private struct Entry {
        let fileId: Int64
        let vector: [Float]
        let model: String
        let chunkIndex: Int
        let chunkText: String?
    }
    private var entries: [Entry] = []
    var count: Int { queue.sync { entries.count } }

    init(store: SQLiteStore) { self.store = store }

    // MARK: - 持久化 (BLOB <-> [Float])
    private struct EmbeddingRow: FetchableRecord {
        let id: Int64
        let fileId: Int64
        let vector: Data
        let dim: Int
        let model: String
        let chunkIndex: Int
        let chunkText: String?
        init(row: Row) {
            id = row["id"]
            fileId = row["file_id"]
            vector = row["vector"]
            dim = row["dim"]
            model = row["model"]
            chunkIndex = row["chunk_idx"]
            chunkText = row["chunk_text"]
        }
    }

    func loadAll() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let rows: [EmbeddingRow] = (try? self.store.dbPool.read { db in
                    try EmbeddingRow.fetchAll(db, sql: "SELECT * FROM embeddings")
                }) ?? []
                var entries: [Entry] = []
                var expectedSpace: (model: String, dim: Int)?
                for r in rows {
                    let vec = Self.decode(r.vector)
                    guard Self.isValidVector(vec), vec.count == r.dim else { continue }
                    let normalized = Self.normalize(vec)
                    guard Self.isValidVector(normalized) else { continue }
                    if expectedSpace == nil { expectedSpace = (r.model, r.dim) }
                    guard expectedSpace?.model == r.model, expectedSpace?.dim == r.dim else { continue }
                    entries.append(Entry(fileId: r.fileId,
                                         vector: normalized,
                                         model: r.model,
                                         chunkIndex: r.chunkIndex,
                                         chunkText: r.chunkText))
                }
                self.entries = entries
                cont.resume()
            }
        }
    }

    @discardableResult
    func replace(fileId: Int64, chunks: [EmbeddingChunk], model: String) async -> Bool {
        guard !chunks.isEmpty,
              chunks.allSatisfy({ Self.isValidVector($0.vector) }) else {
            NSLog("[VectorStore] replace rejected: invalid vector for file \(fileId)")
            return false
        }
        let normalized = chunks.map { chunk in
            return EmbeddingChunk(vector: Self.normalize(chunk.vector), text: chunk.text)
        }
        guard normalized.allSatisfy({ Self.isValidVector($0.vector) }) else {
            NSLog("[VectorStore] replace rejected: normalization failed for file \(fileId)")
            return false
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async {
                let dimensions = Set(normalized.map { $0.vector.count })
                guard dimensions.count <= 1 else {
                    NSLog("[VectorStore] replace rejected: mixed dimensions for file \(fileId)")
                    cont.resume(returning: false)
                    return
                }

                if let first = normalized.first,
                   let existing = self.entries.first(where: { $0.fileId != fileId }),
                   (existing.vector.count != first.vector.count || existing.model != model) {
                    NSLog("[VectorStore] replace rejected: vector space mismatch for file \(fileId)")
                    cont.resume(returning: false)
                    return
                }

                do {
                    try self.store.dbPool.write { db in
                        try db.execute(sql: "DELETE FROM embeddings WHERE file_id = ?", arguments: [fileId])
                        for (index, chunk) in normalized.enumerated() {
                            try db.execute(
                                sql: "INSERT INTO embeddings(file_id, vector, dim, model, chunk_idx, chunk_text) VALUES(?,?,?,?,?,?)",
                                arguments: [fileId, Self.encode(chunk.vector), chunk.vector.count,
                                            model, index, chunk.text]
                            )
                        }
                    }

                    self.entries.removeAll { $0.fileId == fileId }
                    self.entries.append(contentsOf: normalized.enumerated().map { index, chunk in
                        Entry(fileId: fileId, vector: chunk.vector, model: model,
                              chunkIndex: index, chunkText: chunk.text)
                    })
                } catch {
                    NSLog("[VectorStore] replace failed: \(error)")
                    cont.resume(returning: false)
                    return
                }
                cont.resume(returning: true)
            }
        }
    }

    func remove(fileId: Int64) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                do {
                    try self.store.dbPool.write { db in
                        try db.execute(sql: "DELETE FROM embeddings WHERE file_id = ?", arguments: [fileId])
                    }
                    self.entries.removeAll { $0.fileId == fileId }
                } catch {
                    NSLog("[VectorStore] delete failed: \(error)")
                }
                cont.resume()
            }
        }
    }

    // MARK: - 检索
    func search(_ query: [Float], k: Int) async -> [(fileId: Int64, score: Float)] {
        return await withCheckedContinuation { (cont: CheckedContinuation<[(Int64, Float)], Never>) in
            queue.async {
                guard k > 0,
                      let first = self.entries.first,
                      Self.isValidVector(query),
                      query.count == first.vector.count else {
                    cont.resume(returning: [])
                    return
                }

                let q = Self.normalize(query)
                guard Self.isValidVector(q) else {
                    cont.resume(returning: [])
                    return
                }
                // 逐条点积（vectors 已在入库时归一化；这里再做一次防御性归一化）
                var bestScoreByFile: [Int64: Float] = [:]
                bestScoreByFile.reserveCapacity(self.entries.count)
                for e in self.entries {
                    let dot = Self.dot(q, e.vector)
                    if dot > bestScoreByFile[e.fileId, default: -.infinity] {
                        bestScoreByFile[e.fileId] = dot
                    }
                }
                var scored = bestScoreByFile.map { (fileId: $0.key, score: $0.value) }
                scored.sort {
                    $0.score == $1.score ? $0.fileId < $1.fileId : $0.score > $1.score
                }
                cont.resume(returning: Array(scored.prefix(k)))
            }
        }
    }

    // MARK: - vDSP 工具
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var sum: Float = 0
        vDSP_dotpr(a, 1, b, 1, &sum, vDSP_Length(a.count))
        return sum
    }

    static func normalize(_ v: [Float]) -> [Float] {
        var sq: Float = 0
        vDSP_dotpr(v, 1, v, 1, &sq, vDSP_Length(v.count))
        let n = sqrt(sq)
        guard n > 0 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var inv = 1.0 / Float(n)
        vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
        return out
    }

    private static func isValidVector(_ vector: [Float]) -> Bool {
        !vector.isEmpty && vector.allSatisfy { $0.isFinite }
    }

    /// [Float] -> Data (little-endian)
    static func encode(_ v: [Float]) -> Data {
        var copy = v
        return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size)
    }

    /// Data -> [Float]
    static func decode(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: Float.self)
            return Array(buf)
        }
    }
}
