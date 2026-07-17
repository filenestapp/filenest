import Foundation
import NaturalLanguage

enum ChatStreamUpdate {
    case userSaved(ChatMessage)
    case progress(ChatProgress)
    case delta(String)
    case completed(ChatMessage)
    case cloudProviderFailed(String)
    case cancelled
}

enum ChatProviderMode {
    case configured
    case local(model: String)
    case vectorOnly(cloudFailure: String?)
}

struct ChatProgress: Equatable {
    enum Scope: Equatable {
        case library
        case attachedFile
    }

    enum Phase: Equatable {
        case planningSearch
        case queryingIndex
        case matchesFound
        case readingFile
        case fileReady
        case analyzing
        case thinking
    }

    let phase: Phase
    var scope: Scope = .library
    var matchedFileCount: Int = 0
    var matchedFiles: [FileRecord] = []
    var usesExistingIndex = false
    var searchIntent = ""
}

enum LibrarySearchMatchKind: Equatable {
    case fileName
    case title
    case note
    case content
    case path
    case date
    case filter
    case semantic
    case hybrid

    var label: String {
        switch self {
        case .fileName: return "Filename Match"
        case .title: return "Title Match"
        case .note: return "Note Match"
        case .content: return "Content Match"
        case .path: return "Path Match"
        case .date: return "Date Match"
        case .filter: return "Filter Match"
        case .semantic: return "Semantic Match"
        case .hybrid: return "Hybrid Match"
        }
    }
}

struct LibraryRelativeDateIntent: Equatable {
    let interval: DateInterval
    let contentYears: Set<Int>

    func contains(_ date: Date) -> Bool {
        date >= interval.start && date < interval.end
    }
}

struct LibrarySearchResult: Identifiable, Equatable {
    var id: String { file.id.map(String.init) ?? file.path }
    let file: FileRecord
    let score: Double
    let confidence: Double
    let matchKind: LibrarySearchMatchKind
    let snippet: String?
    let sectionPath: [String]
    let pageStart: Int?
    let pageEnd: Int?

    var confidencePercent: Int {
        Int((min(max(confidence, 0), 1) * 100).rounded())
    }
}

struct SmartLibrarySearchPlan: Equatable {
    let semanticQuery: String
    let keywords: [String]
    let categories: Set<FileCategory>
    let dateInterval: DateInterval?
    let sortNewestFirst: Bool
}

struct SmartLibrarySearchResponse: Equatable {
    let results: [LibrarySearchResult]
    let plan: SmartLibrarySearchPlan
    let usedAI: Bool
}

private struct LibrarySearchExecution {
    let results: [LibrarySearchResult]
    let semanticHitsByFile: [Int64: [VectorSearchHit]]
}

private struct SmartSearchPlanPayload: Decodable {
    let intent: String?
    let semanticQuery: String?
    let keywords: [String]?
    let categories: [String]?
    let dateFrom: String?
    let dateTo: String?
    let sort: String?

    enum CodingKeys: String, CodingKey {
        case intent
        case semanticQuery = "semantic_query"
        case keywords
        case categories
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case sort
    }
}

private enum SmartSearchPlanError: Error {
    case invalidJSON
}

/// Chat service for persistence, file and RAG context, streamed model output, and file references.
final class ChatService {
    private static let attachedChunkLimit = 6
    private static let attachedContextCharacterLimit = 24_000
    private let store: SQLiteStore
    private let settings: AppSettings
    private let providedEmbedder: EmbeddingProvider?
    private let providedLLMProvider: LLMProvider?
    private let providedVectorStore: VectorStore?
    private let contextWindowResolver = ChatModelContextWindowResolver()
    private let doclingProcessor = DoclingDocumentProcessor()
    private let embedderLock = NSLock()
    private var cachedEmbedder: (signature: String, provider: EmbeddingProvider)?
    private let ocrProviderLock = NSLock()
    private var cachedOCRProvider: (signature: String, provider: OCRProvider?)?

    init(store: SQLiteStore,
         settings: AppSettings,
         embedder: EmbeddingProvider? = nil,
         llmProvider: LLMProvider? = nil,
         vectorStore: VectorStore? = nil) {
        self.store = store
        self.settings = settings
        self.providedEmbedder = embedder
        self.providedLLMProvider = llmProvider
        self.providedVectorStore = vectorStore
        try? store.migrateLegacyChatMessagesIfNeeded()
        try? store.deleteEmptyChatSessions()
    }

    // MARK: - Sessions

    func loadSessions() -> [ChatSession] {
        var sessions = (try? store.allChatSessions()) ?? []
        for index in sessions.indices where sessions[index].title == "New Chat" {
            guard let id = sessions[index].id,
                  let history = try? store.chatMessages(sessionId: id),
                  let firstQuestion = history.first(where: { $0.role == ChatRole.user.rawValue })?.content,
                  !firstQuestion.isEmpty else { continue }
            sessions[index].title = String(
                firstQuestion
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(32)
            )
            try? store.updateChatSession(sessions[index])
        }
        return sessions
    }

    func createSession(attachedFilePath: String? = nil) -> ChatSession? {
        try? store.createChatSession(attachedFilePath: attachedFilePath)
    }

    func updateAttachment(sessionId: Int64, path: String?) -> ChatSession? {
        guard var session = loadSessions().first(where: { $0.id == sessionId }) else { return nil }
        session.attachedFilePath = path
        session.updatedAt = Date()
        if session.title == "New Chat", let path {
            session.title = URL(fileURLWithPath: path).lastPathComponent
        }
        try? store.updateChatSession(session)
        return session
    }

    func deleteSession(id: Int64) {
        try? store.deleteChatSession(id: id)
    }

    func loadHistory(sessionId: Int64? = nil) -> [ChatMessage] {
        var messages: [ChatMessage]
        if let sessionId {
            messages = (try? store.chatMessages(sessionId: sessionId)) ?? []
        } else {
            messages = (try? store.allChatMessages()) ?? []
        }
        for index in messages.indices {
            messages[index].relatedFiles = resolveRelated(from: messages[index])
        }
        return messages
    }

    // MARK: - Streaming chat

    /// The default chat entry point streams output and persists the complete reply when the stream ends.
    func streamAnswer(_ question: String,
                      sessionId: Int64,
                      attachedFilePath: String?,
                      modelOverride: String? = nil,
                      providerMode: ChatProviderMode = .configured) -> AsyncStream<ChatStreamUpdate> {
        streamResponse(
            question,
            sessionId: sessionId,
            attachedFilePath: attachedFilePath,
            modelOverride: modelOverride,
            providerMode: providerMode,
            savesUserMessage: true,
            replacingAssistantMessageID: nil
        )
    }

    /// Retries the last question by reusing the stored user message and replacing its existing answer in place.
    func retryAnswer(_ question: String,
                     sessionId: Int64,
                     attachedFilePath: String?,
                     replacingAssistantMessageID: Int64?,
                     modelOverride: String? = nil,
                     providerMode: ChatProviderMode = .configured) -> AsyncStream<ChatStreamUpdate> {
        streamResponse(
            question,
            sessionId: sessionId,
            attachedFilePath: attachedFilePath,
            modelOverride: modelOverride,
            providerMode: providerMode,
            savesUserMessage: false,
            replacingAssistantMessageID: replacingAssistantMessageID
        )
    }

    private func streamResponse(_ question: String,
                                sessionId: Int64,
                                attachedFilePath: String?,
                                modelOverride: String?,
                                providerMode: ChatProviderMode,
                                savesUserMessage: Bool,
                                replacingAssistantMessageID: Int64?) -> AsyncStream<ChatStreamUpdate> {
        AsyncStream { continuation in
            let task = Task {
                let responseStartedAt = Date()
                if savesUserMessage {
                    var userMessage = ChatMessage(
                        id: nil,
                        role: ChatRole.user.rawValue,
                        content: question,
                        ts: Date(),
                        relatedFileIds: nil,
                        sessionId: sessionId
                    )
                    if let id = try? store.addChatMessage(userMessage) {
                        userMessage.id = id
                    }
                    updateSessionAfterQuestion(sessionId: sessionId, question: question)
                    continuation.yield(.userSaved(userMessage))
                }

                let isFileChat = !(attachedFilePath?.isEmpty ?? true)
                let usesExistingIndex = attachedFilePath.map { canReuseAttachedIndex(at: $0) } ?? false
                continuation.yield(.progress(ChatProgress(
                    phase: isFileChat ? .readingFile : .planningSearch,
                    scope: isFileChat ? .attachedFile : .library,
                    usesExistingIndex: usesExistingIndex
                )))
                let smartSearchPlan: SmartLibrarySearchPlan?
                var searchIntent = ""
                if isFileChat {
                    smartSearchPlan = nil
                } else {
                    smartSearchPlan = await resolvedSmartSearchPlan(
                        for: question,
                        providerMode: providerMode,
                        modelOverride: modelOverride,
                        onIntentUpdate: { intent in
                            searchIntent = intent
                            continuation.yield(.progress(ChatProgress(
                                phase: .planningSearch,
                                scope: .library,
                                searchIntent: intent
                            )))
                        }
                    ).plan
                    if Task.isCancelled {
                        continuation.yield(.cancelled)
                        continuation.finish()
                        return
                    }
                    continuation.yield(.progress(ChatProgress(
                        phase: .queryingIndex,
                        scope: .library,
                        searchIntent: searchIntent
                    )))
                }
                let related = await relatedFiles(
                    for: question,
                    attachedFilePath: attachedFilePath,
                    smartSearchPlan: smartSearchPlan
                )
                continuation.yield(.progress(ChatProgress(
                    phase: isFileChat ? .fileReady : .matchesFound,
                    scope: isFileChat ? .attachedFile : .library,
                    matchedFileCount: related.files.count,
                    matchedFiles: related.files,
                    usesExistingIndex: usesExistingIndex,
                    searchIntent: searchIntent
                )))

                let history = loadHistory(sessionId: sessionId)
                    .filter { $0.id != replacingAssistantMessageID }
                    .filter { $0.role != ChatRole.system.rawValue }
                    .map { ChatTurn(role: ChatRole(rawValue: $0.role) ?? .user, content: $0.content) }
                continuation.yield(.progress(ChatProgress(
                    phase: settings.thinkingMode ? .thinking : .analyzing,
                    scope: isFileChat ? .attachedFile : .library,
                    matchedFileCount: related.files.count,
                    matchedFiles: related.files,
                    usesExistingIndex: usesExistingIndex,
                    searchIntent: searchIntent
                )))
                var fullReply = ""
                var providerCompleted = false
                var firstResponseDuration: TimeInterval?
                var responseProvider: String?
                var responseModel: String?
                var requestTurns = history
                var requestContext = related.context

                if case let .vectorOnly(cloudFailure) = providerMode {
                    fullReply = vectorFallbackMessage(files: related.files, cloudFailure: cloudFailure)
                } else {
                    let provider: LLMProvider
                    switch providerMode {
                    case .configured:
                        provider = providedLLMProvider
                            ?? settings.makeLLMProvider(modelOverride: modelOverride)
                    case .local(let model):
                        provider = settings.makeLocalLLMProvider(modelOverride: model)
                    case .vectorOnly:
                        preconditionFailure("vector-only mode is handled before provider creation")
                    }
                    let contextWindow = await contextWindowResolver.resolve(
                        contextWindowSource(for: providerMode, modelOverride: modelOverride),
                        overrideTokens: cloudContextWindowOverride(for: providerMode)
                    )
                    let contextPlan = ChatContextPlanner.plan(
                        history: history,
                        context: related.context,
                        contextWindowTokens: contextWindow,
                        thinkingEnabled: settings.thinkingMode
                    )
                    requestTurns = contextPlan.turns
                    requestContext = contextPlan.context
                    do {
                        for try await chunk in provider.streamChat(requestTurns, context: requestContext) {
                            try Task.checkCancellation()
                            if firstResponseDuration == nil, !chunk.isEmpty {
                                firstResponseDuration = Date().timeIntervalSince(responseStartedAt)
                            }
                            fullReply += chunk
                            continuation.yield(.delta(chunk))
                        }
                        providerCompleted = true
                        responseProvider = provider.name
                        responseModel = modelOverride ?? activeModelName(for: providerMode)
                    } catch {
                        if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                            continuation.yield(.cancelled)
                            continuation.finish()
                            return
                        }
                        if case .configured = providerMode,
                           settings.llmChoice == AppSettings.LLMChoice.cloud.rawValue {
                            continuation.yield(.cloudProviderFailed(
                                settings.localizedRuntimeMessage(error.localizedDescription)
                            ))
                            continuation.finish()
                            return
                        }
                        fullReply = llmFailureMessage(error: error, modelOverride: modelOverride)
                    }
                }

                if fullReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fullReply = settings.localized("The model returned no content. Try again or switch models.")
                }

                let totalResponseDuration = Date().timeIntervalSince(responseStartedAt)
                let inputText = requestTurns.map(\.content).joined(separator: "\n") + "\n" + requestContext
                let inputTokens = providerCompleted ? Self.estimatedTokens(in: inputText) : nil
                let outputTokens = providerCompleted ? Self.estimatedTokens(in: fullReply) : nil
                if providerCompleted, responseProvider != "none",
                   let responseProvider, let responseModel,
                   let inputTokens, let outputTokens {
                    try? store.recordTokenUsage(TokenUsageRecord(
                        id: nil,
                        ts: Date(),
                        provider: responseProvider,
                        model: responseModel,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        sessionId: sessionId
                    ))
                }

                let ids = related.files.compactMap(\.id).filter { $0 > 0 }
                let idJSON = (try? JSONEncoder().encode(ids))
                    .flatMap { String(data: $0, encoding: .utf8) }
                var assistantMessage = ChatMessage(
                    id: replacingAssistantMessageID,
                    role: ChatRole.assistant.rawValue,
                    content: fullReply,
                    ts: Date(),
                    relatedFileIds: idJSON,
                    relatedFiles: related.files,
                    sessionId: sessionId,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    firstResponseDuration: firstResponseDuration,
                    totalResponseDuration: providerCompleted ? totalResponseDuration : nil,
                    responseProvider: providerCompleted ? responseProvider : nil,
                    responseModel: providerCompleted ? responseModel : nil
                )
                if replacingAssistantMessageID != nil {
                    try? store.updateChatMessage(assistantMessage)
                } else if let id = try? store.addChatMessage(assistantMessage) {
                    assistantMessage.id = id
                }
                touchSession(sessionId)
                continuation.yield(.completed(assistantMessage))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func cloudContextWindowOverride(for mode: ChatProviderMode) -> Int? {
        guard case .configured = mode,
              settings.llmChoice == AppSettings.LLMChoice.cloud.rawValue,
              settings.cloudContextWindowTokens > 0 else { return nil }
        return settings.cloudContextWindowTokens
    }

    /// Retained for service tests and non-streaming callers; internally it still uses the default streaming path.
    func ask(_ question: String) async -> ChatMessage {
        let session = loadSessions().first ?? createSession()
        guard let sessionId = session?.id else {
            return ChatMessage(
                id: nil,
                role: ChatRole.assistant.rawValue,
                content: settings.localized("Could not create a local chat."),
                ts: Date(),
                relatedFileIds: nil
            )
        }

        var finalMessage: ChatMessage?
        for await update in streamAnswer(
            question,
            sessionId: sessionId,
            attachedFilePath: session?.attachedFilePath
        ) {
            if case let .completed(message) = update { finalMessage = message }
        }
        return finalMessage ?? ChatMessage(
            id: nil,
            role: ChatRole.assistant.rawValue,
            content: settings.localized("The chat was cancelled."),
            ts: Date(),
            relatedFileIds: nil,
            sessionId: sessionId
        )
    }

    func clearHistory() {
        try? store.clearAllChats()
    }

    func searchLibrary(_ rawQuery: String, limit: Int = 200) async -> [LibrarySearchResult] {
        await executeLibrarySearch(rawQuery, limit: limit, smartPlan: nil)
    }

    func smartSearchLibrary(
        _ rawQuery: String,
        limit: Int = 200,
        onIntentUpdate: ((String) -> Void)? = nil
    ) async -> SmartLibrarySearchResponse {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPlan = Self.fallbackSmartSearchPlan(for: query)
        guard !query.isEmpty, limit > 0 else {
            return SmartLibrarySearchResponse(results: [], plan: fallbackPlan, usedAI: false)
        }
        let resolved = await resolvedSmartSearchPlan(
            for: query,
            onIntentUpdate: onIntentUpdate
        )
        guard !Task.isCancelled else {
            return SmartLibrarySearchResponse(results: [], plan: fallbackPlan, usedAI: false)
        }
        let plan = resolved.plan
        let results = await executeLibrarySearch(query, limit: limit, smartPlan: plan)
        return SmartLibrarySearchResponse(results: results, plan: plan, usedAI: resolved.usedAI)
    }

    private func resolvedSmartSearchPlan(
        for query: String,
        providerMode: ChatProviderMode = .configured,
        modelOverride: String? = nil,
        onIntentUpdate: ((String) -> Void)? = nil
    ) async -> (plan: SmartLibrarySearchPlan, usedAI: Bool) {
        let fallbackPlan = Self.fallbackSmartSearchPlan(for: query)
        guard !query.isEmpty,
              settings.llmChoice != AppSettings.LLMChoice.none.rawValue else {
            return (fallbackPlan, false)
        }

        let provider: LLMProvider
        switch providerMode {
        case .configured:
            provider = providedLLMProvider ?? settings.makeLLMProvider(modelOverride: modelOverride)
        case .local(let model):
            provider = settings.makeLocalLLMProvider(modelOverride: model)
        case .vectorOnly:
            return (fallbackPlan, false)
        }

        do {
            var reply = ""
            var lastIntent = ""
            for try await chunk in provider.streamChat([
                ChatTurn(role: .system, content: Self.smartSearchSystemPrompt()),
                ChatTurn(role: .user, content: query),
            ], context: nil) {
                try Task.checkCancellation()
                reply += chunk
                guard let intent = Self.streamedSearchIntent(in: reply),
                      intent != lastIntent else { continue }
                lastIntent = intent
                onIntentUpdate?(intent)
            }
            return (try Self.decodeSmartSearchPlan(reply, fallbackQuery: query), true)
        } catch {
            return (fallbackPlan, false)
        }
    }

    private func executeLibrarySearch(
        _ rawQuery: String,
        limit: Int,
        smartPlan: SmartLibrarySearchPlan?
    ) async -> [LibrarySearchResult] {
        await executeLibrarySearchDetails(
            rawQuery,
            limit: limit,
            smartPlan: smartPlan,
            sortByConfidence: true
        ).results
    }

    private func executeLibrarySearchDetails(
        _ rawQuery: String,
        limit: Int,
        smartPlan: SmartLibrarySearchPlan?,
        sortByConfidence: Bool = false
    ) async -> LibrarySearchExecution {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else {
            return LibrarySearchExecution(results: [], semanticHitsByFile: [:])
        }

        let semanticQuery = smartPlan?.semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSemanticQuery = semanticQuery.flatMap { $0.isEmpty ? nil : $0 } ?? query
        let terms = Self.librarySearchTerms(
            query + " " + effectiveSemanticQuery,
            additionalTerms: smartPlan?.keywords ?? []
        )
        let relativeDateIntent = smartPlan?.dateInterval.map {
            LibraryRelativeDateIntent(interval: $0, contentYears: [])
        } ?? Self.relativeDateIntent(in: query)
        let isRelativeDateOnlyQuery = relativeDateIntent != nil
            && Self.isRelativeDateOnlyQuery(query)
        var lexicalByID = [Int64: LibraryLexicalMatch]()
        for term in terms.prefix(8) {
            for file in (try? store.files(matching: term)) ?? [] {
                guard let id = file.id,
                      let match = Self.libraryLexicalMatch(file: file, query: query, terms: terms) else {
                    continue
                }
                if let existing = lexicalByID[id], match.score <= existing.score { continue }
                lexicalByID[id] = match
            }
        }

        var semanticByID = [Int64: VectorSearchHit]()
        var semanticHitsByFile = [Int64: [VectorSearchHit]]()
        if let queryVector = try? await activeEmbedder().embed(effectiveSemanticQuery), !queryVector.isEmpty {
            let vectorStore = providedVectorStore ?? AppStateIndexerProxy.shared.vectorStore
            let hits = await vectorStore.searchChunks(queryVector, k: max(80, min(limit * 2, 240)))
            for hit in hits where hit.score.isFinite {
                semanticHitsByFile[hit.fileId, default: []].append(hit)
                if hit.score > (semanticByID[hit.fileId]?.score ?? -.infinity) {
                    semanticByID[hit.fileId] = hit
                }
            }
        }

        var temporalByID = [Int64: FileRecord]()
        if isRelativeDateOnlyQuery || smartPlan?.dateInterval != nil || smartPlan?.categories.isEmpty == false {
            for file in (try? store.allFiles()) ?? [] {
                let matchesDate = relativeDateIntent?.contains(file.mtime) ?? true
                let matchesCategory = smartPlan?.categories.isEmpty != false
                    || smartPlan?.categories.contains(file.categoryEnum) == true
                guard matchesDate, matchesCategory, let id = file.id else { continue }
                temporalByID[id] = file
            }
        }

        let lexicalRank = Dictionary(uniqueKeysWithValues: lexicalByID
            .sorted { lhs, rhs in
                lhs.value.score == rhs.value.score
                    ? lhs.key < rhs.key
                    : lhs.value.score > rhs.value.score
            }
            .enumerated()
            .map { ($0.element.key, $0.offset + 1) })
        let semanticRank = Dictionary(uniqueKeysWithValues: semanticByID
            .sorted { lhs, rhs in
                lhs.value.score == rhs.value.score
                    ? lhs.key < rhs.key
                    : lhs.value.score > rhs.value.score
            }
            .enumerated()
            .map { ($0.element.key, $0.offset + 1) })

        let candidateIDs = Set(lexicalByID.keys)
            .union(semanticByID.keys)
            .union(temporalByID.keys)
        let results = candidateIDs.compactMap { fileID -> LibrarySearchResult? in
            guard let file = lexicalByID[fileID]?.file
                ?? temporalByID[fileID]
                ?? (try? store.file(id: fileID)) else { return nil }
            let lexical = lexicalByID[fileID]
            let semantic = semanticByID[fileID]
            var score = 0.0
            if let rank = lexicalRank[fileID] { score += 0.62 / Double(60 + rank) }
            if let rank = semanticRank[fileID] { score += 0.38 / Double(60 + rank) }
            if lexical?.score ?? 0 >= 120 { score += 0.02 }

            let matchKind: LibrarySearchMatchKind
            if lexical != nil, semantic != nil {
                matchKind = .hybrid
            } else if let lexical {
                matchKind = lexical.kind
            } else if semantic != nil {
                matchKind = .semantic
            } else {
                matchKind = relativeDateIntent != nil ? .date : .filter
            }
            let semanticSnippet = semantic?.chunkText.flatMap {
                Self.compactExcerpt($0, terms: terms)
            }
            let confidence = max(
                max(
                    lexical?.confidence ?? 0,
                    semantic.map { Self.semanticConfidence(for: $0) } ?? 0
                ),
                lexical == nil && semantic == nil ? 0.30 : 0
            )
            return LibrarySearchResult(
                file: file,
                score: score,
                confidence: confidence,
                matchKind: matchKind,
                snippet: lexical?.snippet ?? semanticSnippet,
                sectionPath: semantic?.sectionPath ?? [],
                pageStart: semantic?.pageStart,
                pageEnd: semantic?.pageEnd
            )
        }

        let filteredResults = results.filter { result in
            guard let smartPlan else { return true }
            if !smartPlan.categories.isEmpty,
               !smartPlan.categories.contains(result.file.categoryEnum) {
                return false
            }
            if let interval = smartPlan.dateInterval,
               !(result.file.mtime >= interval.start && result.file.mtime < interval.end) {
                return false
            }
            return true
        }
        let requestedYears = Self.requestedYears(in: query)
        let sortedResults = Array(filteredResults.sorted { lhs, rhs in
            if let relativeDateIntent {
                let lhsDateTier = Self.relativeDateMatchTier(
                    of: lhs.file,
                    intent: relativeDateIntent
                )
                let rhsDateTier = Self.relativeDateMatchTier(
                    of: rhs.file,
                    intent: relativeDateIntent
                )
                if lhsDateTier != rhsDateTier { return lhsDateTier > rhsDateTier }
                if isRelativeDateOnlyQuery, lhs.file.mtime != rhs.file.mtime {
                    return lhs.file.mtime > rhs.file.mtime
                }
            }
            if !requestedYears.isEmpty {
                let lhsYearTier = Self.requestedYearMatchTier(
                    of: lhs.file,
                    requestedYears: requestedYears
                )
                let rhsYearTier = Self.requestedYearMatchTier(
                    of: rhs.file,
                    requestedYears: requestedYears
                )
                if lhsYearTier != rhsYearTier { return lhsYearTier > rhsYearTier }
            }
            if sortByConfidence, lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            if smartPlan?.sortNewestFirst == true, sortByConfidence {
                if lhs.file.mtime != rhs.file.mtime { return lhs.file.mtime > rhs.file.mtime }
            } else if smartPlan?.sortNewestFirst == true {
                func relevanceTier(_ result: LibrarySearchResult) -> Int {
                    guard let fileID = result.file.id else { return 0 }
                    guard let lexical = lexicalByID[fileID] else {
                        return semanticByID[fileID] == nil ? 0 : 1
                    }
                    switch lexical.rankingKind {
                    case .fileName, .title: return 3
                    case .note, .content: return 2
                    case .path: return 1
                    default: return 0
                    }
                }
                let lhsTier = relevanceTier(lhs)
                let rhsTier = relevanceTier(rhs)
                if lhsTier != rhsTier { return lhsTier > rhsTier }
                if lhs.file.mtime != rhs.file.mtime { return lhs.file.mtime > rhs.file.mtime }
            }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.file.name.localizedStandardCompare(rhs.file.name) == .orderedAscending
        }.prefix(limit))
        return LibrarySearchExecution(
            results: sortedResults,
            semanticHitsByFile: semanticHitsByFile
        )
    }

    // MARK: - Context

    private func resolveRelated(from message: ChatMessage) -> [FileRecord] {
        guard let json = message.relatedFileIds,
              let ids = try? JSONDecoder().decode([Int64].self, from: Data(json.utf8)) else { return [] }
        return ids.compactMap { try? store.file(id: $0) }
    }

    private func relatedFiles(for question: String,
                              attachedFilePath: String?,
                              smartSearchPlan: SmartLibrarySearchPlan?) async -> (files: [FileRecord], context: String) {
        var files: [FileRecord] = []
        var contextParts: [String] = []
        var matchedChunks: [Int64: [VectorSearchHit]] = [:]

        if let attachedFilePath, !attachedFilePath.isEmpty {
            let url = URL(fileURLWithPath: attachedFilePath)
            if let indexedFile = try? store.file(path: attachedFilePath),
               canReuseIndex(for: indexedFile) {
                let context = await indexedAttachedFileContext(
                    question: question,
                    file: indexedFile
                )
                return ([indexedFile], context)
            }

            let analysis = url.pathExtension.lowercased() == "pdf"
                ? OCRDocumentProcessor.analyzePDF(at: url)
                : nil
            let isRasterImage = OCRDocumentProcessor.isRasterImage(
                extension: url.pathExtension
            )
            let docling = settings.doclingEnabled && !isRasterImage
                ? await doclingProcessor.process(
                    url: url,
                    ext: url.pathExtension,
                    maxTokens: settings.vectorChunkWords,
                    pdfAnalysis: analysis,
                    disableBuiltInOCR: settings.ocrSource != AppSettings.OCRSource.disabled.rawValue
                )
                : nil
            let shouldRunConfiguredOCR = docling == nil || OCRDocumentProcessor.requiresRecognition(
                ext: url.pathExtension,
                pdfAnalysis: analysis
            )
            let ocrText = shouldRunConfiguredOCR
                ? await OCRDocumentProcessor.recognizeIfNeeded(
                    url: url,
                    ext: url.pathExtension,
                    provider: activeOCRProvider()
                )
                : nil
            var extracted = docling?.extracted
                ?? ContentExtractor.extract(url: url, ext: url.pathExtension)
            if let ocrText, !ocrText.isEmpty, !extracted.text.contains(ocrText) {
                extracted.text += "\n\n\(ocrText)"
            }
            let attachedRecord = (try? store.file(path: attachedFilePath)) ?? transientFile(url: url)
            files.append(attachedRecord)
            contextParts.append(buildAttachedFileContext(
                file: attachedRecord,
                extractedText: String(extracted.text.prefix(Self.attachedContextCharacterLimit))
            ))
            // Chat with File is isolated: it uses only the current file and skips library-wide vector and keyword search.
            return (files, contextParts.joined(separator: "\n\n"))
        }

        let execution = await executeLibrarySearchDetails(
            question,
            limit: settings.ragResultLimit,
            smartPlan: smartSearchPlan
        )
        files = execution.results.map(\.file)

        let selectedFileIDs = Set(files.compactMap(\.id))
        let vectorStore = providedVectorStore ?? AppStateIndexerProxy.shared.vectorStore
        var seenChunkKeys = Set<String>()
        for fileID in selectedFileIDs {
            for hit in execution.semanticHitsByFile[fileID] ?? [] {
                let key = "\(hit.fileId):\(hit.chunkIndex ?? -1)"
                if seenChunkKeys.insert(key).inserted {
                    matchedChunks[hit.fileId, default: []].append(hit)
                }
                guard let chunkIndex = hit.chunkIndex else { continue }
                let neighbors = await vectorStore.neighboringChunks(
                    fileId: hit.fileId,
                    around: chunkIndex,
                    radius: 1
                )
                for neighbor in neighbors {
                    let neighborKey = "\(neighbor.fileId):\(neighbor.chunkIndex ?? -1)"
                    if seenChunkKeys.insert(neighborKey).inserted {
                        matchedChunks[neighbor.fileId, default: []].append(neighbor)
                    }
                }
            }
        }
        contextParts.append(buildLibraryContext(from: files, matchedChunks: matchedChunks))
        return (files, contextParts.joined(separator: "\n\n"))
    }

    private func canReuseIndex(for file: FileRecord) -> Bool {
        file.indexedAt != nil && file.indexSignature == settings.indexConfigurationSignature
    }

    private func activeOCRProvider() -> OCRProvider? {
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

    private func canReuseAttachedIndex(at path: String) -> Bool {
        guard let file = try? store.file(path: path) else { return false }
        return canReuseIndex(for: file)
    }

    private func indexedAttachedFileContext(question: String, file: FileRecord) async -> String {
        var selectedChunks = [VectorSearchHit]()
        if let fileID = file.id,
           let queryVector = try? await activeEmbedder().embed(question),
           !queryVector.isEmpty {
            let vectorStore = providedVectorStore ?? AppStateIndexerProxy.shared.vectorStore
            let matches = await vectorStore.searchChunks(
                queryVector,
                fileId: fileID,
                k: Self.attachedChunkLimit
            )
            var seen = Set<String>()
            for match in matches {
                appendUnique(match, to: &selectedChunks, seen: &seen)
                guard let chunkIndex = match.chunkIndex else { continue }
                let neighbors = await vectorStore.neighboringChunks(
                    fileId: fileID,
                    around: chunkIndex,
                    radius: 1
                )
                for neighbor in neighbors where neighbor.chunkIndex != chunkIndex {
                    appendUnique(neighbor, to: &selectedChunks, seen: &seen)
                }
            }
        }

        if !selectedChunks.isEmpty {
            return buildIndexedAttachedFileContext(file: file, chunks: selectedChunks)
        }

        let storedText = [file.title, file.note, file.contentText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return buildAttachedFileContext(
            file: file,
            extractedText: String(storedText.prefix(Self.attachedContextCharacterLimit))
        )
    }

    private func appendUnique(_ hit: VectorSearchHit,
                              to chunks: inout [VectorSearchHit],
                              seen: inout Set<String>) {
        let key = hit.chunkIndex.map { "\(hit.fileId):\($0)" }
            ?? "\(hit.fileId):\(hit.chunkText ?? "")"
        guard seen.insert(key).inserted else { return }
        chunks.append(hit)
    }

    static func relevanceTerms(in question: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "and", "with", "this", "that", "what", "where", "which", "please",
            "find", "show", "list", "file", "files", "document", "documents",
            "latest", "recent", "newest", "last",
            "\u{7684}", "\u{6587}\u{4EF6}", "\u{6587}\u{6863}", "\u{54EA}\u{91CC}",
            "\u{5728}\u{54EA}", "\u{4F4D}\u{7F6E}", "\u{67E5}\u{627E}", "\u{8BF7}",
            "\u{627E}\u{51FA}", "\u{5217}\u{51FA}", "\u{6700}\u{8FD1}",
            "\u{6700}\u{65B0}", "\u{8FD1}\u{671F}", "\u{5F20}", "\u{4E2A}",
            "\u{5341}\u{5F20}"
        ]
        let normalizedQuestion = question.lowercased()
        var candidates = normalizedQuestion
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalizedQuestion
        tokenizer.enumerateTokens(
            in: normalizedQuestion.startIndex..<normalizedQuestion.endIndex
        ) { range, _ in
            candidates.append(String(normalizedQuestion[range]))
            return true
        }
        if normalizedQuestion.contains("\u{53D1}\u{7968}") || normalizedQuestion.contains("invoice") {
            candidates.append(contentsOf: ["\u{53D1}\u{7968}", "invoice", "invoices", "inv-"])
        }
        var seen = Set<String>()
        return candidates
            .filter { $0.count >= 2 && !stopWords.contains($0) && seen.insert($0).inserted }
    }

    static func prefersRecentFiles(in question: String) -> Bool {
        let normalized = question.lowercased()
        return [
            "\u{6700}\u{8FD1}", "\u{6700}\u{65B0}", "\u{8FD1}\u{671F}",
            "\u{65B0}\u{8FD1}", "latest", "recent", "newest", "last ",
        ]
            .contains { normalized.contains($0) }
    }

    private static func smartSearchSystemPrompt(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: now)
        return """
        Convert the user's file-search request into one strict JSON object. Today is \(today).
        Return JSON only. Put the intent field first, using this schema:
        {
          "intent": "one concise user-facing sentence describing what will be searched and prioritized",
          "semantic_query": "content meaning to embed, without date, type, or sorting instructions",
          "keywords": ["exact identifier or lexical term"],
          "categories": ["documents|images|videos|audio|code|archives|other"],
          "date_from": "YYYY-MM-DD or null",
          "date_to": "YYYY-MM-DD or null",
          "sort": "relevance|newest"
        }
        Resolve relative dates such as today, yesterday, this week, last month, this year, and their Chinese equivalents into absolute inclusive dates.
        Write intent in the same language as the user's request. Keep it to one sentence without line breaks or quotation marks.
        Preserve distinctive names, invoice numbers, vehicle numbers, and other identifiers in keywords. Use at most 8 concise keywords.
        Use an empty category list when no type was requested. Use null for both dates when no date was requested.
        Do not answer the request and do not include Markdown fences.
        """
    }

    static func streamedSearchIntent(in response: String) -> String? {
        guard let marker = response.range(of: #""intent""#),
              let colon = response[marker.upperBound...].firstIndex(of: ":") else {
            return nil
        }
        let valueStart = response.index(after: colon)
        guard valueStart < response.endIndex,
              let openingQuote = response[valueStart...].firstIndex(of: "\"") else {
            return nil
        }

        var intent = ""
        var isEscaped = false
        var index = response.index(after: openingQuote)
        while index < response.endIndex {
            let character = response[index]
            if isEscaped {
                switch character {
                case "n", "r", "t": intent.append(" ")
                case "\"": intent.append("\"")
                case "\\": intent.append("\\")
                case "/": intent.append("/")
                default: intent.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return intent.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                intent.append(character)
            }
            index = response.index(after: index)
        }
        return intent
    }

    private static func decodeSmartSearchPlan(
        _ response: String,
        fallbackQuery: String,
        calendar: Calendar = .current
    ) throws -> SmartLibrarySearchPlan {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"),
              start <= end,
              let data = String(response[start...end]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(SmartSearchPlanPayload.self, from: data) else {
            throw SmartSearchPlanError.invalidJSON
        }

        let semanticQuery = payload.semanticQuery?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var seen = Set<String>()
        let keywords = (payload.keywords ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(8)
        let categories = Set((payload.categories ?? []).compactMap {
            FileCategory(rawValue: $0.lowercased())
        })
        let dateInterval = smartSearchDateInterval(
            from: payload.dateFrom,
            through: payload.dateTo,
            calendar: calendar
        )
        let effectiveSemanticQuery = semanticQuery.isEmpty
            && keywords.isEmpty
            && categories.isEmpty
            && dateInterval == nil
            ? fallbackQuery
            : semanticQuery
        return SmartLibrarySearchPlan(
            semanticQuery: effectiveSemanticQuery,
            keywords: Array(keywords),
            categories: categories,
            dateInterval: dateInterval,
            sortNewestFirst: payload.sort?.lowercased() == "newest"
        )
    }

    private static func fallbackSmartSearchPlan(
        for query: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SmartLibrarySearchPlan {
        let relativeIntent = relativeDateIntent(in: query, now: now, calendar: calendar)
        let explicitYearInterval: DateInterval? = {
            let years = requestedYears(in: query)
            guard years.count == 1, let year = years.first,
                  let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(byAdding: .year, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }()
        return SmartLibrarySearchPlan(
            semanticQuery: query,
            keywords: Array(relevanceTerms(in: query).prefix(8)),
            categories: inferredSearchCategories(in: query),
            dateInterval: relativeIntent?.interval ?? explicitYearInterval,
            sortNewestFirst: prefersRecentFiles(in: query)
        )
    }

    private static func smartSearchDateInterval(
        from startValue: String?,
        through endValue: String?,
        calendar: Calendar
    ) -> DateInterval? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let startValue, let endValue,
              let rawStart = formatter.date(from: startValue),
              let rawEnd = formatter.date(from: endValue) else { return nil }
        let start = calendar.startOfDay(for: min(rawStart, rawEnd))
        let endStart = calendar.startOfDay(for: max(rawStart, rawEnd))
        guard let end = calendar.date(byAdding: .day, value: 1, to: endStart) else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func inferredSearchCategories(in query: String) -> Set<FileCategory> {
        let normalized = query.lowercased()
        let mappings: [(FileCategory, [String])] = [
            (.documents, ["\u{6587}\u{6863}", "pdf", "word", "docx", "document"]),
            (.images, ["\u{56FE}\u{7247}", "\u{7167}\u{7247}", "\u{622A}\u{56FE}", "image", "photo", "screenshot"]),
            (.videos, ["\u{89C6}\u{9891}", "video", "movie"]),
            (.audio, ["\u{97F3}\u{9891}", "\u{5F55}\u{97F3}", "audio", "recording"]),
            (.code, ["\u{4EE3}\u{7801}", "\u{6E90}\u{7801}", "code", "source"]),
            (.archives, ["\u{538B}\u{7F29}\u{5305}", "\u{5F52}\u{6863}", "zip", "archive"]),
        ]
        return Set(mappings.compactMap { category, terms in
            terms.contains(where: { normalized.contains($0) }) ? category : nil
        })
    }

    private static let relativeDatePhrases = [
        "day before yesterday", "\u{6700}\u{8FD1} 30 \u{5929}", "\u{8FC7}\u{53BB} 30 \u{5929}", "last 30 days", "past 30 days",
        "\u{6700}\u{8FD1}30\u{5929}", "\u{8FC7}\u{53BB}30\u{5929}", "\u{6700}\u{8FD1} 7 \u{5929}", "\u{8FC7}\u{53BB} 7 \u{5929}", "last 7 days", "past 7 days",
        "\u{6700}\u{8FD1}7\u{5929}", "\u{8FC7}\u{53BB}7\u{5929}", "this month", "last month", "this week", "last week",
        "this year", "last year", "\u{8FD9}\u{4E2A}\u{6708}", "\u{4E0A}\u{4E2A}\u{6708}", "\u{672C}\u{6708}",
        "\u{672C}\u{5468}", "\u{8FD9}\u{5468}", "\u{4E0A}\u{5468}", "\u{4ECA}\u{5E74}",
        "\u{672C}\u{5E74}", "\u{53BB}\u{5E74}", "\u{524D}\u{5929}", "yesterday", "\u{6628}\u{5929}",
        "today", "\u{4ECA}\u{5929}",
    ]

    static func relativeDateIntent(
        in query: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> LibraryRelativeDateIntent? {
        let normalized = query.lowercased()
        func containsAny(_ phrases: [String]) -> Bool {
            phrases.contains { normalized.contains($0) }
        }
        func dayIntent(offset: Int) -> LibraryRelativeDateIntent? {
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return LibraryRelativeDateIntent(
                interval: DateInterval(start: start, end: end),
                contentYears: []
            )
        }
        func trailingDaysIntent(_ days: Int) -> LibraryRelativeDateIntent? {
            let today = calendar.startOfDay(for: now)
            guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return LibraryRelativeDateIntent(
                interval: DateInterval(start: start, end: end),
                contentYears: []
            )
        }
        func currentInterval(
            _ component: Calendar.Component,
            contentYears: Set<Int> = []
        ) -> LibraryRelativeDateIntent? {
            guard let interval = calendar.dateInterval(of: component, for: now) else { return nil }
            return LibraryRelativeDateIntent(interval: interval, contentYears: contentYears)
        }
        func previousInterval(
            _ component: Calendar.Component,
            contentYears: Set<Int> = []
        ) -> LibraryRelativeDateIntent? {
            guard let current = calendar.dateInterval(of: component, for: now),
                  let start = calendar.date(byAdding: component, value: -1, to: current.start) else {
                return nil
            }
            return LibraryRelativeDateIntent(
                interval: DateInterval(start: start, end: current.start),
                contentYears: contentYears
            )
        }

        if containsAny(["\u{6700}\u{8FD1}30\u{5929}", "\u{8FC7}\u{53BB} 30 \u{5929}", "\u{8FC7}\u{53BB}30\u{5929}", "last 30 days", "past 30 days"]) {
            return trailingDaysIntent(30)
        }
        if containsAny(["\u{6700}\u{8FD1}7\u{5929}", "\u{8FC7}\u{53BB} 7 \u{5929}", "\u{8FC7}\u{53BB}7\u{5929}", "last 7 days", "past 7 days"]) {
            return trailingDaysIntent(7)
        }
        if containsAny(["day before yesterday", "\u{524D}\u{5929}"]) { return dayIntent(offset: -2) }
        if containsAny(["yesterday", "\u{6628}\u{5929}"]) { return dayIntent(offset: -1) }
        if containsAny(["today", "\u{4ECA}\u{5929}"]) { return dayIntent(offset: 0) }
        if containsAny(["last week", "\u{4E0A}\u{5468}"]) { return previousInterval(.weekOfYear) }
        if containsAny(["this week", "\u{672C}\u{5468}", "\u{8FD9}\u{5468}"]) { return currentInterval(.weekOfYear) }
        if containsAny(["last month", "\u{4E0A}\u{4E2A}\u{6708}"]) { return previousInterval(.month) }
        if containsAny(["this month", "\u{672C}\u{6708}", "\u{8FD9}\u{4E2A}\u{6708}"]) { return currentInterval(.month) }

        let currentYear = calendar.component(.year, from: now)
        if containsAny(["last year", "\u{53BB}\u{5E74}"]) {
            return previousInterval(.year, contentYears: [currentYear - 1])
        }
        if containsAny(["this year", "\u{4ECA}\u{5E74}", "\u{672C}\u{5E74}"]) {
            return currentInterval(.year, contentYears: [currentYear])
        }
        return nil
    }

    static func isRelativeDateOnlyQuery(_ query: String) -> Bool {
        var remainder = query.lowercased()
        for phrase in relativeDatePhrases.sorted(by: { $0.count > $1.count }) {
            remainder = remainder.replacingOccurrences(of: phrase, with: " ")
        }
        let structuralWords = [
            "documents", "document", "files", "file", "pictures", "picture",
            "modified", "show", "find", "list", "please", "give me", "from", "the",
            "\u{6709}\u{54EA}\u{4E9B}", "\u{6709}\u{4EC0}\u{4E48}", "\u{6587}\u{4EF6}",
            "\u{6587}\u{6863}", "\u{56FE}\u{7247}", "\u{4FEE}\u{6539}", "\u{67E5}\u{627E}",
            "\u{627E}\u{51FA}", "\u{663E}\u{793A}", "\u{5217}\u{51FA}", "\u{7ED9}\u{6211}",
            "\u{8BF7}", "\u{7684}",
        ]
        for word in structuralWords.sorted(by: { $0.count > $1.count }) {
            remainder = remainder.replacingOccurrences(of: word, with: " ")
        }
        return !remainder.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func relativeDateMatchTier(
        of file: FileRecord,
        intent: LibraryRelativeDateIntent
    ) -> Int {
        if !intent.contentYears.isEmpty {
            let searchableText = [file.name, file.title, file.note, file.contentText, file.path]
                .compactMap { $0 }
            if intent.contentYears.contains(where: { year in
                searchableText.contains { containsStandaloneYear(year, in: $0) }
            }) {
                return 2
            }
        }
        return intent.contains(file.mtime) ? 1 : 0
    }

    static func requestedYears(in query: String) -> Set<Int> {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?<!\d)(?:19|20)\d{2}(?!\d)"#
        ) else { return [] }
        let range = NSRange(query.startIndex..<query.endIndex, in: query)
        return Set(expression.matches(in: query, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: query) else { return nil }
            return Int(query[swiftRange])
        })
    }

    private static func requestedYearMatchTier(
        of file: FileRecord,
        requestedYears: Set<Int>,
        calendar: Calendar = .current
    ) -> Int {
        let searchableText = [file.name, file.title, file.note, file.contentText, file.path]
            .compactMap { $0 }
        if requestedYears.contains(where: { year in
            searchableText.contains { containsStandaloneYear(year, in: $0) }
        }) {
            return 2
        }

        return requestedYears.contains(calendar.component(.year, from: file.mtime))
            ? 1
            : 0
    }

    private static func containsStandaloneYear(_ year: Int, in text: String) -> Bool {
        let target = String(year)
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: target, range: searchStart..<text.endIndex) {
            let beforeIsNumber: Bool
            if range.lowerBound == text.startIndex {
                beforeIsNumber = false
            } else {
                beforeIsNumber = text[text.index(before: range.lowerBound)].isNumber
            }
            let afterIsNumber = range.upperBound < text.endIndex
                ? text[range.upperBound].isNumber
                : false
            if !beforeIsNumber && !afterIsNumber { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private struct LibraryLexicalMatch {
        let file: FileRecord
        let score: Int
        let confidence: Double
        let kind: LibrarySearchMatchKind
        let rankingKind: LibrarySearchMatchKind
        let snippet: String?
    }

    private struct LibraryConfidenceEvidence {
        let confidence: Double
        let kind: LibrarySearchMatchKind
        let source: String?
    }

    private static func librarySearchTerms(
        _ query: String,
        additionalTerms: [String] = []
    ) -> [String] {
        var seen = Set<String>()
        return ([query.lowercased()] + additionalTerms.map { $0.lowercased() } + relevanceTerms(in: query)).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    private static func libraryLexicalMatch(
        file: FileRecord,
        query: String,
        terms: [String]
    ) -> LibraryLexicalMatch? {
        let normalizedQuery = query.lowercased()
        let name = file.name.lowercased()
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let title = (file.title ?? "").lowercased()
        let note = (file.note ?? "").lowercased()
        let content = (file.contentText ?? "").lowercased()
        let path = file.path.lowercased()

        var evidence: LibraryConfidenceEvidence?
        func considerEvidence(
            confidence: Double,
            kind: LibrarySearchMatchKind,
            source: String?
        ) {
            guard confidence > evidence?.confidence ?? -1 else { return }
            evidence = LibraryConfidenceEvidence(
                confidence: confidence,
                kind: kind,
                source: source
            )
        }

        let evidenceTerms = terms.filter { !$0.isEmpty && $0 != normalizedQuery }
        func evidenceStrength(in source: String) -> Double? {
            if source.contains(normalizedQuery) { return 1 }
            guard !evidenceTerms.isEmpty else { return nil }
            let matchedCount = evidenceTerms.reduce(into: 0) { count, term in
                if source.contains(term) { count += 1 }
            }
            guard matchedCount > 0 else { return nil }
            return Double(matchedCount) / Double(evidenceTerms.count)
        }

        if stem == normalizedQuery || name == normalizedQuery {
            considerEvidence(confidence: 1, kind: .fileName, source: file.title ?? file.displayPath)
        } else if let strength = evidenceStrength(in: name) {
            considerEvidence(
                confidence: 0.50 + (0.09 * strength),
                kind: .fileName,
                source: file.title ?? file.displayPath
            )
        }
        if let strength = evidenceStrength(in: title) {
            considerEvidence(
                confidence: 0.60 + (0.09 * strength),
                kind: .title,
                source: file.title
            )
        }
        if let strength = evidenceStrength(in: note) {
            considerEvidence(
                confidence: 0.75 + (0.09 * strength),
                kind: .note,
                source: file.note
            )
        }
        if let strength = evidenceStrength(in: content) {
            considerEvidence(
                confidence: 0.90 + (0.09 * strength),
                kind: .content,
                source: file.contentText
            )
        }
        if let strength = evidenceStrength(in: path) {
            considerEvidence(
                confidence: 0.35 + (0.09 * strength),
                kind: .path,
                source: file.displayPath
            )
        }

        var best: (score: Int, kind: LibrarySearchMatchKind, source: String?)?
        func consider(_ score: Int, _ kind: LibrarySearchMatchKind, _ source: String?) {
            guard score > best?.score ?? -1 else { return }
            best = (score, kind, source)
        }

        if stem == normalizedQuery || name == normalizedQuery {
            consider(140, .fileName, file.title ?? file.note ?? file.displayPath)
        } else if stem.contains(normalizedQuery) || name.contains(normalizedQuery) {
            consider(120, .fileName, file.title ?? file.note ?? file.displayPath)
        }
        if title == normalizedQuery { consider(115, .title, file.title) }
        else if title.contains(normalizedQuery) { consider(100, .title, file.title) }
        if note.contains(normalizedQuery) { consider(85, .note, file.note) }
        if content.contains(normalizedQuery) { consider(65, .content, file.contentText) }
        if path.contains(normalizedQuery) { consider(50, .path, file.displayPath) }

        var termScore = 0
        var termMatch: (priority: Int, kind: LibrarySearchMatchKind, source: String?)?
        func recordTermMatch(
            priority: Int,
            kind: LibrarySearchMatchKind,
            source: String?
        ) {
            guard priority > termMatch?.priority ?? -1 else { return }
            termMatch = (priority, kind, source)
        }
        for term in terms where term != normalizedQuery {
            if name.contains(term) {
                termScore += 12
                recordTermMatch(priority: 5, kind: .fileName, source: file.title ?? file.displayPath)
            } else if title.contains(term) {
                termScore += 10
                recordTermMatch(priority: 4, kind: .title, source: file.title)
            } else if note.contains(term) {
                termScore += 7
                recordTermMatch(priority: 3, kind: .note, source: file.note)
            } else if content.contains(term) {
                termScore += 4
                recordTermMatch(priority: 2, kind: .content, source: file.contentText)
            } else if path.contains(term) {
                termScore += 3
                recordTermMatch(priority: 1, kind: .path, source: file.displayPath)
            }
        }
        if best == nil, let termMatch, termScore > 0 {
            best = (termScore, termMatch.kind, termMatch.source)
        } else {
            best?.score += termScore
        }
        guard let best, let evidence else { return nil }
        return LibraryLexicalMatch(
            file: file,
            score: best.score,
            confidence: min(evidence.confidence, 1),
            kind: evidence.kind,
            rankingKind: best.kind,
            snippet: evidence.source.flatMap { compactExcerpt($0, terms: terms) }
        )
    }

    private static func semanticConfidence(for hit: VectorSearchHit) -> Double {
        let strength = min(max(Double(hit.score), 0), 1)
        let base: Double
        switch hit.kind {
        case .text, .table, .list, .picture:
            base = 0.90
        case .note:
            base = 0.75
        case .title:
            base = 0.60
        case .metadata:
            base = 0.35
        }
        return min(base + (0.09 * strength), 1)
    }

    private static func compactExcerpt(_ source: String, terms: [String], limit: Int = 240) -> String? {
        let normalized = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let match = terms.lazy.compactMap {
            normalized.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
        }.first
        guard let match else {
            return normalized.count > limit ? String(normalized.prefix(limit)) + "…" : normalized
        }
        let leading = 72
        let trailing = max(0, limit - leading)
        let start = normalized.index(match.lowerBound, offsetBy: -leading, limitedBy: normalized.startIndex)
            ?? normalized.startIndex
        let end = normalized.index(match.upperBound, offsetBy: trailing, limitedBy: normalized.endIndex)
            ?? normalized.endIndex
        let excerpt = String(normalized[start..<end])
        return (start == normalized.startIndex ? "" : "…")
            + excerpt
            + (end == normalized.endIndex ? "" : "…")
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

    private func buildLibraryContext(from files: [FileRecord],
                                     matchedChunks: [Int64: [VectorSearchHit]]) -> String {
        let responseInstructions = """
        You are FileNest, a local file assistant. Follow these response rules:
        - Answer in the same language as the user's latest question.
        - Return clean, valid Markdown. Start with a direct answer, then use short paragraphs or a flat bullet list only when it improves clarity.
        - If a table is useful, use valid GitHub-Flavored Markdown with the header, separator, and every data row on separate lines. Add a blank line before and after the table.
        - Use **bold** only for short labels and `backticks` only for file names or short technical values.
        - Refer to files by their natural file names. Never expose internal retrieval indexes such as [1] or [2], the label "File:", raw context delimiters, or source-debug metadata.
        - Retrieved files are ordered by combined filename/title and semantic relevance. For requests asking for recent or latest files, preserve the supplied newest-first order. When the question includes a distinctive identifier found in a filename or title, prefer that direct match over a transcript that only mentions it.
        - Keep the answer and cited file consistent. Do not describe one file while presenting another file as the primary match.
        - Do not repeat the same file metadata. The FileNest interface already shows matched-file cards with preview and full location.
        - Mention a readable parent folder when location matters. Include an exact path only when the user explicitly asks for the exact path.
        - Do not invent facts. If the retrieved content is insufficient, say so clearly.
        """

        guard !files.isEmpty else {
            return responseInstructions + "\n\nNo highly relevant local files were found. Say this clearly and suggest a more specific search phrase."
        }

        var lines = [responseInstructions, "RETRIEVED FILES START"]
        for file in files {
            var fileLines = [
                "FILE START",
                "Name: \(file.name)",
                "Category: \(settings.localized(file.categoryEnum.label))",
                "Location: \(abbreviatedPath(file.path))",
                "Modified: \(ISO8601DateFormatter().string(from: file.mtime))",
            ]
            if let title = file.title, !title.isEmpty {
                fileLines.append("Title: \(title)")
            }
            if let id = file.id, let chunks = matchedChunks[id], !chunks.isEmpty {
                for hit in chunks.prefix(3) {
                    guard let chunk = hit.chunkText, !chunk.isEmpty else { continue }
                    var location = hit.sectionPath.joined(separator: " › ")
                    if let start = hit.pageStart {
                        let pageLabel = hit.pageEnd.flatMap { $0 == start ? nil : $0 }
                            .map { "p.\(start)–\($0)" } ?? "p.\(start)"
                        location = location.isEmpty ? pageLabel : "\(location) · \(pageLabel)"
                    }
                    let locationLabel = location.isEmpty ? "" : " (\(location))"
                    fileLines.append("Relevant excerpt\(locationLabel): \(String(chunk.prefix(1_200)))")
                }
            } else if let content = file.contentText, !content.isEmpty {
                fileLines.append("Excerpt: \(String(content.prefix(500)))")
            }
            fileLines.append("FILE END")
            lines.append(fileLines.joined(separator: "\n"))
        }
        lines.append("RETRIEVED FILES END")
        return lines.joined(separator: "\n\n")
    }

    private func buildAttachedFileContext(file: FileRecord, extractedText: String) -> String {
        """
        You are FileNest in single-file chat mode. Answer only from the attached file below.
        - Answer in the same language as the user's latest question.
        - Do not search, mention, or infer facts from the wider file library.
        - Start with a direct answer. Use concise headings, paragraphs, or lists when useful.
        - Return clean, valid Markdown. If a table is useful, put the header, separator, and every row on separate lines, with a blank line before and after it.
        - Do not repeat the path unless the user explicitly asks for it.
        - If the file does not contain enough information, say so clearly instead of guessing.

        ATTACHED FILE START
        Name: \(file.name)
        Type: \(file.ext)
        Content:
        \(extractedText)
        ATTACHED FILE END
        """
    }

    private func buildIndexedAttachedFileContext(file: FileRecord,
                                                 chunks: [VectorSearchHit]) -> String {
        var excerpts = [String]()
        var characterCount = 0
        for chunk in chunks {
            guard let text = chunk.chunkText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            var location = chunk.sectionPath.joined(separator: " › ")
            if let start = chunk.pageStart {
                let page = chunk.pageEnd.flatMap { $0 == start ? nil : $0 }
                    .map { "p.\(start)–\($0)" } ?? "p.\(start)"
                location = location.isEmpty ? page : "\(location) · \(page)"
            }
            let label = location.isEmpty ? "RELEVANT EXCERPT" : "RELEVANT EXCERPT (\(location))"
            let separatorLength = excerpts.isEmpty ? 0 : 2
            let remaining = Self.attachedContextCharacterLimit
                - characterCount
                - label.count
                - 1
                - separatorLength
            guard remaining > 0 else { break }
            let excerpt = "\(label)\n\(String(text.prefix(remaining)))"
            excerpts.append(excerpt)
            characterCount += separatorLength + excerpt.count
        }

        return buildAttachedFileContext(
            file: file,
            extractedText: excerpts.joined(separator: "\n\n")
        )
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func transientFile(url: URL) -> FileRecord {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileRecord(
            id: nil,
            path: url.path,
            name: url.lastPathComponent,
            ext: url.pathExtension.lowercased(),
            size: Int64(values?.fileSize ?? 0),
            mtime: values?.contentModificationDate ?? Date(),
            category: FileCategory.from(extension: url.pathExtension).rawValue,
            sourceDir: url.deletingLastPathComponent().path,
            indexedAt: nil,
            contentHash: nil,
            title: url.deletingPathExtension().lastPathComponent,
            contentText: nil
        )
    }

    // MARK: - Session updates

    private func updateSessionAfterQuestion(sessionId: Int64, question: String) {
        guard var session = loadSessions().first(where: { $0.id == sessionId }) else { return }
        if session.title == "New Chat" || session.title == URL(fileURLWithPath: session.attachedFilePath ?? "").lastPathComponent {
            let compact = question
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            session.title = String(compact.prefix(32))
        }
        session.updatedAt = Date()
        try? store.updateChatSession(session)
    }

    private func touchSession(_ sessionId: Int64) {
        guard var session = loadSessions().first(where: { $0.id == sessionId }) else { return }
        session.updatedAt = Date()
        try? store.updateChatSession(session)
    }

    private func llmFailureMessage(error: Error, modelOverride: String?) -> String {
        let model = modelOverride ?? settings.ollamaModel
        return settings.localizedFormat(
            "⚠️ LLM call failed: %@\n\nMake sure model %@ is available, or switch models at the top of the chat page.",
            settings.localizedRuntimeMessage(error.localizedDescription),
            model
        )
    }

    private func activeModelName(for mode: ChatProviderMode = .configured) -> String {
        if case .local(let model) = mode { return model }
        switch AppSettings.LLMChoice(rawValue: settings.llmChoice) ?? .ollama {
        case .ollama: return settings.ollamaModel
        case .cloud: return settings.cloudModel
        case .none: return "none"
        }
    }

    private func contextWindowSource(for mode: ChatProviderMode,
                                     modelOverride: String?) -> ChatModelContextSource {
        if providedLLMProvider != nil, case .configured = mode { return .fallback }
        switch mode {
        case .local(let model):
            return .ollama(
                host: settings.ollamaHost,
                model: model,
                memoryGB: OllamaModelRecommendation.currentMemoryGB
            )
        case .configured:
            switch AppSettings.LLMChoice(rawValue: settings.llmChoice) ?? .ollama {
            case .ollama:
                return .ollama(
                    host: settings.ollamaHost,
                    model: modelOverride ?? settings.ollamaModel,
                    memoryGB: OllamaModelRecommendation.currentMemoryGB
                )
            case .cloud:
                return .cloud(
                    format: settings.cloudAPIFormat,
                    model: modelOverride ?? settings.cloudModel
                )
            case .none:
                return .fallback
            }
        case .vectorOnly:
            return .fallback
        }
    }

    private func vectorFallbackMessage(files: [FileRecord], cloudFailure: String?) -> String {
        let prefix: String
        if let cloudFailure, !cloudFailure.isEmpty {
            prefix = settings.localizedFormat("Cloud AI failed: %@", cloudFailure)
        } else {
            prefix = settings.localized("No generation model is currently being used.")
        }
        guard !files.isEmpty else {
            return prefix + "\n\n" + settings.localized("No related files were found in the local index.")
        }
        return prefix + "\n\n" + settings.localizedFormat(
            "Showing the top %d matches from the local vector index. Click a file below to preview it.",
            files.count
        )
    }

    /// Uses one estimate across local and cloud providers: 1 token is about 0.75 English words or 1.5 CJK characters.
    static func estimatedTokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var estimate = 0.0
        var insideEnglishWord = false
        for character in text {
            let isEnglishWordCharacter = character.unicodeScalars.allSatisfy { scalar in
                guard scalar.isASCII else { return false }
                return CharacterSet.alphanumerics.contains(scalar)
                    || scalar.value == 0x27
                    || scalar.value == 0x2D
                    || scalar.value == 0x5F
            }
            if isEnglishWordCharacter {
                if !insideEnglishWord { estimate += 4.0 / 3.0 }
                insideEnglishWord = true
            } else {
                insideEnglishWord = false
                if character.isWhitespace { continue }
                let isChinese = character.unicodeScalars.allSatisfy { scalar in
                    switch scalar.value {
                    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                         0x20000...0x2A6DF, 0x2A700...0x2EBEF, 0x30000...0x323AF:
                        return true
                    default:
                        return false
                    }
                }
                estimate += isChinese ? 2.0 / 3.0 : 1
            }
        }
        return max(1, Int(ceil(estimate)))
    }
}

/// Lightweight proxy for the IndexerService vector store, avoiding a ChatService-to-IndexerService ownership cycle.
final class AppStateIndexerProxy {
    static let shared = AppStateIndexerProxy()
    weak var indexer: IndexerService?
    var vectorStore: AccelerateVectorStore {
        indexer?.vectorStore ?? AccelerateVectorStore(store: SQLiteStore.shared)
    }
}
