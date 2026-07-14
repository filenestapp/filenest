import Foundation
import Accelerate
import GRDB

/// 基于 Accelerate (vDSP) 的内存向量检索：向量以 BLOB 持久化于 SQLite，启动时载入内存做暴力 cosine。
/// 完全 App Sandbox 友好，零依赖。规模到几十万向量内足够快（M 系列 chip）。
final class AccelerateVectorStore: VectorStore {
    private let store: SQLiteStore
    private let queue = DispatchQueue(label: "filenest.vectorstore", attributes: .concurrent)

    /// 内存索引：fileId -> (向量 Float 数组，块文本)
    private struct Entry {
        let fileId: Int64
        let vector: [Float]
        let chunkText: String?
    }
    private var entries: [Entry] = []
    /// 扁平化的连续 Float 矩阵 + 每条记录在其中的起始/长度，便于 vDSP 批量点积
    private var matrix: [Float] = []
    private var spans: [(start: Int, count: Int)] = []
    private(set) var count: Int = 0
    private var dim: Int = 0

    init(store: SQLiteStore) { self.store = store }

    // MARK: - 持久化 (BLOB <-> [Float])
    private struct EmbeddingRow: FetchableRecord {
        let id: Int64
        let fileId: Int64
        let vector: Data
        let dim: Int
        let chunkText: String?
        init(row: Row) {
            id = row["id"]
            fileId = row["file_id"]
            vector = row["vector"]
            dim = row["dim"]
            chunkText = row["chunk_text"]
        }
    }

    func loadAll() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async(flags: .barrier) { [store] in
                let rows: [EmbeddingRow] = (try? store.dbPool.read { db in
                    try EmbeddingRow.fetchAll(db, sql: "SELECT * FROM embeddings")
                }) ?? []
                var entries: [Entry] = []
                var matrix: [Float] = []
                var spans: [(start: Int, count: Int)] = []
                var dim = 0
                for r in rows {
                    let vec = Self.decode(r.vector)
                    if vec.isEmpty { continue }
                    if dim == 0 { dim = vec.count }
                    guard vec.count == dim else { continue } // 维度一致才纳入
                    let start = matrix.count
                    matrix.append(contentsOf: vec)
                    spans.append((start, vec.count))
                    entries.append(Entry(fileId: r.fileId, vector: vec, chunkText: r.chunkText))
                }
                self.entries = entries
                self.matrix = matrix
                self.spans = spans
                self.dim = dim
                self.count = entries.count
                cont.resume()
            }
        }
    }

    func upsert(fileId: Int64, vector: [Float], chunkText: String?) async {
        guard !vector.isEmpty else { return }
        // 先删后插（同一文件可能多块）
        removeFromDB(fileId: fileId)
        insertToDB(fileId: fileId, vector: vector, chunkText: chunkText)
        // 更新内存索引（无需全部重载）
        queue.sync(flags: .barrier) {
            if dim == 0 { dim = vector.count }
            guard vector.count == dim else { return } // 维度不一致跳过
            let start = matrix.count
            matrix.append(contentsOf: vector)
            spans.append((start, vector.count))
            entries.append(Entry(fileId: fileId, vector: vector, chunkText: chunkText))
            count = entries.count
        }
    }

    private func insertToDB(fileId: Int64, vector: [Float], chunkText: String?) {
        let blob = Self.encode(vector)
        let model = "nlembedding"
        do {
            _ = try store.dbPool.writeWithoutTransaction { db in
                try db.execute(
                    sql: "INSERT INTO embeddings(file_id, vector, dim, model, chunk_idx, chunk_text) VALUES(?,?,?,?,?,?)",
                    arguments: [fileId, blob, vector.count, model, 0, chunkText]
                )
            }
        } catch {
            NSLog("[VectorStore] insert failed: \(error)")
        }
    }

    func remove(fileId: Int64) async {
        removeFromDB(fileId: fileId)
        queue.sync(flags: .barrier) {
            // 重建内存索引（删除不频繁）
            entries.removeAll { $0.fileId == fileId }
            rebuildMatrixLocked()
            count = entries.count
        }
    }

    private func removeFromDB(fileId: Int64) {
        do {
            _ = try store.dbPool.writeWithoutTransaction { db in
                try db.execute(sql: "DELETE FROM embeddings WHERE file_id = ?", arguments: [fileId])
            }
        } catch {
            NSLog("[VectorStore] delete failed: \(error)")
        }
    }

    private func rebuildMatrixLocked() {
        matrix.removeAll(keepingCapacity: true)
        spans.removeAll(keepingCapacity: true)
        for v in entries.map(\.vector) {
            spans.append((matrix.count, v.count))
            matrix.append(contentsOf: v)
        }
    }

    // MARK: - 检索
    func search(_ query: [Float], k: Int) async -> [(fileId: Int64, score: Float)] {
        guard !entries.isEmpty, !query.isEmpty else { return [] }
        let dim = self.dim
        guard query.count == dim else { return [] }

        // 归一化 query
        let q = Self.normalize(query)

        return await withCheckedContinuation { (cont: CheckedContinuation<[(Int64, Float)], Never>) in
            queue.async { [entries] in
                // 逐条点积（vectors 已在入库时归一化；这里再做一次防御性归一化）
                var scored: [(Int64, Float)] = []
                scored.reserveCapacity(entries.count)
                for e in entries {
                    let v = Self.normalize(e.vector)
                    let dot = Self.dot(q, v)
                    scored.append((e.fileId, dot))
                }
                scored.sort { $0.1 > $1.1 }
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
