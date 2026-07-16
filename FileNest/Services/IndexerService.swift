import Foundation
import GRDB

enum IndexingStage: Equatable, Sendable {
    case hashing
    case ocr
    case docling
    case extracting
    case chunking
    case embedding(completed: Int, total: Int)
    case saving

    var statusText: String {
        switch self {
        case .hashing: return "Checking file"
        case .ocr: return "Recognizing image text"
        case .docling: return "Parsing document"
        case .extracting: return "Extracting content"
        case .chunking: return "Splitting document"
        case let .embedding(completed, total): return "Generating vectors \(completed)/\(total)"
        case .saving: return "Saving index"
        }
    }
}

struct VectorIndexRebuildProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case clearing
        case indexing
        case paused
        case stopping
        case stopped
        case completed
        case failed
    }

    let phase: Phase
    let completed: Int
    let total: Int
    let currentFileName: String?
    let failed: Int
    let stage: IndexingStage?

    init(phase: Phase, completed: Int, total: Int, currentFileName: String?,
         failed: Int, stage: IndexingStage? = nil) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.currentFileName = currentFileName
        self.failed = failed
        self.stage = stage
    }

    var fraction: Double {
        guard total > 0 else { return phase == .completed ? 1 : 0 }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

struct IndexBatchResult: Equatable, Sendable {
    let completed: Int
    let failed: Int
    let stopped: Bool
}

private actor IndexTaskCoordinator {
    private struct Entry {
        let token: UUID
        let requestKey: String
        let task: Task<Bool, Never>
    }
    private var entries = [Int64: Entry]()

    func run(fileID: Int64, requestKey: String,
             operation: @escaping @Sendable () async -> Bool) async -> Bool {
        if let entry = entries[fileID] {
            if entry.requestKey == requestKey { return await entry.task.value }
            _ = await entry.task.value
            if entries[fileID]?.token == entry.token { entries.removeValue(forKey: fileID) }
        }
        let token = UUID()
        let task = Task { await operation() }
        entries[fileID] = Entry(token: token, requestKey: requestKey, task: task)
        let result = await task.value
        if entries[fileID]?.token == token { entries.removeValue(forKey: fileID) }
        return result
    }

    func cancel(fileID: Int64) { entries[fileID]?.task.cancel() }

    func cancelAll() {
        entries.values.forEach { $0.task.cancel() }
        entries.removeAll()
    }
}

private actor IndexBatchProgressReporter {
    private let total: Int
    private let progress: (@MainActor (VectorIndexRebuildProgress) -> Void)?
    private var completed = 0
    private var failed = 0

    init(total: Int, progress: (@MainActor (VectorIndexRebuildProgress) -> Void)?) {
        self.total = total
        self.progress = progress
    }

    func report(fileName: String, stage: IndexingStage?) async {
        await progress?(VectorIndexRebuildProgress(
            phase: .indexing,
            completed: completed,
            total: total,
            currentFileName: fileName,
            failed: failed,
            stage: stage
        ))
    }

    func finishFile(named fileName: String, succeeded: Bool) async {
        completed += 1
        if !succeeded { failed += 1 }
        await progress?(VectorIndexRebuildProgress(
            phase: .indexing,
            completed: completed,
            total: total,
            currentFileName: fileName,
            failed: failed
        ))
    }

    func result(stopped: Bool) -> IndexBatchResult {
        IndexBatchResult(completed: completed, failed: failed, stopped: stopped)
    }
}

actor IndexingExecutionGate {
    private enum State {
        case running
        case paused
        case stopped
    }

    private var state: State = .running

    func reset() { state = .running }

    func pause() {
        guard state == .running else { return }
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        state = .running
    }

    func stop() { state = .stopped }

    func waitUntilRunnable() async -> Bool {
        while state == .paused {
            guard !Task.isCancelled else { return false }
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return false
            }
        }
        return state == .running && !Task.isCancelled
    }
}

private struct FileMutationSnapshot {
    let size: Int64
    let modificationDate: Date

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modificationDate = values.contentModificationDate else { return nil }
        self.size = Int64(size)
        self.modificationDate = modificationDate
    }

    func matches(_ url: URL) -> Bool {
        guard let current = FileMutationSnapshot(url: url) else { return false }
        return current.size == size && current.modificationDate == modificationDate
    }
}

private enum EmbeddingBatchError: LocalizedError {
    case emptyVector(index: Int)

    var errorDescription: String? {
        switch self {
        case let .emptyVector(index):
            return "Embedding response returned an empty vector for segment \(index + 1)"
        }
    }
}

/// Indexing service: extracts one file, splits it into chunks, creates embeddings, and stores the result.
/// Owns the EmbeddingProvider and VectorStore instances.
final class IndexerService {
    private let store: SQLiteStore
    private let settings: AppSettings
    private let providedEmbedder: EmbeddingProvider?
    private let providedOCRProvider: OCRProvider?
    private let doclingProcessor = DoclingDocumentProcessor()
    private let taskCoordinator = IndexTaskCoordinator()
    private let embedderLock = NSLock()
    private var cachedEmbedder: (signature: String, provider: EmbeddingProvider)?
    private let ocrProviderLock = NSLock()
    private var cachedOCRProvider: (signature: String, provider: OCRProvider?)?
    let vectorStore: AccelerateVectorStore
    private let generationLock = NSLock()
    private var nextGeneration: UInt64 = 0
    private var activeGenerations: [Int64: UInt64] = [:]

    init(store: SQLiteStore, settings: AppSettings, embedder: EmbeddingProvider? = nil,
         ocrProvider: OCRProvider? = nil) {
        self.store = store
        self.settings = settings
        self.providedEmbedder = embedder
        self.providedOCRProvider = ocrProvider
        self.vectorStore = AccelerateVectorStore(store: store)
    }

    /// Loads the vector index at startup.
    func warmup() async {
        // AppState starts an atomic rebuild for incompatible models; warm-up retains old chunks and vectors as a fallback.
        await vectorStore.loadAll()
    }

    /// Builds or rebuilds the index for one file.
    /// - Parameter overridePath: Optional physical path used when the file has not yet moved to its database-recorded path.
    @discardableResult
    func indexFile(id: Int64, overridePath: URL? = nil, force: Bool = false,
                   forceVectorization: Bool = false,
                   checkpoint: (@Sendable () async -> Bool)? = nil,
                   stageProgress: (@Sendable (IndexingStage) async -> Void)? = nil) async -> Bool {
        await withTaskCancellationHandler {
            let requestKey = [
                force ? "force" : "incremental",
                forceVectorization ? "vector" : "configured",
                overridePath?.standardizedFileURL.path ?? "stored-path",
                settings.indexConfigurationSignature,
            ].joined(separator: "|")
            return await taskCoordinator.run(fileID: id, requestKey: requestKey) { [weak self] in
                guard let self else { return false }
                return await self.performIndexFile(
                    id: id,
                    overridePath: overridePath,
                    force: force,
                    forceVectorization: forceVectorization,
                    checkpoint: checkpoint,
                    stageProgress: stageProgress
                )
            }
        } onCancel: { [taskCoordinator] in
            Task { await taskCoordinator.cancel(fileID: id) }
        }
    }

    func cancelAll() async {
        await taskCoordinator.cancelAll()
    }

    func cancel(fileID: Int64) async {
        generationLock.lock()
        activeGenerations.removeValue(forKey: fileID)
        generationLock.unlock()
        await taskCoordinator.cancel(fileID: fileID)
    }

    /// Re-embeds only the editable note chunk. Source extraction, Docling, OCR, and the
    /// existing title/body vectors are deliberately not touched.
    @discardableResult
    func updateNoteIndex(fileID: Int64, note: String) async -> Bool {
        let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored = try? store.file(id: fileID),
              (stored.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == normalized else {
            return false
        }

        let generation = beginIndexGeneration(fileId: fileID)
        defer { finishIndexGeneration(fileId: fileID, generation: generation) }
        let embedder = activeEmbedder()

        if normalized.isEmpty {
            return await vectorStore.updateNote(
                fileId: fileID,
                chunk: nil,
                model: embedder.name,
                revision: generation
            )
        }

        let chunks = [StructuredDocumentChunk(
            text: "User note: \(normalized)",
            kind: .note
        )]
        let embeddings = await embed(
            chunks: chunks,
            using: embedder,
            checkpoint: { !Task.isCancelled },
            stageProgress: nil
        )
        guard embeddings.count == 1,
              isCurrentGeneration(fileId: fileID, generation: generation),
              let latest = try? store.file(id: fileID),
              (latest.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == normalized else {
            return false
        }
        return await vectorStore.updateNote(
            fileId: fileID,
            chunk: embeddings[0],
            model: embedder.name,
            revision: generation
        )
    }

    private func performIndexFile(
        id: Int64,
        overridePath: URL?,
        force: Bool,
        forceVectorization: Bool,
        checkpoint: (@Sendable () async -> Bool)?,
        stageProgress: (@Sendable (IndexingStage) async -> Void)?
    ) async -> Bool {
        guard let file = try? store.file(id: id) else {
            Self.log("file record not found", level: .error, metadata: ["fileID": "\(id)"])
            return false
        }
        let url = overridePath ?? URL(fileURLWithPath: file.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Self.log("source file not found", level: .error, metadata: ["file": file.name])
            return false
        }
        if file.isDirectory {
            guard let inspection = DirectoryInspector.inspect(url) else {
                Self.log(
                    "directory inspection failed",
                    category: .indexExtraction,
                    level: .error,
                    metadata: ["entry": file.name]
                )
                return false
            }
            return await indexDirectory(
                file: file,
                url: url,
                inspection: inspection,
                force: force,
                checkpoint: checkpoint,
                stageProgress: stageProgress
            )
        }

        let generation = beginIndexGeneration(fileId: id)
        defer { finishIndexGeneration(fileId: id, generation: generation) }
        Self.log(
            "file indexing started",
            metadata: ["file": file.name, "extension": file.ext, "fileID": "\(id)"]
        )

        guard await canContinue(checkpoint) else { return false }
        await stageProgress?(.hashing)
        let sourceSnapshot = FileMutationSnapshot(url: url)
        let contentHash = try? FileContentHasher.sha256(of: url)
        let indexSignature = settings.indexConfigurationSignature
        if !force,
           file.indexedAt != nil,
           let contentHash,
           file.contentHash == contentHash,
           file.indexSignature == indexSignature {
            Self.log(
                "file indexing skipped; content and configuration unchanged",
                level: .debug,
                metadata: ["file": file.name]
            )
            return true
        }

        let shouldProcessContent = forceVectorization || settings.shouldVectorize(extension: file.ext)
        guard await canContinue(checkpoint) else { return false }
        await stageProgress?(.ocr)
        let pdfAnalysis = file.ext.lowercased() == "pdf"
            ? OCRDocumentProcessor.analyzePDF(at: url)
            : nil
        let isRasterImage = OCRDocumentProcessor.isRasterImage(extension: file.ext)
        guard await canContinue(checkpoint) else { return false }
        await stageProgress?(.docling)
        // Raster images use the dedicated OCR pipeline. Sending them through Docling first
        // duplicated work and can hit native OpenCV resize crashes in the Docling environment.
        let docling = settings.doclingEnabled && shouldProcessContent && !isRasterImage
            ? await doclingProcessor.process(
                url: url,
                ext: file.ext,
                maxTokens: settings.vectorChunkWords,
                pdfAnalysis: pdfAnalysis,
                disableBuiltInOCR: settings.ocrSource != AppSettings.OCRSource.disabled.rawValue
            )
            : nil
        // Docling handles structure parsing; pages that need OCR go to the configured primary OCR provider.
        let shouldRunConfiguredOCR = docling == nil || OCRDocumentProcessor.requiresRecognition(
            ext: file.ext,
            pdfAnalysis: pdfAnalysis
        )
        let ocrText = shouldRunConfiguredOCR
            ? await OCRDocumentProcessor.recognizeIfNeeded(
                url: url,
                ext: file.ext,
                provider: shouldProcessContent ? activeOCRProvider() : nil,
                checkpoint: checkpoint
            )
            : nil
        guard await canContinue(checkpoint) else { return false }
        await stageProgress?(.extracting)
        var extracted = docling?.extracted ?? ContentExtractor.extract(url: url, ext: file.ext)
        var appendedOCRText: String?
        if let ocrText,
           Self.shouldAppendOCRText(ocrText, to: extracted.text) {
            extracted.text = [extracted.text, ocrText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            appendedOCRText = ocrText
        }
        // Update the content columns in the files table.
        var updated = file
        updated.title = extracted.title
        updated.contentText = extracted.text
        updated.contentHash = contentHash
        updated.indexedAt = nil
        updated.indexSignature = nil
        do {
            guard try upsertIfCurrent(updated, fileId: id, generation: generation) else {
                Self.log("indexing superseded before metadata update", level: .notice,
                         metadata: ["file": file.name])
                return false
            }
        } catch {
            Self.log("metadata update failed: \(error)", category: .indexPersistence,
                     level: .error, metadata: ["file": file.name])
            return false
        }

        let note = (updated.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let extractedTitle = (extracted.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // When automatic vectorization is disabled or the extension is out of scope, still save the title and metadata and mark scanning complete,
        // but remove old vectors so settings changes do not keep out-of-scope content in semantic results.
        if !forceVectorization && !settings.shouldVectorize(extension: file.ext) {
            guard Self.contentHashMatches(url, expectedHash: contentHash),
                  isCurrentGeneration(fileId: id, generation: generation),
                  await vectorStore.remove(fileId: id, revision: generation) else {
                return false
            }
            updated.indexedAt = Date()
            updated.indexSignature = indexSignature
            do {
                guard try upsertIfCurrent(updated, fileId: id, generation: generation) else { return false }
            } catch {
                Self.log("metadata-only completion failed: \(error)", category: .indexPersistence,
                         level: .error, metadata: ["file": file.name])
                return false
            }
            Self.log(
                "metadata-only indexing completed; vectorization disabled",
                category: .indexExtraction,
                metadata: ["file": file.name, "extension": file.ext]
            )
            return true
        }

        // The title, user note, and body share one file vector space; notes remain searchable even when the file itself cannot be extracted.
        guard !extracted.text.isEmpty || !note.isEmpty || !extractedTitle.isEmpty else {
            guard Self.contentHashMatches(url, expectedHash: contentHash) else {
                Self.log("index aborted \(file.name): file changed during extraction")
                return false
            }
            guard isCurrentGeneration(fileId: id, generation: generation) else {
                Self.log("index superseded \(file.name) before vector removal")
                return false
            }
            guard await vectorStore.remove(fileId: id, revision: generation) else {
                Self.log("vector removal rejected", category: .indexPersistence, level: .error,
                         metadata: ["file": file.name])
                return false
            }
            guard sourceSnapshot?.matches(url) != false else {
                Self.log("index aborted \(file.name): file changed before completion")
                return false
            }
            updated.indexedAt = Date()
            updated.indexSignature = indexSignature
            do {
                guard try upsertIfCurrent(updated, fileId: id, generation: generation) else {
                    Self.log("index superseded \(file.name) before completion")
                    return false
                }
            } catch {
                Self.log("index completion metadata failed: \(error)", category: .indexPersistence,
                         level: .error, metadata: ["file": file.name])
                return false
            }
            Self.log("vectorization skipped; no extractable text", category: .indexExtraction,
                     level: .notice, metadata: ["file": file.name])
            return true
        }
        guard await canContinue(checkpoint) else { return false }
        await stageProgress?(.chunking)
        let chunks = Self.contentChunks(
            doclingChunks: docling?.chunks,
            extractedText: extracted.text,
            appendedOCRText: appendedOCRText,
            maxTokens: settings.vectorChunkWords,
            overlap: settings.vectorChunkOverlap
        )
        // Put the note first so explicit user-supplied information has stable retrieval weight.
        var indexChunks = [StructuredDocumentChunk]()
        if !note.isEmpty {
            indexChunks.append(StructuredDocumentChunk(text: "User note: \(note)", kind: .note))
        }
        if !extractedTitle.isEmpty {
            indexChunks.append(StructuredDocumentChunk(text: extractedTitle, kind: .title))
        }
        indexChunks.append(contentsOf: chunks)

        let embedder = activeEmbedder()
        Self.log(
            "embedding generation started",
            category: .indexEmbedding,
            metadata: [
                "file": file.name,
                "segments": "\(indexChunks.count)",
                "textCharacters": "\(extracted.text.count)",
                "provider": embedder.name,
            ]
        )
        let embeddings = await embed(
            chunks: indexChunks,
            using: embedder,
            checkpoint: checkpoint,
            stageProgress: stageProgress
        )
        guard !embeddings.isEmpty else {
            Self.log("embedding generation produced no vectors", category: .indexEmbedding,
                     level: .error, metadata: ["file": file.name])
            return false
        }
        guard Self.contentHashMatches(url, expectedHash: contentHash) else {
            Self.log("index aborted \(file.name): file changed during embedding")
            return false
        }
        guard isCurrentGeneration(fileId: id, generation: generation) else {
            Self.log("index superseded \(file.name) before vector replacement")
            return false
        }
        await stageProgress?(.saving)
        guard await vectorStore.replace(
            fileId: id,
            chunks: embeddings,
            model: embedder.name,
            revision: generation
        ) else {
            Self.log("vector replacement rejected", category: .indexPersistence, level: .error,
                     metadata: ["file": file.name])
            return false
        }
        guard sourceSnapshot?.matches(url) != false else {
            Self.log("index aborted \(file.name): file changed before completion")
            return false
        }
        updated.indexedAt = Date()
        updated.indexSignature = indexSignature
        do {
            guard try upsertIfCurrent(updated, fileId: id, generation: generation) else {
                Self.log("index superseded \(file.name) before completion")
                return false
            }
        } catch {
            Self.log("index completion metadata failed: \(error)", category: .indexPersistence,
                     level: .error, metadata: ["file": file.name])
            return false
        }
        Self.log(
            "file indexing completed",
            metadata: ["file": file.name, "embedded": "\(embeddings.count)",
                       "segments": "\(indexChunks.count)"]
        )
        return true
    }

    private func activeOCRProvider() -> OCRProvider? {
        if let providedOCRProvider { return providedOCRProvider }
        let signature = settings.ocrConfigurationSignature
        ocrProviderLock.lock()
        defer { ocrProviderLock.unlock() }
        if let cachedOCRProvider, cachedOCRProvider.signature == signature {
            return cachedOCRProvider.provider
        }
        let provider = settings.makeOCRProvider()
        cachedOCRProvider = (signature, provider)
        return provider
    }

    /// A folder uses its README, project description, or manifest as primary indexed content and is recorded as one item,
    /// without splitting or moving its contents.
    private func indexDirectory(file: FileRecord,
                                url: URL,
                                inspection: DirectoryInspection,
                                force: Bool,
                                checkpoint: (@Sendable () async -> Bool)?,
                                stageProgress: (@Sendable (IndexingStage) async -> Void)?) async -> Bool {
        guard let id = file.id else { return false }
        let generation = beginIndexGeneration(fileId: id)
        defer { finishIndexGeneration(fileId: id, generation: generation) }

        if !force,
           file.indexedAt != nil,
           file.contentHash == inspection.snapshot.signature,
           file.indexSignature == settings.indexConfigurationSignature {
            Self.log("directory indexing skipped; tree unchanged", level: .debug,
                     metadata: ["entry": file.name])
            return true
        }

        guard await canContinue(checkpoint) else { return false }
        await stageProgress?(.extracting)
        let reference = inspection.referenceFile
        let extracted: ContentExtractor.Extracted
        if let reference {
            let ext = reference.pathExtension.isEmpty ? "txt" : reference.pathExtension
            extracted = ContentExtractor.extract(url: reference, ext: ext)
        } else {
            extracted = ContentExtractor.Extracted(title: file.name, text: "")
        }
        let visibleNames = inspection.topLevelNames
            .filter { !$0.hasPrefix(".") }
            .prefix(80)
            .joined(separator: "、")
        let referenceLabel = reference.map { "Reference file: \($0.lastPathComponent)" } ?? "No project description file found"
        let content = [
            "Folder: \(file.name)",
            referenceLabel,
            visibleNames.isEmpty ? nil : "Top-level content: \(visibleNames)",
            extracted.text.isEmpty ? nil : extracted.text,
        ].compactMap { $0 }.joined(separator: "\n\n")

        var updated = file
        updated.title = extracted.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? extracted.title
            : file.name
        updated.contentText = String(content.prefix(ContentExtractor.maxChars))
        updated.contentHash = inspection.snapshot.signature
        updated.indexedAt = nil
        updated.indexSignature = nil
        do {
            guard try upsertIfCurrent(updated, fileId: id, generation: generation) else { return false }
        } catch {
            Self.log("directory metadata update failed: \(error)", category: .indexPersistence,
                     level: .error, metadata: ["entry": file.name])
            return false
        }

        guard await canContinue(checkpoint) else { return false }
        await stageProgress?(.chunking)
        var chunks: [StructuredDocumentChunk] = []
        let note = (updated.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            chunks.append(StructuredDocumentChunk(text: "User note: \(note)", kind: .note))
        }
        if let title = updated.title, !title.isEmpty {
            chunks.append(StructuredDocumentChunk(text: title, kind: .title))
        }
        chunks.append(contentsOf: Self.chunk(
            text: updated.contentText ?? "",
            maxWords: settings.vectorChunkWords,
            overlap: settings.vectorChunkOverlap
        ).map { StructuredDocumentChunk(text: $0) })

        let embedder = activeEmbedder()
        let embeddings = await embed(
            chunks: chunks,
            using: embedder,
            checkpoint: checkpoint,
            stageProgress: stageProgress
        )
        guard !embeddings.isEmpty else {
            Self.log("directory embedding produced no vectors", category: .indexEmbedding,
                     level: .error, metadata: ["entry": file.name])
            return false
        }
        guard await canContinue(checkpoint) else { return false }
        await stageProgress?(.saving)
        guard
              DirectoryInspector.inspect(url)?.snapshot.signature == inspection.snapshot.signature,
              isCurrentGeneration(fileId: id, generation: generation),
              await vectorStore.replace(
                fileId: id,
                chunks: embeddings,
                model: embedder.name,
                revision: generation
              ),
              DirectoryInspector.inspect(url)?.snapshot.signature == inspection.snapshot.signature else {
            Self.log("directory index aborted \(file.name): directory changed during indexing")
            return false
        }
        updated.indexedAt = Date()
        updated.indexSignature = settings.indexConfigurationSignature
        do {
            guard try upsertIfCurrent(updated, fileId: id, generation: generation) else { return false }
        } catch {
            Self.log("directory completion metadata failed: \(error)", category: .indexPersistence,
                     level: .error, metadata: ["entry": file.name])
            return false
        }
        Self.log(
            "directory indexing completed",
            metadata: ["entry": file.name,
                       "reference": reference?.lastPathComponent ?? "folder inventory"]
        )
        return true
    }

    private func embed(
        chunks: [StructuredDocumentChunk],
        using provider: EmbeddingProvider,
        checkpoint: (@Sendable () async -> Bool)?,
        stageProgress: (@Sendable (IndexingStage) async -> Void)?
    ) async -> [EmbeddingChunk] {
        let batchSize = max(1, provider.maximumBatchSize)
        var result = [EmbeddingChunk]()
        result.reserveCapacity(chunks.count)
        var start = 0
        while start < chunks.count {
            guard await canContinue(checkpoint) else { return [] }
            let end = min(start + batchSize, chunks.count)
            do {
                result.append(contentsOf: try await embedBatchWithFallback(
                    chunks: chunks,
                    range: start..<end,
                    using: provider,
                    checkpoint: checkpoint
                ))
            } catch {
                guard !Self.isCancellation(error) else { return [] }
                Self.log(
                    "embedding failed provider=\(provider.name), " +
                    "segments=\(start + 1)-\(end)/\(chunks.count): \(Self.errorText(error))",
                    category: .indexEmbedding,
                    level: .error
                )
                return []
            }
            start = end
            await stageProgress?(.embedding(completed: start, total: chunks.count))
        }
        return result
    }

    private func embedBatchWithFallback(
        chunks: [StructuredDocumentChunk],
        range: Range<Int>,
        using provider: EmbeddingProvider,
        checkpoint: (@Sendable () async -> Bool)?,
        singleRetriesRemaining: Int = 1,
        runnerEOFSplitDepth: Int = 0
    ) async throws -> [EmbeddingChunk] {
        guard await canContinue(checkpoint) else { throw CancellationError() }
        let batchChunks = Array(chunks[range])
        let inputs = batchChunks.map(\.contextualText)

        do {
            let vectors = try await provider.embedBatch(inputs)
            guard vectors.count == batchChunks.count else {
                throw EmbeddingProviderError.responseCount(
                    expected: batchChunks.count,
                    actual: vectors.count
                )
            }
            var result = [EmbeddingChunk]()
            result.reserveCapacity(batchChunks.count)
            for (offset, pair) in zip(batchChunks, vectors).enumerated() {
                let (chunk, vector) = pair
                guard !vector.isEmpty else {
                    throw EmbeddingBatchError.emptyVector(index: range.lowerBound + offset)
                }
                result.append(EmbeddingChunk(
                    vector: vector,
                    text: chunk.text,
                    contextualText: chunk.contextualText,
                    sectionPath: chunk.sectionPath,
                    pageStart: chunk.pageStart,
                    pageEnd: chunk.pageEnd,
                    kind: chunk.kind
                ))
            }
            return result
        } catch {
            guard !Self.isCancellation(error) else { throw error }
            if range.count == 1,
               Self.isRunnerEOF(error),
               runnerEOFSplitDepth < 6,
               let halves = Self.splitForRunnerEOF(batchChunks[0]) {
                Self.log(
                    "embedding runner EOF provider=\(provider.name), " +
                    "segment=\(range.lowerBound + 1), characters=\(batchChunks[0].contextualText.count); " +
                    "retrying as halves=\(halves[0].contextualText.count)+\(halves[1].contextualText.count)",
                    category: .indexEmbedding,
                    level: .warning
                )
                try await Task.sleep(nanoseconds: 250_000_000)
                let left = try await embedBatchWithFallback(
                    chunks: halves,
                    range: 0..<1,
                    using: provider,
                    checkpoint: checkpoint,
                    singleRetriesRemaining: 1,
                    runnerEOFSplitDepth: runnerEOFSplitDepth + 1
                )
                let right = try await embedBatchWithFallback(
                    chunks: halves,
                    range: 1..<2,
                    using: provider,
                    checkpoint: checkpoint,
                    singleRetriesRemaining: 1,
                    runnerEOFSplitDepth: runnerEOFSplitDepth + 1
                )
                return left + right
            }
            if range.count == 1, singleRetriesRemaining > 0 {
                Self.log(
                    "embedding segment failed provider=\(provider.name), " +
                    "segment=\(range.lowerBound + 1); retrying once: \(Self.errorText(error))",
                    category: .indexEmbedding,
                    level: .warning
                )
                try await Task.sleep(nanoseconds: 200_000_000)
                return try await embedBatchWithFallback(
                    chunks: chunks,
                    range: range,
                    using: provider,
                    checkpoint: checkpoint,
                    singleRetriesRemaining: singleRetriesRemaining - 1,
                    runnerEOFSplitDepth: runnerEOFSplitDepth
                )
            }
            guard range.count > 1 else { throw error }
            let middle = range.lowerBound + range.count / 2
            Self.log(
                "embedding batch failed provider=\(provider.name), " +
                "segments=\(range.lowerBound + 1)-\(range.upperBound); " +
                "retrying as smaller batches: \(Self.errorText(error))",
                category: .indexEmbedding,
                level: .warning
            )
            let left = try await embedBatchWithFallback(
                chunks: chunks,
                range: range.lowerBound..<middle,
                using: provider,
                checkpoint: checkpoint,
                singleRetriesRemaining: 1,
                runnerEOFSplitDepth: runnerEOFSplitDepth
            )
            let right = try await embedBatchWithFallback(
                chunks: chunks,
                range: middle..<range.upperBound,
                using: provider,
                checkpoint: checkpoint,
                singleRetriesRemaining: 1,
                runnerEOFSplitDepth: runnerEOFSplitDepth
            )
            return left + right
        }
    }

    private static func isRunnerEOF(_ error: Error) -> Bool {
        guard case let EmbeddingProviderError.httpStatus(_, body) = error else { return false }
        return body.range(of: "EOF", options: [.caseInsensitive]) != nil
    }

    private static func splitForRunnerEOF(_ chunk: StructuredDocumentChunk) -> [StructuredDocumentChunk]? {
        let textHalves = splitInHalf(chunk.text)
        guard textHalves.count == 2 else { return nil }

        let contextualHalves: [String]
        if chunk.contextualText == chunk.text {
            contextualHalves = textHalves
        } else if chunk.contextualText.hasSuffix(chunk.text) {
            let prefix = String(chunk.contextualText.dropLast(chunk.text.count))
            contextualHalves = textHalves.map { prefix + $0 }
        } else {
            contextualHalves = splitInHalf(chunk.contextualText)
        }
        guard contextualHalves.count == 2 else { return nil }

        return zip(textHalves, contextualHalves).map { text, contextualText in
            StructuredDocumentChunk(
                text: text,
                contextualText: contextualText,
                sectionPath: chunk.sectionPath,
                pageStart: chunk.pageStart,
                pageEnd: chunk.pageEnd,
                kind: chunk.kind
            )
        }
    }

    private static func splitInHalf(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count > 1 else { return [] }
        let middle = characters.count / 2
        return [String(characters[..<middle]), String(characters[middle...])]
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func errorText(_ error: Error) -> String {
        let description = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        return description.replacingOccurrences(of: "\n", with: " ")
    }

    private func activeEmbedder() -> EmbeddingProvider {
        if let providedEmbedder { return providedEmbedder }
        let signature = settings.embeddingConfigurationSignature
        embedderLock.lock()
        defer { embedderLock.unlock() }
        if let cachedEmbedder, cachedEmbedder.signature == signature { return cachedEmbedder.provider }
        let provider = settings.makeEmbeddingProvider()
        cachedEmbedder = (signature, provider)
        return provider
    }

    private static func contentHashMatches(_ url: URL, expectedHash: String?) -> Bool {
        guard let expectedHash else { return true }
        return (try? FileContentHasher.sha256(of: url)) == expectedHash
    }

    private func beginIndexGeneration(fileId: Int64) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        nextGeneration &+= 1
        activeGenerations[fileId] = nextGeneration
        return nextGeneration
    }

    private func finishIndexGeneration(fileId: Int64, generation: UInt64) {
        generationLock.lock()
        defer { generationLock.unlock() }
        if activeGenerations[fileId] == generation {
            activeGenerations.removeValue(forKey: fileId)
        }
    }

    private func isCurrentGeneration(fileId: Int64, generation: UInt64) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        return activeGenerations[fileId] == generation
    }

    private func upsertIfCurrent(_ record: FileRecord,
                                 fileId: Int64,
                                 generation: UInt64) throws -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard activeGenerations[fileId] == generation else { return false }
        _ = try store.upsertFile(record)
        return true
    }

    /// Reindex All Files
    func reindexAll(rebuildVectorSpace: Bool = false) {
        Task {
            _ = await rebuildAll(rebuildVectorSpace: rebuildVectorSpace)
        }
    }

    /// Waits for all indexing tasks and reports progress using the actual file count.
    @discardableResult
    func rebuildAll(
        rebuildVectorSpace: Bool = false,
        forceReprocessing: Bool = false,
        onlyUnindexedFiles: Bool = false,
        includeUnindexedFiles: Bool = false,
        checkpoint: (@Sendable () async -> Bool)? = nil,
        progress: (@MainActor (VectorIndexRebuildProgress) -> Void)? = nil
    ) async -> Bool {
        let allFiles = ((try? store.allFiles()) ?? []).filter { $0.id != nil }
        let files = onlyUnindexedFiles
            ? allFiles.filter { $0.indexedAt == nil }
            : allFiles
        let total = rebuildVectorSpace && !forceReprocessing
            ? allFiles.filter { $0.indexedAt != nil }.count
                + (includeUnindexedFiles ? allFiles.filter { $0.indexedAt == nil }.count : 0)
            : files.count
        await progress?(VectorIndexRebuildProgress(
            phase: .preparing, completed: 0, total: total, currentFileName: nil, failed: 0
        ))
        guard await canContinue(checkpoint) else {
            await progress?(VectorIndexRebuildProgress(
                phase: .stopped, completed: 0, total: total, currentFileName: nil, failed: 0
            ))
            return false
        }
        if rebuildVectorSpace && !forceReprocessing {
            return await rebuildEmbeddingsOnly(
                files: files.filter { $0.indexedAt != nil },
                newFiles: includeUnindexedFiles ? allFiles.filter { $0.indexedAt == nil } : [],
                checkpoint: checkpoint,
                progress: progress
            )
        }
        if rebuildVectorSpace {
            await progress?(VectorIndexRebuildProgress(
                phase: .clearing, completed: 0, total: total, currentFileName: nil, failed: 0
            ))
            guard await vectorStore.removeAll() else {
                await progress?(VectorIndexRebuildProgress(
                    phase: .failed,
                    completed: 0,
                    total: total,
                    currentFileName: nil,
                    failed: total
                ))
                return false
            }
        } else {
            await vectorStore.loadAll()
        }

        let result = await indexFiles(
            files,
            force: rebuildVectorSpace || forceReprocessing,
            checkpoint: checkpoint,
            progress: progress
        )
        if result.stopped {
            await progress?(VectorIndexRebuildProgress(
                phase: .stopped,
                completed: result.completed,
                total: total,
                currentFileName: nil,
                failed: result.failed
            ))
            return false
        }
        await progress?(VectorIndexRebuildProgress(
            phase: .completed,
            completed: result.completed,
            total: total,
            currentFileName: nil,
            failed: result.failed
        ))
        return result.failed == 0
    }

    /// Reuses persisted chunks and calls only the embedding provider, atomically replacing old vectors after every call succeeds.
    private func rebuildEmbeddingsOnly(
        files: [FileRecord],
        newFiles: [FileRecord] = [],
        checkpoint: (@Sendable () async -> Bool)?,
        progress: (@MainActor (VectorIndexRebuildProgress) -> Void)?
    ) async -> Bool {
        let total = files.count + newFiles.count
        let storedChunks: [Int64: [StructuredDocumentChunk]]
        do {
            storedChunks = try store.allStoredDocumentChunks()
        } catch {
            await progress?(VectorIndexRebuildProgress(
                phase: .failed, completed: 0, total: total,
                currentFileName: nil, failed: total
            ))
            return false
        }

        let embedder = activeEmbedder()
        var rebuilt = [Int64: [EmbeddingChunk]]()
        var completed = 0
        var failed = 0
        for file in files {
            guard await canContinue(checkpoint) else {
                await progress?(VectorIndexRebuildProgress(
                    phase: .stopped, completed: completed, total: total,
                    currentFileName: file.name, failed: failed
                ))
                return false
            }
            guard let fileID = file.id else { continue }
            let chunks = storedChunks[fileID] ?? []
            await progress?(VectorIndexRebuildProgress(
                phase: .indexing, completed: completed, total: total,
                currentFileName: file.name, failed: failed,
                stage: chunks.isEmpty ? .saving : .embedding(completed: 0, total: chunks.count)
            ))
            if !chunks.isEmpty {
                let completedBeforeFile = completed
                let failedBeforeFile = failed
                let currentFileName = file.name
                let totalFiles = total
                let embeddings = await embed(
                    chunks: chunks,
                    using: embedder,
                    checkpoint: checkpoint,
                    stageProgress: { stage in
                        await progress?(VectorIndexRebuildProgress(
                            phase: .indexing, completed: completedBeforeFile, total: totalFiles,
                            currentFileName: currentFileName, failed: failedBeforeFile, stage: stage
                        ))
                    }
                )
                if embeddings.isEmpty {
                    failed += 1
                } else {
                    rebuilt[fileID] = embeddings
                }
            }
            completed += 1
            await progress?(VectorIndexRebuildProgress(
                phase: .indexing, completed: completed, total: total,
                currentFileName: file.name, failed: failed
            ))
        }

        guard failed == 0 else {
            await progress?(VectorIndexRebuildProgress(
                phase: .failed, completed: completed, total: total,
                currentFileName: nil, failed: failed
            ))
            return false
        }
        await progress?(VectorIndexRebuildProgress(
            phase: .clearing, completed: completed, total: total,
            currentFileName: nil, failed: 0, stage: .saving
        ))
        guard await vectorStore.replaceAllEmbeddingsPreservingChunks(rebuilt, model: embedder.name) else {
            await progress?(VectorIndexRebuildProgress(
                phase: .failed, completed: completed, total: total,
                currentFileName: nil, failed: total
            ))
            return false
        }
        try? store.migrateIndexedFileSignatures(to: settings.embeddingSpaceSignature)
        if !newFiles.isEmpty {
            let completedEmbeddingFiles = completed
            let newResult = await indexFiles(
                newFiles,
                checkpoint: checkpoint,
                progress: { childProgress in
                    progress?(VectorIndexRebuildProgress(
                        phase: childProgress.phase,
                        completed: completedEmbeddingFiles + childProgress.completed,
                        total: total,
                        currentFileName: childProgress.currentFileName,
                        failed: childProgress.failed,
                        stage: childProgress.stage
                    ))
                }
            )
            if newResult.stopped || newResult.failed > 0 {
                await progress?(VectorIndexRebuildProgress(
                    phase: newResult.stopped ? .stopped : .failed,
                    completed: completedEmbeddingFiles + newResult.completed,
                    total: total,
                    currentFileName: nil,
                    failed: newResult.failed
                ))
                return false
            }
            completed += newResult.completed
        }
        await progress?(VectorIndexRebuildProgress(
            phase: .completed, completed: completed, total: total,
            currentFileName: nil, failed: 0
        ))
        return true
    }

    /// Two files in parallel are enough to hide disk and network waits; OCR and Docling remain single-task within their own execution lanes.
    func indexFiles(
        _ files: [FileRecord],
        force: Bool = false,
        checkpoint: (@Sendable () async -> Bool)? = nil,
        progress: (@MainActor (VectorIndexRebuildProgress) -> Void)? = nil
    ) async -> IndexBatchResult {
        let candidates = files.filter { $0.id != nil }
        let reporter = IndexBatchProgressReporter(total: candidates.count, progress: progress)
        var nextIndex = 0
        var stopped = false

        await withTaskGroup(of: (name: String, succeeded: Bool, stopped: Bool).self) { group in
            func enqueue(_ file: FileRecord) {
                group.addTask { [weak self] in
                    guard let self, let id = file.id,
                          await self.canContinue(checkpoint) else {
                        return (file.name, false, true)
                    }
                    await reporter.report(fileName: file.name, stage: .hashing)
                    let succeeded = await self.indexFile(
                        id: id,
                        force: force,
                        checkpoint: checkpoint,
                        stageProgress: { stage in
                            await reporter.report(fileName: file.name, stage: stage)
                        }
                    )
                    let remainsRunnable = await self.canContinue(checkpoint)
                    let didStop = Task.isCancelled || !remainsRunnable
                    return (file.name, succeeded, didStop)
                }
            }

            while nextIndex < min(2, candidates.count) {
                enqueue(candidates[nextIndex])
                nextIndex += 1
            }

            while let outcome = await group.next() {
                if outcome.stopped {
                    stopped = true
                    group.cancelAll()
                    await cancelAll()
                } else {
                    await reporter.finishFile(named: outcome.name, succeeded: outcome.succeeded)
                    if nextIndex < candidates.count {
                        enqueue(candidates[nextIndex])
                        nextIndex += 1
                    }
                }
            }
        }
        return await reporter.result(stopped: stopped)
    }

    private func canContinue(_ checkpoint: (@Sendable () async -> Bool)?) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await checkpoint?() ?? true
    }

    /// Model-independent local estimate: 1 token is about 0.75 English words or 1.5 CJK characters.
    /// Docling uses its model tokenizer; this estimate serves only the native parser's sliding-window fallback.
    static func chunk(text: String, maxWords: Int, overlap: Int) -> [String] {
        guard maxWords > 0 else { return [] }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let characters = Array(normalized)
        let weights = estimatedTokenWeights(characters)
        let maxTokens = Double(maxWords)
        let overlapTokens = Double(min(max(overlap, 0), maxWords - 1))
        var chunks = [String]()
        var start = 0

        while start < characters.count {
            var end = start
            var tokens = 0.0
            while end < characters.count, tokens + weights[end] <= maxTokens + 0.000_001 {
                tokens += weights[end]
                end += 1
            }
            if end == start { end += 1 }
            if end < characters.count {
                let minimumBoundary = start + max(1, (end - start) * 3 / 4)
                if let whitespace = stride(from: end - 1, through: minimumBoundary, by: -1)
                    .first(where: { characters[$0].isWhitespace }) {
                    end = whitespace
                }
            }
            let value = String(characters[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { chunks.append(value) }
            if end >= characters.count { break }

            var nextStart = end
            var retainedTokens = 0.0
            while nextStart > start,
                  retainedTokens + weights[nextStart - 1] <= overlapTokens + 0.000_001 {
                nextStart -= 1
                retainedTokens += weights[nextStart]
            }
            start = max(start + 1, nextStart)
        }
        return chunks
    }

    /// Docling chunks do not include OCR text appended afterwards, while the native fallback
    /// chunks the already-combined extracted text. Keeping these paths separate prevents OCR
    /// from being embedded twice for raster images and extraction fallbacks.
    static func contentChunks(
        doclingChunks: [StructuredDocumentChunk]?,
        extractedText: String,
        appendedOCRText: String?,
        maxTokens: Int,
        overlap: Int
    ) -> [StructuredDocumentChunk] {
        guard var chunks = doclingChunks else {
            return chunk(text: extractedText, maxWords: maxTokens, overlap: overlap)
                .map { StructuredDocumentChunk(text: $0) }
        }
        if let appendedOCRText, !appendedOCRText.isEmpty {
            chunks.append(contentsOf: chunk(
                text: appendedOCRText,
                maxWords: maxTokens,
                overlap: overlap
            ).map { StructuredDocumentChunk(text: $0) })
        }
        return chunks
    }

    static func shouldAppendOCRText(_ candidate: String, to existing: String) -> Bool {
        let candidate = normalizedTextFingerprint(candidate)
        guard !candidate.isEmpty else { return false }
        let existing = normalizedTextFingerprint(existing)
        return !existing.contains(candidate)
    }

    private static func normalizedTextFingerprint(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func estimatedTokenWeights(_ characters: [Character]) -> [Double] {
        var weights = Array(repeating: 0.0, count: characters.count)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if isChineseCharacter(character) {
                weights[index] = 2.0 / 3.0
                index += 1
            } else if isEnglishWordCharacter(character) {
                let start = index
                while index < characters.count, isEnglishWordCharacter(characters[index]) {
                    index += 1
                }
                let perCharacter = (4.0 / 3.0) / Double(index - start)
                for wordIndex in start..<index { weights[wordIndex] = perCharacter }
            } else {
                // Punctuation and other symbols often form individual tokens; using 1 avoids underestimating dense CSV or source code.
                weights[index] = 1
                index += 1
            }
        }
        return weights
    }

    private static func isEnglishWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            guard scalar.isASCII else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
                || scalar.value == 0x27
                || scalar.value == 0x2D
                || scalar.value == 0x5F
        }
    }

    private static func isChineseCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2A6DF, 0x2A700...0x2EBEF, 0x30000...0x323AF:
                return true
            default:
                return false
            }
        }
    }

    static func log(
        _ message: String,
        category: AppLogCategory = .indexPipeline,
        level: AppLogLevel = .info,
        metadata: [String: String] = [:]
    ) {
        AppLogService.shared.write(message, category: category, level: level, metadata: metadata)
    }
}
