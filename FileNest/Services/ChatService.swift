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
        case reranking
        case matchesFound
        case readingFile
        case fileReady
        case analyzing
        case thinking
        case verifying
    }

    let phase: Phase
    var scope: Scope = .library
    var matchedFileCount: Int = 0
    var matchedFiles: [FileRecord] = []
    var usesExistingIndex = false
    var searchIntent = ""
}

enum LibrarySearchMatchKind: String, Codable, Equatable {
    case fileName
    case title
    case note
    case content
    case path
    case date
    case filter
    case semantic
    case entity
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
        case .entity: return "Exact Entity Match"
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

struct SmartLibrarySearchPlan: Codable, Equatable {
    let semanticQuery: String
    let keywords: [String]
    let exactName: String?
    let fileExtensions: Set<String>
    let categories: Set<FileCategory>
    let folderTerms: [String]
    let itemKind: LibrarySearchItemKind
    let dateField: LibrarySearchDateField
    let dateInterval: DateInterval?
    let minimumSizeBytes: Int64?
    let maximumSizeBytes: Int64?
    let hasNote: Bool?
    let isIndexed: Bool?
    let sort: LibrarySearchSort

    var sortNewestFirst: Bool { sort == .newest }

    var hasStructuredFilters: Bool {
        exactName != nil
            || !fileExtensions.isEmpty
            || !categories.isEmpty
            || !folderTerms.isEmpty
            || itemKind != .any
            || dateInterval != nil
            || minimumSizeBytes != nil
            || maximumSizeBytes != nil
            || hasNote != nil
            || isIndexed != nil
    }

    var hasContentIntent: Bool {
        !semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !keywords.isEmpty
            || exactName != nil
    }
}

enum LibrarySearchItemKind: String, Codable, Equatable {
    case any
    case file
    case directory
}

enum LibrarySearchDateField: String, Codable, Equatable {
    case modified
    case added
    case organized

    func date(for file: FileRecord) -> Date? {
        switch self {
        case .modified: return file.mtime
        case .added: return file.addedAt
        case .organized: return file.organizedAt
        }
    }
}

enum LibrarySearchSort: String, Codable, Equatable {
    case relevance
    case newest
    case oldest
    case largest
    case smallest
}

struct SmartLibrarySearchResponse: Equatable {
    let results: [LibrarySearchResult]
    let plan: SmartLibrarySearchPlan
    let usedAI: Bool
}

struct CachedLibrarySearch: Equatable {
    let results: [LibrarySearchResult]
    let smartPlan: SmartLibrarySearchPlan?
    let usedAI: Bool
}

struct CachedLibrarySearchPayload: Codable, Equatable {
    let results: [CachedLibrarySearchResult]
    let smartPlan: SmartLibrarySearchPlan?
    let usedAI: Bool
}

struct CachedLibrarySearchResult: Codable, Equatable {
    let fileID: Int64?
    let path: String
    let score: Double
    let confidence: Double
    let matchKind: LibrarySearchMatchKind
    let snippet: String?
    let sectionPath: [String]
    let pageStart: Int?
    let pageEnd: Int?

    init(_ result: LibrarySearchResult) {
        fileID = result.file.id
        path = result.file.path
        score = result.score
        confidence = result.confidence
        matchKind = result.matchKind
        snippet = result.snippet
        sectionPath = result.sectionPath
        pageStart = result.pageStart
        pageEnd = result.pageEnd
    }
}

struct LibrarySearchHistoryEntry: Identifiable, Equatable, Sendable {
    let id: Int64
    let query: String
    let isSmartSearch: Bool
    let updatedAt: Date
    let resultCount: Int
    let hasValidCache: Bool
}

struct LibrarySearchCacheRecord: Equatable, Sendable {
    let revision: Int64
    let payload: Data
}

private struct LibrarySearchExecution {
    let results: [LibrarySearchResult]
    let semanticHitsByFile: [Int64: [VectorSearchHit]]
}

private struct SmartSearchPlanPayload: Decodable {
    let intent: String?
    let semanticQuery: String?
    let keywords: [String]?
    let exactName: String?
    let fileExtensions: [String]?
    let categories: [String]?
    let folderTerms: [String]?
    let itemKind: String?
    let dateField: String?
    let dateFrom: String?
    let dateTo: String?
    let minimumSizeBytes: Int64?
    let maximumSizeBytes: Int64?
    let hasNote: Bool?
    let isIndexed: Bool?
    let sort: String?

    enum CodingKeys: String, CodingKey {
        case intent
        case semanticQuery = "semantic_query"
        case keywords
        case exactName = "exact_name"
        case fileExtensions = "file_extensions"
        case categories
        case folderTerms = "folder_terms"
        case itemKind = "item_kind"
        case dateField = "date_field"
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case minimumSizeBytes = "size_min_bytes"
        case maximumSizeBytes = "size_max_bytes"
        case hasNote = "has_note"
        case isIndexed = "is_indexed"
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
    private static let semanticScoreFloor: Float = 0.38
    private static let semanticScoreWindow: Float = 0.18
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

    /// Updates the latest editable user question without inserting another message.
    /// The following assistant answer can then be replaced through `retryAnswer`.
    @discardableResult
    func editUserMessage(id: Int64, sessionId: Int64, content rawContent: String) -> ChatMessage? {
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty,
              var message = loadHistory(sessionId: sessionId).first(where: {
                  $0.id == id && $0.role == ChatRole.user.rawValue
              }) else { return nil }
        message.content = content
        do {
            try store.updateChatMessage(message)
            updateSessionAfterQuestion(sessionId: sessionId, question: content)
            return message
        } catch {
            AppLogService.shared.write(
                "chat user message edit failed",
                category: .chat,
                level: .error,
                metadata: ["session_id": "\(sessionId)", "message_id": "\(id)", "error": error.localizedDescription]
            )
            return nil
        }
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
                    smartSearchPlan: smartSearchPlan,
                    onReranking: {
                        continuation.yield(.progress(ChatProgress(
                            phase: .reranking,
                            scope: .library,
                            searchIntent: searchIntent
                        )))
                    }
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
                if providerCompleted, !isFileChat, !related.files.isEmpty {
                    continuation.yield(.progress(ChatProgress(
                        phase: .verifying,
                        scope: .library,
                        matchedFileCount: related.files.count,
                        matchedFiles: related.files,
                        searchIntent: searchIntent
                    )))
                    fullReply = verifiedRAGAnswer(fullReply, retrievalContext: related.context)
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

    private func verifiedRAGAnswer(_ answer: String, retrievalContext: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"\[F\d+(?::P\d+)?\]"#) else {
            return answer
        }
        let contextRange = NSRange(retrievalContext.startIndex..<retrievalContext.endIndex, in: retrievalContext)
        let validIDs = Set(expression.matches(in: retrievalContext, range: contextRange).compactMap { match in
            Range(match.range, in: retrievalContext).map { String(retrievalContext[$0]) }
        })
        let answerRange = NSRange(answer.startIndex..<answer.endIndex, in: answer)
        let answerIDs = expression.matches(in: answer, range: answerRange).compactMap { match in
            Range(match.range, in: answer).map { String(answer[$0]) }
        }
        var verified = answer
        let invalidIDs = Set(answerIDs).subtracting(validIDs)
        for invalidID in invalidIDs { verified = verified.replacingOccurrences(of: invalidID, with: "") }
        let supportedCount = answerIDs.filter(validIDs.contains).count
        let hasSpecificFactualClaim = verified.range(
            of: #"(?:\d{2,}|[$€£¥]\s*\d|\b(?:SGD|USD|EUR|CNY|RMB)\s*\d)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if supportedCount == 0, hasSpecificFactualClaim {
            verified += "\n\n> " + settings.localized(
                "Evidence note: this answer did not include a verifiable source citation. Review the matched files before relying on specific details."
            )
        }
        AppLogService.shared.write(
            "RAG answer citation validation completed",
            category: .vectorSearch,
            level: invalidIDs.isEmpty && supportedCount > 0 ? .debug : .warning,
            metadata: ["supported": "\(supportedCount)", "invalid": "\(invalidIDs.count)"]
        )
        return verified
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

    func searchLibrary(
        _ rawQuery: String,
        limit: Int = 200,
        managedRootPath: String? = nil
    ) async -> [LibrarySearchResult] {
        let results = await executeLibrarySearch(rawQuery, limit: limit, smartPlan: nil)
        return Self.existingManagedResults(results, rootPath: managedRootPath)
    }

    func smartSearchLibrary(
        _ rawQuery: String,
        limit: Int = 200,
        managedRootPath: String? = nil,
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
        let results = Self.existingManagedResults(
            await executeLibrarySearch(query, limit: limit, smartPlan: plan),
            rootPath: managedRootPath
        )
        return SmartLibrarySearchResponse(results: results, plan: plan, usedAI: resolved.usedAI)
    }

    private static func existingManagedResults(
        _ results: [LibrarySearchResult],
        rootPath: String?
    ) -> [LibrarySearchResult] {
        guard let rootPath else { return results }
        let canonicalRoot = canonicalPath(rootPath)
        return results.filter { result in
            let path = result.file.path
            return canonicalPath(path).hasPrefix(canonicalRoot + "/")
                && FileManager.default.fileExists(atPath: path)
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
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
            let decoded = try Self.decodeSmartSearchPlan(reply, fallbackQuery: query)
            return (Self.reconciledSmartSearchPlan(decoded, fallback: fallbackPlan, query: query), true)
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
        sortByConfidence: Bool = false,
        onReranking: (() -> Void)? = nil
    ) async -> LibrarySearchExecution {
        let searchStartedAt = Date()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else {
            return LibrarySearchExecution(results: [], semanticHitsByFile: [:])
        }

        let semanticQuery = smartPlan?.semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSemanticQuery = semanticQuery.flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.contentSearchQuery(in: query)
        // Keep model paraphrases in vector retrieval only. Lexical ranking must use terms
        // grounded in the user's original wording, otherwise translated grammar can become evidence.
        let terms = Self.librarySearchTerms(
            query,
            additionalTerms: (smartPlan?.keywords ?? [])
                + [smartPlan?.exactName].compactMap { $0 }
                + (smartPlan?.folderTerms ?? [])
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
        var acceptedSemanticCount = 0
        var effectiveSemanticThreshold: Float?
        let entityTerms = IndexerService.extractedEntityTerms(from: query)
        let entityHits = (try? store.entityChunkMatches(
            terms: entityTerms,
            limit: max(20, min(limit * 2, 60))
        )) ?? []
        var entityByID = [Int64: VectorSearchHit]()
        for hit in entityHits {
            semanticHitsByFile[hit.fileId, default: []].append(hit)
            if hit.score > (entityByID[hit.fileId]?.score ?? -.infinity) {
                entityByID[hit.fileId] = hit
            }
        }
        if !effectiveSemanticQuery.isEmpty,
           let queryVector = try? await activeEmbedder().embed(effectiveSemanticQuery), !queryVector.isEmpty {
            let vectorStore = providedVectorStore ?? AppStateIndexerProxy.shared.vectorStore
            let hits = await vectorStore.searchChunks(queryVector, k: max(40, min(limit * 6, 120)))
            let dynamicallyAccepted: [VectorSearchHit]
            if relativeDateIntent != nil || !Self.requestedYears(in: query).isEmpty {
                dynamicallyAccepted = hits
                    .filter { $0.score.isFinite && $0.score >= Self.semanticScoreFloor }
                    .sorted { $0.score > $1.score }
            } else {
                dynamicallyAccepted = Self.dynamicallyAcceptedSemanticHits(hits)
            }
            acceptedSemanticCount = dynamicallyAccepted.count
            effectiveSemanticThreshold = dynamicallyAccepted.map(\.score).min()
            if settings.makeRerankingProvider() != nil, dynamicallyAccepted.count > 1 {
                onReranking?()
            }
            let acceptedHits = await rerankedSemanticHits(
                dynamicallyAccepted,
                query: effectiveSemanticQuery
            )
            for hit in acceptedHits {
                semanticHitsByFile[hit.fileId, default: []].append(hit)
                if hit.score > (semanticByID[hit.fileId]?.score ?? -.infinity) {
                    semanticByID[hit.fileId] = hit
                }
            }
        }

        var structuredByID = [Int64: FileRecord]()
        if isRelativeDateOnlyQuery || smartPlan?.hasStructuredFilters == true {
            for file in (try? store.allFiles()) ?? [] {
                let date: Date? = smartPlan == nil
                    ? file.mtime
                    : smartPlan?.dateField.date(for: file)
                let matchesDate = date.map { relativeDateIntent?.contains($0) ?? true } ?? false
                guard matchesDate,
                      smartPlan.map({ Self.matchesStructuredPlan(file, plan: $0) }) ?? true,
                      let id = file.id else { continue }
                structuredByID[id] = file
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
        let entityRank = Dictionary(uniqueKeysWithValues: entityByID
            .sorted { lhs, rhs in
                lhs.value.score == rhs.value.score
                    ? lhs.key < rhs.key
                    : lhs.value.score > rhs.value.score
            }
            .enumerated()
            .map { ($0.element.key, $0.offset + 1) })

        let candidateIDs = Set(lexicalByID.keys)
            .union(semanticByID.keys)
            .union(entityByID.keys)
            .union(structuredByID.keys)
        let results = candidateIDs.compactMap { fileID -> LibrarySearchResult? in
            guard let file = lexicalByID[fileID]?.file
                ?? structuredByID[fileID]
                ?? (try? store.file(id: fileID)) else { return nil }
            let lexical = lexicalByID[fileID]
            let semantic = semanticByID[fileID]
            let entity = entityByID[fileID]
            let isExactNameMatch = smartPlan?.exactName.map {
                Self.fileName(file.name, equals: $0)
            } ?? false
            var score = 0.0
            if let rank = lexicalRank[fileID] { score += 0.36 / Double(60 + rank) }
            if let rank = semanticRank[fileID] { score += 0.44 / Double(60 + rank) }
            if let rank = entityRank[fileID] { score += 0.20 / Double(60 + rank) }
            if isExactNameMatch { score += 0.10 }

            let matchKind: LibrarySearchMatchKind
            if isExactNameMatch || lexical?.confidence == 1 {
                matchKind = .fileName
            } else if entity != nil, lexical != nil || semantic != nil {
                matchKind = .hybrid
            } else if entity != nil {
                matchKind = .entity
            } else if lexical != nil, semantic != nil {
                matchKind = .hybrid
            } else if let lexical {
                matchKind = lexical.kind
            } else if semantic != nil {
                matchKind = .semantic
            } else {
                matchKind = relativeDateIntent != nil ? .date : .filter
            }
            let semanticSnippet = (entity ?? semantic)?.chunkText.flatMap {
                Self.compactExcerpt($0, terms: terms)
            }
            let confidence = max(
                max(
                    max(
                        isExactNameMatch ? 1 : (lexical?.confidence ?? 0),
                        semantic.map { Self.semanticConfidence(for: $0) } ?? 0
                    ),
                    entity == nil ? 0 : 0.98
                ),
                lexical == nil && semantic == nil && entity == nil
                    ? Self.structuredOnlyConfidence(for: smartPlan)
                    : 0
            )
            return LibrarySearchResult(
                file: file,
                score: score,
                confidence: confidence,
                matchKind: matchKind,
                snippet: lexical?.snippet ?? semanticSnippet,
                sectionPath: (entity ?? semantic)?.sectionPath ?? [],
                pageStart: (entity ?? semantic)?.pageStart,
                pageEnd: (entity ?? semantic)?.pageEnd
            )
        }

        let filteredResults = results.filter { result in
            guard let smartPlan else { return true }
            return Self.matchesStructuredPlan(result.file, plan: smartPlan)
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
            if sortByConfidence, let smartPlan {
                let lhsDate = smartPlan.dateField.date(for: lhs.file) ?? .distantPast
                let rhsDate = smartPlan.dateField.date(for: rhs.file) ?? .distantPast
                switch smartPlan.sort {
                case .newest where lhsDate != rhsDate: return lhsDate > rhsDate
                case .oldest where lhsDate != rhsDate: return lhsDate < rhsDate
                case .largest where lhs.file.size != rhs.file.size: return lhs.file.size > rhs.file.size
                case .smallest where lhs.file.size != rhs.file.size: return lhs.file.size < rhs.file.size
                default: break
                }
            } else if smartPlan?.sortNewestFirst == true {
                func relevanceTier(_ result: LibrarySearchResult) -> Int {
                    guard let fileID = result.file.id else { return 0 }
                    guard let lexical = lexicalByID[fileID] else {
                        return semanticByID[fileID] == nil ? 0 : 1
                    }
                    switch lexical.rankingKind {
                    case .content: return 5
                    case .note: return 4
                    case .fileName: return lexical.confidence == 1 ? 6 : 3
                    case .path: return 3
                    case .title: return 2
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
        try? store.recordRAGSearchTrace(
            query: query,
            semanticQuery: effectiveSemanticQuery,
            lexicalCandidates: lexicalByID.count,
            semanticCandidates: acceptedSemanticCount,
            entityCandidates: entityByID.count,
            fusedCandidates: candidateIDs.count,
            returnedResults: sortedResults.count,
            semanticThreshold: effectiveSemanticThreshold,
            reranker: settings.makeRerankingProvider()?.name,
            duration: Date().timeIntervalSince(searchStartedAt)
        )
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
                              smartSearchPlan: SmartLibrarySearchPlan?,
                              onReranking: (() -> Void)? = nil) async -> (files: [FileRecord], context: String) {
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
                    maxTokens: settings.chunkTokenLimit,
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
            smartPlan: smartSearchPlan,
            sortByConfidence: true,
            onReranking: onReranking
        )
        files = execution.results.map(\.file)

        let selectedFileIDs = Set(files.compactMap(\.id))
        let vectorStore = providedVectorStore ?? AppStateIndexerProxy.shared.vectorStore
        var seenChunkKeys = Set<String>()
        for fileID in selectedFileIDs {
            for hit in execution.semanticHitsByFile[fileID] ?? [] {
                let key = "\(hit.fileId):p\(hit.parentIndex ?? hit.chunkIndex ?? -1)"
                if seenChunkKeys.insert(key).inserted {
                    matchedChunks[hit.fileId, default: []].append(hit)
                }
                // New indexes return the complete parent section directly. Neighbor expansion
                // remains only for legacy indexes that do not yet have a parent mapping.
                guard hit.parentText == nil else { continue }
                guard let chunkIndex = hit.chunkIndex else { continue }
                let neighbors = await vectorStore.neighboringChunks(
                    fileId: hit.fileId,
                    around: chunkIndex,
                    radius: 1
                )
                for neighbor in neighbors {
                    let neighborKey = "\(neighbor.fileId):p\(neighbor.parentIndex ?? neighbor.chunkIndex ?? -1)"
                    if seenChunkKeys.insert(neighborKey).inserted {
                        matchedChunks[neighbor.fileId, default: []].append(neighbor)
                    }
                }
            }
        }
        contextParts.append(buildLibraryContext(
            from: execution.results,
            matchedChunks: matchedChunks
        ))
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
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = normalizedQuestion
        tagger.enumerateTags(
            in: normalizedQuestion.startIndex..<normalizedQuestion.endIndex,
            unit: .word,
            scheme: .lemma
        ) { tag, range in
            if let tag { candidates.append(tag.rawValue) }
            candidates.append(String(normalizedQuestion[range]))
            return true
        }
        var seen = Set<String>()
        return candidates
            .filter { $0.count >= 2 && !stopWords.contains($0) && seen.insert($0).inserted }
    }

    private static let genericStructuralWords: Set<String> = [
        "file", "files", "document", "documents", "folder", "folders", "directory", "directories",
        "image", "images", "picture", "pictures", "photo", "photos", "video", "videos", "audio",
        "archive", "archives", "code", "source", "\u{6587}\u{4EF6}", "\u{6587}\u{6863}",
        "\u{6587}\u{4EF6}\u{5939}", "\u{56FE}\u{7247}", "\u{7167}\u{7247}", "\u{89C6}\u{9891}",
        "\u{97F3}\u{9891}", "\u{538B}\u{7F29}\u{5305}", "\u{4EE3}\u{7801}", "\u{6E90}\u{7801}",
    ]

    private static func contentSearchQuery(in query: String) -> String {
        contentSearchTerms(in: query).joined(separator: " ")
    }

    /// Derives content evidence from the user query while removing terms that are
    /// already represented by deterministic filters such as dates and extensions.
    private static func contentSearchTerms(in query: String) -> [String] {
        let stripped = strippingStructuralPhrases(from: query)
        return uniqueSearchTerms(relevanceTerms(in: stripped).filter(isLexicalEvidenceTerm))
    }

    private static func strippingStructuralPhrases(from query: String) -> String {
        var output = query.lowercased()
        let phrases = relativeDatePhrases + Array(genericStructuralWords)
        for phrase in phrases.sorted(by: { $0.count > $1.count }) {
            output = output.replacingOccurrences(of: phrase, with: " ")
        }
        return output
    }

    private static func containsStructuralQueryMarker(in value: String) -> Bool {
        let normalized = value.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if relativeDatePhrases.contains(where: normalized.contains) { return true }
        if recognizedFileExtensions
            .filter({ $0.count >= 2 })
            .contains(where: normalized.contains) {
            return true
        }
        if ["\u{6587}\u{4EF6}", "\u{6587}\u{6863}", "\u{6587}\u{4EF6}\u{5939}", "\u{56FE}\u{7247}",
            "\u{89C6}\u{9891}", "\u{97F3}\u{9891}", "\u{4EE3}\u{7801}", "\u{538B}\u{7F29}\u{5305}"].contains(where: normalized.contains) {
            return true
        }
        let tokens = Set(normalized.components(separatedBy: CharacterSet.alphanumerics.inverted))
        return !tokens.isDisjoint(with: genericStructuralWords)
            || !tokens.isDisjoint(with: recognizedFileExtensions)
    }

    private static func isLexicalEvidenceTerm(_ rawValue: String) -> Bool {
        let value = rawValue.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2,
              !containsStructuralQueryMarker(in: value) else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = value
        let lexicalClass = tagger.tag(
            at: value.startIndex,
            unit: .word,
            scheme: .lexicalClass
        ).0?.rawValue.lowercased()
        let nonEvidenceClasses: Set<String> = [
            "preposition", "conjunction", "determiner", "pronoun", "particle", "interjection",
        ]
        return lexicalClass.map { !nonEvidenceClasses.contains($0) } ?? true
    }

    private static func isExactFileNameCandidate(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = URL(fileURLWithPath: value).pathExtension.lowercased()
        return value.contains(".") && recognizedFileExtensions.contains(ext)
    }

    private static func uniqueSearchTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value.lowercased()).inserted else { return nil }
            return value
        }
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
        return PromptCatalog.Search.planner(today: today)
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
        let rawExactName = payload.exactName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let exactName = rawExactName.isEmpty ? nil : rawExactName
        let fileExtensions = Set((payload.fileExtensions ?? []).compactMap(normalizedExtension))
        var seenFolders = Set<String>()
        let folderTerms = (payload.folderTerms ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seenFolders.insert($0.lowercased()).inserted }
            .prefix(4)
        let itemKind = LibrarySearchItemKind(rawValue: payload.itemKind?.lowercased() ?? "") ?? .any
        let dateField = LibrarySearchDateField(rawValue: payload.dateField?.lowercased() ?? "") ?? .modified
        let dateInterval = smartSearchDateInterval(
            from: payload.dateFrom,
            through: payload.dateTo,
            calendar: calendar
        )
        let effectiveSemanticQuery = semanticQuery.isEmpty
            && keywords.isEmpty
            && exactName == nil
            && fileExtensions.isEmpty
            && categories.isEmpty
            && folderTerms.isEmpty
            && itemKind == .any
            && dateInterval == nil
            && payload.minimumSizeBytes == nil
            && payload.maximumSizeBytes == nil
            && payload.hasNote == nil
            && payload.isIndexed == nil
            ? fallbackQuery
            : semanticQuery
        let sizeBounds = normalizedSizeBounds(
            minimum: payload.minimumSizeBytes,
            maximum: payload.maximumSizeBytes
        )
        return SmartLibrarySearchPlan(
            semanticQuery: effectiveSemanticQuery,
            keywords: Array(keywords),
            exactName: exactName,
            fileExtensions: fileExtensions,
            categories: categories,
            folderTerms: Array(folderTerms),
            itemKind: itemKind,
            dateField: dateField,
            dateInterval: dateInterval,
            minimumSizeBytes: sizeBounds.minimum,
            maximumSizeBytes: sizeBounds.maximum,
            hasNote: payload.hasNote,
            isIndexed: payload.isIndexed,
            sort: LibrarySearchSort(rawValue: payload.sort?.lowercased() ?? "") ?? .relevance
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
            semanticQuery: contentSearchQuery(in: query),
            keywords: Array(contentSearchTerms(in: query).prefix(8)),
            exactName: inferredExactFileName(in: query),
            fileExtensions: inferredFileExtensions(in: query),
            categories: inferredSearchCategories(in: query),
            folderTerms: [],
            itemKind: inferredItemKind(in: query),
            dateField: inferredDateField(in: query),
            dateInterval: relativeIntent?.interval ?? explicitYearInterval,
            minimumSizeBytes: nil,
            maximumSizeBytes: nil,
            hasNote: inferredNoteRequirement(in: query),
            isIndexed: inferredIndexRequirement(in: query),
            sort: inferredSort(in: query)
        )
    }

    /// AI may improve the content wording, but it must not create a hard filter that
    /// was not present in the user's request. Locally recognized constraints win.
    private static func reconciledSmartSearchPlan(
        _ aiPlan: SmartLibrarySearchPlan,
        fallback: SmartLibrarySearchPlan,
        query: String
    ) -> SmartLibrarySearchPlan {
        let useLocalDate = fallback.dateInterval != nil
        let useLocalExtensions = !fallback.fileExtensions.isEmpty
        let useLocalCategories = !fallback.categories.isEmpty
        let useLocalItemKind = fallback.itemKind != .any
        let aiSemanticQuery = aiPlan.semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let semanticQuery: String
        if !aiSemanticQuery.isEmpty, !containsStructuralQueryMarker(in: aiSemanticQuery) {
            // A clean model paraphrase can improve vector recall, but it never
            // participates in lexical matching or filter construction.
            semanticQuery = aiSemanticQuery
        } else {
            semanticQuery = uniqueSearchTerms(
                contentSearchTerms(in: query) + aiPlan.keywords.filter(isLexicalEvidenceTerm)
            ).joined(separator: " ")
        }
        let bounds = normalizedSizeBounds(
            minimum: aiPlan.minimumSizeBytes == 0 ? nil : aiPlan.minimumSizeBytes,
            maximum: aiPlan.maximumSizeBytes
        )
        return SmartLibrarySearchPlan(
            semanticQuery: semanticQuery,
            keywords: Array(uniqueSearchTerms(aiPlan.keywords.filter(isLexicalEvidenceTerm)).prefix(8)),
            exactName: fallback.exactName ?? aiPlan.exactName,
            fileExtensions: useLocalExtensions ? fallback.fileExtensions : aiPlan.fileExtensions,
            categories: useLocalCategories ? fallback.categories : aiPlan.categories,
            folderTerms: aiPlan.folderTerms,
            itemKind: useLocalItemKind ? fallback.itemKind : aiPlan.itemKind,
            dateField: useLocalDate ? fallback.dateField : aiPlan.dateField,
            dateInterval: useLocalDate ? fallback.dateInterval : aiPlan.dateInterval,
            minimumSizeBytes: bounds.minimum,
            maximumSizeBytes: bounds.maximum,
            hasNote: fallback.hasNote,
            isIndexed: fallback.isIndexed,
            sort: aiPlan.sort
        )
    }

    private static func structuredOnlyConfidence(for plan: SmartLibrarySearchPlan?) -> Double {
        guard let plan else { return 0.30 }
        guard plan.hasContentIntent else {
            return plan.hasStructuredFilters ? 0.60 : 0.30
        }
        // A file that satisfies only metadata filters is a candidate, not evidence
        // that it answers a content-bearing request.
        return 0.20
    }

    private static func normalizedExtension(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }
        return normalized
    }

    private static func normalizedSizeBounds(
        minimum: Int64?,
        maximum: Int64?
    ) -> (minimum: Int64?, maximum: Int64?) {
        let positiveMinimum = minimum.map { max($0, 0) }
        let positiveMaximum = maximum.map { max($0, 0) }
        guard let positiveMinimum, let positiveMaximum, positiveMinimum > positiveMaximum else {
            return (positiveMinimum, positiveMaximum)
        }
        return (positiveMaximum, positiveMinimum)
    }

    private static func fileName(_ fileName: String, equals requestedName: String) -> Bool {
        fileName.compare(
            requestedName,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: nil,
            locale: .current
        ) == .orderedSame
    }

    private static func matchesStructuredPlan(
        _ file: FileRecord,
        plan: SmartLibrarySearchPlan
    ) -> Bool {
        if let exactName = plan.exactName, !fileName(file.name, equals: exactName) {
            return false
        }
        if !plan.fileExtensions.isEmpty,
           !plan.fileExtensions.contains(file.ext.lowercased()) {
            return false
        }
        if !plan.categories.isEmpty, !plan.categories.contains(file.categoryEnum) {
            return false
        }
        if !plan.folderTerms.isEmpty {
            let folderMetadata = [file.sourceDir, file.path, file.organizationSubfolder ?? ""]
                .joined(separator: "\n")
                .lowercased()
            if !plan.folderTerms.allSatisfy({
                folderMetadata.range(
                    of: $0,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }) {
                return false
            }
        }
        switch plan.itemKind {
        case .any: break
        case .file where file.isDirectory: return false
        case .directory where !file.isDirectory: return false
        default: break
        }
        if let interval = plan.dateInterval {
            guard let date = plan.dateField.date(for: file),
                  date >= interval.start, date < interval.end else { return false }
        }
        if let minimum = plan.minimumSizeBytes, file.size < minimum { return false }
        if let maximum = plan.maximumSizeBytes, file.size > maximum { return false }
        let hasNote = !(file.note ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if let required = plan.hasNote, hasNote != required { return false }
        if let required = plan.isIndexed, (file.indexedAt != nil) != required { return false }
        return true
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
        let rawStart = startValue.flatMap { formatter.date(from: $0) }
        let rawEnd = endValue.flatMap { formatter.date(from: $0) }
        guard rawStart != nil || rawEnd != nil else { return nil }
        if let rawStart, let rawEnd {
            let start = calendar.startOfDay(for: min(rawStart, rawEnd))
            let endStart = calendar.startOfDay(for: max(rawStart, rawEnd))
            guard let end = calendar.date(byAdding: .day, value: 1, to: endStart) else { return nil }
            return DateInterval(start: start, end: end)
        }
        if let rawStart {
            return DateInterval(start: calendar.startOfDay(for: rawStart), end: .distantFuture)
        }
        guard let rawEnd,
              let end = calendar.date(
                byAdding: .day,
                value: 1,
                to: calendar.startOfDay(for: rawEnd)
              ) else { return nil }
        return DateInterval(start: .distantPast, end: end)
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

    private static let recognizedFileExtensions: Set<String> = [
        "pdf", "doc", "docx", "docm", "txt", "md", "rtf", "pages", "xls", "xlsx",
        "xlsm", "ppt", "pptx", "ppsx", "csv", "key", "keynote", "numbers", "epub",
        "odt", "ods", "odp", "png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp",
        "svg", "webp", "psd", "sketch", "mp4", "mov", "avi", "mkv", "m4v", "wmv",
        "flv", "webm", "mp3", "wav", "aac", "flac", "m4a", "ogg", "aiff", "swift",
        "py", "js", "ts", "tsx", "jsx", "java", "kt", "go", "rs", "c", "cpp", "h",
        "hpp", "cs", "rb", "php", "sh", "sql", "json", "yaml", "yml", "html", "css",
        "vue", "lua", "r", "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso",
    ]

    private static func inferredFileExtensions(in query: String) -> Set<String> {
        let normalized = query.lowercased()
        var extensions = Set(normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { recognizedFileExtensions.contains($0) })
        let mappings: [([String], [String])] = [
            (["word"], ["doc", "docx"]),
            (["excel", "spreadsheet"], ["xls", "xlsx", "csv"]),
            (["powerpoint", "slides"], ["ppt", "pptx"]),
            (["markdown"], ["md"]),
            (["jpeg"], ["jpg", "jpeg"]),
        ]
        for (phrases, mappedExtensions) in mappings
        where phrases.contains(where: normalized.contains) {
            extensions.formUnion(mappedExtensions)
        }
        return extensions
    }

    private static func inferredExactFileName(in query: String) -> String? {
        let punctuation = CharacterSet(charactersIn: "\"'“”‘’()[]{}<>,;:!?，。；：！？")
        for token in query.components(separatedBy: .whitespacesAndNewlines) {
            let candidate = token.trimmingCharacters(in: punctuation)
            let ext = URL(fileURLWithPath: candidate).pathExtension.lowercased()
            if recognizedFileExtensions.contains(ext), candidate.contains(".") {
                return candidate
            }
        }
        return nil
    }

    private static func inferredItemKind(in query: String) -> LibrarySearchItemKind {
        let normalized = query.lowercased()
        if [
            "folders", "directories", "folder only", "directory only",
            "\u{67E5}\u{627E}\u{6587}\u{4EF6}\u{5939}",
            "\u{663E}\u{793A}\u{6587}\u{4EF6}\u{5939}",
            "\u{6587}\u{4EF6}\u{5939}\u{672C}\u{8EAB}",
        ].contains(where: normalized.contains) {
            return .directory
        }
        if ["files", "file only", "\u{6587}\u{4EF6}"].contains(where: normalized.contains) {
            return .file
        }
        return .any
    }

    private static func inferredDateField(in query: String) -> LibrarySearchDateField {
        let normalized = query.lowercased()
        if ["organized", "moved", "sorted", "\u{6574}\u{7406}", "\u{79FB}\u{52A8}"].contains(where: normalized.contains) {
            return .organized
        }
        if ["added", "imported", "discovered", "\u{6DFB}\u{52A0}", "\u{5BFC}\u{5165}"].contains(where: normalized.contains) {
            return .added
        }
        return .modified
    }

    private static func inferredNoteRequirement(in query: String) -> Bool? {
        let normalized = query.lowercased()
        if ["without note", "no note", "\u{6CA1}\u{6709}\u{5907}\u{6CE8}", "\u{65E0}\u{5907}\u{6CE8}"].contains(where: normalized.contains) {
            return false
        }
        if ["with note", "has note", "\u{6709}\u{5907}\u{6CE8}"].contains(where: normalized.contains) {
            return true
        }
        return nil
    }

    private static func inferredIndexRequirement(in query: String) -> Bool? {
        let normalized = query.lowercased()
        if ["unindexed", "not indexed", "\u{672A}\u{7D22}\u{5F15}"].contains(where: normalized.contains) {
            return false
        }
        if ["indexed", "\u{5DF2}\u{7D22}\u{5F15}"].contains(where: normalized.contains) {
            return true
        }
        return nil
    }

    private static func inferredSort(in query: String) -> LibrarySearchSort {
        let normalized = query.lowercased()
        if ["largest", "biggest", "\u{6700}\u{5927}"].contains(where: normalized.contains) { return .largest }
        if ["smallest", "\u{6700}\u{5C0F}"].contains(where: normalized.contains) { return .smallest }
        if ["oldest", "\u{6700}\u{65E9}", "\u{6700}\u{65E7}"].contains(where: normalized.contains) { return .oldest }
        return prefersRecentFiles(in: query) ? .newest : .relevance
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
        uniqueSearchTerms(
            contentSearchTerms(in: query)
                + additionalTerms.filter { isExactFileNameCandidate($0) || isLexicalEvidenceTerm($0) }
        )
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
                confidence: 0.60 + (0.09 * strength),
                kind: .fileName,
                source: file.title ?? file.displayPath
            )
        }
        if let strength = evidenceStrength(in: title) {
            considerEvidence(
                confidence: 0.45 + (0.09 * strength),
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
                confidence: 0.60 + (0.09 * strength),
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
            consider(500, .fileName, file.title ?? file.note ?? file.displayPath)
        } else if stem.contains(normalizedQuery) || name.contains(normalizedQuery) {
            consider(200, .fileName, file.title ?? file.note ?? file.displayPath)
        }
        if content.contains(normalizedQuery) { consider(400, .content, file.contentText) }
        if note.contains(normalizedQuery) { consider(300, .note, file.note) }
        if path.contains(normalizedQuery) { consider(200, .path, file.displayPath) }
        if title == normalizedQuery { consider(110, .title, file.title) }
        else if title.contains(normalizedQuery) { consider(100, .title, file.title) }

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
            if content.contains(term) {
                termScore += 40
                recordTermMatch(priority: 5, kind: .content, source: file.contentText)
            } else if note.contains(term) {
                termScore += 30
                recordTermMatch(priority: 4, kind: .note, source: file.note)
            } else if name.contains(term) {
                termScore += 20
                recordTermMatch(priority: 3, kind: .fileName, source: file.title ?? file.displayPath)
            } else if path.contains(term) {
                termScore += 20
                recordTermMatch(priority: 3, kind: .path, source: file.displayPath)
            } else if title.contains(term) {
                termScore += 10
                recordTermMatch(priority: 2, kind: .title, source: file.title)
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

    static func dynamicallyAcceptedSemanticHits(_ hits: [VectorSearchHit]) -> [VectorSearchHit] {
        let finite = hits.filter { $0.score.isFinite }.sorted { $0.score > $1.score }
        guard let topScore = finite.first?.score, topScore >= semanticScoreFloor else { return [] }
        let threshold = max(semanticScoreFloor, topScore - semanticScoreWindow)
        return finite.filter { $0.score >= threshold }
    }

    private func rerankedSemanticHits(_ hits: [VectorSearchHit], query: String) async -> [VectorSearchHit] {
        guard let provider = settings.makeRerankingProvider(), hits.count > 1 else { return hits }
        let candidates = Array(hits.prefix(24))
        let documents = candidates.map { $0.chunkText ?? "" }
        do {
            let results = try await provider.rerank(
                query: query,
                documents: documents,
                topN: candidates.count
            )
            let resultByIndex = Dictionary(uniqueKeysWithValues: results.map { ($0.index, $0.score) })
            let reranked = candidates.enumerated().compactMap { index, hit -> VectorSearchHit? in
                guard let score = resultByIndex[index] else { return nil }
                return VectorSearchHit(
                    fileId: hit.fileId,
                    score: Float(min(max(score, 0), 1)),
                    chunkText: hit.chunkText,
                    chunkIndex: hit.chunkIndex,
                    sectionPath: hit.sectionPath,
                    pageStart: hit.pageStart,
                    pageEnd: hit.pageEnd,
                    kind: hit.kind,
                    parentIndex: hit.parentIndex,
                    parentText: hit.parentText,
                    entityTerms: hit.entityTerms
                )
            }.sorted { $0.score > $1.score }
            guard !reranked.isEmpty else { return hits }
            AppLogService.shared.write(
                "RAG candidates reranked",
                category: .vectorSearch,
                level: .debug,
                metadata: ["provider": provider.name, "candidates": "\(candidates.count)"]
            )
            return reranked
        } catch {
            AppLogService.shared.write(
                "RAG reranker unavailable; fused retrieval order retained: \(error.localizedDescription)",
                category: .vectorSearch,
                level: .warning,
                metadata: ["provider": provider.name]
            )
            return hits
        }
    }

    private static func semanticConfidence(for hit: VectorSearchHit) -> Double {
        let threshold = Double(semanticScoreFloor)
        let strength = min(max((Double(hit.score) - threshold) / (1 - threshold), 0), 1)
        let base: Double
        switch hit.kind {
        case .text, .table, .list, .picture:
            base = 0.90
        case .note:
            base = 0.75
        case .title:
            base = 0.45
        case .metadata:
            base = 0.60
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

    private func buildLibraryContext(from results: [LibrarySearchResult],
                                     matchedChunks: [Int64: [VectorSearchHit]]) -> String {
        let responseInstructions = PromptCatalog.Chat.libraryAnswerInstructions
        guard !results.isEmpty else {
            return responseInstructions + "\n\n" + PromptCatalog.Chat.emptyLibraryAnswer
        }

        var lines = [responseInstructions, "RETRIEVED FILES START"]
        let dateFormatter = ISO8601DateFormatter()
        var remainingParentEvidence = 8
        var remainingEvidenceCharacters = 20_000
        for (index, result) in results.enumerated() {
            let file = result.file
            let userNote = file.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var fileLines = [
                "FILE START",
                "Source ID: [F\(index + 1)]",
                "Retrieval rank (internal): \(index + 1)",
                "Retrieval evidence (internal): \(Self.libraryEvidenceLabel(for: result)); confidence \(result.confidencePercent)%",
                "Name: \(file.name)",
            ]
            if let id = file.id, let chunks = matchedChunks[id], !chunks.isEmpty {
                let prioritizedChunks = chunks.filter { hit in
                    switch hit.kind {
                    case .title: return false
                    case .note: return userNote.isEmpty
                    default: return true
                    }
                }.sorted {
                    let lhsPriority = Self.contextPriority(for: $0.kind)
                    let rhsPriority = Self.contextPriority(for: $1.kind)
                    return lhsPriority == rhsPriority
                        ? $0.score > $1.score
                        : lhsPriority > rhsPriority
                }
                for hit in prioritizedChunks.prefix(min(4, remainingParentEvidence)) {
                    guard let chunk = hit.parentText ?? hit.chunkText, !chunk.isEmpty else { continue }
                    guard remainingEvidenceCharacters > 0 else { break }
                    var location = hit.sectionPath.joined(separator: " › ")
                    if let start = hit.pageStart {
                        let pageLabel = hit.pageEnd.flatMap { $0 == start ? nil : $0 }
                            .map { "p.\(start)–\($0)" } ?? "p.\(start)"
                        location = location.isEmpty ? pageLabel : "\(location) · \(pageLabel)"
                    }
                    let locationLabel = location.isEmpty ? "" : " (\(location))"
                    let parentID = hit.parentIndex ?? hit.chunkIndex ?? 0
                    let excerpt = String(chunk.prefix(min(2_800, remainingEvidenceCharacters)))
                    fileLines.append(
                        "Relevant \(Self.contextLabel(for: hit.kind))\(locationLabel) "
                        + "[F\(index + 1):P\(parentID + 1)]: "
                        + excerpt
                    )
                    remainingParentEvidence -= 1
                    remainingEvidenceCharacters -= excerpt.count
                }
            } else if result.confidence >= 0.90,
                      let snippet = result.snippet?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !snippet.isEmpty {
                fileLines.append("Relevant content excerpt: \(String(snippet.prefix(1_200)))")
            } else if result.confidence >= 0.90,
                      let content = file.contentText, !content.isEmpty {
                fileLines.append("Relevant content excerpt: \(String(content.prefix(800)))")
            }
            if !userNote.isEmpty {
                fileLines.append("User note: \(String(userNote.prefix(800)))")
            }
            fileLines.append("Metadata: type=\(file.ext.isEmpty ? "none" : file.ext); category=\(file.categoryEnum.rawValue); item=\(file.isDirectory ? "directory" : "file"); size=\(file.size) bytes")
            fileLines.append("Location metadata: current=\(abbreviatedPath(file.path)); source=\(abbreviatedPath(file.sourceDir))")
            fileLines.append("Time metadata: modified=\(dateFormatter.string(from: file.mtime)); added=\(dateFormatter.string(from: file.addedAt))")
            if let organizedAt = file.organizedAt {
                fileLines.append("Organized: \(dateFormatter.string(from: organizedAt))")
            }
            fileLines.append("Indexed: \(file.indexedAt == nil ? "no" : "yes")")
            if let subfolder = file.organizationSubfolder, !subfolder.isEmpty {
                fileLines.append("Organization subfolder: \(subfolder)")
            }
            if let title = file.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                fileLines.append("Generated title (lowest-priority evidence): \(title)")
            }
            fileLines.append("FILE END")
            lines.append(fileLines.joined(separator: "\n"))
        }
        lines.append("RETRIEVED FILES END")
        return lines.joined(separator: "\n\n")
    }

    private func buildAttachedFileContext(file: FileRecord, extractedText: String) -> String {
        """
        \(PromptCatalog.Chat.attachedFileInstructions)

        ATTACHED FILE START
        Name: \(file.name)
        Type: \(file.ext)
        Content:
        \(extractedText)
        ATTACHED FILE END
        """
    }

    private static func libraryEvidenceLabel(for result: LibrarySearchResult) -> String {
        if result.confidence >= 1, result.matchKind == .fileName { return "exact filename" }
        if result.confidence >= 0.90 { return "extracted content" }
        if result.confidence >= 0.75 { return "user note" }
        if result.confidence >= 0.60 { return "file metadata" }
        if result.confidence >= 0.45 { return "generated title" }
        return result.matchKind.label.lowercased()
    }

    private static func contextPriority(for kind: DocumentChunkKind) -> Int {
        switch kind {
        case .text, .table, .list, .picture: return 5
        case .note: return 4
        case .metadata: return 3
        case .title: return 2
        }
    }

    private static func contextLabel(for kind: DocumentChunkKind) -> String {
        switch kind {
        case .text, .table, .list, .picture: return "content excerpt"
        case .note: return "user-note excerpt"
        case .metadata: return "metadata excerpt"
        case .title: return "title excerpt"
        }
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

    /// Uses the shared fallback profile when a provider does not report exact generation usage.
    static func estimatedTokens(in text: String) -> Int {
        TokenCounter.estimate(
            text,
            profile: TokenCounter.generationFallbackProfile,
            version: TokenCounter.generationFallbackVersion
        ).count
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
