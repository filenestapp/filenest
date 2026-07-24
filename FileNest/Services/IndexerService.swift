import Foundation
import GRDB
import NaturalLanguage

enum IndexingStage: Equatable, Sendable {
    case hashing
    case transcribing
    case ocr
    case docling
    case extracting
    case chunking
    case embedding(completed: Int, total: Int)
    case saving

    var statusText: String {
        switch self {
        case .hashing: return "Checking file"
        case .transcribing: return "Transcribing audio or video"
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

enum IndexWriteTarget: String, Sendable {
    case active
    case shadow
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
    private var completed: Int
    private var failed: Int

    init(
        total: Int,
        initialCompleted: Int = 0,
        initialFailed: Int = 0,
        progress: (@MainActor (VectorIndexRebuildProgress) -> Void)?
    ) {
        self.total = total
        completed = initialCompleted
        failed = initialFailed
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

struct MediaTranscriptionResult: Sendable {
    let extracted: ContentExtractor.Extracted
    let chunks: [StructuredDocumentChunk]
}

private struct WhisperTranscriptionPayload: Decodable, Sendable {
    struct Segment: Decodable, Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    let text: String
    let language: String?
    let segments: [Segment]
}

private actor MediaTranscriptionProcessor {
    func process(url: URL, model: String, maxTokens: Int) async -> MediaTranscriptionResult? {
        let model = WhisperModelCatalog.normalizedModel(model)
        guard let ffmpeg = FFmpegServiceManager.resolveExecutable() else {
            Self.log("Media transcription skipped because FFmpeg is unavailable", url: url, model: model)
            return nil
        }
        guard WhisperServiceManager.isRuntimeAndModelAvailable(model) else {
            Self.log("Media transcription skipped because the selected Whisper model is unavailable",
                     url: url, model: model)
            return nil
        }

        do {
            let payload = try await Task.detached(priority: .userInitiated) {
                try Self.transcribe(url: url, model: model, ffmpeg: ffmpeg)
            }.value
            let chunks = Self.makeChunks(
                from: payload.segments,
                fileName: url.lastPathComponent,
                language: payload.language,
                maxTokens: maxTokens
            )
            let transcript = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty, !chunks.isEmpty else {
                Self.log("Whisper completed without recognized speech", url: url, model: model)
                return nil
            }
            AppLogService.shared.write(
                "Media transcription completed",
                category: .indexExtraction,
                metadata: [
                    "file": url.lastPathComponent,
                    "model": model,
                    "language": payload.language ?? "unknown",
                    "segments": "\(payload.segments.count)",
                    "chunks": "\(chunks.count)",
                ]
            )
            return MediaTranscriptionResult(
                extracted: ContentExtractor.Extracted(
                    title: url.deletingPathExtension().lastPathComponent,
                    text: String(transcript.prefix(ContentExtractor.maxChars))
                ),
                chunks: chunks
            )
        } catch {
            AppLogService.shared.write(
                "Media transcription failed: \(error.localizedDescription)",
                category: .indexExtraction,
                level: .error,
                metadata: ["file": url.lastPathComponent, "model": model]
            )
            return nil
        }
    }

    nonisolated private static func transcribe(
        url: URL,
        model: String,
        ffmpeg: URL
    ) throws -> WhisperTranscriptionPayload {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("filenest-whisper-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let script = """
        import json, sys, whisper
        model = whisper.load_model(sys.argv[1], download_root=sys.argv[2])
        result = model.transcribe(sys.argv[3], verbose=False, fp16=False, task="transcribe")
        payload = {
            "text": result.get("text", ""),
            "language": result.get("language"),
            "segments": [
                {"start": s.get("start", 0), "end": s.get("end", 0), "text": s.get("text", "")}
                for s in result.get("segments", [])
            ],
        }
        with open(sys.argv[4], "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False)
        """
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(ffmpeg.deletingLastPathComponent().path):\(environment["PATH"] ?? "")"
        let process = Process()
        process.executableURL = WhisperServiceManager.pythonExecutable
        process.arguments = [
            "-c", script, model, WhisperServiceManager.modelRoot.path, url.path, output.path,
        ]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MediaTranscriptionError.commandFailed }
        return try JSONDecoder().decode(WhisperTranscriptionPayload.self, from: Data(contentsOf: output))
    }

    nonisolated private static func makeChunks(
        from segments: [WhisperTranscriptionPayload.Segment],
        fileName: String,
        language: String?,
        maxTokens: Int
    ) -> [StructuredDocumentChunk] {
        let normalized = segments.compactMap { segment -> WhisperTranscriptionPayload.Segment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return .init(start: max(0, segment.start), end: max(segment.start, segment.end), text: text)
        }
        guard !normalized.isEmpty else { return [] }

        var groups = [[WhisperTranscriptionPayload.Segment]]()
        var current = [WhisperTranscriptionPayload.Segment]()
        for segment in normalized {
            let candidate = (current + [segment]).map(\.text).joined(separator: " ")
            if !current.isEmpty, TokenCounter.estimate(candidate).count > maxTokens {
                groups.append(current)
                current = [segment]
            } else {
                current.append(segment)
            }
        }
        if !current.isEmpty { groups.append(current) }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let range = "\(timestamp(first.start))–\(timestamp(last.end))"
            let body = group.map(\.text).joined(separator: " ")
            let context = [
                "Transcript: \(fileName)",
                language.map { "Language: \($0)" },
                "Time range: \(range)",
                body,
            ].compactMap { $0 }.joined(separator: "\n")
            return StructuredDocumentChunk(
                text: "[\(range)]\n\(body)",
                contextualText: context,
                sectionPath: ["Transcript", range],
                kind: .transcript
            )
        }
    }

    nonisolated private static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }

    nonisolated private static func log(_ message: String, url: URL, model: String) {
        AppLogService.shared.write(
            message,
            category: .indexExtraction,
            level: .notice,
            metadata: ["file": url.lastPathComponent, "model": model]
        )
    }
}

private enum MediaTranscriptionError: LocalizedError {
    case commandFailed

    var errorDescription: String? { "OpenAI Whisper transcription failed" }
}

/// Indexing service: extracts one file, splits it into chunks, creates embeddings, and stores the result.
/// Owns the EmbeddingProvider and VectorStore instances.
final class IndexerService {
    private let store: SQLiteStore
    private let settings: AppSettings
    private let providedEmbedder: EmbeddingProvider?
    private let providedOCRProvider: OCRProvider?
    private let doclingProcessor = DoclingDocumentProcessor()
    private let mediaTranscriptionProcessor = MediaTranscriptionProcessor()
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

    /// Chooses a small file-level concurrency cap so foreground interaction and
    /// local model inference remain responsive during large backfills.
    static func recommendedFileConcurrency(
        physicalMemory: UInt64,
        usesLocalEmbedding: Bool,
        usesDocling: Bool,
        usesLocalOCR: Bool
    ) -> Int {
        let gibibyte = UInt64(1_024 * 1_024 * 1_024)
        guard physicalMemory >= 16 * gibibyte else { return 1 }

        // Docling and local OCR have their own serialized execution lanes. Keep
        // two file pipelines in flight so one can make progress while the other
        // waits on disk or a service, without multiplying peak memory pressure.
        if usesDocling || usesLocalOCR { return 2 }

        // A third pipeline is useful only on high-memory systems when the batch
        // is lightweight enough not to compete with a local embedding model.
        if physicalMemory >= 32 * gibibyte, !usesLocalEmbedding { return 3 }
        return 2
    }

    private var fileConcurrency: Int {
        Self.recommendedFileConcurrency(
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            usesLocalEmbedding: settings.embeddingSource == AppSettings.EmbeddingSource.ollama.rawValue,
            usesDocling: settings.doclingEnabled,
            usesLocalOCR: settings.ocrSource == AppSettings.OCRSource.local.rawValue
        )
    }

    /// Builds or rebuilds the index for one file.
    /// - Parameter overridePath: Optional physical path used when the file has not yet moved to its database-recorded path.
    @discardableResult
    func indexFile(id: Int64, overridePath: URL? = nil, force: Bool = false,
                   forceVectorization: Bool = false,
                   writeTarget: IndexWriteTarget = .active,
                   checkpoint: (@Sendable () async -> Bool)? = nil,
                   stageProgress: (@Sendable (IndexingStage) async -> Void)? = nil) async -> Bool {
        await withTaskCancellationHandler {
            let requestKey = [
                force ? "force" : "incremental",
                forceVectorization ? "vector" : "configured",
                writeTarget.rawValue,
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
                    writeTarget: writeTarget,
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

    /// Releases persistent provider subprocesses after indexing tasks have been
    /// cancelled. Clearing the cache prevents a shutting-down provider from being
    /// reused if another request races with application termination.
    func shutdownManagedProviders() async {
        let provider = detachManagedOCRProvider()
        if let provider = provider as? ManagedOCRProviderLifecycle {
            await provider.shutdown()
        }
    }

    private func detachManagedOCRProvider() -> OCRProvider? {
        ocrProviderLock.lock()
        defer { ocrProviderLock.unlock() }
        let provider = providedOCRProvider ?? cachedOCRProvider?.provider
        cachedOCRProvider = nil
        return provider
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
        writeTarget: IndexWriteTarget,
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
                writeTarget: writeTarget,
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
        // A changed former duplicate becomes an independent file again before its
        // content and vectors are rebuilt.
        try? store.clearFileDuplicateLink(id: id)

        let shouldProcessContent = forceVectorization || settings.shouldVectorize(extension: file.ext)
        let shouldTranscribeMedia = shouldProcessContent
            && settings.shouldTranscribeMedia(extension: file.ext)
        let transcription: MediaTranscriptionResult?
        if shouldTranscribeMedia {
            guard await canContinue(checkpoint) else { return false }
            await stageProgress?(.transcribing)
            transcription = await mediaTranscriptionProcessor.process(
                url: url,
                model: settings.whisperModel,
                maxTokens: settings.chunkTokenLimit
            )
        } else {
            transcription = nil
        }
        if shouldTranscribeMedia, transcription == nil {
            Self.log(
                "media indexing stopped because transcription did not produce searchable text",
                category: .indexExtraction,
                level: .error,
                metadata: ["file": file.name, "model": settings.whisperModel]
            )
            return false
        }
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
            && !shouldTranscribeMedia
            ? await doclingProcessor.process(
                url: url,
                ext: file.ext,
                maxTokens: settings.chunkTokenLimit,
                pdfAnalysis: pdfAnalysis,
                disableBuiltInOCR: settings.ocrSource != AppSettings.OCRSource.disabled.rawValue
            )
            : nil
        // Docling handles structure parsing; pages that need OCR go to the configured primary OCR provider.
        let shouldRunConfiguredOCR = !shouldTranscribeMedia && (
            docling == nil || OCRDocumentProcessor.requiresRecognition(
                ext: file.ext,
                pdfAnalysis: pdfAnalysis
            )
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
        var extracted = transcription?.extracted
            ?? docling?.extracted
            ?? ContentExtractor.extract(url: url, ext: file.ext)
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
        updated.duplicateOfFileID = nil
        updated.duplicateDetectedAt = nil
        updated.indexedAt = nil
        updated.indexSignature = nil
        if writeTarget == .active {
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
        }

        let note = (updated.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let extractedTitle = (extracted.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // When automatic vectorization is disabled or the extension is out of scope, still save the title and metadata and mark scanning complete,
        // but remove old vectors so settings changes do not keep out-of-scope content in semantic results.
        if !forceVectorization && !settings.shouldVectorize(extension: file.ext) {
            guard Self.contentHashMatches(url, expectedHash: contentHash),
                  isCurrentGeneration(fileId: id, generation: generation),
                  await removeIndex(fileId: id, revision: generation, writeTarget: writeTarget) else {
                return false
            }
            updated.indexedAt = Date()
            updated.indexSignature = indexSignature
            guard await persistCompletedMetadata(
                updated,
                fileId: id,
                generation: generation,
                writeTarget: writeTarget
            ) else {
                Self.log("metadata-only completion failed", category: .indexPersistence,
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
            guard await removeIndex(fileId: id, revision: generation, writeTarget: writeTarget) else {
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
            guard await persistCompletedMetadata(
                updated,
                fileId: id,
                generation: generation,
                writeTarget: writeTarget
            ) else {
                Self.log("index completion metadata failed", category: .indexPersistence,
                         level: .error, metadata: ["file": file.name])
                return false
            }
            Self.log("vectorization skipped; no extractable text", category: .indexExtraction,
                     level: .notice, metadata: ["file": file.name])
            return true
        }
        guard await canContinue(checkpoint) else { return false }
        await stageProgress?(.chunking)
        var chunks = transcription?.chunks ?? Self.contentChunks(
            doclingChunks: docling?.chunks,
            extractedText: extracted.text,
            appendedOCRText: appendedOCRText,
            maxTokens: settings.chunkTokenLimit
        )
        if (docling != nil || transcription != nil), !extractedTitle.isEmpty, !chunks.isEmpty {
            chunks = chunks.map {
                Self.addDocumentTitleContext(extractedTitle, to: $0, maxTokens: settings.chunkTokenLimit)
            }
        }
        // Put the note first so explicit user-supplied information has stable retrieval weight.
        var indexChunks = [StructuredDocumentChunk]()
        if !note.isEmpty {
            indexChunks.append(StructuredDocumentChunk(text: "User note: \(note)", kind: .note))
        }
        // A standalone title is useful only when no body could be extracted. For normal
        // documents the title is embedded as context on body chunks instead of becoming a
        // tiny, weak semantic result by itself.
        if (docling == nil || chunks.isEmpty), !extractedTitle.isEmpty {
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
        guard await replaceIndex(
            fileId: id,
            chunks: embeddings,
            model: embedder.name,
            revision: generation,
            writeTarget: writeTarget
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
        guard await persistCompletedMetadata(
            updated,
            fileId: id,
            generation: generation,
            writeTarget: writeTarget
        ) else {
            Self.log("index completion metadata failed", category: .indexPersistence,
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
                                writeTarget: IndexWriteTarget,
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
        if writeTarget == .active {
            do {
                guard try upsertIfCurrent(updated, fileId: id, generation: generation) else { return false }
            } catch {
                Self.log("directory metadata update failed: \(error)", category: .indexPersistence,
                         level: .error, metadata: ["entry": file.name])
                return false
            }
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
            maxWords: settings.chunkTokenLimit,
            overlap: 0
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
              await replaceIndex(
                fileId: id,
                chunks: embeddings,
                model: embedder.name,
                revision: generation,
                writeTarget: writeTarget
              ),
              DirectoryInspector.inspect(url)?.snapshot.signature == inspection.snapshot.signature else {
            Self.log("directory index aborted \(file.name): directory changed during indexing")
            return false
        }
        updated.indexedAt = Date()
        updated.indexSignature = settings.indexConfigurationSignature
        guard await persistCompletedMetadata(
            updated,
            fileId: id,
            generation: generation,
            writeTarget: writeTarget
        ) else {
            Self.log("directory completion metadata failed", category: .indexPersistence,
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

    private func replaceIndex(
        fileId: Int64,
        chunks: [EmbeddingChunk],
        model: String,
        revision: UInt64,
        writeTarget: IndexWriteTarget
    ) async -> Bool {
        switch writeTarget {
        case .active:
            return await vectorStore.replace(
                fileId: fileId,
                chunks: chunks,
                model: model,
                revision: revision
            )
        case .shadow:
            return await vectorStore.replaceShadow(
                fileId: fileId,
                chunks: chunks,
                model: model
            )
        }
    }

    private func removeIndex(
        fileId: Int64,
        revision: UInt64,
        writeTarget: IndexWriteTarget
    ) async -> Bool {
        switch writeTarget {
        case .active:
            return await vectorStore.remove(fileId: fileId, revision: revision)
        case .shadow:
            // A shadow generation starts empty, so a file without vectors needs only metadata.
            return true
        }
    }

    private func persistCompletedMetadata(
        _ file: FileRecord,
        fileId: Int64,
        generation: UInt64,
        writeTarget: IndexWriteTarget
    ) async -> Bool {
        guard isCurrentGeneration(fileId: fileId, generation: generation) else { return false }
        switch writeTarget {
        case .active:
            do {
                return try upsertIfCurrent(file, fileId: fileId, generation: generation)
            } catch {
                Self.log(
                    "index metadata persistence failed: \(error)",
                    category: .indexPersistence,
                    level: .error,
                    metadata: ["fileID": "\(fileId)"]
                )
                return false
            }
        case .shadow:
            return await vectorStore.stageShadowMetadata(file)
        }
    }

    private func embed(
        chunks: [StructuredDocumentChunk],
        using provider: EmbeddingProvider,
        checkpoint: (@Sendable () async -> Bool)?,
        stageProgress: (@Sendable (IndexingStage) async -> Void)?
    ) async -> [EmbeddingChunk] {
        let chunks = Self.retrievalChildren(
            from: chunks,
            targetTokens: settings.vectorRetrievalChunkTokens,
            overlapTokens: settings.vectorChunkOverlap
        )
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
                    kind: chunk.kind,
                    parentIndex: chunk.parentIndex,
                    parentText: chunk.parentText,
                    entityTerms: chunk.entityTerms,
                    tokenCount: chunk.tokenCount,
                    tokenizerProfile: chunk.tokenizerProfile,
                    tokenizerVersion: chunk.tokenizerVersion,
                    tokenCountAccuracy: chunk.tokenCountAccuracy
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
                kind: chunk.kind,
                parentIndex: chunk.parentIndex,
                parentText: chunk.parentText,
                entityTerms: chunk.entityTerms
            )
        }
    }

    /// Builds small retrieval units while retaining the larger Docling section as the unit
    /// supplied to the answer model. This improves recall without fragmenting answer context.
    static func retrievalChildren(
        from parents: [StructuredDocumentChunk],
        targetTokens: Int = 280,
        overlapTokens: Int = 48
    ) -> [StructuredDocumentChunk] {
        var children = [StructuredDocumentChunk]()
        for (parentIndex, parent) in parents.enumerated() {
            let resolvedParentIndex = parent.parentIndex ?? parentIndex
            let parentText = parent.parentText ?? parent.text
            let pieces: [String]
            if estimatedTokenCount(parent.text) > Double(max(360, targetTokens)) {
                pieces = parent.kind == .table
                    ? tableRetrievalPieces(parent.text, targetTokens: targetTokens)
                    : chunk(
                        text: parent.text,
                        maxWords: max(120, targetTokens),
                        overlap: min(max(0, overlapTokens), max(119, targetTokens - 1))
                    )
            } else {
                pieces = [parent.text]
            }

            let prefix: String
            if parent.contextualText.hasSuffix(parent.text) {
                prefix = String(parent.contextualText.dropLast(parent.text.count))
            } else if !parent.sectionPath.isEmpty {
                prefix = parent.sectionPath.joined(separator: " > ") + "\n"
            } else {
                prefix = ""
            }
            for piece in pieces where !piece.isEmpty {
                children.append(StructuredDocumentChunk(
                    text: piece,
                    contextualText: prefix + piece,
                    sectionPath: parent.sectionPath,
                    pageStart: parent.pageStart,
                    pageEnd: parent.pageEnd,
                    kind: parent.kind,
                    parentIndex: resolvedParentIndex,
                    parentText: parentText,
                    entityTerms: extractedEntityTerms(from: piece)
                ))
            }
        }
        return children
    }

    /// Splits large tables by rows and repeats the header so each child remains meaningful.
    private static func tableRetrievalPieces(_ text: String, targetTokens: Int) -> [String] {
        let rows = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard rows.count > 2 else {
            return chunk(text: text, maxWords: targetTokens, overlap: 0)
        }
        let header = rows[0]
        var result = [String]()
        var current = [header]
        var currentTokens = estimatedTokenCount(header)
        for row in rows.dropFirst() {
            let rowTokens = estimatedTokenCount(row)
            if current.count > 1, currentTokens + rowTokens > Double(targetTokens) {
                result.append(current.joined(separator: "\n"))
                current = [header]
                currentTokens = estimatedTokenCount(header)
            }
            current.append(row)
            currentTokens += rowTokens
        }
        if current.count > 1 { result.append(current.joined(separator: "\n")) }
        return result.isEmpty ? [text] : result
    }

    /// Extract high-precision identifiers before semantic retrieval. These terms are useful
    /// for invoice numbers, registration IDs, email addresses, dates, and monetary values.
    static func extractedEntityTerms(from text: String) -> [String] {
        let patterns = [
            #"\b[A-Z0-9][A-Z0-9._/-]{2,}\d[A-Z0-9._/-]*\b"#,
            #"\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b"#,
            #"\b\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\b"#,
            #"(?:[$€£¥]|SGD|USD|EUR|CNY|RMB)\s*\d[\d,.]*"#,
        ]
        var matches = Set<String>()
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            for result in expression.matches(in: text, range: range) {
                guard let matchRange = Range(result.range, in: text) else { continue }
                let value = text[matchRange]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if value.count >= 3 { matches.insert(value) }
            }
        }
        return matches.sorted()
    }

    private static func splitInHalf(_ text: String) -> [String] {
        let paragraphs = semanticParagraphs(in: text)
        if paragraphs.count > 1 {
            return balancedSemanticHalves(paragraphs, separator: "\n\n")
        }
        let sentences = semanticSentences(in: text)
        if sentences.count > 1 {
            return balancedSemanticHalves(sentences, separator: " ")
        }

        // Emergency fallback for a single oversized sentence: preserve every complete word.
        // Boundary-free CJK or generated data has no smaller linguistic unit to preserve, so
        // the final fallback uses an extended-grapheme boundary rather than a raw byte offset.
        let characters = Array(text)
        guard characters.count > 1 else { return [] }
        let middle = characters.count / 2
        let candidateOffsets = (0..<characters.count).filter { characters[$0].isWhitespace }
        let split = candidateOffsets.min { abs($0 - middle) < abs($1 - middle) } ?? middle
        guard split > 0, split < characters.count else { return [] }
        let left = String(characters[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(characters[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return left.isEmpty || right.isEmpty ? [] : [left, right]
    }

    private static func balancedSemanticHalves(_ units: [String], separator: String) -> [String] {
        guard units.count > 1 else { return [] }
        let target = units.reduce(0) { $0 + $1.count } / 2
        var bestIndex = 1
        var accumulated = units[0].count
        var bestDistance = abs(accumulated - target)
        for index in 1..<units.count {
            accumulated += separator.count + units[index].count
            let distance = abs(accumulated - target)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index + 1
            }
        }
        bestIndex = min(max(1, bestIndex), units.count - 1)
        return [
            units[..<bestIndex].joined(separator: separator),
            units[bestIndex...].joined(separator: separator),
        ]
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

    @discardableResult
    func rebuildRetrievalIndex(
        progress: (@MainActor (VectorIndexRebuildProgress) -> Void)? = nil
    ) async -> Bool {
        let total = vectorStore.count
        await progress?(VectorIndexRebuildProgress(
            phase: .preparing, completed: 0, total: total,
            currentFileName: nil, failed: 0, stage: .saving
        ))
        let succeeded = await vectorStore.rebuildRetrievalIndex()
        await progress?(VectorIndexRebuildProgress(
            phase: succeeded ? .completed : .failed,
            completed: succeeded ? total : 0,
            total: total,
            currentFileName: nil,
            failed: succeeded ? 0 : total,
            stage: .saving
        ))
        return succeeded
    }

    /// Waits for all indexing tasks and reports progress using the actual file count.
    @discardableResult
    func rebuildAll(
        rebuildVectorSpace: Bool = false,
        forceReprocessing: Bool = false,
        onlyUnindexedFiles: Bool = false,
        includeUnindexedFiles: Bool = false,
        onlyMediaFiles: Bool = false,
        fileCategories: Set<FileCategory> = [],
        fileIDs: Set<Int64>? = nil,
        totalOverride: Int? = nil,
        initialCompleted: Int = 0,
        resumeShadow: Bool = false,
        checkpoint: (@Sendable () async -> Bool)? = nil,
        fileCompletion: (@Sendable (Int64, Bool) async -> Void)? = nil,
        progress: (@MainActor (VectorIndexRebuildProgress) -> Void)? = nil
    ) async -> Bool {
        // Duplicate copies intentionally reuse their retained original's index.
        // They must never be reintroduced by a bulk reindex merely because they
        // have no independent indexedAt timestamp.
        let allFiles = ((try? store.allFiles()) ?? []).filter {
            $0.id != nil && $0.duplicateOfFileID == nil
        }
        let scopedFiles = allFiles.filter { file in
            (!onlyMediaFiles || AppSettings.mediaTranscriptionExtensions.contains(file.ext.lowercased()))
                && (fileCategories.isEmpty || fileCategories.contains(file.categoryEnum))
                && (fileIDs == nil || file.id.map { fileIDs?.contains($0) == true } == true)
        }
        let files = onlyUnindexedFiles
            ? scopedFiles.filter { $0.indexedAt == nil }
            : scopedFiles
        let calculatedTotal = rebuildVectorSpace && !forceReprocessing
            ? scopedFiles.filter { $0.indexedAt != nil }.count
                + (includeUnindexedFiles ? scopedFiles.filter { $0.indexedAt == nil }.count : 0)
            : files.count
        let total = totalOverride ?? (initialCompleted + calculatedTotal)
        await progress?(VectorIndexRebuildProgress(
            phase: .preparing, completed: initialCompleted, total: total, currentFileName: nil, failed: 0
        ))
        guard await canContinue(checkpoint) else {
            await progress?(VectorIndexRebuildProgress(
                phase: .stopped,
                completed: initialCompleted,
                total: total,
                currentFileName: nil,
                failed: 0
            ))
            return false
        }
        if rebuildVectorSpace && !forceReprocessing {
            return await rebuildEmbeddingsOnly(
                files: files.filter { $0.indexedAt != nil },
                newFiles: includeUnindexedFiles ? scopedFiles.filter { $0.indexedAt == nil } : [],
                totalOverride: total,
                initialCompleted: initialCompleted,
                resumeShadow: resumeShadow,
                checkpoint: checkpoint,
                fileCompletion: fileCompletion,
                progress: progress
            )
        }
        if rebuildVectorSpace && forceReprocessing {
            return await rebuildSourcesUsingShadowIndex(
                files: files,
                totalOverride: total,
                initialCompleted: initialCompleted,
                resumeShadow: resumeShadow,
                checkpoint: checkpoint,
                fileCompletion: fileCompletion,
                progress: progress
            )
        }
        await vectorStore.loadAll()

        let result = await indexFiles(
            files,
            force: rebuildVectorSpace || forceReprocessing,
            totalOverride: total,
            initialCompleted: initialCompleted,
            checkpoint: checkpoint,
            fileCompletion: fileCompletion,
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

    /// Rebuilds parsing, chunks, and vectors into an isolated generation.
    /// The active RAG index remains queryable until the final atomic commit.
    private func rebuildSourcesUsingShadowIndex(
        files: [FileRecord],
        totalOverride: Int,
        initialCompleted: Int,
        resumeShadow: Bool,
        checkpoint: (@Sendable () async -> Bool)?,
        fileCompletion: (@Sendable (Int64, Bool) async -> Void)?,
        progress: (@MainActor (VectorIndexRebuildProgress) -> Void)?
    ) async -> Bool {
        guard await vectorStore.beginShadowRebuild(resumeIfAvailable: resumeShadow) else {
            await progress?(VectorIndexRebuildProgress(
                phase: .failed, completed: initialCompleted, total: totalOverride,
                currentFileName: nil, failed: files.count, stage: .saving
            ))
            return false
        }
        let stagedFileIDs = await vectorStore.shadowStagedFileIDs()
        let pendingFiles = files.filter { file in
            guard let fileID = file.id else { return false }
            return !stagedFileIDs.contains(fileID)
        }
        let completedBeforeRun = max(initialCompleted, stagedFileIDs.count)
        let expectedFileCount = stagedFileIDs.count + pendingFiles.count

        let result = await indexFiles(
            pendingFiles,
            force: true,
            writeTarget: .shadow,
            totalOverride: totalOverride,
            initialCompleted: completedBeforeRun,
            checkpoint: checkpoint,
            fileCompletion: fileCompletion,
            progress: progress
        )
        guard !result.stopped, result.failed == 0, await canContinue(checkpoint) else {
            await progress?(VectorIndexRebuildProgress(
                phase: result.stopped || Task.isCancelled ? .stopped : .failed,
                completed: result.completed, total: totalOverride,
                currentFileName: nil,
                failed: result.failed
            ))
            return false
        }

        await progress?(VectorIndexRebuildProgress(
            phase: .clearing,
            completed: result.completed,
            total: totalOverride,
            currentFileName: nil,
            failed: 0,
            stage: .saving
        ))
        let committed = await vectorStore.commitShadowRebuild(expectedFileCount: expectedFileCount)
        guard committed else {
            await progress?(VectorIndexRebuildProgress(
                phase: .failed,
                completed: result.completed,
                total: totalOverride,
                currentFileName: nil,
                failed: pendingFiles.count,
                stage: .saving
            ))
            return false
        }
        await progress?(VectorIndexRebuildProgress(
            phase: .completed,
            completed: totalOverride,
            total: totalOverride,
            currentFileName: nil,
            failed: 0,
            stage: .saving
        ))
        return true
    }

    /// Reuses persisted chunks and calls only the embedding provider, atomically replacing old vectors after every call succeeds.
    private func rebuildEmbeddingsOnly(
        files: [FileRecord],
        newFiles: [FileRecord] = [],
        totalOverride: Int,
        initialCompleted: Int,
        resumeShadow: Bool,
        checkpoint: (@Sendable () async -> Bool)?,
        fileCompletion: (@Sendable (Int64, Bool) async -> Void)?,
        progress: (@MainActor (VectorIndexRebuildProgress) -> Void)?
    ) async -> Bool {
        let storedChunks: [Int64: [StructuredDocumentChunk]]
        do {
            storedChunks = try store.allStoredDocumentChunks()
        } catch {
            await progress?(VectorIndexRebuildProgress(
                phase: .failed, completed: initialCompleted, total: totalOverride,
                currentFileName: nil, failed: files.count + newFiles.count
            ))
            return false
        }

        let embedder = activeEmbedder()
        var completed = initialCompleted
        var failed = 0
        var stagedFileIDs = resumeShadow ? await vectorStore.shadowStagedFileIDs() : []
        if !files.isEmpty || !stagedFileIDs.isEmpty {
            guard await vectorStore.beginShadowRebuild(resumeIfAvailable: resumeShadow) else {
                await progress?(VectorIndexRebuildProgress(
                    phase: .failed, completed: completed, total: totalOverride,
                    currentFileName: nil, failed: files.count
                ))
                return false
            }
            stagedFileIDs = await vectorStore.shadowStagedFileIDs()
        }
        completed = max(completed, stagedFileIDs.count)
        let pendingFiles = files.filter { file in
            guard let fileID = file.id else { return false }
            return !stagedFileIDs.contains(fileID)
        }
        let expectedStagedFileCount = stagedFileIDs.count + pendingFiles.count

        for file in pendingFiles {
            guard await canContinue(checkpoint) else {
                await progress?(VectorIndexRebuildProgress(
                    phase: .stopped, completed: completed, total: totalOverride,
                    currentFileName: file.name, failed: failed
                ))
                return false
            }
            guard let fileID = file.id else { continue }
            let chunks = storedChunks[fileID] ?? []
            await progress?(VectorIndexRebuildProgress(
                phase: .indexing, completed: completed, total: totalOverride,
                currentFileName: file.name, failed: failed,
                stage: chunks.isEmpty ? .saving : .embedding(completed: 0, total: chunks.count)
            ))
            let embeddings: [EmbeddingChunk]
            if chunks.isEmpty {
                embeddings = []
            } else {
                let completedBeforeFile = completed
                let failedBeforeFile = failed
                let fileName = file.name
                embeddings = await embed(
                    chunks: chunks,
                    using: embedder,
                    checkpoint: checkpoint,
                    stageProgress: { stage in
                        await progress?(VectorIndexRebuildProgress(
                            phase: .indexing, completed: completedBeforeFile, total: totalOverride,
                            currentFileName: fileName, failed: failedBeforeFile, stage: stage
                        ))
                    }
                )
            }
            let generatedEmbeddings = chunks.isEmpty || !embeddings.isEmpty
            let staged = generatedEmbeddings
                ? await vectorStore.stageShadowEmbeddings(
                    fileID: fileID,
                    chunks: embeddings,
                    model: embedder.name
                )
                : false
            let succeeded = generatedEmbeddings && staged
            await fileCompletion?(fileID, succeeded)
            if !succeeded { failed += 1 }
            completed += 1
            await progress?(VectorIndexRebuildProgress(
                phase: .indexing, completed: completed, total: totalOverride,
                currentFileName: file.name, failed: failed
            ))
        }

        guard failed == 0 else {
            await progress?(VectorIndexRebuildProgress(
                phase: .failed, completed: completed, total: totalOverride,
                currentFileName: nil, failed: failed
            ))
            return false
        }
        if expectedStagedFileCount > 0 {
            await progress?(VectorIndexRebuildProgress(
                phase: .clearing, completed: completed, total: totalOverride,
                currentFileName: nil, failed: 0, stage: .saving
            ))
            guard await vectorStore.commitShadowEmbeddingRebuild(
                expectedFileCount: expectedStagedFileCount
            ) else {
                await progress?(VectorIndexRebuildProgress(
                    phase: .failed, completed: completed, total: totalOverride,
                    currentFileName: nil, failed: pendingFiles.count
                ))
                return false
            }
            try? store.migrateIndexedFileSignatures(to: settings.embeddingSpaceSignature)
        }
        if !newFiles.isEmpty {
            let newResult = await indexFiles(
                newFiles,
                totalOverride: totalOverride,
                initialCompleted: completed,
                checkpoint: checkpoint,
                fileCompletion: fileCompletion,
                progress: { childProgress in
                    progress?(VectorIndexRebuildProgress(
                        phase: childProgress.phase,
                        completed: childProgress.completed,
                        total: totalOverride,
                        currentFileName: childProgress.currentFileName,
                        failed: childProgress.failed,
                        stage: childProgress.stage
                    ))
                }
            )
            if newResult.stopped || newResult.failed > 0 {
                await progress?(VectorIndexRebuildProgress(
                    phase: newResult.stopped ? .stopped : .failed,
                    completed: newResult.completed,
                    total: totalOverride,
                    currentFileName: nil,
                    failed: newResult.failed
                ))
                return false
            }
            completed = newResult.completed
        }
        await progress?(VectorIndexRebuildProgress(
            phase: .completed, completed: totalOverride, total: totalOverride,
            currentFileName: nil, failed: 0
        ))
        return true
    }

    /// The cap adapts to available memory and enabled local processing services.
    func indexFiles(
        _ files: [FileRecord],
        force: Bool = false,
        writeTarget: IndexWriteTarget = .active,
        totalOverride: Int? = nil,
        initialCompleted: Int = 0,
        checkpoint: (@Sendable () async -> Bool)? = nil,
        fileCompletion: (@Sendable (Int64, Bool) async -> Void)? = nil,
        progress: (@MainActor (VectorIndexRebuildProgress) -> Void)? = nil
    ) async -> IndexBatchResult {
        let candidates = files.filter { $0.id != nil }
        let reporter = IndexBatchProgressReporter(
            total: totalOverride ?? (initialCompleted + candidates.count),
            initialCompleted: initialCompleted,
            progress: progress
        )
        var nextIndex = 0
        var stopped = false

        await withTaskGroup(of: (id: Int64?, name: String, succeeded: Bool, stopped: Bool).self) { group in
            func enqueue(_ file: FileRecord) {
                group.addTask { [weak self] in
                    guard let self, let id = file.id,
                          await self.canContinue(checkpoint) else {
                        return (file.id, file.name, false, true)
                    }
                    await reporter.report(fileName: file.name, stage: .hashing)
                    let succeeded = await self.indexFile(
                        id: id,
                        force: force,
                        writeTarget: writeTarget,
                        checkpoint: checkpoint,
                        stageProgress: { stage in
                            await reporter.report(fileName: file.name, stage: stage)
                        }
                    )
                    let remainsRunnable = await self.canContinue(checkpoint)
                    let didStop = Task.isCancelled || !remainsRunnable
                    return (id, file.name, succeeded, didStop)
                }
            }

            let concurrency = min(fileConcurrency, candidates.count)
            while nextIndex < concurrency {
                enqueue(candidates[nextIndex])
                nextIndex += 1
            }

            while let outcome = await group.next() {
                if outcome.stopped {
                    stopped = true
                    group.cancelAll()
                    await cancelAll()
                } else {
                    if let fileID = outcome.id {
                        await fileCompletion?(fileID, outcome.succeeded)
                    }
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

    private struct SemanticChunkUnit {
        let text: String
        let paragraphIndex: Int
    }

    /// Splits on semantic boundaries in descending order of strength: paragraphs first, then
    /// complete sentences. A single sentence is never divided merely to satisfy a soft target.
    /// Overlap also consists only of complete semantic units, so no chunk can begin mid-word.
    static func chunk(text: String, maxWords: Int, overlap: Int) -> [String] {
        guard maxWords > 0 else { return [] }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        if maxWords >= 64,
           estimatedTokenCount(normalized) > Double(maxWords),
           semanticParagraphs(in: normalized).count == 1,
           semanticSentences(in: normalized).count == 1 {
            return emergencyLexicalChunks(
                normalized,
                maxTokens: maxWords,
                overlapTokens: min(max(overlap, 0), maxWords - 1)
            )
        }
        let units = semanticChunkUnits(in: normalized, maxTokens: maxWords)
        guard !units.isEmpty else { return [] }

        let overlapBudget = min(max(overlap, 0), maxWords - 1)
        var result = [String]()
        var current = [SemanticChunkUnit]()

        for unit in units {
            if current.isEmpty {
                current = [unit]
                continue
            }
            let candidate = renderedSemanticUnits(current + [unit])
            if estimatedTokenCount(candidate) <= Double(maxWords) {
                current.append(unit)
                continue
            }

            result.append(renderedSemanticUnits(current))
            var next = trailingSemanticOverlap(from: current, tokenBudget: overlapBudget)
            while !next.isEmpty,
                  estimatedTokenCount(renderedSemanticUnits(next + [unit])) > Double(maxWords) {
                next.removeFirst()
            }
            next.append(unit)
            current = next
        }
        if !current.isEmpty { result.append(renderedSemanticUnits(current)) }
        return result
    }

    private static func semanticChunkUnits(in text: String, maxTokens: Int) -> [SemanticChunkUnit] {
        semanticParagraphs(in: text).enumerated().flatMap { paragraphIndex, paragraph in
            guard estimatedTokenCount(paragraph) > Double(maxTokens) else {
                return [SemanticChunkUnit(text: paragraph, paragraphIndex: paragraphIndex)]
            }
            let sentences = semanticSentences(in: paragraph)
            guard sentences.count > 1 else {
                return [SemanticChunkUnit(text: paragraph, paragraphIndex: paragraphIndex)]
            }
            return sentences.map {
                SemanticChunkUnit(text: $0, paragraphIndex: paragraphIndex)
            }
        }
    }

    /// Emergency path for generated run-on text. It keeps complete lexical units and applies
    /// overlap using the same canonical token counter as normal semantic chunking.
    private static func emergencyLexicalChunks(
        _ text: String,
        maxTokens: Int,
        overlapTokens: Int
    ) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let usesWords = words.count > 1
        let units = usesWords ? words : Array(text).map(String.init)
        let separator = usesWords ? " " : ""
        guard !units.isEmpty else { return [] }

        func render(_ values: [String]) -> String { values.joined(separator: separator) }
        var chunks = [String]()
        var current = [String]()
        for unit in units {
            if current.isEmpty || estimatedTokenCount(render(current + [unit])) <= Double(maxTokens) {
                current.append(unit)
                continue
            }
            chunks.append(render(current))
            var next = [String]()
            if overlapTokens > 0 {
                for candidate in current.reversed() {
                    let suffix = [candidate] + next
                    guard estimatedTokenCount(render(suffix)) <= Double(overlapTokens) else { break }
                    next = suffix
                }
            }
            while !next.isEmpty,
                  estimatedTokenCount(render(next + [unit])) > Double(maxTokens) {
                next.removeFirst()
            }
            next.append(unit)
            current = next
        }
        if !current.isEmpty { chunks.append(render(current)) }
        return chunks
    }

    private static func semanticParagraphs(in text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let expression = try? NSRegularExpression(pattern: #"\n[\t ]*\n+"#) else {
            return [normalized]
        }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let separated = expression.stringByReplacingMatches(
            in: normalized,
            range: range,
            withTemplate: "\u{001E}"
        )
        return separated.split(separator: "\u{001E}").compactMap { value in
            let paragraph = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return paragraph.isEmpty ? nil : paragraph
        }
    }

    private static func semanticSentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences = [String]()
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        return sentences.isEmpty ? [text] : sentences
    }

    private static func renderedSemanticUnits(_ units: [SemanticChunkUnit]) -> String {
        guard let first = units.first else { return "" }
        var result = first.text
        for (previous, current) in zip(units, units.dropFirst()) {
            result += previous.paragraphIndex == current.paragraphIndex ? " " : "\n\n"
            result += current.text
        }
        return result
    }

    private static func trailingSemanticOverlap(
        from units: [SemanticChunkUnit],
        tokenBudget: Int
    ) -> [SemanticChunkUnit] {
        guard tokenBudget > 0 else { return [] }
        var suffix = [SemanticChunkUnit]()
        for unit in units.reversed() {
            let candidate = [unit] + suffix
            guard estimatedTokenCount(renderedSemanticUnits(candidate)) <= Double(tokenBudget) else {
                break
            }
            suffix = candidate
        }
        return suffix
    }

    /// Docling chunks do not include OCR text appended afterwards, while the native fallback
    /// chunks the already-combined extracted text. Keeping these paths separate prevents OCR
    /// from being embedded twice for raster images and extraction fallbacks.
    static func contentChunks(
        doclingChunks: [StructuredDocumentChunk]?,
        extractedText: String,
        appendedOCRText: String?,
        maxTokens: Int
    ) -> [StructuredDocumentChunk] {
        guard let doclingChunks else {
            return chunk(text: extractedText, maxWords: maxTokens, overlap: 0)
                .map { StructuredDocumentChunk(text: $0) }
        }
        var chunks = postProcessDoclingChunks(doclingChunks, maxTokens: maxTokens)
        if let appendedOCRText, !appendedOCRText.isEmpty {
            chunks.append(contentsOf: chunk(
                text: appendedOCRText,
                maxWords: maxTokens,
                overlap: 0
            ).map { StructuredDocumentChunk(text: $0) })
        }
        return chunks
    }

    /// Docling preserves document boundaries and enforces a maximum size, but it can still
    /// return tiny titles, list tails, or layout fragments. This pass removes unambiguous
    /// noise and merges short compatible neighbors without crossing semantic boundaries.
    static func postProcessDoclingChunks(
        _ source: [StructuredDocumentChunk],
        maxTokens: Int,
        minimumTokens: Int? = nil
    ) -> [StructuredDocumentChunk] {
        let minimum = max(24, min(minimumTokens ?? 80, max(24, maxTokens / 4)))
        let normalized = source.compactMap(normalizedChunk).filter { !isUnambiguousNoise($0.text) }
        guard normalized.count > 1 else { return normalized }
        let sentenceRepaired = repairSplitSentences(in: normalized)

        // A short heading belongs with the following content. Resolve it before the general
        // forward merge so it cannot accidentally attach to the previous section.
        var titleAttached = [StructuredDocumentChunk]()
        var index = 0
        while index < sentenceRepaired.count {
            let current = sentenceRepaired[index]
            if current.kind == .title,
               estimatedTokenCount(current.text) < Double(minimum),
               index + 1 < sentenceRepaired.count {
                let next = sentenceRepaired[index + 1]
                let candidate = mergeChunks(current, next)
                if canAttachTitle(current, to: next),
                   estimatedTokenCount(candidate.contextualText) <= Double(maxTokens) {
                    titleAttached.append(candidate)
                    index += 2
                    continue
                }
            }
            titleAttached.append(current)
            index += 1
        }

        var merged = [StructuredDocumentChunk]()
        for current in titleAttached {
            guard let previous = merged.last else {
                merged.append(current)
                continue
            }
            let eitherIsShort = estimatedTokenCount(previous.text) < Double(minimum)
                || estimatedTokenCount(current.text) < Double(minimum)
            let candidate = mergeChunks(previous, current)
            if eitherIsShort,
               canMergePeerChunks(previous, current),
               estimatedTokenCount(candidate.contextualText) <= Double(maxTokens) {
                merged[merged.count - 1] = candidate
            } else {
                merged.append(current)
            }
        }

        if merged.count != source.count {
            log(
                "Docling chunks post-processed",
                category: .indexExtraction,
                level: .debug,
                metadata: [
                    "before": "\(source.count)",
                    "after": "\(merged.count)",
                    "minimumTokens": "\(minimum)",
                    "maxTokens": "\(maxTokens)",
                ]
            )
        }
        return merged
    }

    private static func repairSplitSentences(
        in chunks: [StructuredDocumentChunk]
    ) -> [StructuredDocumentChunk] {
        var repaired = [StructuredDocumentChunk]()
        for current in chunks {
            guard let previous = repaired.last,
                  boundarySplitsSentence(previous, current) else {
                repaired.append(current)
                continue
            }
            repaired[repaired.count - 1] = mergeSentenceFragments(previous, current)
        }
        return repaired
    }

    private static func boundarySplitsSentence(
        _ first: StructuredDocumentChunk,
        _ second: StructuredDocumentChunk
    ) -> Bool {
        guard first.kind == .text, second.kind == .text,
              first.sectionPath == second.sectionPath,
              pagesAreAdjacent(first, second) else { return false }
        let firstText = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondText = second.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let leading = secondText.first, leading.isLowercase,
              let trailing = firstText.last else { return false }
        return !".!?。！？".contains(trailing)
    }

    private static func mergeSentenceFragments(
        _ first: StructuredDocumentChunk,
        _ second: StructuredDocumentChunk
    ) -> StructuredDocumentChunk {
        let text = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            + " "
            + second.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstPrefix = contextualPrefix(of: first)
        let secondPrefix = contextualPrefix(of: second)
        let prefix = firstPrefix == secondPrefix
            ? firstPrefix
            : (firstPrefix.isEmpty ? secondPrefix : firstPrefix)
        return StructuredDocumentChunk(
            text: text,
            contextualText: prefix + text,
            sectionPath: second.sectionPath.isEmpty ? first.sectionPath : second.sectionPath,
            pageStart: [first.pageStart, second.pageStart].compactMap { $0 }.min(),
            pageEnd: [first.pageEnd, second.pageEnd].compactMap { $0 }.max(),
            kind: .text
        )
    }

    private static func contextualPrefix(of chunk: StructuredDocumentChunk) -> String {
        guard chunk.contextualText.hasSuffix(chunk.text) else {
            return chunk.sectionPath.isEmpty ? "" : chunk.sectionPath.joined(separator: " > ") + "\n"
        }
        return String(chunk.contextualText.dropLast(chunk.text.count))
    }

    private static func normalizedChunk(_ chunk: StructuredDocumentChunk) -> StructuredDocumentChunk? {
        let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let contextual = chunk.contextualText.trimmingCharacters(in: .whitespacesAndNewlines)
        return StructuredDocumentChunk(
            text: text,
            contextualText: contextual.isEmpty ? text : contextual,
            sectionPath: chunk.sectionPath.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
            pageStart: chunk.pageStart,
            pageEnd: chunk.pageEnd,
            kind: chunk.kind,
            parentIndex: chunk.parentIndex,
            parentText: chunk.parentText,
            entityTerms: chunk.entityTerms,
            tokenCount: chunk.tokenCount,
            tokenizerProfile: chunk.tokenizerProfile,
            tokenizerVersion: chunk.tokenizerVersion,
            tokenCountAccuracy: chunk.tokenCountAccuracy
        )
    }

    private static func isUnambiguousNoise(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        // Preserve short words, identifiers, amounts, and numeric values. Only symbol-only
        // fragments and explicit page labels are safe to remove without OCR confidence data.
        if normalized.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return true }
        return normalized.range(
            of: #"^(?:page|p\.?|页)\s*\d{1,4}(?:\s*(?:of|/|共)\s*\d{1,4})?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func canAttachTitle(
        _ title: StructuredDocumentChunk,
        to content: StructuredDocumentChunk
    ) -> Bool {
        guard content.kind != .table && content.kind != .picture && pagesAreAdjacent(title, content) else {
            return false
        }
        if title.sectionPath == content.sectionPath { return true }
        let normalizedTitle = normalizedTextFingerprint(title.text)
        return content.sectionPath.contains { heading in
            let normalizedHeading = normalizedTextFingerprint(heading)
            return !normalizedTitle.isEmpty
                && (normalizedHeading.contains(normalizedTitle) || normalizedTitle.contains(normalizedHeading))
        }
    }

    private static func canMergePeerChunks(
        _ first: StructuredDocumentChunk,
        _ second: StructuredDocumentChunk
    ) -> Bool {
        guard first.sectionPath == second.sectionPath, pagesAreAdjacent(first, second) else { return false }
        let compatibleKinds: Set<DocumentChunkKind> = [.text, .list]
        return compatibleKinds.contains(first.kind) && compatibleKinds.contains(second.kind)
    }

    private static func pagesAreAdjacent(
        _ first: StructuredDocumentChunk,
        _ second: StructuredDocumentChunk
    ) -> Bool {
        guard let firstEnd = first.pageEnd ?? first.pageStart,
              let secondStart = second.pageStart ?? second.pageEnd else { return true }
        return secondStart >= firstEnd && secondStart <= firstEnd + 1
    }

    private static func mergeChunks(
        _ first: StructuredDocumentChunk,
        _ second: StructuredDocumentChunk
    ) -> StructuredDocumentChunk {
        let text = [first.text, second.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let contextual = mergeContextualText(first.contextualText, second.contextualText, fallback: text)
        let sectionPath = second.sectionPath.isEmpty ? first.sectionPath : second.sectionPath
        let kind: DocumentChunkKind = first.kind == second.kind ? first.kind : .text
        return StructuredDocumentChunk(
            text: text,
            contextualText: contextual,
            sectionPath: sectionPath,
            pageStart: [first.pageStart, second.pageStart].compactMap { $0 }.min(),
            pageEnd: [first.pageEnd, second.pageEnd].compactMap { $0 }.max(),
            kind: kind
        )
    }

    private static func mergeContextualText(_ first: String, _ second: String, fallback: String) -> String {
        let first = first.trimmingCharacters(in: .whitespacesAndNewlines)
        let second = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if first.isEmpty { return second.isEmpty ? fallback : second }
        if second.isEmpty || first == second { return first }
        if first.contains(second) { return first }
        if second.contains(first) { return second }
        return first + "\n\n" + second
    }

    private static func addDocumentTitleContext(
        _ title: String,
        to chunk: StructuredDocumentChunk,
        maxTokens: Int
    ) -> StructuredDocumentChunk {
        let normalizedTitle = normalizedTextFingerprint(title)
        let contextualFingerprint = normalizedTextFingerprint(chunk.contextualText)
        guard !normalizedTitle.isEmpty, !contextualFingerprint.contains(normalizedTitle) else { return chunk }
        let contextualText = "Document: \(title)\n\n\(chunk.contextualText)"
        guard estimatedTokenCount(contextualText) <= Double(maxTokens) else { return chunk }
        return StructuredDocumentChunk(
            text: chunk.text,
            contextualText: contextualText,
            sectionPath: chunk.sectionPath,
            pageStart: chunk.pageStart,
            pageEnd: chunk.pageEnd,
            kind: chunk.kind
        )
    }

    static func estimatedTokenCount(_ text: String) -> Double {
        Double(TokenCounter.estimate(text).count)
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

    static func log(
        _ message: String,
        category: AppLogCategory = .indexPipeline,
        level: AppLogLevel = .info,
        metadata: [String: String] = [:]
    ) {
        AppLogService.shared.write(message, category: category, level: level, metadata: metadata)
    }
}
