import Accelerate
import Foundation
import GRDB

/// Persistent sqlite-vec retrieval. The class name remains for compatibility; Accelerate is used only for vector normalization.
final class AccelerateVectorStore: VectorStore, @unchecked Sendable {
    private static let vectorTable = "vec_embeddings"
    private static let dimensionSetting = "sqlite_vec_dimension"
    private let store: SQLiteStore
    private let queue = DispatchQueue(label: "filenest.vectorstore")
    private var storedCount = 0
    private var latestRevisionByFile: [Int64: UInt64] = [:]

    var count: Int { queue.sync { storedCount } }

    init(store: SQLiteStore) { self.store = store }

    func loadAll() async {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    try self.store.dbPool.write { db in
                        _ = try String.fetchOne(db, sql: "SELECT vec_version()")
                        guard let dimension = try Int.fetchOne(
                            db,
                            sql: "SELECT MIN(dim) FROM embeddings HAVING COUNT(DISTINCT dim) = 1"
                        ) else {
                            try self.dropVectorTable(db)
                            return
                        }
                        try self.ensureVectorTable(db, dimension: dimension, allowRecreate: true)
                        let embeddingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings") ?? 0
                        let vectorCount = try Int.fetchOne(
                            db,
                            sql: "SELECT COUNT(*) FROM \(Self.vectorTable)"
                        ) ?? 0
                        if embeddingCount != vectorCount {
                            try db.execute(sql: "DELETE FROM \(Self.vectorTable)")
                            let rows = try Row.fetchAll(db, sql: "SELECT id, vector FROM embeddings ORDER BY id")
                            for row in rows {
                                try db.execute(
                                    sql: "INSERT INTO \(Self.vectorTable)(rowid, embedding) VALUES (?, vec_f32(?))",
                                    arguments: [row["id"] as Int64, row["vector"] as Data]
                                )
                            }
                        }
                    }
                    self.refreshCount()
                    AppLogService.shared.write(
                        "vector store warmup completed",
                        category: .vectorLifecycle,
                        metadata: ["vectors": "\(self.storedCount)"]
                    )
                } catch {
                    self.storedCount = 0
                    AppLogService.shared.write("vector store warmup failed: \(error)",
                                               category: .vectorLifecycle, level: .error)
                }
                continuation.resume()
            }
        }
    }

    @discardableResult
    func replace(fileId: Int64, chunks: [EmbeddingChunk], model: String) async -> Bool {
        await replace(fileId: fileId, chunks: chunks, model: model, revision: nil)
    }

    @discardableResult
    func replace(fileId: Int64,
                 chunks: [EmbeddingChunk],
                 model: String,
                 revision: UInt64?) async -> Bool {
        guard !chunks.isEmpty,
              chunks.allSatisfy({ Self.isValidVector($0.vector) }),
              Set(chunks.map { $0.vector.count }).count == 1,
              let dimension = chunks.first?.vector.count else { return false }
        let normalized = chunks.map { chunk in
            EmbeddingChunk(
                vector: Self.normalize(chunk.vector),
                text: chunk.text,
                contextualText: chunk.contextualText,
                sectionPath: chunk.sectionPath,
                pageStart: chunk.pageStart,
                pageEnd: chunk.pageEnd,
                kind: chunk.kind
            )
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                if let revision,
                   let latest = self.latestRevisionByFile[fileId],
                   revision < latest {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    try self.store.dbPool.write { db in
                        let incompatible = try Bool.fetchOne(
                            db,
                            sql: """
                            SELECT EXISTS(
                                SELECT 1 FROM embeddings
                                WHERE file_id != ? AND (model != ? OR dim != ?)
                            )
                            """,
                            arguments: [fileId, model, dimension]
                        ) ?? false
                        guard !incompatible else { throw VectorStoreError.incompatibleVectorSpace }
                        try self.deleteFileRows(db, fileId: fileId)
                        try self.ensureVectorTable(db, dimension: dimension, allowRecreate: true)

                        for (index, chunk) in normalized.enumerated() {
                            let text = chunk.text ?? ""
                            let contextualText = chunk.contextualText ?? text
                            let sectionData = try JSONEncoder().encode(chunk.sectionPath)
                            let sectionJSON = String(data: sectionData, encoding: .utf8) ?? "[]"
                            try db.execute(
                                sql: """
                                INSERT INTO document_chunks(
                                    file_id, chunk_idx, text, contextual_text, section_path,
                                    page_start, page_end, kind
                                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                                """,
                                arguments: [fileId, index, text, contextualText, sectionJSON,
                                            chunk.pageStart, chunk.pageEnd, chunk.kind.rawValue]
                            )
                            try db.execute(
                                sql: """
                                INSERT INTO embeddings(file_id, vector, dim, model, chunk_idx, chunk_text)
                                VALUES (?, ?, ?, ?, ?, ?)
                                """,
                                arguments: [fileId, Self.encode(chunk.vector), dimension,
                                            model, index, contextualText]
                            )
                            let embeddingID = db.lastInsertedRowID
                            try db.execute(
                                sql: "INSERT INTO \(Self.vectorTable)(rowid, embedding) VALUES (?, vec_f32(?))",
                                arguments: [embeddingID, Self.encode(chunk.vector)]
                            )
                        }
                    }
                    if let revision { self.latestRevisionByFile[fileId] = revision }
                    self.refreshCount()
                    AppLogService.shared.write(
                        "file vectors replaced",
                        category: .vectorWrite,
                        level: .debug,
                        metadata: ["fileID": "\(fileId)", "chunks": "\(chunks.count)", "model": model]
                    )
                    continuation.resume(returning: true)
                } catch {
                    AppLogService.shared.write("file vector replacement failed: \(error)",
                                               category: .vectorWrite, level: .error,
                                               metadata: ["fileID": "\(fileId)"])
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Updates only the user-note chunk for a file. Existing title/body chunks and their
    /// vectors remain untouched, so editing a note never needs to parse the source again.
    @discardableResult
    func updateNote(
        fileId: Int64,
        chunk: EmbeddingChunk?,
        model: String,
        revision: UInt64? = nil
    ) async -> Bool {
        if let chunk {
            guard Self.isValidVector(chunk.vector) else { return false }
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                if let revision,
                   let latest = self.latestRevisionByFile[fileId],
                   revision < latest {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    try self.store.dbPool.write { db in
                        let noteIndexes = try Int.fetchAll(
                            db,
                            sql: "SELECT chunk_idx FROM document_chunks WHERE file_id = ? AND kind = ? ORDER BY chunk_idx",
                            arguments: [fileId, DocumentChunkKind.note.rawValue]
                        )
                        let targetIndex: Int
                        if let existingIndex = noteIndexes.first {
                            targetIndex = existingIndex
                        } else {
                            targetIndex = (try Int.fetchOne(
                                db,
                                sql: "SELECT MAX(chunk_idx) + 1 FROM document_chunks WHERE file_id = ?",
                                arguments: [fileId]
                            )) ?? 0
                        }

                        if !noteIndexes.isEmpty {
                            let embeddingIDs = try Int64.fetchAll(
                                db,
                                sql: """
                                SELECT e.id
                                FROM embeddings e
                                JOIN document_chunks c
                                  ON c.file_id = e.file_id AND c.chunk_idx = e.chunk_idx
                                WHERE e.file_id = ? AND c.kind = ?
                                """,
                                arguments: [fileId, DocumentChunkKind.note.rawValue]
                            )
                            if try self.vectorTableDimension(db) != nil {
                                for embeddingID in embeddingIDs {
                                    try db.execute(
                                        sql: "DELETE FROM \(Self.vectorTable) WHERE rowid = ?",
                                        arguments: [embeddingID]
                                    )
                                }
                            }
                            try db.execute(
                                sql: """
                                DELETE FROM embeddings
                                WHERE file_id = ? AND chunk_idx IN (
                                    SELECT chunk_idx FROM document_chunks
                                    WHERE file_id = ? AND kind = ?
                                )
                                """,
                                arguments: [fileId, fileId, DocumentChunkKind.note.rawValue]
                            )
                            try db.execute(
                                sql: "DELETE FROM document_chunks WHERE file_id = ? AND kind = ?",
                                arguments: [fileId, DocumentChunkKind.note.rawValue]
                            )
                        }

                        guard let chunk else { return }
                        let dimension = chunk.vector.count
                        let incompatible = try Bool.fetchOne(
                            db,
                            sql: "SELECT EXISTS(SELECT 1 FROM embeddings WHERE model != ? OR dim != ?)",
                            arguments: [model, dimension]
                        ) ?? false
                        guard !incompatible else { throw VectorStoreError.incompatibleVectorSpace }
                        try self.ensureVectorTable(db, dimension: dimension, allowRecreate: true)

                        let normalized = Self.normalize(chunk.vector)
                        let text = chunk.text ?? ""
                        let contextualText = chunk.contextualText ?? text
                        let sectionData = try JSONEncoder().encode(chunk.sectionPath)
                        let sectionJSON = String(data: sectionData, encoding: .utf8) ?? "[]"
                        try db.execute(
                            sql: """
                            INSERT INTO document_chunks(
                                file_id, chunk_idx, text, contextual_text, section_path,
                                page_start, page_end, kind
                            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                            arguments: [fileId, targetIndex, text, contextualText, sectionJSON,
                                        chunk.pageStart, chunk.pageEnd, DocumentChunkKind.note.rawValue]
                        )
                        let vectorData = Self.encode(normalized)
                        try db.execute(
                            sql: """
                            INSERT INTO embeddings(file_id, vector, dim, model, chunk_idx, chunk_text)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                            arguments: [fileId, vectorData, dimension, model,
                                        targetIndex, contextualText]
                        )
                        try db.execute(
                            sql: "INSERT INTO \(Self.vectorTable)(rowid, embedding) VALUES (?, vec_f32(?))",
                            arguments: [db.lastInsertedRowID, vectorData]
                        )
                    }
                    if let revision { self.latestRevisionByFile[fileId] = revision }
                    self.refreshCount()
                    AppLogService.shared.write(
                        chunk == nil ? "file note vector removed" : "file note vector updated",
                        category: .vectorWrite,
                        level: .debug,
                        metadata: ["fileID": "\(fileId)", "model": model]
                    )
                    continuation.resume(returning: true)
                } catch {
                    AppLogService.shared.write(
                        "file note vector update failed: \(error)",
                        category: .vectorWrite,
                        level: .error,
                        metadata: ["fileID": "\(fileId)"]
                    )
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func remove(fileId: Int64) async {
        _ = await remove(fileId: fileId, revision: nil)
    }

    @discardableResult
    func remove(fileId: Int64, revision: UInt64?) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                if let revision,
                   let latest = self.latestRevisionByFile[fileId],
                   revision < latest {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    try self.store.dbPool.write { db in try self.deleteFileRows(db, fileId: fileId) }
                    if let revision { self.latestRevisionByFile[fileId] = revision }
                    self.refreshCount()
                    continuation.resume(returning: true)
                } catch {
                    AppLogService.shared.write("file vector removal failed: \(error)",
                                               category: .vectorWrite, level: .error,
                                               metadata: ["fileID": "\(fileId)"])
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Atomically replaces all vectors while retaining extracted document_chunks for embedding-only model migrations.
    @discardableResult
    func replaceAllEmbeddingsPreservingChunks(
        _ chunksByFile: [Int64: [EmbeddingChunk]],
        model: String
    ) async -> Bool {
        let allChunks = chunksByFile.values.flatMap { $0 }
        guard allChunks.allSatisfy({ Self.isValidVector($0.vector) }),
              Set(allChunks.map { $0.vector.count }).count <= 1 else { return false }
        let normalized = chunksByFile.mapValues { chunks in
            chunks.map { chunk in
                EmbeddingChunk(
                    vector: Self.normalize(chunk.vector),
                    text: chunk.text,
                    contextualText: chunk.contextualText,
                    sectionPath: chunk.sectionPath,
                    pageStart: chunk.pageStart,
                    pageEnd: chunk.pageEnd,
                    kind: chunk.kind
                )
            }
        }

        return await withCheckedContinuation { continuation in
            queue.async {
                do {
                    try self.store.dbPool.write { db in
                        try self.dropVectorTable(db)
                        try db.execute(sql: "DELETE FROM embeddings")
                        if let dimension = allChunks.first?.vector.count {
                            try self.ensureVectorTable(db, dimension: dimension, allowRecreate: true)
                            for fileID in normalized.keys.sorted() {
                                for (index, chunk) in (normalized[fileID] ?? []).enumerated() {
                                    let contextualText = chunk.contextualText ?? chunk.text ?? ""
                                    let vectorData = Self.encode(chunk.vector)
                                    try db.execute(
                                        sql: """
                                            INSERT INTO embeddings(
                                                file_id, vector, dim, model, chunk_idx, chunk_text
                                            ) VALUES (?, ?, ?, ?, ?, ?)
                                            """,
                                        arguments: [fileID, vectorData, dimension, model, index, contextualText]
                                    )
                                    try db.execute(
                                        sql: "INSERT INTO \(Self.vectorTable)(rowid, embedding) VALUES (?, vec_f32(?))",
                                        arguments: [db.lastInsertedRowID, vectorData]
                                    )
                                }
                            }
                        }
                    }
                    self.latestRevisionByFile.removeAll()
                    self.refreshCount()
                    AppLogService.shared.write(
                        "embedding-only vector rebuild committed",
                        category: .vectorWrite,
                        level: .notice,
                        metadata: ["files": "\(chunksByFile.count)", "model": model,
                                   "vectors": "\(self.storedCount)"]
                    )
                    continuation.resume(returning: true)
                } catch {
                    AppLogService.shared.write(
                        "embedding-only vector rebuild failed: \(error)",
                        category: .vectorWrite,
                        level: .error
                    )
                    continuation.resume(returning: false)
                }
            }
        }
    }

    @discardableResult
    func removeAll() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    try self.store.dbPool.write { db in
                        try self.dropVectorTable(db)
                        try db.execute(sql: "DELETE FROM embeddings")
                        try db.execute(sql: "DELETE FROM document_chunks")
                    }
                    self.latestRevisionByFile.removeAll()
                    self.storedCount = 0
                    AppLogService.shared.write("all vectors and chunks removed",
                                               category: .vectorWrite, level: .notice)
                    continuation.resume(returning: true)
                } catch {
                    AppLogService.shared.write("removing all vectors failed: \(error)",
                                               category: .vectorWrite, level: .error)
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func search(_ query: [Float], k: Int) async -> [(fileId: Int64, score: Float)] {
        guard k > 0 else { return [] }
        let chunkHits = await searchChunks(query, k: max(k * 4, k))
        var bestByFile = [Int64: Float]()
        for hit in chunkHits {
            bestByFile[hit.fileId] = max(bestByFile[hit.fileId] ?? -.infinity, hit.score)
        }
        let ranked: [(fileId: Int64, score: Float)] = bestByFile.map {
            (fileId: $0.key, score: $0.value)
        }
        return ranked
            .sorted { $0.score == $1.score ? $0.fileId < $1.fileId : $0.score > $1.score }
            .prefix(k).map { $0 }
    }

    func searchChunks(_ query: [Float], k: Int) async -> [VectorSearchHit] {
        guard k > 0, Self.isValidVector(query) else { return [] }
        let normalized = Self.normalize(query)
        return await withCheckedContinuation { (continuation: CheckedContinuation<[VectorSearchHit], Never>) in
            queue.async {
                do {
                    let hits = try self.store.dbPool.read { db -> [VectorSearchHit] in
                        guard try self.vectorTableDimension(db) == normalized.count else { return [] }
                        let rows = try Row.fetchAll(
                            db,
                            sql: """
                            WITH matches AS (
                                SELECT rowid, distance
                                FROM \(Self.vectorTable)
                                WHERE embedding MATCH vec_f32(?) AND k = ?
                            )
                            SELECT e.file_id, e.chunk_idx,
                                   COALESCE(c.contextual_text, e.chunk_text) AS chunk_text,
                                   c.section_path, c.page_start, c.page_end, c.kind,
                                   matches.distance
                            FROM matches
                            JOIN embeddings e ON e.id = matches.rowid
                            LEFT JOIN document_chunks c
                              ON c.file_id = e.file_id AND c.chunk_idx = e.chunk_idx
                            ORDER BY matches.distance, e.id
                            """,
                            arguments: [Self.encode(normalized), k]
                        )
                        return rows.map { Self.hit(from: $0) }
                    }
                    continuation.resume(returning: hits)
                } catch {
                    AppLogService.shared.write("vector search failed: \(error)",
                                               category: .vectorSearch, level: .error,
                                               metadata: ["limit": "\(k)"])
                    continuation.resume(returning: [])
                }
            }
        }
    }

    func searchChunks(_ query: [Float], fileId: Int64, k: Int) async -> [VectorSearchHit] {
        guard k > 0, fileId > 0, Self.isValidVector(query) else { return [] }
        let normalized = Self.normalize(query)
        return await withCheckedContinuation { (continuation: CheckedContinuation<[VectorSearchHit], Never>) in
            queue.async {
                do {
                    let hits = try self.store.dbPool.read { db -> [VectorSearchHit] in
                        let rows = try Row.fetchAll(
                            db,
                            sql: """
                            SELECT e.file_id, e.chunk_idx,
                                   COALESCE(c.contextual_text, e.chunk_text) AS chunk_text,
                                   c.section_path, c.page_start, c.page_end, c.kind,
                                   vec_distance_cosine(e.vector, ?) AS distance
                            FROM embeddings e
                            LEFT JOIN document_chunks c
                              ON c.file_id = e.file_id AND c.chunk_idx = e.chunk_idx
                            WHERE e.file_id = ? AND e.dim = ?
                            ORDER BY distance, e.id
                            LIMIT ?
                            """,
                            arguments: [Self.encode(normalized), fileId, normalized.count, k]
                        )
                        return rows.map { Self.hit(from: $0) }
                    }
                    continuation.resume(returning: hits)
                } catch {
                    AppLogService.shared.write(
                        "file-scoped vector search failed: \(error)",
                        category: .vectorSearch,
                        level: .error,
                        metadata: ["fileID": "\(fileId)", "limit": "\(k)"]
                    )
                    continuation.resume(returning: [])
                }
            }
        }
    }

    func neighboringChunks(fileId: Int64,
                           around chunkIndex: Int,
                           radius: Int) async -> [VectorSearchHit] {
        let safeRadius = max(0, radius)
        return await withCheckedContinuation { continuation in
            queue.async {
                let hits: [VectorSearchHit] = (try? self.store.dbPool.read { db in
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT file_id, chunk_idx, contextual_text AS chunk_text,
                               section_path, page_start, page_end, kind
                        FROM document_chunks
                        WHERE file_id = ? AND chunk_idx BETWEEN ? AND ?
                        ORDER BY chunk_idx
                        """,
                        arguments: [fileId, chunkIndex - safeRadius, chunkIndex + safeRadius]
                    )
                    return rows.map { Self.hit(from: $0, score: 0) }
                }) ?? []
                continuation.resume(returning: hits)
            }
        }
    }

    private func ensureVectorTable(_ db: Database,
                                   dimension: Int,
                                   allowRecreate: Bool) throws {
        guard dimension > 0 else { throw VectorStoreError.invalidDimension }
        let currentDimension = try vectorTableDimension(db)
        if let currentDimension, currentDimension != dimension {
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings") ?? 0
            guard allowRecreate && count == 0 else { throw VectorStoreError.incompatibleVectorSpace }
            try dropVectorTable(db)
        }
        if try vectorTableDimension(db) == nil {
            try db.execute(sql: """
                CREATE VIRTUAL TABLE \(Self.vectorTable)
                USING vec0(embedding float[\(dimension)])
                """)
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: [Self.dimensionSetting, String(dimension)]
            )
        }
    }

    private func vectorTableDimension(_ db: Database) throws -> Int? {
        guard try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?)",
            arguments: [Self.vectorTable]
        ) == true else { return nil }
        return try Int.fetchOne(
            db,
            sql: "SELECT CAST(value AS INTEGER) FROM settings WHERE key = ?",
            arguments: [Self.dimensionSetting]
        )
    }

    private func dropVectorTable(_ db: Database) throws {
        try db.execute(sql: "DROP TABLE IF EXISTS \(Self.vectorTable)")
        try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [Self.dimensionSetting])
    }

    private func deleteFileRows(_ db: Database, fileId: Int64) throws {
        if try vectorTableDimension(db) != nil {
            let ids = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM embeddings WHERE file_id = ?",
                arguments: [fileId]
            )
            for id in ids {
                try db.execute(sql: "DELETE FROM \(Self.vectorTable) WHERE rowid = ?", arguments: [id])
            }
        }
        try db.execute(sql: "DELETE FROM embeddings WHERE file_id = ?", arguments: [fileId])
        try db.execute(sql: "DELETE FROM document_chunks WHERE file_id = ?", arguments: [fileId])
    }

    private func refreshCount() {
        storedCount = (try? store.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings") ?? 0
        }) ?? 0
    }

    private static func hit(from row: Row, score: Float? = nil) -> VectorSearchHit {
        let distance = (row["distance"] as Double?) ?? 0
        let similarity = score ?? Float(max(-1, min(1, 1 - (distance * distance / 2))))
        let sectionJSON = (row["section_path"] as String?) ?? "[]"
        let sectionPath = (try? JSONDecoder().decode([String].self, from: Data(sectionJSON.utf8))) ?? []
        return VectorSearchHit(
            fileId: row["file_id"],
            score: similarity,
            chunkText: row["chunk_text"],
            chunkIndex: row["chunk_idx"],
            sectionPath: sectionPath,
            pageStart: row["page_start"],
            pageEnd: row["page_end"],
            kind: DocumentChunkKind(rawValue: (row["kind"] as String?) ?? "") ?? .text
        )
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var sum: Float = 0
        vDSP_dotpr(a, 1, b, 1, &sum, vDSP_Length(a.count))
        return sum
    }

    static func normalize(_ vector: [Float]) -> [Float] {
        var squared: Float = 0
        vDSP_dotpr(vector, 1, vector, 1, &squared, vDSP_Length(vector.count))
        let norm = sqrt(squared)
        guard norm > 0, norm.isFinite else { return vector }
        var output = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &output, 1, vDSP_Length(vector.count))
        return output
    }

    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
    }

    private static func isValidVector(_ vector: [Float]) -> Bool {
        !vector.isEmpty && vector.allSatisfy(\.isFinite)
    }
}

private enum VectorStoreError: Error {
    case invalidDimension
    case incompatibleVectorSpace
}
