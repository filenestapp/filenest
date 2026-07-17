import XCTest
@testable import FileNest

final class ChatServiceTests: XCTestCase {
    func testTokenEstimatorHandlesEnglishAndCJKText() {
        XCTAssertEqual(ChatService.estimatedTokens(in: "hello world"), 3)
        XCTAssertEqual(ChatService.estimatedTokens(in: "\u{4E2D}\u{6587}\u{6D4B}\u{8BD5}"), 3)
        XCTAssertEqual(ChatService.estimatedTokens(in: "one two three"), 4)
        XCTAssertEqual(ChatService.estimatedTokens(in: "\u{4E00}\u{4E8C}\u{4E09}\u{56DB}\u{4E94}\u{516D}"), 4)
        XCTAssertEqual(ChatService.estimatedTokens(in: ""), 0)
    }

    func testContextPlannerKeepsCompleteHistoryWhenItFitsModelWindow() {
        let history = [
            ChatTurn(role: .user, content: "Find the contract"),
            ChatTurn(role: .assistant, content: "Which contract do you mean?"),
            ChatTurn(role: .user, content: "The one downloaded yesterday"),
        ]

        let plan = ChatContextPlanner.plan(
            history: history,
            context: "A short retrieval context",
            contextWindowTokens: 32_768,
            thinkingEnabled: false
        )

        XCTAssertEqual(plan.turns.count, history.count)
        XCTAssertEqual(plan.compressedTurnCount, 0)
        XCTAssertEqual(plan.turns.last?.content, history.last?.content)
        XCTAssertLessThanOrEqual(plan.estimatedInputTokens, plan.inputBudgetTokens)
    }

    func testContextPlannerCompressesOldTurnsAndAlwaysKeepsLatestQuestion() {
        var history = [ChatTurn]()
        for index in 0..<30 {
            history.append(ChatTurn(
                role: .user,
                content: "old question \(index) " + String(repeating: "detail ", count: 100)
            ))
            history.append(ChatTurn(
                role: .assistant,
                content: "old answer \(index) " + String(repeating: "result ", count: 100)
            ))
        }
        let latestQuestion = "This is the current question and it must remain intact."
        history.append(ChatTurn(role: .user, content: latestQuestion))

        let plan = ChatContextPlanner.plan(
            history: history,
            context: String(repeating: "retrieved evidence ", count: 600),
            contextWindowTokens: 4_096,
            thinkingEnabled: true
        )

        XCTAssertGreaterThan(plan.compressedTurnCount, 0)
        XCTAssertEqual(plan.turns.first?.role, .system)
        XCTAssertEqual(plan.turns.last?.content, latestQuestion)
        XCTAssertLessThanOrEqual(plan.estimatedInputTokens, plan.inputBudgetTokens)
    }

    func testContextPlannerTrimsRetrievalContextWithinSharedBudget() {
        let originalContext = String(repeating: "large document evidence ", count: 5_000)
        let plan = ChatContextPlanner.plan(
            history: [ChatTurn(role: .user, content: "Summarize this")],
            context: originalContext,
            contextWindowTokens: 4_096,
            thinkingEnabled: false
        )

        XCTAssertLessThan(plan.context.count, originalContext.count)
        XCTAssertLessThanOrEqual(plan.estimatedInputTokens, plan.inputBudgetTokens)
    }

    func testModelContextCatalogUsesKnownCloudWindowsAnd612KFallback() {
        XCTAssertEqual(
            ChatModelContextWindowCatalog.cloudContextWindow(model: "gpt-4o-mini", format: "openai"),
            128_000
        )
        XCTAssertEqual(
            ChatModelContextWindowCatalog.cloudContextWindow(model: "claude-sonnet-4", format: "anthropic"),
            200_000
        )
        XCTAssertEqual(
            ChatModelContextWindowCatalog.cloudContextWindow(model: "custom-model", format: "openai"),
            612_000
        )
    }

    func testManualContextWindowOverridesAutomaticModelValue() async {
        let resolver = ChatModelContextWindowResolver()

        let automatic = await resolver.resolve(.fallback)
        let overridden = await resolver.resolve(.fallback, overrideTokens: 96_000)

        XCTAssertEqual(automatic, 612_000)
        XCTAssertEqual(overridden, 96_000)
    }

    private final class FailingEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name = "failing"
        let dimension = 2

        func embed(_ text: String) async throws -> [Float] {
            throw URLError(.cannotConnectToHost)
        }
    }

    private final class SuccessfulEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name = "successful"
        let dimension = 2

        func embed(_ text: String) async throws -> [Float] { [1, 0] }
    }

    private final class CountingEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name = "counting"
        let dimension = 2
        private let lock = NSLock()
        private var storedCallCount = 0

        var callCount: Int {
            lock.withLock { storedCallCount }
        }

        func embed(_ text: String) async throws -> [Float] {
            lock.withLock { storedCallCount += 1 }
            return [1, 0]
        }
    }

    private final class RecordingEmbedder: EmbeddingProvider, @unchecked Sendable {
        let name = "recording"
        let dimension = 2
        private let lock = NSLock()
        private var storedTexts = [String]()

        var texts: [String] { lock.withLock { storedTexts } }

        func embed(_ text: String) async throws -> [Float] {
            lock.withLock { storedTexts.append(text) }
            return [1, 0]
        }
    }

    private final class StubVectorStore: VectorStore, @unchecked Sendable {
        let hits: [(fileId: Int64, score: Float)]
        var count: Int { hits.count }

        init(hits: [(fileId: Int64, score: Float)]) { self.hits = hits }

        func replace(fileId: Int64, chunks: [EmbeddingChunk], model: String) async -> Bool { false }
        func remove(fileId: Int64) async {}
        func search(_ query: [Float], k: Int) async -> [(fileId: Int64, score: Float)] {
            Array(hits.prefix(k))
        }
        func loadAll() async {}
    }

    private final class StubChunkVectorStore: VectorStore, @unchecked Sendable {
        let hit: VectorSearchHit
        let neighbors: [VectorSearchHit]
        var count: Int { 1 }

        init(fileId: Int64, chunk: String, neighbors: [VectorSearchHit] = []) {
            hit = VectorSearchHit(
                fileId: fileId,
                score: 0.95,
                chunkText: chunk,
                chunkIndex: 1,
                sectionPath: ["Contract", "Renewal"],
                pageStart: 7,
                pageEnd: 7
            )
            self.neighbors = neighbors
        }

        func replace(fileId: Int64, chunks: [EmbeddingChunk], model: String) async -> Bool { false }
        func remove(fileId: Int64) async {}
        func search(_ query: [Float], k: Int) async -> [(fileId: Int64, score: Float)] {
            [(hit.fileId, hit.score)]
        }
        func searchChunks(_ query: [Float], k: Int) async -> [VectorSearchHit] { [hit] }
        func neighboringChunks(fileId: Int64,
                               around chunkIndex: Int,
                               radius: Int) async -> [VectorSearchHit] { neighbors }
        func loadAll() async {}
    }

    private final class StubLLMProvider: LLMProvider, @unchecked Sendable {
        let name = "stub"

        func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
            "stub reply"
        }
    }

    private final class SmartSearchLLMProvider: LLMProvider, @unchecked Sendable {
        let name = "smart-search-stub"
        let response: String

        init(response: String) {
            self.response = response
        }

        func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
            response
        }
    }

    private final class StreamingSearchIntentLLMProvider: LLMProvider, @unchecked Sendable {
        let name = "streaming-search-intent-stub"

        func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
            "answer"
        }

        func streamChat(
            _ messages: [ChatTurn],
            context: String?
        ) -> AsyncThrowingStream<String, Error> {
            let isPlanningRequest = messages.first?.content.contains(#""intent""#) == true
            return AsyncThrowingStream { continuation in
                if isPlanningRequest {
                    continuation.yield(#"{"intent":"Find June "#)
                    continuation.yield(#"invoices and prioritize the newest files","semantic_query":"invoice payment details","keywords":["INV-42"],"categories":["documents"],"date_from":"2026-06-01","date_to":"2026-06-30","sort":"newest"}"#)
                } else {
                    continuation.yield("answer")
                }
                continuation.finish()
            }
        }
    }

    private final class StreamingLLMProvider: LLMProvider, @unchecked Sendable {
        let name = "streaming-stub"
        private let lock = NSLock()
        private var storedContexts: [String] = []

        var contexts: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storedContexts
        }

        func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
            "first second"
        }

        func streamChat(_ messages: [ChatTurn], context: String?) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            storedContexts.append(context ?? "")
            lock.unlock()
            return AsyncThrowingStream { continuation in
                continuation.yield("first ")
                continuation.yield("second")
                continuation.finish()
            }
        }
    }

    private final class FailingLLMProvider: LLMProvider, @unchecked Sendable {
        let name = "failing-cloud"

        func chat(_ messages: [ChatTurn], context: String?) async throws -> String {
            throw URLError(.cannotConnectToHost)
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

    func testEmbeddingFailureFallsBackToKeywordSearchAndPersistsReference() async throws {
        let matchingId = try insertFile(named: "agreement.pdf", title: "Annual contract")
        _ = try insertFile(named: "photo.jpg", title: "Travel photo")
        let chat = makeChatService()

        let response = await chat.ask("contract")

        XCTAssertEqual(response.content, "stub reply")
        XCTAssertEqual(response.relatedFiles.map(\.id), [matchingId])
        let ids = try decodeRelatedIds(response)
        XCTAssertEqual(ids, [matchingId])

        let history = chat.loadHistory()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.last?.relatedFiles.map(\.id), [matchingId])
    }

    func testKeywordFallbackUsesDefaultTenFileLimit() async throws {
        for index in 0..<12 {
            _ = try insertFile(named: "contract-\(index).txt", title: "Contracts \(index)")
        }
        let chat = makeChatService()

        let response = await chat.ask("contract")

        XCTAssertEqual(response.relatedFiles.count, 10)
        XCTAssertEqual(try decodeRelatedIds(response).count, 10)
    }

    func testConfiguredRAGFileLimitControlsReturnedContext() async throws {
        for index in 0..<7 {
            _ = try insertFile(named: "report-\(index).txt", title: "Report \(index)")
        }
        let settings = AppSettings(store: store)
        settings.setRAGResultLimit(3)
        let chat = makeChatService(settings: settings)

        let response = await chat.ask("Report")

        XCTAssertEqual(response.relatedFiles.count, 3)
        XCTAssertEqual(try decodeRelatedIds(response).count, 3)
    }

    func testEmptySemanticResultsFallBackToKeywordSearch() async throws {
        let matchingId = try insertFile(named: "agreement.pdf", title: "Annual contract")
        let chat = makeChatService(
            embedder: SuccessfulEmbedder(),
            vectorStore: StubVectorStore(hits: [])
        )

        let response = await chat.ask("contract")

        XCTAssertEqual(response.relatedFiles.compactMap(\.id), [matchingId])
    }

    func testDirectTitleMatchIsMergedAheadOfSemanticOnlyMatch() async throws {
        let semanticId = try insertFile(named: "semantic.pdf", title: "Semantic result")
        let directMatchID = try insertFile(named: "agreement.pdf", title: "Annual contract")
        let chat = makeChatService(
            embedder: SuccessfulEmbedder(),
            vectorStore: StubVectorStore(hits: [(semanticId, 0.9)])
        )

        let response = await chat.ask("contract")

        XCTAssertEqual(response.relatedFiles.compactMap(\.id), [directMatchID, semanticId])
    }

    func testSemanticFilesAreSortedByHighestSimilarity() async throws {
        let lowerScoreID = try insertFile(named: "possible.pdf", title: "Possible result")
        let highestScoreID = try insertFile(named: "exact.pdf", title: "Exact result")
        let chat = makeChatService(
            embedder: SuccessfulEmbedder(),
            vectorStore: StubVectorStore(hits: [
                (lowerScoreID, 0.62),
                (highestScoreID, 0.97),
                (lowerScoreID, 0.55),
            ])
        )

        let response = await chat.ask("exact result")

        XCTAssertEqual(response.relatedFiles.compactMap(\.id), [highestScoreID, lowerScoreID])
    }

    func testRecentInvoiceQueryExpandsChineseTermAndRanksNewestRelevantFileFirst() async throws {
        let olderID = try insertFile(
            named: "invoice209.pdf",
            title: "Invoice 209",
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            contentText: "Invoice date May 18, 2024"
        )
        let newestID = try insertFile(
            named: "INV-20250377.pdf",
            title: "INV-20250377",
            mtime: Date(timeIntervalSince1970: 1_800_000_000),
            contentText: "INVOICE Invoice Date 08 Apr 2026"
        )
        let contentOnlyID = try insertFile(
            named: "recent-rfi.docx",
            title: "Recent RFI",
            mtime: Date(timeIntervalSince1970: 1_900_000_000),
            contentText: "Payment terms may refer to a future invoice."
        )
        let chat = makeChatService(
            embedder: SuccessfulEmbedder(),
            vectorStore: StubVectorStore(hits: [(olderID, 0.99)])
        )

        let response = await chat.ask("Find the ten most recent invoices")

        XCTAssertEqual(response.relatedFiles.compactMap(\.id).first, newestID)
        XCTAssertTrue(response.relatedFiles.compactMap(\.id).contains(olderID))
        XCTAssertTrue(response.relatedFiles.compactMap(\.id).contains(contentOnlyID))
        XCTAssertTrue(ChatService.relevanceTerms(in: "Find the ten most recent invoices").contains("invoice"))
        XCTAssertTrue(ChatService.prefersRecentFiles(in: "Find the ten most recent invoices"))

        let fallbackResponse = await makeChatService(embedder: FailingEmbedder())
            .ask("Find the ten most recent invoices")
        XCTAssertEqual(fallbackResponse.relatedFiles.compactMap(\.id).first, newestID)
    }

    func testLibrarySearchPromotesExplicitRequestedYearOverHigherSemanticScore() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let year2024 = calendar.date(from: DateComponents(year: 2024, month: 6, day: 4))!
        let year2026 = calendar.date(from: DateComponents(year: 2026, month: 4, day: 8))!
        let olderID = try insertFile(
            named: "generic-old.pdf",
            title: "Billing statement",
            mtime: year2024
        )
        let requestedYearID = try insertFile(
            named: "generic-new.pdf",
            title: "Billing statement",
            mtime: year2026
        )
        let chat = makeChatService(
            embedder: SuccessfulEmbedder(),
            vectorStore: StubVectorStore(hits: [
                (olderID, 0.99),
                (requestedYearID, 0.61),
            ])
        )

        let results = await chat.searchLibrary("Invoices from 2026")

        XCTAssertEqual(results.first?.file.id, requestedYearID)
        XCTAssertEqual(ChatService.requestedYears(in: "Invoices from 2026"), [2026])
        XCTAssertTrue(ChatService.requestedYears(in: "INV-20250377").isEmpty)
    }

    func testRelativeDateIntentParsesChineseAndEnglishCalendarRanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 10))!

        let thisYear = try XCTUnwrap(ChatService.relativeDateIntent(
            in: "Invoices from this year",
            now: now,
            calendar: calendar
        ))
        XCTAssertEqual(thisYear.interval.start, calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        XCTAssertEqual(thisYear.contentYears, [2026])

        let yesterday = try XCTUnwrap(ChatService.relativeDateIntent(
            in: "files modified yesterday",
            now: now,
            calendar: calendar
        ))
        XCTAssertTrue(yesterday.contains(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 15, hour: 23
        ))!))
        XCTAssertFalse(yesterday.contains(now))

        let lastMonth = try XCTUnwrap(ChatService.relativeDateIntent(
            in: "Documents from last month",
            now: now,
            calendar: calendar
        ))
        XCTAssertEqual(lastMonth.interval.start, calendar.date(from: DateComponents(year: 2026, month: 6, day: 1)))
        XCTAssertEqual(lastMonth.interval.end, calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
    }

    func testLibrarySearchPromotesRelativeDateMatchOverHigherSemanticScore() async throws {
        let calendar = Calendar.current
        let now = Date()
        let thisMonth = try XCTUnwrap(calendar.dateInterval(of: .month, for: now))
        let lastMonthDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: thisMonth.start))
        let outsideDate = try XCTUnwrap(calendar.date(byAdding: .month, value: -2, to: thisMonth.start))
        let outsideID = try insertFile(
            named: "outside-period.pdf",
            title: "Billing statement",
            mtime: outsideDate
        )
        let lastMonthID = try insertFile(
            named: "last-month.pdf",
            title: "Billing statement",
            mtime: lastMonthDate
        )
        let chat = makeChatService(
            embedder: SuccessfulEmbedder(),
            vectorStore: StubVectorStore(hits: [
                (outsideID, 0.99),
                (lastMonthID, 0.61),
            ])
        )

        let results = await chat.searchLibrary("Invoices from last month")

        XCTAssertEqual(results.first?.file.id, lastMonthID)
    }

    func testRelativeDateOnlySearchRecallsFilesWithoutKeywordOrVectorMatches() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .hour, value: -12, to: today))
        let todayFileID = try insertFile(
            named: "today-generic.pdf",
            title: "Unrelated material",
            mtime: today
        )
        let yesterdayFileID = try insertFile(
            named: "older-generic.pdf",
            title: "Unrelated material",
            mtime: yesterday
        )
        let chat = makeChatService(embedder: FailingEmbedder())

        let results = await chat.searchLibrary("Files from yesterday")

        XCTAssertEqual(results.map(\.file.id), [yesterdayFileID])
        XCTAssertFalse(results.map(\.file.id).contains(todayFileID))
        XCTAssertEqual(results.first?.matchKind, .date)
        XCTAssertTrue(ChatService.isRelativeDateOnlyQuery("Files from yesterday"))
        XCTAssertFalse(ChatService.isRelativeDateOnlyQuery("Invoices from yesterday"))
    }

    func testSmartSearchUsesAIPlanForVectorQueryAndExactMetadataFilters() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let matchingDate = calendar.date(from: DateComponents(year: 2026, month: 6, day: 18))!
        let outsideDate = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20))!
        let matchingID = try insertFile(
            named: "matching.pdf",
            title: "Unrelated title",
            mtime: matchingDate,
            contentText: "Invoice INV-42 payment details"
        )
        let outsideID = try insertFile(
            named: "outside.pdf",
            title: "Invoice INV-42",
            mtime: outsideDate
        )
        let provider = SmartSearchLLMProvider(response: """
        {
          "semantic_query": "invoice payment details",
          "keywords": ["INV-42"],
          "categories": ["documents"],
          "date_from": "2026-06-01",
          "date_to": "2026-06-30",
          "sort": "newest"
        }
        """)
        let embedder = RecordingEmbedder()
        let chat = makeChatService(
            embedder: embedder,
            vectorStore: StubVectorStore(hits: [
                (outsideID, 0.99),
                (matchingID, 0.61),
            ]),
            llmProvider: provider
        )

        let response = await chat.smartSearchLibrary("Find the June INV-42 invoice")

        XCTAssertTrue(response.usedAI)
        XCTAssertEqual(response.plan.semanticQuery, "invoice payment details")
        XCTAssertEqual(response.plan.keywords, ["INV-42"])
        XCTAssertEqual(response.plan.categories, [.documents])
        XCTAssertEqual(embedder.texts.last, "invoice payment details")
        XCTAssertEqual(response.results.map(\.file.id), [matchingID])
    }

    func testSmartSearchFallsBackToLocalPlanWhenAIResponseIsInvalid() async throws {
        let matchingID = try insertFile(
            named: "invoice.pdf",
            title: "Invoice",
            contentText: "invoice payment"
        )
        let chat = makeChatService(
            embedder: FailingEmbedder(),
            llmProvider: SmartSearchLLMProvider(response: "not json")
        )

        let response = await chat.smartSearchLibrary("Find invoice")

        XCTAssertFalse(response.usedAI)
        XCTAssertTrue(response.plan.keywords.contains("invoice"))
        XCTAssertEqual(response.results.first?.file.id, matchingID)
    }

    func testSmartSearchStreamsUserFacingIntentWhileBuildingPlan() async throws {
        let chat = makeChatService(llmProvider: StreamingSearchIntentLLMProvider())
        var intentUpdates = [String]()

        let response = await chat.smartSearchLibrary(
            "Find the June INV-42 invoice",
            onIntentUpdate: { intentUpdates.append($0) }
        )

        XCTAssertEqual(intentUpdates, [
            "Find June ",
            "Find June invoices and prioritize the newest files",
        ])
        XCTAssertTrue(response.usedAI)
        XCTAssertEqual(response.plan.semanticQuery, "invoice payment details")
        XCTAssertEqual(response.plan.keywords, ["INV-42"])
        XCTAssertTrue(response.plan.sortNewestFirst)
    }

    func testFindWithChatStreamsSearchIntentThroughPlanningProgress() async throws {
        let chat = makeChatService(llmProvider: StreamingSearchIntentLLMProvider())
        let session = try XCTUnwrap(chat.createSession())
        let sessionID = try XCTUnwrap(session.id)
        var intentUpdates = [String]()
        var completed: ChatMessage?

        for await update in chat.streamAnswer(
            "Find the June INV-42 invoice",
            sessionId: sessionID,
            attachedFilePath: nil
        ) {
            if case let .progress(progress) = update,
               progress.phase == .planningSearch,
               !progress.searchIntent.isEmpty {
                intentUpdates.append(progress.searchIntent)
            }
            if case let .completed(message) = update { completed = message }
        }

        XCTAssertEqual(intentUpdates, [
            "Find June ",
            "Find June invoices and prioritize the newest files",
        ])
        XCTAssertEqual(completed?.content, "answer")
    }

    func testFindWithChatReusesSmartPlanForVectorQueryAndFilters() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let matchingDate = calendar.date(from: DateComponents(year: 2026, month: 6, day: 18))!
        let outsideDate = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20))!
        let matchingID = try insertFile(
            named: "matching.pdf",
            title: "Unrelated title",
            mtime: matchingDate,
            contentText: "Invoice INV-42 payment details"
        )
        let outsideID = try insertFile(
            named: "outside.pdf",
            title: "Invoice INV-42",
            mtime: outsideDate
        )
        let provider = SmartSearchLLMProvider(response: """
        {
          "semantic_query": "invoice payment details",
          "keywords": ["INV-42"],
          "categories": ["documents"],
          "date_from": "2026-06-01",
          "date_to": "2026-06-30",
          "sort": "newest"
        }
        """)
        let embedder = RecordingEmbedder()
        let chat = makeChatService(
            embedder: embedder,
            vectorStore: StubVectorStore(hits: [
                (outsideID, 0.99),
                (matchingID, 0.61),
            ]),
            llmProvider: provider
        )

        let response = await chat.ask("Find the June INV-42 invoice")

        XCTAssertEqual(embedder.texts, ["invoice payment details"])
        XCTAssertEqual(response.relatedFiles.compactMap(\.id), [matchingID])
    }

    func testDistinctiveFilenameMatchOutranksTranscriptMention() async throws {
        let transcriptID = try insertFile(named: "_chat.txt", title: "WhatsApp chat history")
        let documentID = try insertFile(
            named: "00000394-SNH9727U.pdf",
            title: "VEP Registration Confirmation Slip"
        )
        let chat = makeChatService(
            embedder: SuccessfulEmbedder(),
            vectorStore: StubVectorStore(hits: [
                (transcriptID, 0.98),
                (documentID, 0.87),
            ])
        )

        let response = await chat.ask("Where is the VEP file for SNH9727U?")

        XCTAssertEqual(response.relatedFiles.compactMap(\.id), [documentID, transcriptID])
    }

    func testLibrarySearchCombinesFileKeywordsAndSemanticChunks() async throws {
        let semanticID = try insertFile(named: "meeting-notes.pdf", title: "Weekly notes")
        let exactID = try insertFile(named: "SNH9727U.pdf", title: "Vehicle registration")
        let chat = makeChatService(
            embedder: SuccessfulEmbedder(),
            vectorStore: StubVectorStore(hits: [
                (semanticID, 0.99),
                (exactID, 0.72),
            ])
        )

        let results = await chat.searchLibrary("SNH9727U")

        XCTAssertEqual(results.map(\.file.id), [exactID, semanticID])
        XCTAssertEqual(results.first?.matchKind, .hybrid)
        XCTAssertEqual(results.last?.matchKind, .semantic)
    }

    func testLibrarySearchReturnsSemanticChunkSnippetAndLocation() async throws {
        let fileID = try insertFile(named: "contract.pdf", title: "Service agreement")
        let chat = makeChatService(
            embedder: SuccessfulEmbedder(),
            vectorStore: StubChunkVectorStore(
                fileId: fileID,
                chunk: "The subscription renews automatically every twelve months."
            )
        )

        let results = await chat.searchLibrary("automatic renewal")
        let result = try XCTUnwrap(results.first)

        XCTAssertEqual(result.file.id, fileID)
        XCTAssertEqual(result.matchKind, .semantic)
        XCTAssertTrue(result.snippet?.contains("renews automatically") == true)
        XCTAssertEqual(result.sectionPath, ["Contract", "Renewal"])
        XCTAssertEqual(result.pageStart, 7)
    }

    func testLibrarySearchFallsBackToFileLevelContentWhenEmbeddingFails() async throws {
        let matchingID = try insertFile(
            named: "generic.txt",
            title: "Unrelated title",
            contentText: "Project heliotrope launch plan"
        )
        _ = try insertFile(named: "unrelated.txt", title: "Other material")
        let chat = makeChatService(embedder: FailingEmbedder())

        let results = await chat.searchLibrary("heliotrope")

        XCTAssertEqual(results.map(\.file.id), [matchingID])
        XCTAssertEqual(results.first?.matchKind, .content)
        XCTAssertTrue(results.first?.snippet?.contains("heliotrope") == true)
    }

    func testLibrarySearchMatchesSeparatedTermsInsideContentWithoutTitleMatch() async throws {
        let matchingID = try insertFile(
            named: "generic-invoice.pdf",
            title: "Unrelated title",
            contentText: "Remittance must be sent to the finance team after approval."
        )
        _ = try insertFile(
            named: "other.pdf",
            title: "Operations handbook",
            contentText: "No payment instructions are present."
        )
        let chat = makeChatService(embedder: FailingEmbedder())

        let results = await chat.searchLibrary("remittance finance")

        XCTAssertEqual(results.map(\.file.id), [matchingID])
        XCTAssertEqual(results.first?.matchKind, .content)
        XCTAssertTrue(results.first?.snippet?.contains("Remittance") == true)
    }

    func testLibrarySearchConfidenceRanksContentBeforeNoteAndTitle() async throws {
        let contentID = try insertFile(
            named: "content-source.pdf",
            title: "Project archive",
            contentText: "Heliotrope launch details"
        )
        let noteID = try insertFile(
            named: "note-source.pdf",
            title: "Reference material",
            contentText: "Unrelated body text",
            note: "Heliotrope follow-up"
        )
        let titleID = try insertFile(
            named: "title-source.pdf",
            title: "Heliotrope overview",
            contentText: "Unrelated body text"
        )
        let chat = makeChatService(embedder: FailingEmbedder())

        let results = await chat.searchLibrary("heliotrope")

        XCTAssertEqual(results.map(\.file.id), [contentID, noteID, titleID])
        XCTAssertEqual(results.map(\.matchKind), [.content, .note, .title])
        XCTAssertGreaterThan(results[0].confidence, results[1].confidence)
        XCTAssertGreaterThan(results[1].confidence, results[2].confidence)
        XCTAssertTrue(results.allSatisfy { (0...1).contains($0.confidence) })
    }

    func testLoadingSessionsDoesNotCreateOrKeepAnEmptyDraft() throws {
        let chat = makeChatService()
        XCTAssertTrue(chat.loadSessions().isEmpty)

        _ = try XCTUnwrap(chat.createSession())
        XCTAssertEqual(chat.loadSessions().count, 1)

        let reloaded = makeChatService()
        XCTAssertTrue(reloaded.loadSessions().isEmpty)
    }

    func testLegacyMessagesAreMigratedWithoutCreatingAnEmptySession() throws {
        _ = try store.addChatMessage(ChatMessage(
            id: nil,
            role: ChatRole.user.rawValue,
            content: "legacy question",
            ts: Date(),
            relatedFileIds: nil,
            sessionId: nil
        ))

        let chat = makeChatService()
        let session = try XCTUnwrap(chat.loadSessions().first)

        XCTAssertEqual(chat.loadHistory(sessionId: try XCTUnwrap(session.id)).map(\.content), ["legacy question"])
    }

    func testSemanticContextUsesMatchedChunkInsteadOfDocumentPrefix() async throws {
        let fileId = try insertFile(named: "long.md", title: "Long document")
        let provider = StreamingLLMProvider()
        let chat = makeChatService(
            embedder: SuccessfulEmbedder(),
            vectorStore: StubChunkVectorStore(
                fileId: fileId,
                chunk: "later section with the exact renewal clause"
            ),
            llmProvider: provider
        )
        let session = try XCTUnwrap(chat.createSession())

        _ = await completedMessage(chat.streamAnswer(
            "renewal clause",
            sessionId: try XCTUnwrap(session.id),
            attachedFilePath: nil
        ))

        XCTAssertTrue(provider.contexts.last?.contains("later section with the exact renewal clause") == true)
        XCTAssertTrue(provider.contexts.last?.contains("Contract › Renewal · p.7") == true)
        XCTAssertTrue(provider.contexts.last?.contains("Return clean, valid Markdown") == true)
        XCTAssertTrue(provider.contexts.last?.contains("Never expose internal retrieval indexes") == true)
        XCTAssertFalse(provider.contexts.last?.contains("[1] File name") == true)
    }

    func testSemanticContextExpandsAdjacentDocumentChunks() async throws {
        let fileId = try insertFile(named: "manual.pdf", title: "Manual")
        let provider = StreamingLLMProvider()
        let adjacent = VectorSearchHit(
            fileId: fileId,
            score: 0,
            chunkText: "the prerequisite explained on the previous page",
            chunkIndex: 0,
            sectionPath: ["Setup"],
            pageStart: 6,
            pageEnd: 6
        )
        let chat = makeChatService(
            embedder: SuccessfulEmbedder(),
            vectorStore: StubChunkVectorStore(
                fileId: fileId,
                chunk: "the matched installation step",
                neighbors: [adjacent]
            ),
            llmProvider: provider
        )
        let session = try XCTUnwrap(chat.createSession())

        _ = await completedMessage(chat.streamAnswer(
            "installation",
            sessionId: try XCTUnwrap(session.id),
            attachedFilePath: nil
        ))

        XCTAssertTrue(provider.contexts.last?.contains("the matched installation step") == true)
        XCTAssertTrue(provider.contexts.last?.contains("the prerequisite explained on the previous page") == true)
    }

    func testSessionsPersistAndKeepMessageHistoryIsolated() async throws {
        let provider = StreamingLLMProvider()
        let chat = makeChatService(llmProvider: provider)
        let first = try XCTUnwrap(chat.createSession())
        let second = try XCTUnwrap(chat.createSession())

        _ = await completedMessage(
            chat.streamAnswer("first question", sessionId: try XCTUnwrap(first.id), attachedFilePath: nil)
        )
        _ = await completedMessage(
            chat.streamAnswer("second question", sessionId: try XCTUnwrap(second.id), attachedFilePath: nil)
        )

        XCTAssertEqual(chat.loadHistory(sessionId: try XCTUnwrap(first.id)).map(\.content), ["first question", "first second"])
        XCTAssertEqual(chat.loadHistory(sessionId: try XCTUnwrap(second.id)).map(\.content), ["second question", "first second"])
        XCTAssertEqual(chat.loadSessions().count, 2)
        XCTAssertEqual(chat.loadSessions().first { $0.id == first.id }?.title, "first question")
    }

    func testRetryReusesUserQuestionAndReplacesExistingAssistantMessage() async throws {
        let chat = makeChatService(llmProvider: StreamingLLMProvider())
        let session = try XCTUnwrap(chat.createSession())
        let sessionID = try XCTUnwrap(session.id)
        let firstCompleted = await completedMessage(
            chat.streamAnswer("original question", sessionId: sessionID, attachedFilePath: nil)
        )
        let firstAnswer = try XCTUnwrap(firstCompleted)
        let originalAssistantID = try XCTUnwrap(firstAnswer.id)

        let retryCompleted = await completedMessage(chat.retryAnswer(
            "original question",
            sessionId: sessionID,
            attachedFilePath: nil,
            replacingAssistantMessageID: originalAssistantID
        ))
        let retried = try XCTUnwrap(retryCompleted)
        let history = chat.loadHistory(sessionId: sessionID)

        XCTAssertEqual(retried.id, originalAssistantID)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.filter { $0.role == ChatRole.user.rawValue }.map(\.content), ["original question"])
        XCTAssertEqual(history.filter { $0.role == ChatRole.assistant.rawValue }.map(\.id), [originalAssistantID])
    }

    func testRetryCreatesAnswerWithoutDuplicatingUserWhenAssistantIsMissing() async throws {
        let chat = makeChatService(llmProvider: StreamingLLMProvider())
        let session = try XCTUnwrap(chat.createSession())
        let sessionID = try XCTUnwrap(session.id)
        _ = try store.addChatMessage(ChatMessage(
            id: nil,
            role: ChatRole.user.rawValue,
            content: "question without answer",
            ts: Date(),
            relatedFileIds: nil,
            sessionId: sessionID
        ))

        _ = await completedMessage(chat.retryAnswer(
            "question without answer",
            sessionId: sessionID,
            attachedFilePath: nil,
            replacingAssistantMessageID: nil
        ))
        let history = chat.loadHistory(sessionId: sessionID)

        XCTAssertEqual(history.filter { $0.role == ChatRole.user.rawValue }.count, 1)
        XCTAssertEqual(history.filter { $0.role == ChatRole.assistant.rawValue }.count, 1)
    }

    func testAttachedFileContentIsIncludedInStreamingContext() async throws {
        let provider = StreamingLLMProvider()
        let chat = makeChatService(llmProvider: provider)
        let fileURL = temporaryDirectory.appendingPathComponent("brief.md")
        try Data("private roadmap details".utf8).write(to: fileURL)
        let session = try XCTUnwrap(chat.createSession(attachedFilePath: fileURL.path))

        let response = await completedMessage(
            chat.streamAnswer(
                "summarize this file",
                sessionId: try XCTUnwrap(session.id),
                attachedFilePath: fileURL.path
            )
        )

        XCTAssertEqual(response?.content, "first second")
        XCTAssertTrue(provider.contexts.last?.contains("private roadmap details") == true)
        XCTAssertEqual(response?.relatedFiles.first?.path, fileURL.path)
    }

    func testAttachedFileChatSkipsLibraryRetrievalEntirely() async throws {
        let libraryFileID = try insertFile(named: "roadmap-library.pdf", title: "Roadmap Library")
        let provider = StreamingLLMProvider()
        let embedder = CountingEmbedder()
        let chat = makeChatService(
            embedder: embedder,
            vectorStore: StubVectorStore(hits: [(libraryFileID, 0.99)]),
            llmProvider: provider
        )
        let attachedURL = temporaryDirectory.appendingPathComponent("attached-brief.md")
        try Data("attached source only".utf8).write(to: attachedURL)
        let session = try XCTUnwrap(chat.createSession(attachedFilePath: attachedURL.path))

        let response = await completedMessage(chat.streamAnswer(
            "roadmap",
            sessionId: try XCTUnwrap(session.id),
            attachedFilePath: attachedURL.path
        ))

        XCTAssertEqual(embedder.callCount, 0)
        XCTAssertEqual(response?.relatedFiles.map(\.path), [attachedURL.path])
        XCTAssertTrue(provider.contexts.last?.contains("attached source only") == true)
        XCTAssertFalse(provider.contexts.last?.contains("Roadmap Library") == true)
        XCTAssertTrue(provider.contexts.last?.contains("single-file chat mode") == true)
    }

    func testIndexedAttachedFileUsesStoredRelevantChunksWithoutReparsingSource() async throws {
        let settings = AppSettings(store: store)
        let missingURL = temporaryDirectory.appendingPathComponent("already-indexed.pdf")
        let fileID = try store.upsertFile(FileRecord(
            id: nil,
            path: missingURL.path,
            name: missingURL.lastPathComponent,
            ext: "pdf",
            size: 123,
            mtime: Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: temporaryDirectory.path,
            indexedAt: Date(),
            contentHash: "stored-hash",
            title: "Indexed document",
            contentText: "stored full-document prefix that should not be selected",
            indexSignature: settings.indexConfigurationSignature
        ))
        let provider = StreamingLLMProvider()
        let embedder = CountingEmbedder()
        let vectorStore = StubChunkVectorStore(
            fileId: fileID,
            chunk: "indexed answer from the relevant section"
        )
        let chat = makeChatService(
            settings: settings,
            embedder: embedder,
            vectorStore: vectorStore,
            llmProvider: provider
        )
        let session = try XCTUnwrap(chat.createSession(attachedFilePath: missingURL.path))

        let response = await completedMessage(chat.streamAnswer(
            "What is the answer?",
            sessionId: try XCTUnwrap(session.id),
            attachedFilePath: missingURL.path
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
        XCTAssertEqual(embedder.callCount, 1)
        XCTAssertEqual(response?.relatedFiles.map(\.id), [fileID])
        XCTAssertTrue(provider.contexts.last?.contains("indexed answer from the relevant section") == true)
        XCTAssertFalse(provider.contexts.last?.contains("stored full-document prefix") == true)
    }

    func testIndexedAttachedFileUsesStoredTextWhenEmbeddingIsUnavailable() async throws {
        let settings = AppSettings(store: store)
        let missingURL = temporaryDirectory.appendingPathComponent("stored-only.docx")
        let fileID = try store.upsertFile(FileRecord(
            id: nil,
            path: missingURL.path,
            name: missingURL.lastPathComponent,
            ext: "docx",
            size: 456,
            mtime: Date(),
            category: FileCategory.documents.rawValue,
            sourceDir: temporaryDirectory.path,
            indexedAt: Date(),
            contentHash: "stored-hash",
            title: "Stored document",
            contentText: "answer preserved in the indexed text",
            indexSignature: settings.indexConfigurationSignature
        ))
        let provider = StreamingLLMProvider()
        let chat = makeChatService(
            settings: settings,
            embedder: FailingEmbedder(),
            vectorStore: StubVectorStore(hits: []),
            llmProvider: provider
        )
        let session = try XCTUnwrap(chat.createSession(attachedFilePath: missingURL.path))

        _ = await completedMessage(chat.streamAnswer(
            "Summarize it",
            sessionId: try XCTUnwrap(session.id),
            attachedFilePath: missingURL.path
        ))

        XCTAssertEqual(fileID, try store.file(path: missingURL.path)?.id)
        XCTAssertTrue(provider.contexts.last?.contains("answer preserved in the indexed text") == true)
    }

    func testCompletedAssistantPersistsUsageAndResponseTiming() async throws {
        let provider = StreamingLLMProvider()
        let chat = makeChatService(llmProvider: provider)
        let session = try XCTUnwrap(chat.createSession())
        let sessionID = try XCTUnwrap(session.id)

        let completed = await completedMessage(chat.streamAnswer(
            "usage question",
            sessionId: sessionID,
            attachedFilePath: nil
        ))
        let response = try XCTUnwrap(completed)
        let persisted = try XCTUnwrap(chat.loadHistory(sessionId: sessionID).last)

        XCTAssertEqual(response.responseProvider, "streaming-stub")
        XCTAssertGreaterThan(response.inputTokens ?? 0, 0)
        XCTAssertGreaterThan(response.outputTokens ?? 0, 0)
        XCTAssertGreaterThanOrEqual(response.firstResponseDuration ?? -1, 0)
        XCTAssertGreaterThanOrEqual(response.totalResponseDuration ?? -1, 0)
        XCTAssertEqual(persisted.inputTokens, response.inputTokens)
        XCTAssertEqual(persisted.outputTokens, response.outputTokens)
        XCTAssertEqual(persisted.responseProvider, response.responseProvider)
        XCTAssertEqual(persisted.responseModel, response.responseModel)
    }

    func testConfiguredCloudFailureRequestsFallbackWithoutPersistingFailedAnswer() async throws {
        let settings = AppSettings(store: store)
        settings.setLLMChoice(AppSettings.LLMChoice.cloud.rawValue)
        let chat = makeChatService(settings: settings, llmProvider: FailingLLMProvider())
        let session = try XCTUnwrap(chat.createSession())
        let sessionID = try XCTUnwrap(session.id)
        var failure: String?
        var completed: ChatMessage?

        for await update in chat.streamAnswer(
            "find contract",
            sessionId: sessionID,
            attachedFilePath: nil
        ) {
            if case let .cloudProviderFailed(message) = update { failure = message }
            if case let .completed(message) = update { completed = message }
        }

        XCTAssertNotNil(failure)
        XCTAssertNil(completed)
        XCTAssertEqual(chat.loadHistory(sessionId: sessionID).map(\.role), [ChatRole.user.rawValue])
    }

    func testVectorOnlyFallbackPersistsLocalRetrievalResultsWithoutCallingLLM() async throws {
        let fileID = try insertFile(named: "contract.pdf", title: "Contract")
        let settings = AppSettings(store: store)
        settings.setAppLanguage(AppSettings.AppLanguage.simplifiedChinese.rawValue)
        let chat = makeChatService(
            settings: settings,
            embedder: SuccessfulEmbedder(),
            vectorStore: StubVectorStore(hits: [(fileID, 0.96)]),
            llmProvider: FailingLLMProvider()
        )
        let session = try XCTUnwrap(chat.createSession())

        let completed = await completedMessage(chat.streamAnswer(
            "contract",
            sessionId: try XCTUnwrap(session.id),
            attachedFilePath: nil,
            providerMode: .vectorOnly(cloudFailure: "offline")
        ))

        XCTAssertEqual(completed?.relatedFiles.compactMap(\.id), [fileID])
        XCTAssertEqual(
            completed?.content,
            settings.localizedFormat("Cloud AI failed: %@", "offline")
                + "\n\n"
                + settings.localizedFormat(
                    "Showing the top %d matches from the local vector index. Click a file below to preview it.",
                    1
                )
        )
        XCTAssertNil(completed?.responseProvider)
    }

    func testMarkdownNormalizerRepairsModelStrongWhitespaceWithoutChangingCode() {
        let markdown = """
        📠 **Recipient **(From / Issued by)
        📦 ** Payer**(Issued to / Bill To)
        __ Address __: Singapore
        `** keep code whitespace **`
        ```swift
        let value = "** keep fenced code whitespace **"
        ```
        """

        XCTAssertEqual(ChatMarkdownNormalizer.normalize(markdown), """
        📠 **Recipient**(From / Issued by)
        📦 **Payer**(Issued to / Bill To)
        __Address__: Singapore
        `** keep code whitespace **`
        ```swift
        let value = "** keep fenced code whitespace **"
        ```
        """)
    }

    func testComposerHeightStartsAtTwoLinesGrowsAndCapsAtTenLines() {
        let lineHeight: CGFloat = 18
        let inset: CGFloat = 3

        XCTAssertEqual(
            ChatComposerTextView.clampedHeight(
                usedTextHeight: lineHeight,
                lineHeight: lineHeight,
                verticalInset: inset
            ),
            lineHeight * 2 + inset * 2
        )
        XCTAssertEqual(
            ChatComposerTextView.clampedHeight(
                usedTextHeight: lineHeight * 6,
                lineHeight: lineHeight,
                verticalInset: inset
            ),
            lineHeight * 6 + inset * 2
        )
        XCTAssertEqual(
            ChatComposerTextView.clampedHeight(
                usedTextHeight: lineHeight * 14,
                lineHeight: lineHeight,
                verticalInset: inset
            ),
            lineHeight * 10 + inset * 2
        )
        XCTAssertEqual(
            ChatComposerTextView.clampedHeight(
                usedTextHeight: 0,
                lineHeight: lineHeight,
                verticalInset: inset
            ),
            lineHeight * 2 + inset * 2
        )
    }

    func testComposerReturnKeySeparatesSubmitFromShiftNewline() {
        XCTAssertEqual(ChatComposerTextView.returnAction(for: []), .submit)
        XCTAssertEqual(ChatComposerTextView.returnAction(for: [.command]), .submit)
        XCTAssertEqual(ChatComposerTextView.returnAction(for: [.shift]), .insertNewline)
        XCTAssertEqual(ChatComposerTextView.returnAction(for: [.shift, .option]), .insertNewline)
    }

    func testStreamingReportsRealRetrievalAndAIProgress() async throws {
        _ = try insertFile(named: "agreement.pdf", title: "Annual contract")
        let settings = AppSettings(store: store)
        settings.setThinkingMode(true)
        let chat = makeChatService(settings: settings)
        let session = try XCTUnwrap(chat.createSession())
        var progresses: [ChatProgress] = []

        for await update in chat.streamAnswer(
            "contract",
            sessionId: try XCTUnwrap(session.id),
            attachedFilePath: nil
        ) {
            if case let .progress(progress) = update { progresses.append(progress) }
        }

        XCTAssertEqual(
            progresses.map(\.phase),
            [.planningSearch, .queryingIndex, .matchesFound, .thinking]
        )
        XCTAssertEqual(progresses[2].matchedFileCount, 1)
        XCTAssertEqual(progresses[3].matchedFileCount, 1)
        XCTAssertEqual(progresses[2].matchedFiles.map(\.name), ["agreement.pdf"])
        XCTAssertEqual(progresses[3].matchedFiles.map(\.name), ["agreement.pdf"])
    }

    private func makeChatService(settings: AppSettings? = nil,
                                 embedder: EmbeddingProvider = FailingEmbedder(),
                                 vectorStore: VectorStore? = nil,
                                 llmProvider: LLMProvider = StubLLMProvider()) -> ChatService {
        ChatService(
            store: store,
            settings: settings ?? AppSettings(store: store),
            embedder: embedder,
            llmProvider: llmProvider,
            vectorStore: vectorStore
        )
    }

    private func completedMessage(_ stream: AsyncStream<ChatStreamUpdate>) async -> ChatMessage? {
        var completed: ChatMessage?
        for await update in stream {
            if case let .completed(message) = update { completed = message }
        }
        return completed
    }

    private func insertFile(
        named name: String,
        title: String,
        mtime: Date = Date(),
        contentText: String? = nil,
        note: String? = nil
    ) throws -> Int64 {
        try store.upsertFile(FileRecord(
            id: nil,
            path: temporaryDirectory.appendingPathComponent(name).path,
            name: name,
            ext: URL(fileURLWithPath: name).pathExtension,
            size: 1,
            mtime: mtime,
            category: FileCategory.documents.rawValue,
            sourceDir: temporaryDirectory.path,
            indexedAt: Date(),
            contentHash: nil,
            title: title,
            contentText: contentText ?? title,
            note: note
        ))
    }

    private func decodeRelatedIds(_ message: ChatMessage) throws -> [Int64] {
        let json = try XCTUnwrap(message.relatedFileIds)
        return try JSONDecoder().decode([Int64].self, from: Data(json.utf8))
    }
}
