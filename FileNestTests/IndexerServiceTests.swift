import XCTest
import AppKit
import ImageIO
@testable import FileNest

final class IndexerServiceTests: XCTestCase {
    func testRecommendedFileConcurrencyProtectsLowMemoryAndHeavyLocalProcessing() {
        let gibibyte = UInt64(1_024 * 1_024 * 1_024)

        XCTAssertEqual(IndexerService.recommendedFileConcurrency(
            physicalMemory: 8 * gibibyte,
            usesLocalEmbedding: false,
            usesDocling: false,
            usesLocalOCR: false
        ), 1)
        XCTAssertEqual(IndexerService.recommendedFileConcurrency(
            physicalMemory: 64 * gibibyte,
            usesLocalEmbedding: false,
            usesDocling: true,
            usesLocalOCR: false
        ), 2)
        XCTAssertEqual(IndexerService.recommendedFileConcurrency(
            physicalMemory: 64 * gibibyte,
            usesLocalEmbedding: false,
            usesDocling: false,
            usesLocalOCR: false
        ), 3)
    }
    private actor StageRecorder {
        private var stages = [IndexingStage]()
        func append(_ stage: IndexingStage) { stages.append(stage) }
        func values() -> [IndexingStage] { stages }
    }

    private final class StubEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name: String
        let dimension = 2
        private let queue = DispatchQueue(label: "filenest.tests.stub-embedder")
        private let result: [Float]
        private var calls = 0
        private var texts: [String] = []

        init(result: [Float], name: String = "stub") {
            self.result = result
            self.name = name
        }

        var callCount: Int { queue.sync { calls } }
        var embeddedTexts: [String] { queue.sync { texts } }

        func embed(_ text: String) async throws -> [Float] {
            queue.sync {
                calls += 1
                texts.append(text)
            }
            return result
        }
    }

    private final class SplittingEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name = "splitting"
        let dimension = 2
        let maximumBatchSize = 4
        private let lock = NSLock()
        private let permanentlyFailingText: String?
        private var singleFailuresRemaining: Int
        private var recordedBatchSizes = [Int]()

        init(permanentlyFailingText: String? = nil, singleFailuresRemaining: Int = 0) {
            self.permanentlyFailingText = permanentlyFailingText
            self.singleFailuresRemaining = singleFailuresRemaining
        }

        var batchSizes: [Int] { lock.withLock { recordedBatchSizes } }

        func embed(_ text: String) async throws -> [Float] {
            try await embedBatch([text])[0]
        }

        func embedBatch(_ texts: [String]) async throws -> [[Float]] {
            let shouldFailSingle = lock.withLock {
                recordedBatchSizes.append(texts.count)
                guard texts.count == 1, singleFailuresRemaining > 0 else { return false }
                singleFailuresRemaining -= 1
                return true
            }
            if texts.count > 1 { throw URLError(.badServerResponse) }
            if shouldFailSingle { throw URLError(.networkConnectionLost) }
            if let permanentlyFailingText,
               texts[0].contains(permanentlyFailingText) {
                throw URLError(.cannotParseResponse)
            }
            return texts.map { _ in [1, 0] }
        }
    }

    private final class RunnerEOFEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name = "runner-eof"
        let dimension = 2
        let maximumBatchSize = 1
        private let lock = NSLock()
        private let maximumCharacters: Int
        private var recordedFailures = [String]()
        private var recordedSuccesses = [String]()

        init(maximumCharacters: Int) {
            self.maximumCharacters = maximumCharacters
        }

        var failedInputs: [String] { lock.withLock { recordedFailures } }
        var successfulInputs: [String] { lock.withLock { recordedSuccesses } }

        func embed(_ text: String) async throws -> [Float] {
            if text.count > maximumCharacters {
                lock.withLock { recordedFailures.append(text) }
                throw EmbeddingProviderError.httpStatus(
                    code: 400,
                    body: "do embedding request: Post http://127.0.0.1:1234/embedding: EOF"
                )
            }
            lock.withLock { recordedSuccesses.append(text) }
            return [1, 0]
        }
    }

    private final class GateEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name = "gate"
        let dimension = 2
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        var isWaiting: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation != nil
        }

        func embed(_ text: String) async throws -> [Float] {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
            return [1, 0]
        }

        func release() {
            lock.lock()
            released = true
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    private final class StubOCRProvider: OCRProvider {
        let name = "stub-ocr"
        let result: String
        init(result: String) { self.result = result }
        func recognize(imageData: Data, mimeType: String) async throws -> String { result }
    }

    private final class RecordingOCRProvider: OCRProvider, @unchecked Sendable {
        let name = "recording-ocr"
        private let lock = NSLock()
        private var calls = [(mimeType: String, width: Int, height: Int)]()

        var recordedCalls: [(mimeType: String, width: Int, height: Int)] {
            lock.withLock { calls }
        }

        func recognize(imageData: Data, mimeType: String) async throws -> String {
            try await recognizeResult(imageData: imageData, mimeType: mimeType).text
        }

        func recognizeResult(imageData: Data,
                             mimeType: String) async throws -> OCRRecognitionResult {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw URLError(.cannotDecodeContentData)
            }
            let callIndex = lock.withLock { () -> Int in
                calls.append((mimeType, width.intValue, height.intValue))
                return calls.count
            }
            return OCRRecognitionResult(
                text: "Region \(callIndex)",
                observations: [OCRTextObservation(
                    text: "Region \(callIndex)",
                    confidence: 0.95,
                    bounds: OCRBoundingBox(x: 20, y: 20, width: 100, height: 30)
                )]
            )
        }
    }

    private final class FailingOCRProvider: OCRProvider, @unchecked Sendable {
        let name = "failing-ocr-\(UUID().uuidString)"
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }

        func recognize(imageData: Data, mimeType: String) async throws -> String {
            lock.withLock { calls += 1 }
            throw URLError(.timedOut)
        }
    }

    private final class SupersedingEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name = "superseding"
        let dimension = 2
        private let queue = DispatchQueue(label: "filenest.tests.superseding-embedder")
        private var calls = 0
        private var continuation: CheckedContinuation<Void, Never>?

        var isFirstCallWaiting: Bool { queue.sync { continuation != nil } }
        var callCount: Int { queue.sync { calls } }

        func embed(_ text: String) async throws -> [Float] {
            let call = queue.sync {
                calls += 1
                return calls
            }
            if call == 1 {
                await withCheckedContinuation { continuation in
                    queue.sync { self.continuation = continuation }
                }
            }
            return call == 2 || call == 3 ? [0, 1] : [1, 0]
        }

        func releaseFirstCall() {
            let continuation = queue.sync {
                let value = self.continuation
                self.continuation = nil
                return value
            }
            continuation?.resume()
        }
    }

    private var temporaryDirectory: URL!
    private var store: SQLiteStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
        store = SQLiteStore(path: temporaryDirectory.appendingPathComponent("test.sqlite").path)
    }

    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testSuccessfulIndexSetsHashAndSkipsUnchangedContent() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("notes.txt")
        try Data("hello world".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let embedder = StubEmbedder(result: [1, 0])
        let indexer = IndexerService(store: store, settings: AppSettings(store: store), embedder: embedder)

        let didIndex = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(didIndex)

        let indexed = try XCTUnwrap(store.file(id: fileId))
        XCTAssertNotNil(indexed.indexedAt)
        XCTAssertEqual(indexed.contentHash,
                       "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
        XCTAssertEqual(indexer.vectorStore.count, 2)
        XCTAssertEqual(embedder.callCount, 2)

        let didSkipUnchanged = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(didSkipUnchanged)
        XCTAssertEqual(embedder.callCount, 2)
        XCTAssertEqual(indexer.vectorStore.count, 2)

        try Data("changed content".utf8).write(to: fileURL)
        let didReindex = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(didReindex)
        XCTAssertEqual(embedder.callCount, 4)
        XCTAssertEqual(indexer.vectorStore.count, 2)
        let reindexed = try XCTUnwrap(store.file(id: fileId))
        XCTAssertNotEqual(reindexed.contentHash, indexed.contentHash)
        XCTAssertNotNil(reindexed.indexedAt)
    }

    func testIncrementalRebuildSkipsUnchangedContentWithMatchingConfiguration() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("incremental.txt")
        try Data("stable searchable content".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let embedder = StubEmbedder(result: [1, 0])
        let settings = AppSettings(store: store)
        let indexer = IndexerService(store: store, settings: settings, embedder: embedder)
        let initialIndexSucceeded = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(initialIndexSucceeded)
        let callsAfterInitialIndex = embedder.callCount

        let rebuildSucceeded = await indexer.rebuildAll()
        XCTAssertTrue(rebuildSucceeded)

        XCTAssertEqual(embedder.callCount, callsAfterInitialIndex)
        XCTAssertEqual(try store.file(id: fileId)?.indexSignature, settings.indexConfigurationSignature)
    }

    func testProcessingConfigurationChangeWaitsForForcedReindex() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("configuration.txt")
        try Data("stable searchable content".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let embedder = StubEmbedder(result: [1, 0])
        let settings = AppSettings(store: store)
        let indexer = IndexerService(store: store, settings: settings, embedder: embedder)
        let initialIndexSucceeded = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(initialIndexSucceeded)
        let callsAfterInitialIndex = embedder.callCount

        settings.setVectorChunkWords(900)
        let incrementalSucceeded = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(incrementalSucceeded)
        XCTAssertEqual(embedder.callCount, callsAfterInitialIndex)

        let reindexSucceeded = await indexer.rebuildAll(forceReprocessing: true)
        XCTAssertTrue(reindexSucceeded)

        XCTAssertGreaterThan(embedder.callCount, callsAfterInitialIndex)
    }

    func testWarmupPreservesStoredChunksUntilAtomicEmbeddingRebuild() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("old-model.txt")
        try Data("content indexed with an old model".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        var indexed = try XCTUnwrap(store.file(id: fileId))
        indexed.indexedAt = Date()
        indexed.indexSignature = "old-signature"
        _ = try store.upsertFile(indexed)

        let vectorStore = AccelerateVectorStore(store: store)
        let didStoreOldVector = await vectorStore.replace(
            fileId: fileId,
            chunks: [EmbeddingChunk(vector: [1, 0], text: "old")],
            model: "old-model"
        )
        XCTAssertTrue(didStoreOldVector)
        let indexer = IndexerService(
            store: store,
            settings: AppSettings(store: store),
            embedder: StubEmbedder(result: [1, 0])
        )

        await indexer.warmup()

        XCTAssertEqual(indexer.vectorStore.count, 1)
        XCTAssertNotNil(try store.file(id: fileId)?.indexedAt)
        XCTAssertEqual(try store.file(id: fileId)?.indexSignature, "old-signature")
    }

    func testIndexReportsDetailedStages() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("stages.txt")
        try Data("stage progress content".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let recorder = StageRecorder()
        let indexer = IndexerService(
            store: store,
            settings: AppSettings(store: store),
            embedder: StubEmbedder(result: [1, 0])
        )

        let succeeded = await indexer.indexFile(
            id: fileId,
            overridePath: fileURL,
            stageProgress: { await recorder.append($0) }
        )
        XCTAssertTrue(succeeded)

        let stages = await recorder.values()
        XCTAssertTrue(stages.contains(.hashing))
        XCTAssertTrue(stages.contains(.chunking))
        XCTAssertTrue(stages.contains { if case .embedding = $0 { return true }; return false })
        XCTAssertTrue(stages.contains(.saving))
    }

    func testFailedEmbeddingDoesNotMarkFileIndexed() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("notes.txt")
        try Data("hello world".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let indexer = IndexerService(
            store: store,
            settings: AppSettings(store: store),
            embedder: StubEmbedder(result: [])
        )

        let didIndex = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertFalse(didIndex)

        let record = try XCTUnwrap(store.file(id: fileId))
        XCTAssertNil(record.indexedAt)
        XCTAssertNotNil(record.contentHash)
        XCTAssertEqual(indexer.vectorStore.count, 0)
    }

    func testFailedEmbeddingBatchSplitsAndRetriesUntilSuccessful() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("retry.txt")
        try Data("searchable retry content".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let embedder = SplittingEmbedder()
        let indexer = IndexerService(
            store: store,
            settings: AppSettings(store: store),
            embedder: embedder
        )

        let didIndex = await indexer.indexFile(id: fileId, overridePath: fileURL)

        XCTAssertTrue(didIndex)
        XCTAssertEqual(embedder.batchSizes, [2, 1, 1])
        XCTAssertNotNil(try store.file(id: fileId)?.indexedAt)
        XCTAssertEqual(indexer.vectorStore.count, 2)
    }

    func testTransientSingleSegmentFailureRetriesOnce() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("single-retry.txt")
        try Data("searchable retry content".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let embedder = SplittingEmbedder(singleFailuresRemaining: 1)
        let indexer = IndexerService(
            store: store,
            settings: AppSettings(store: store),
            embedder: embedder
        )

        let didIndex = await indexer.indexFile(id: fileId, overridePath: fileURL)

        XCTAssertTrue(didIndex)
        XCTAssertEqual(embedder.batchSizes, [2, 1, 1, 1])
        XCTAssertNotNil(try store.file(id: fileId)?.indexedAt)
        XCTAssertEqual(indexer.vectorStore.count, 2)
    }

    func testRunnerEOFHalvesCurrentSegmentAndIndexesBothHalves() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("runner-eof.txt")
        try Data(String(repeating: "\u{6587}", count: 900).utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let embedder = RunnerEOFEmbedder(maximumCharacters: 500)
        let indexer = IndexerService(
            store: store,
            settings: AppSettings(store: store),
            embedder: embedder
        )

        let didIndex = await indexer.indexFile(id: fileId, overridePath: fileURL)

        XCTAssertTrue(didIndex)
        XCTAssertTrue(embedder.failedInputs.isEmpty)
        XCTAssertTrue(embedder.successfulInputs.allSatisfy { $0.count <= 500 })
        XCTAssertEqual(indexer.vectorStore.count, embedder.successfulInputs.count)
        XCTAssertGreaterThanOrEqual(embedder.successfulInputs.count, 3)
        XCTAssertNotNil(try store.file(id: fileId)?.indexedAt)
    }

    func testPermanentSingleSegmentEmbeddingFailureRejectsWholeFile() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("permanent.txt")
        try Data("permanent failure marker".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let embedder = SplittingEmbedder(permanentlyFailingText: "failure marker")
        let indexer = IndexerService(
            store: store,
            settings: AppSettings(store: store),
            embedder: embedder
        )

        let didIndex = await indexer.indexFile(id: fileId, overridePath: fileURL)

        XCTAssertFalse(didIndex)
        XCTAssertEqual(embedder.batchSizes, [2, 1, 1, 1])
        XCTAssertNil(try store.file(id: fileId)?.indexedAt)
        XCTAssertEqual(indexer.vectorStore.count, 0)
    }

    func testUserNoteIsIncludedInFileVectorIndex() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("roadmap.txt")
        try Data("release checklist".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        try store.updateFileNote(id: fileId, note: "Polaris Project Q4 Delivery")
        let embedder = StubEmbedder(result: [1, 0])
        let indexer = IndexerService(store: store, settings: AppSettings(store: store), embedder: embedder)

        let indexed = await indexer.indexFile(id: fileId, overridePath: fileURL, force: true)

        XCTAssertTrue(indexed)
        XCTAssertTrue(embedder.embeddedTexts.contains { $0.contains("User note: Polaris Project Q4 Delivery") })
        XCTAssertNotNil(try store.file(id: fileId)?.indexedAt)
        XCTAssertGreaterThanOrEqual(indexer.vectorStore.count, 2)
    }

    func testFileChangedDuringEmbeddingIsRejectedAndLatestContentCanRetry() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("changing.txt")
        try Data("old content".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let embedder = GateEmbedder()
        defer { embedder.release() }
        let indexer = IndexerService(store: store, settings: AppSettings(store: store), embedder: embedder)

        let indexingTask = Task {
            await indexer.indexFile(id: fileId, overridePath: fileURL)
        }
        let didStartEmbedding = await waitUntil { embedder.isWaiting }
        XCTAssertTrue(didStartEmbedding)
        try Data("latest content".utf8).write(to: fileURL)
        embedder.release()

        let acceptedStaleContent = await indexingTask.value
        XCTAssertFalse(acceptedStaleContent)
        XCTAssertNil(try store.file(id: fileId)?.indexedAt)
        XCTAssertEqual(indexer.vectorStore.count, 0)

        let didRetryLatestContent = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(didRetryLatestContent)
        let latest = try XCTUnwrap(store.file(id: fileId))
        XCTAssertEqual(latest.contentText, "latest content")
        XCTAssertEqual(latest.contentHash, try FileContentHasher.sha256(of: fileURL))
        XCTAssertNotNil(latest.indexedAt)
        XCTAssertEqual(indexer.vectorStore.count, 2)
    }

    func testConcurrentRequestsForSameFileShareOneIndexTask() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("concurrent.txt")
        try Data("same content".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let embedder = SupersedingEmbedder()
        defer { embedder.releaseFirstCall() }
        let indexer = IndexerService(store: store, settings: AppSettings(store: store), embedder: embedder)

        let olderTask = Task {
            await indexer.indexFile(id: fileId, overridePath: fileURL)
        }
        let olderTaskDidBlock = await waitUntil { embedder.isFirstCallWaiting }
        XCTAssertTrue(olderTaskDidBlock)

        let newerTask = Task {
            await indexer.indexFile(id: fileId, overridePath: fileURL)
        }
        embedder.releaseFirstCall()

        let olderSucceeded = await olderTask.value
        let newerSucceeded = await newerTask.value
        XCTAssertTrue(olderSucceeded)
        XCTAssertTrue(newerSucceeded)
        XCTAssertEqual(embedder.callCount, 2)
        XCTAssertNotNil(try store.file(id: fileId)?.indexedAt)
    }

    func testDisabledExtensionStoresMetadataWithoutEmbeddingAndCanBeForced() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("notes.txt")
        try Data("searchable document".utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let settings = AppSettings(store: store)
        settings.setVectorizeExtensions(["pdf"])
        let embedder = StubEmbedder(result: [1, 0])
        let indexer = IndexerService(store: store, settings: settings, embedder: embedder)

        let metadataIndexed = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(metadataIndexed)
        XCTAssertEqual(embedder.callCount, 0)
        XCTAssertEqual(try store.file(id: fileId)?.contentText, "searchable document")
        XCTAssertEqual(indexer.vectorStore.count, 0)

        let forceIndexed = await indexer.indexFile(
            id: fileId,
            overridePath: fileURL,
            force: true,
            forceVectorization: true
        )
        XCTAssertTrue(forceIndexed)
        XCTAssertGreaterThan(embedder.callCount, 0)
        XCTAssertGreaterThan(indexer.vectorStore.count, 0)
    }

    func testConfiguredChunkSizeAndOverlapDriveEmbeddingSegments() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("long.txt")
        let text = (0..<1_200).map { "word\($0)" }.joined(separator: " ")
        try Data(text.utf8).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let settings = AppSettings(store: store)
        settings.setVectorChunkWords(600)
        settings.setVectorChunkOverlap(100)
        let embedder = StubEmbedder(result: [1, 0])
        let indexer = IndexerService(store: store, settings: settings, embedder: embedder)

        let indexed = await indexer.indexFile(id: fileId, overridePath: fileURL)
        XCTAssertTrue(indexed)
        let contentSegments = embedder.embeddedTexts.filter { $0.hasPrefix("word") }
        XCTAssertGreaterThan(contentSegments.count, 1)
        XCTAssertTrue(contentSegments.allSatisfy { $0.split(separator: " ").count <= 450 })
        XCTAssertFalse(Set(contentSegments[0].split(separator: " ").suffix(20))
            .isDisjoint(with: Set(contentSegments[1].split(separator: " ").prefix(80))))
    }

    func testDOCXContentIsExtractedChunkedAndStoredInLocalVectorIndex() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("local-plan.docx")
        let paragraph = (0..<1_400).map { "milestone\($0)" }.joined(separator: " ")
        try ArchiveTestSupport.write(entries: [
            "word/document.xml": "<?xml version=\"1.0\"?><document><p><t>\(paragraph)</t></p></document>",
        ], to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let settings = AppSettings(store: store)
        settings.setVectorChunkWords(600)
        settings.setVectorChunkOverlap(100)
        let embedder = StubEmbedder(result: [1, 0])
        let indexer = IndexerService(store: store, settings: settings, embedder: embedder)

        let indexed = await indexer.indexFile(id: fileId, overridePath: fileURL)

        XCTAssertTrue(indexed)
        let stored = try XCTUnwrap(store.file(id: fileId))
        XCTAssertTrue(stored.contentText?.contains("milestone1399") == true)
        XCTAssertNotNil(stored.indexedAt)
        let bodySegments = embedder.embeddedTexts.filter { $0.contains("milestone") }
        XCTAssertGreaterThan(bodySegments.count, 1)
        XCTAssertGreaterThan(indexer.vectorStore.count, 1)
    }

    func testImageOCRTextIsStoredAndVectorized() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("invoice.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: fileURL)
        let fileId = try insertFile(at: fileURL)
        let embedder = StubEmbedder(result: [1, 0])
        let indexer = IndexerService(
            store: store,
            settings: AppSettings(store: store),
            embedder: embedder,
            ocrProvider: StubOCRProvider(result: "Invoice total 4200")
        )

        let indexed = await indexer.indexFile(id: fileId, overridePath: fileURL)

        XCTAssertTrue(indexed)
        XCTAssertTrue(try XCTUnwrap(store.file(id: fileId)?.contentText).contains("Invoice total 4200"))
        XCTAssertTrue(embedder.embeddedTexts.contains { $0.contains("Invoice total 4200") })
    }

    func testImageOCRRunsWithoutVisionPreflightOrForceFlag() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("stylized-seal.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: fileURL)

        let text = await OCRDocumentProcessor.recognizeIfNeeded(
            url: fileURL,
            ext: "png",
            provider: StubOCRProvider(result: "BRITECH CLOUD UEN 202344212C")
        )

        XCTAssertEqual(text, "BRITECH CLOUD UEN 202344212C")
    }

    func testPanoramicOCRPlanUsesOverlappingSourceResolutionTiles() {
        let plan = OCRDocumentProcessor.imagePlan(width: 14_568, height: 2_723)

        XCTAssertTrue(plan.usesTiling)
        XCTAssertEqual(plan.processingScale, 1, accuracy: 0.001)
        XCTAssertEqual(plan.tileRects.count, 18)
        XCTAssertLessThanOrEqual(plan.tileRects.count, 32)
        XCTAssertEqual(plan.tileRects[0].width, 2_048)
        XCTAssertEqual(plan.tileRects[1].minX, 1_760)
        XCTAssertEqual(plan.tileRects[0].maxX - plan.tileRects[1].minX, 288)
        XCTAssertEqual(plan.tileRects.last?.maxX, 14_568)
        XCTAssertEqual(plan.tileRects.last?.maxY, 2_723)
    }

    func testOrdinaryOCRPlanKeepsSingleImageProcessing() {
        let plan = OCRDocumentProcessor.imagePlan(width: 1_600, height: 1_200)

        XCTAssertFalse(plan.usesTiling)
        XCTAssertTrue(plan.tileRects.isEmpty)
    }

    func testOCRMergePrefersHigherConfidenceTileTextAndPreservesReadingOrder() {
        let observations = [
            OCRDocumentProcessor.PositionedObservation(
                text: "Groue CTO",
                confidence: 0.62,
                bounds: OCRBoundingBox(x: 100, y: 20, width: 180, height: 50),
                source: .overview
            ),
            OCRDocumentProcessor.PositionedObservation(
                text: "Head of Engineering",
                confidence: 0.91,
                bounds: OCRBoundingBox(x: 80, y: 180, width: 260, height: 60),
                source: .tile
            ),
            OCRDocumentProcessor.PositionedObservation(
                text: "Group CTO",
                confidence: 0.98,
                bounds: OCRBoundingBox(x: 102, y: 22, width: 176, height: 48),
                source: .tile
            ),
        ]

        XCTAssertEqual(
            OCRDocumentProcessor.mergedText(from: observations),
            "Group CTO\nHead of Engineering"
        )
    }

    func testPanoramicImageOCRUsesLosslessOverviewAndTiles() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("panorama.png")
        let width = 5_000
        let height = 800
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor.systemBlue.cgColor)
        for x in stride(from: 100, to: width, by: 400) {
            context.fill(CGRect(x: x, y: 200, width: 180, height: 80))
        }
        let image = try XCTUnwrap(context.makeImage())
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(
            using: .png,
            properties: [:]
        )).write(to: fileURL)
        let provider = RecordingOCRProvider()

        let text = await OCRDocumentProcessor.recognizeIfNeeded(
            url: fileURL,
            ext: "png",
            provider: provider
        )

        XCTAssertNotNil(text)
        XCTAssertEqual(provider.recordedCalls.count, 4)
        XCTAssertTrue(provider.recordedCalls.allSatisfy { $0.mimeType == "image/png" })
        XCTAssertTrue(provider.recordedCalls.allSatisfy {
            max($0.width, $0.height) <= 2_048
        })
    }

    func testUpdatingNoteIndexPreservesExistingDocumentChunks() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("contract.txt")
        try Data("body content remains indexed".utf8).write(to: fileURL)
        let fileID = try insertFile(at: fileURL)
        let embedder = StubEmbedder(result: [1, 0])
        let settings = AppSettings(store: store)
        let indexer = IndexerService(store: store, settings: settings, embedder: embedder)
        let initialReplaceSucceeded = await indexer.vectorStore.replace(
            fileId: fileID,
            chunks: [
                EmbeddingChunk(vector: [1, 0], text: "Contract", kind: .title),
                EmbeddingChunk(vector: [0, 1], text: "body content remains indexed", kind: .text),
            ],
            model: embedder.name
        )
        XCTAssertTrue(initialReplaceSucceeded)
        try store.updateFileNote(id: fileID, note: "Signed for the APAC rollout")

        let updated = await indexer.updateNoteIndex(
            fileID: fileID,
            note: "Signed for the APAC rollout"
        )

        XCTAssertTrue(updated)
        XCTAssertEqual(embedder.callCount, 1)
        XCTAssertEqual(embedder.embeddedTexts, ["User note: Signed for the APAC rollout"])
        let chunks = try store.documentChunks(fileID: fileID)
        XCTAssertEqual(chunks.filter { $0.kind == .title }.map(\.text), ["Contract"])
        XCTAssertEqual(chunks.filter { $0.kind == .text }.map(\.text), ["body content remains indexed"])
        XCTAssertEqual(chunks.filter { $0.kind == .note }.map(\.text), [
            "User note: Signed for the APAC rollout",
        ])
    }

    func testOCRProviderFailureTemporarilySkipsFollowingFiles() async throws {
        let first = temporaryDirectory.appendingPathComponent("first.png")
        let second = temporaryDirectory.appendingPathComponent("second.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let imageData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try imageData.write(to: first)
        try imageData.write(to: second)
        let provider = FailingOCRProvider()

        let firstText = await OCRDocumentProcessor.recognizeIfNeeded(
            url: first,
            ext: "png",
            provider: provider,
            forceImageOCR: true
        )
        let secondText = await OCRDocumentProcessor.recognizeIfNeeded(
            url: second,
            ext: "png",
            provider: provider,
            forceImageOCR: true
        )

        XCTAssertNil(firstText)
        XCTAssertNil(secondText)
        XCTAssertEqual(provider.callCount, 1)
    }

    func testChunkReturnsNoSegmentsForBlankOrInvalidInput() {
        XCTAssertEqual(IndexerService.chunk(text: "", maxWords: 200, overlap: 30), [])
        XCTAssertEqual(IndexerService.chunk(text: "  \n\t", maxWords: 200, overlap: 30), [])
        XCTAssertEqual(IndexerService.chunk(text: "content", maxWords: 0, overlap: 0), [])
    }

    func testFallbackContentChunksDoNotAppendOCRTwice() {
        let extracted = "Tron\nOnly Tron assets (TRC10/TRC20) are supported\nWallet address ABC123\nimToken"
        let ocr = "Only Tron assets (TRC10/TRC20) are supported\nWallet address ABC123"

        XCTAssertFalse(IndexerService.shouldAppendOCRText(ocr, to: extracted))
        let chunks = IndexerService.contentChunks(
            doclingChunks: nil,
            extractedText: extracted,
            appendedOCRText: ocr,
            maxTokens: 600
        )

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text, extracted)
    }

    func testDoclingContentChunksAppendOnlyPostProcessingOCR() {
        let docling = [StructuredDocumentChunk(
            text: "Embedded PDF text",
            sectionPath: ["Section"],
            pageStart: 1,
            pageEnd: 1
        )]

        let chunks = IndexerService.contentChunks(
            doclingChunks: docling,
            extractedText: "Embedded PDF text\nOCR scanned page",
            appendedOCRText: "OCR scanned page",
            maxTokens: 600
        )

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0], docling[0])
        XCTAssertEqual(chunks[1].text, "OCR scanned page")
    }

    func testDoclingPostProcessingRepairsSentenceSplitAcrossChunks() {
        let source = [
            StructuredDocumentChunk(
                text: "If the regulator reaches that conclusion, we would",
                contextualText: "Risk Factors\nIf the regulator reaches that conclusion, we would",
                sectionPath: ["Risk Factors"],
                pageStart: 10,
                pageEnd: 10
            ),
            StructuredDocumentChunk(
                text: "be identified as a covered issuer. The decision could affect our operations.",
                contextualText: "Risk Factors\nbe identified as a covered issuer. The decision could affect our operations.",
                sectionPath: ["Risk Factors"],
                pageStart: 10,
                pageEnd: 10
            ),
        ]

        let result = IndexerService.postProcessDoclingChunks(source, maxTokens: 600)

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].text.contains("we would be identified"))
        XCTAssertTrue(result[0].contextualText.hasPrefix("Risk Factors\n"))
        XCTAssertTrue(result[0].contextualText.hasSuffix(result[0].text))
    }

    func testDoclingPostProcessingMergesShortPeersWithinSameSection() {
        let chunks = [
            StructuredDocumentChunk(
                text: "Payment status",
                contextualText: "Invoice > Payment\nPayment status",
                sectionPath: ["Invoice", "Payment"],
                pageStart: 1,
                pageEnd: 1
            ),
            StructuredDocumentChunk(
                text: "Paid",
                contextualText: "Invoice > Payment\nPaid",
                sectionPath: ["Invoice", "Payment"],
                pageStart: 1,
                pageEnd: 1
            )
        ]

        let result = IndexerService.postProcessDoclingChunks(
            chunks,
            maxTokens: 600,
            minimumTokens: 80
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "Payment status\n\nPaid")
        XCTAssertEqual(result[0].sectionPath, ["Invoice", "Payment"])
        XCTAssertTrue(result[0].contextualText.contains("Invoice > Payment"))
    }

    func testDoclingPostProcessingDoesNotMergeAcrossSectionsOrTables() {
        let chunks = [
            StructuredDocumentChunk(text: "Yes", sectionPath: ["Eligibility"], pageStart: 1, kind: .text),
            StructuredDocumentChunk(text: "No", sectionPath: ["Refund"], pageStart: 1, kind: .text),
            StructuredDocumentChunk(text: "1", sectionPath: ["Refund"], pageStart: 1, kind: .table)
        ]

        let result = IndexerService.postProcessDoclingChunks(
            chunks,
            maxTokens: 600,
            minimumTokens: 80
        )

        XCTAssertEqual(result.map(\.text), ["Yes", "No", "1"])
    }

    func testDoclingPostProcessingAttachesShortTitleToFollowingContent() {
        let chunks = [
            StructuredDocumentChunk(
                text: "Payment Terms",
                sectionPath: ["Agreement"],
                pageStart: 2,
                kind: .title
            ),
            StructuredDocumentChunk(
                text: "The customer shall pay within thirty days.",
                sectionPath: ["Agreement", "Payment Terms"],
                pageStart: 2,
                kind: .text
            )
        ]

        let result = IndexerService.postProcessDoclingChunks(
            chunks,
            maxTokens: 600,
            minimumTokens: 80
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .text)
        XCTAssertEqual(result[0].text, "Payment Terms\n\nThe customer shall pay within thirty days.")
        XCTAssertEqual(result[0].sectionPath, ["Agreement", "Payment Terms"])
    }

    func testDoclingPostProcessingDropsOnlyUnambiguousNoise() {
        let chunks = [
            StructuredDocumentChunk(text: "---", pageStart: 1),
            StructuredDocumentChunk(text: "Page 12", pageStart: 12),
            StructuredDocumentChunk(text: "SGD 500", sectionPath: ["Amount"], pageStart: 12),
            StructuredDocumentChunk(text: "A", sectionPath: ["Status"], pageStart: 12)
        ]

        let result = IndexerService.postProcessDoclingChunks(
            chunks,
            maxTokens: 600,
            minimumTokens: 80
        )

        XCTAssertEqual(result.map(\.text), ["SGD 500", "A"])
    }

    @MainActor
    func testRebuildAllReportsRealPerFileProgress() async throws {
        let first = temporaryDirectory.appendingPathComponent("first.txt")
        let second = temporaryDirectory.appendingPathComponent("second.txt")
        try Data("first searchable document".utf8).write(to: first)
        try Data("second searchable document".utf8).write(to: second)
        _ = try insertFile(at: first)
        _ = try insertFile(at: second)
        let settings = AppSettings(store: store)
        let indexer = IndexerService(
            store: store,
            settings: settings,
            embedder: StubEmbedder(result: [1, 0])
        )
        var updates: [VectorIndexRebuildProgress] = []

        let succeeded = await indexer.rebuildAll(
            rebuildVectorSpace: true,
            forceReprocessing: true,
            progress: { updates.append($0) }
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(updates.first?.phase, .preparing)
        XCTAssertTrue(updates.contains { $0.phase == .clearing })
        XCTAssertTrue(updates.contains { $0.phase == .indexing && $0.currentFileName != nil })
        XCTAssertEqual(updates.last?.phase, .completed)
        XCTAssertEqual(updates.last?.completed, 2)
        XCTAssertEqual(updates.last?.total, 2)
        XCTAssertEqual(updates.last?.fraction, 1)
    }

    func testEmbeddingOnlyRebuildReusesStoredChunksWithoutReadingSourceFile() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("stored-chunks.txt")
        try Data("content that should only be extracted once".utf8).write(to: fileURL)
        let fileID = try insertFile(at: fileURL)
        let settings = AppSettings(store: store)
        let originalIndexer = IndexerService(
            store: store,
            settings: settings,
            embedder: StubEmbedder(result: [1, 0], name: "old-model")
        )
        let initialIndexSucceeded = await originalIndexer.indexFile(id: fileID)
        XCTAssertTrue(initialIndexSucceeded)
        let originalFile = try XCTUnwrap(store.file(id: fileID))
        let originalChunks = try store.allStoredDocumentChunks()[fileID]
        try FileManager.default.removeItem(at: fileURL)

        let replacementIndexer = IndexerService(
            store: store,
            settings: settings,
            embedder: StubEmbedder(result: [0, 1], name: "new-model")
        )
        let succeeded = await replacementIndexer.rebuildAll(rebuildVectorSpace: true)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(try store.distinctEmbeddingModels(), Set(["new-model"]))
        XCTAssertEqual(try store.allStoredDocumentChunks()[fileID], originalChunks)
        XCTAssertEqual(try store.file(id: fileID)?.contentHash, originalFile.contentHash)
    }

    func testEmbeddingRebuildCanAlsoIndexOnlyNewFiles() async throws {
        let existingURL = temporaryDirectory.appendingPathComponent("existing.txt")
        let newURL = temporaryDirectory.appendingPathComponent("new.txt")
        try Data("already indexed content".utf8).write(to: existingURL)
        try Data("new searchable content".utf8).write(to: newURL)
        let existingID = try insertFile(at: existingURL)
        let newID = try insertFile(at: newURL)
        let settings = AppSettings(store: store)
        let originalIndexer = IndexerService(
            store: store,
            settings: settings,
            embedder: StubEmbedder(result: [1, 0], name: "old-model")
        )
        let initialSucceeded = await originalIndexer.indexFile(id: existingID)
        XCTAssertTrue(initialSucceeded)
        XCTAssertNil(try store.file(id: newID)?.indexedAt)

        let replacementIndexer = IndexerService(
            store: store,
            settings: settings,
            embedder: StubEmbedder(result: [0, 1], name: "new-model")
        )
        let succeeded = await replacementIndexer.rebuildAll(
            rebuildVectorSpace: true,
            includeUnindexedFiles: true
        )

        XCTAssertTrue(succeeded)
        XCTAssertNotNil(try store.file(id: newID)?.indexedAt)
        XCTAssertEqual(try store.distinctEmbeddingModels(), Set(["new-model"]))
    }

    func testUnindexedOnlyRebuildLeavesIndexedFilesUntouched() async throws {
        let existingURL = temporaryDirectory.appendingPathComponent("existing-only-new.txt")
        let newURL = temporaryDirectory.appendingPathComponent("only-new.txt")
        try Data("stable old content".utf8).write(to: existingURL)
        try Data("brand new content".utf8).write(to: newURL)
        let existingID = try insertFile(at: existingURL)
        let newID = try insertFile(at: newURL)
        let embedder = StubEmbedder(result: [1, 0])
        let settings = AppSettings(store: store)
        let indexer = IndexerService(store: store, settings: settings, embedder: embedder)
        let initialSucceeded = await indexer.indexFile(id: existingID)
        XCTAssertTrue(initialSucceeded)
        let existingBefore = try XCTUnwrap(store.file(id: existingID))
        let callsBefore = embedder.callCount

        let succeeded = await indexer.rebuildAll(onlyUnindexedFiles: true)

        XCTAssertTrue(succeeded)
        XCTAssertGreaterThan(embedder.callCount, callsBefore)
        XCTAssertEqual(try store.file(id: existingID)?.contentHash, existingBefore.contentHash)
        XCTAssertNotNil(try store.file(id: newID)?.indexedAt)
    }

    func testFailedEmbeddingOnlyRebuildKeepsPreviousVectorSpace() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("atomic-rebuild.txt")
        try Data("keep the old vectors until replacement succeeds".utf8).write(to: fileURL)
        let fileID = try insertFile(at: fileURL)
        let settings = AppSettings(store: store)
        let originalIndexer = IndexerService(
            store: store,
            settings: settings,
            embedder: StubEmbedder(result: [1, 0], name: "old-model")
        )
        let initialIndexSucceeded = await originalIndexer.indexFile(id: fileID)
        XCTAssertTrue(initialIndexSucceeded)
        let originalChunks = try store.allStoredDocumentChunks()[fileID]

        let failingIndexer = IndexerService(
            store: store,
            settings: settings,
            embedder: StubEmbedder(result: [], name: "new-model")
        )
        let succeeded = await failingIndexer.rebuildAll(rebuildVectorSpace: true)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(try store.distinctEmbeddingModels(), Set(["old-model"]))
        XCTAssertEqual(try store.allStoredDocumentChunks()[fileID], originalChunks)
    }

    func testFailedFullRebuildKeepsPreviousChunksVectorsAndMetadata() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("atomic-full-rebuild.txt")
        try Data("content from the active generation".utf8).write(to: fileURL)
        let fileID = try insertFile(at: fileURL)
        let settings = AppSettings(store: store)
        let originalIndexer = IndexerService(
            store: store,
            settings: settings,
            embedder: StubEmbedder(result: [1, 0], name: "old-model")
        )
        let initialIndexSucceeded = await originalIndexer.indexFile(id: fileID)
        XCTAssertTrue(initialIndexSucceeded)
        let originalFile = try XCTUnwrap(store.file(id: fileID))
        let originalChunks = try XCTUnwrap(store.allStoredDocumentChunks()[fileID])

        try Data("changed content that must not leak from a failed rebuild".utf8).write(to: fileURL)
        let failingIndexer = IndexerService(
            store: store,
            settings: settings,
            embedder: StubEmbedder(result: [], name: "new-model")
        )
        let succeeded = await failingIndexer.rebuildAll(
            rebuildVectorSpace: true,
            forceReprocessing: true
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(try store.distinctEmbeddingModels(), Set(["old-model"]))
        XCTAssertEqual(try store.allStoredDocumentChunks()[fileID], originalChunks)
        let preservedFile = try XCTUnwrap(store.file(id: fileID))
        XCTAssertEqual(preservedFile.contentHash, originalFile.contentHash)
        XCTAssertEqual(preservedFile.indexSignature, originalFile.indexSignature)
        XCTAssertEqual(preservedFile.indexedAt, originalFile.indexedAt)
    }

    func testIndexingExecutionGatePausesResumesAndStops() async throws {
        let gate = IndexingExecutionGate()
        await gate.pause()
        let startedAt = Date()
        let waiting = Task { await gate.waitUntilRunnable() }

        try await Task.sleep(nanoseconds: 120_000_000)
        await gate.resume()

        let didResume = await waiting.value
        XCTAssertTrue(didResume)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), 0.10)

        await gate.stop()
        let didRunAfterStop = await gate.waitUntilRunnable()
        XCTAssertFalse(didRunAfterStop)
    }

    @MainActor
    func testRebuildAllReportsStoppedWhenCheckpointRejectsWork() async throws {
        let fileURL = temporaryDirectory.appendingPathComponent("stopped.txt")
        try Data("should not be indexed".utf8).write(to: fileURL)
        _ = try insertFile(at: fileURL)
        let gate = IndexingExecutionGate()
        await gate.stop()
        let indexer = IndexerService(
            store: store,
            settings: AppSettings(store: store),
            embedder: StubEmbedder(result: [1, 0])
        )
        var updates: [VectorIndexRebuildProgress] = []

        let succeeded = await indexer.rebuildAll(
            checkpoint: { await gate.waitUntilRunnable() },
            progress: { updates.append($0) }
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(updates.last?.phase, .stopped)
        XCTAssertEqual(updates.last?.completed, 0)
        XCTAssertEqual(indexer.vectorStore.count, 0)
    }

    func testChunkUsesWholeSentenceOverlap() {
        let chunks = IndexerService.chunk(
            text: "Alpha beta. Gamma delta. Epsilon zeta. Eta theta.",
            maxWords: 8,
            overlap: 4
        )

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks[0].hasSuffix("Gamma delta."))
        XCTAssertTrue(chunks[1].hasPrefix("Gamma delta."))
    }

    func testChunkKeepsCompleteParagraphsWheneverTheyFit() {
        let first = "The first paragraph contains complete business context."
        let second = "The second paragraph must remain an indivisible semantic unit."
        let third = "The third paragraph closes the example."
        let text = [first, second, third].joined(separator: "\n\n")

        let chunks = IndexerService.chunk(text: text, maxWords: 12, overlap: 0)

        XCTAssertEqual(chunks, [first, second, third])
    }

    func testChunkSplitsOversizedParagraphOnlyBetweenCompleteSentences() {
        let sentences = [
            "Revenue increased during the reporting period.",
            "Operating expenses remained carefully controlled.",
            "Management expects the trend to continue.",
        ]
        let chunks = IndexerService.chunk(
            text: sentences.joined(separator: " "),
            maxWords: 12,
            overlap: 0
        )

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(separator: " "), sentences.joined(separator: " "))
        XCTAssertTrue(chunks.allSatisfy { chunk in
            sentences.contains(chunk) || sentences.contains { chunk.contains($0) }
        })
    }

    func testChunkNeverSplitsAWordOrAnOversizedSingleSentence() {
        let sentence = "Supercalifragilisticexpialidocious remains one complete lexical unit."

        let chunks = IndexerService.chunk(text: sentence, maxWords: 2, overlap: 1)

        XCTAssertEqual(chunks, [sentence])
    }

    func testEmergencyOversizedSentenceFallbackKeepsEveryWordWhole() {
        let words = (0..<120).map { "accountingTerm\($0)" }
        let chunks = IndexerService.chunk(
            text: words.joined(separator: " "),
            maxWords: 64,
            overlap: 10
        )
        let validWords = Set(words)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { chunk in
            chunk.split(separator: " ").allSatisfy { validWords.contains(String($0)) }
        })
    }

    func testRetrievalChildrenKeepTheCompleteParentSection() {
        let parentText = (0..<400).map { "term\($0)" }.joined(separator: " ")
        let children = IndexerService.retrievalChildren(
            from: [StructuredDocumentChunk(
                text: parentText,
                contextualText: "Invoices\n" + parentText,
                sectionPath: ["Invoices"]
            )],
            targetTokens: 80,
            overlapTokens: 12
        )

        XCTAssertGreaterThan(children.count, 1)
        XCTAssertTrue(children.allSatisfy { $0.parentIndex == 0 })
        XCTAssertTrue(children.allSatisfy { $0.parentText == parentText })
        XCTAssertTrue(children.allSatisfy { $0.contextualText.hasPrefix("Invoices\n") })
    }

    func testTableRetrievalChildrenRepeatHeaderRows() {
        let rows = ["Invoice | Amount"] + (0..<80).map { "INV-2026-\($0) | SGD \($0).00" }
        let children = IndexerService.retrievalChildren(
            from: [StructuredDocumentChunk(text: rows.joined(separator: "\n"), kind: .table)],
            targetTokens: 80,
            overlapTokens: 0
        )

        XCTAssertGreaterThan(children.count, 1)
        XCTAssertTrue(children.allSatisfy { $0.text.hasPrefix("Invoice | Amount\n") })
    }

    func testEntityExtractionFindsBusinessIdentifiers() {
        let terms = IndexerService.extractedEntityTerms(
            from: "Invoice INV-20250377 was issued on 2026-07-17 for SGD 1,240.50 to finance@example.com."
        )

        XCTAssertTrue(terms.contains("inv-20250377"))
        XCTAssertTrue(terms.contains("2026-07-17"))
        XCTAssertTrue(terms.contains("sgd 1,240.50"))
        XCTAssertTrue(terms.contains("finance@example.com"))
    }

    private func insertFile(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try store.upsertFile(FileRecord(
            id: nil,
            path: url.path,
            name: url.lastPathComponent,
            ext: url.pathExtension,
            size: Int64((attributes[.size] as? NSNumber)?.intValue ?? 0),
            mtime: (attributes[.modificationDate] as? Date) ?? Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: temporaryDirectory.path,
            indexedAt: nil,
            contentHash: nil,
            title: nil,
            contentText: nil
        ))
    }

    private func waitUntil(timeout: TimeInterval = 5,
                           condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
