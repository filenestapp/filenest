import AppKit
import MarkdownUI
import SwiftUI
import UniformTypeIdentifiers

/// Natural-language file search with message history, result references, and a composer.
struct ChatView: View {
    private static let conversationBottomID = "chat-conversation-bottom"
    private static let messagePageSize = 40

    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    let returnFromFileChat: () -> Void
    @State private var sendTasks = [Int64: Task<Void, Never>]()
    @State private var pendingStreamDeltas = [Int64: String]()
    @State private var streamFlushTasks = [Int64: Task<Void, Never>]()
    @State private var streamScrollTask: Task<Void, Never>?
    @State private var followsStreamingOutput = true
    @State private var composerTextHeight = ChatComposerTextView.defaultHeight
    @State private var activeFallbackRequests = [Int64: ChatFallbackRequest]()
    @State private var pendingCloudFallback: ChatFallbackRequest?
    @State private var editingContext: ChatEditingContext?
    @State private var isLoadingEarlierMessages = false

    private var messages: [ChatMessage] {
        if FileNestEnvironment.isUIPreview { return UIShowcaseData.messages }
        guard let sessionID = appState.selectedChatSessionID else { return appState.chatMessages }
        return appState.presentedChatMessages(
            sessionID: sessionID,
            persistedMessages: appState.chatMessages
        )
    }

    private var lastUserMessageID: Int64? {
        messages.last(where: { $0.role == ChatRole.user.rawValue })?.id
    }

    private var displayedMessages: [ChatMessage] {
        messages
    }

    private var composerInput: Binding<String> {
        Binding(
            get: { appState.chatComposerInput },
            set: { appState.updateChatComposerInput($0) }
        )
    }

    private var composerText: String { appState.chatComposerInput }

    private var sending: Bool {
        guard let sessionID = appState.selectedChatSessionID else { return false }
        return appState.runningChatSessionIDs.contains(sessionID)
    }

    private var isFileChat: Bool {
        !(appState.currentChatAttachmentPath?.isEmpty ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader

            conversation
            composer
        }
        .background(FileNestTheme.surface)
        .onAppear {
            guard !FileNestEnvironment.isUIPreview else { return }
            appState.refreshChatSessions()
            markSelectedChatSeenIfActive()
            Task { await appState.ollama.refresh(host: appState.settings.ollamaHost) }
        }
        .onChange(of: appState.selectedChatSessionID) { _ in
            isLoadingEarlierMessages = false
            if editingContext?.sessionID != appState.selectedChatSessionID {
                editingContext = nil
            }
            markSelectedChatSeenIfActive()
        }
        .onChange(of: appState.completedChatSessionIDs) { _ in
            markSelectedChatSeenIfActive()
        }
        .alert(
            "Cloud AI Is Temporarily Unavailable",
            isPresented: Binding(
                get: { pendingCloudFallback != nil },
                set: { if !$0 { pendingCloudFallback = nil } }
            ),
            presenting: pendingCloudFallback
        ) { request in
            Button("Switch to Local AI") {
                switchToLocalAIAndRetry(request)
            }
            Button("Show Search Results Only") {
                startFallback(request, mode: .vectorOnly(cloudFailure: request.failureMessage))
            }
            Button("Cancel", role: .cancel) {
                appState.refreshChatSessionsPreservingSelection()
            }
        } message: { request in
            Text(appState.settings.localizedFormat(
                "The cloud model failed: %@\n\nSwitch to a local model and continue?",
                request.failureMessage
            ))
        }
    }

    private var chatHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(LocalizedStringKey(isFileChat ? "Chat with File" : "Find with Chat"))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(2)

                    if let path = appState.currentChatAttachmentPath {
                        FileContextPill(
                            path: path,
                            preview: { appState.presentAttachedFilePreview(path: path) }
                        )
                        .frame(maxWidth: 220)
                        .layoutPriority(0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(LocalizedStringKey(isFileChat
                    ? "Analyze only the current file without searching or mixing in content from the library."
                    : "Find files naturally, or attach one file and chat with it directly."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)

            Spacer(minLength: 24)

            HStack(spacing: 8) {
                if isFileChat {
                    Button(action: returnFromFileChat) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(QuietButtonStyle(compact: true, foreground: .secondary))
                    .help("Back to previous view")
                }

                Button {
                    appState.newChat()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .buttonStyle(QuietButtonStyle(compact: true, foreground: FileNestTheme.accent))
                .keyboardShortcut("n", modifiers: .command)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 28)
        .frame(height: 96)
        .background(FileNestTheme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FileNestTheme.border).frame(height: 1)
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A growing streamed message needs an exact, continuously updated
                // layout. LazyVStack can retain a stale estimated height while a
                // visible row changes rapidly, leaving the scroll position beyond
                // the rendered content until the user scrolls manually.
                VStack(alignment: .leading, spacing: 0) {
                    if messages.isEmpty {
                        if let path = appState.currentChatAttachmentPath {
                            EmptyFileChatState(path: path) { query in submit(query) }
                                .frame(maxWidth: .infinity, minHeight: 430)
                        } else {
                            EmptyChatState { query in submit(query) }
                                .frame(maxWidth: .infinity, minHeight: 430)
                        }
                    } else {
                        if appState.hasEarlierChatMessages {
                            Button {
                                let previousFirstID = displayedMessages.first?.id
                                isLoadingEarlierMessages = true
                                Task {
                                    await appState.loadEarlierChatMessages()
                                    await Task.yield()
                                    if let previousFirstID {
                                        proxy.scrollTo(previousFirstID, anchor: .top)
                                    }
                                    isLoadingEarlierMessages = false
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    if isLoadingEarlierMessages { ProgressView().controlSize(.small) }
                                    Text(appState.settings.localizedFormat(
                                        "Show %d Earlier Messages",
                                        Self.messagePageSize
                                    ))
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoadingEarlierMessages)
                            .foregroundStyle(FileNestTheme.accent)
                            .padding(.vertical, 12)
                        }

                        ForEach(displayedMessages) { message in
                            MessageRow(
                                message: message,
                                progress: progress(for: message),
                                isStreamingContent: isStreamingContent(for: message),
                                showsRelatedFiles: !isFileChat,
                                openSettings: openSettings,
                                retry: retryLastQuestion,
                                edit: { beginEditing(message) },
                                editingText: editingBinding(for: message),
                                cancelEdit: { editingContext = nil },
                                resendEditedQuestion: resendEditedLastQuestion,
                                showsLastUserActions: !sending && message.id == lastUserMessageID,
                                startFileChat: { file in
                                    appState.startFileChat(
                                        attachedFilePath: file.path,
                                        returnDestination: .chat
                                    )
                                }
                            )
                            .id(message.id)

                            Divider()
                                .padding(.leading, 72)
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.conversationBottomID)
                }
                .frame(maxWidth: 1040)
                .frame(maxWidth: .infinity)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 1).onChanged { _ in
                    // Do not keep pulling the transcript to the bottom while the
                    // user is inspecting an earlier part of the conversation.
                    followsStreamingOutput = false
                }
            )
            .onAppear {
                // The chat view is recreated when returning from the library. In that
                // transition the selected session can be set before this ScrollView
                // begins observing it, so explicitly restore the newest message.
                followsStreamingOutput = true
                scrollToConversationBottom(proxy, animated: false)
            }
            .onChange(of: messages.count) { _ in
                guard !isLoadingEarlierMessages else { return }
                followsStreamingOutput = true
                scrollToConversationBottom(proxy, animated: !sending)
            }
            .onChange(of: messages.last?.content) { _ in
                guard sending else { return }
                scheduleStreamScroll(proxy)
            }
            .onChange(of: sending) { _ in
                if !sending {
                    streamScrollTask?.cancel()
                    streamScrollTask = nil
                }
                guard followsStreamingOutput else { return }
                scrollToConversationBottom(proxy, animated: false)
            }
            .onChange(of: appState.selectedChatSessionID) { _ in
                followsStreamingOutput = true
                scrollToConversationBottom(proxy, animated: false)
            }
        }
    }

    private func scrollToConversationBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.conversationBottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.conversationBottomID, anchor: .bottom)
            }
        }
    }

    private func scheduleStreamScroll(_ proxy: ScrollViewProxy) {
        guard followsStreamingOutput, streamScrollTask == nil else { return }
        streamScrollTask = Task { @MainActor in
            defer { streamScrollTask = nil }
            do {
                // Coalesce token updates and wait until SwiftUI has laid out the
                // newly grown transcript before changing the scroll position.
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            guard followsStreamingOutput, sending else { return }
            await Task.yield()
            proxy.scrollTo(Self.conversationBottomID, anchor: .bottom)
        }
    }

    private func isStreamingContent(for message: ChatMessage) -> Bool {
        guard sending,
              message.role == ChatRole.assistant.rawValue,
              let sessionID = appState.selectedChatSessionID,
              let presentation = appState.chatExecutionPresentations[sessionID] else {
            return false
        }
        return presentation.assistantMessage.id == message.id && !message.content.isEmpty
    }

    private func progress(for message: ChatMessage) -> ChatProgress? {
        guard let sessionID = appState.selectedChatSessionID,
              let presentation = appState.chatExecutionPresentations[sessionID],
              presentation.assistantMessage.id == message.id else { return nil }
        return presentation.progress
    }

    private var composer: some View {
        VStack(spacing: 7) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ChatComposerTextView(
                        text: composerInput,
                        height: $composerTextHeight,
                        onSubmit: { submit(composerText) }
                    )
                    .frame(height: composerTextHeight)

                    if composerText.isEmpty {
                        Text(isFileChat ? "Ask about this file…" : "Describe the file you're looking for…")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Color.secondary.opacity(0.38))
                            .padding(.top, 3)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 15)
                .padding(.top, 13)
                .padding(.bottom, 7)
                .help("Enter to send, Shift+Enter for a new line")

                HStack(spacing: 10) {
                    Button(action: chooseFile) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Attach a file and chat with it")

                    HStack(spacing: 5) {
                        Image(systemName: "shield.lefthalf.filled")
                        Text("Local file access")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.orange)

                        Spacer()

                        Button {
                            appState.settings.setThinkingMode(!appState.settings.thinkingMode)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "brain.head.profile")
                                Text("Thinking")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(appState.settings.thinkingMode ? FileNestTheme.accent : .secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .background(
                                appState.settings.thinkingMode ? FileNestTheme.selection : Color.clear,
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .help(appState.settings.thinkingMode ? "Turn off Thinking Mode" : "Turn on Thinking Mode")

                        ChatComposerModelMenu(openSettings: openSettings)

                        Button(action: startDictation) {
                            Image(systemName: "mic")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Use system dictation")

                        Button {
                            sending ? stopStreaming() : submit(composerText)
                        } label: {
                            Image(systemName: sending ? "stop.fill" : "arrow.up")
                                .font(.system(size: sending ? 10 : 13, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background {
                                    if sending || !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        Circle().fill(FileNestTheme.primaryGradient)
                                    } else {
                                        Circle().fill(Color.primary.opacity(0.78))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .disabled(!sending && composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.return, modifiers: [.command])
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 13)
                .padding(.bottom, 11)
            }
            .background(
                FileNestTheme.elevatedSurface.opacity(0.88),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(FileNestTheme.border, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.07), radius: 12, y: 5)
            .animation(.easeOut(duration: 0.14), value: composerTextHeight)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .background(FileNestTheme.surface)
    }

    private func openSettings() {
        appState.selectSettingsSection(.aiModels)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private func submit(_ rawQuestion: String) {
        sendNewQuestion(rawQuestion)
    }

    private func sendNewQuestion(_ rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !sending, !FileNestEnvironment.isUIPreview else { return }
        guard let sessionID = appState.persistChatForQuestion() else { return }

        discardPendingStreamDelta(sessionID: sessionID)
        appState.updateChatComposerInput("")

        let seed = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let userID = -max(seed, 1)
        let assistantID = userID - 1
        let persistedUserMessage = appState.saveUserQuestionForImmediateDisplay(
            question,
            sessionID: sessionID
        )
        let userMessage = persistedUserMessage ?? ChatMessage(
            id: userID,
            role: ChatRole.user.rawValue,
            content: question,
            ts: Date(),
            relatedFileIds: nil,
            sessionId: sessionID
        )
        let assistantMessage = ChatMessage(
            id: assistantID,
            role: ChatRole.assistant.rawValue,
            content: "",
            ts: Date(),
            relatedFileIds: nil,
            sessionId: sessionID
        )

        let attachment = appState.currentChatAttachmentPath
        let progress = ChatProgress(
            phase: attachment == nil ? .planningSearch : .readingFile,
            scope: attachment == nil ? .library : .attachedFile
        )
        appState.beginChatExecution(
            sessionID: sessionID,
            userMessage: userMessage,
            assistantMessage: assistantMessage,
            progress: progress
        )
        let model = currentModel
        activeFallbackRequests[sessionID] = ChatFallbackRequest(
            question: question,
            sessionID: sessionID,
            attachment: attachment,
            replacingAssistantMessageID: nil,
            failureMessage: ""
        )
        sendTasks[sessionID] = Task {
            for await update in appState.chat.streamAnswer(
                question,
                sessionId: sessionID,
                attachedFilePath: attachment,
                modelOverride: model,
                savesUserMessage: persistedUserMessage == nil
            ) {
                guard !Task.isCancelled else { break }
                handle(update, sessionID: sessionID)
            }
        }
    }

    private func retryLastQuestion() {
        guard !sending,
              !FileNestEnvironment.isUIPreview,
              let sessionID = appState.selectedChatSessionID,
              let userIndex = appState.chatMessages.lastIndex(where: {
                  $0.role == ChatRole.user.rawValue
              }) else { return }

        startRetry(
            question: appState.chatMessages[userIndex].content,
            sessionID: sessionID,
            userIndex: userIndex
        )
    }

    private func beginEditing(_ message: ChatMessage) {
        guard !sending,
              let sessionID = appState.selectedChatSessionID,
              message.id == lastUserMessageID,
              let messageID = message.id else { return }
        editingContext = ChatEditingContext(
            sessionID: sessionID,
            messageID: messageID,
            text: message.content
        )
    }

    private func editingBinding(for message: ChatMessage) -> Binding<String>? {
        guard let context = editingContext,
              context.sessionID == appState.selectedChatSessionID,
              context.messageID == message.id else { return nil }
        return Binding(
            get: { editingContext?.text ?? message.content },
            set: { value in
                guard var context = editingContext,
                      context.sessionID == appState.selectedChatSessionID,
                      context.messageID == message.id else { return }
                context.text = value
                editingContext = context
            }
        )
    }

    private func resendEditedLastQuestion() {
        guard let context = editingContext else { return }
        let rawQuestion = context.text
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty,
              !sending,
              context.sessionID == appState.selectedChatSessionID,
              let userIndex = appState.chatMessages.firstIndex(where: { $0.id == context.messageID }),
              let updatedMessage = appState.chat.editUserMessage(
                  id: context.messageID,
                  sessionId: context.sessionID,
                  content: question
              ) else { return }

        appState.chatMessages[userIndex] = updatedMessage
        editingContext = nil
        startRetry(question: question, sessionID: context.sessionID, userIndex: userIndex)
    }

    private func startRetry(question: String, sessionID: Int64, userIndex: Int) {
        guard !appState.runningChatSessionIDs.contains(sessionID) else { return }

        discardPendingStreamDelta(sessionID: sessionID)
        let assistantIndex = appState.chatMessages.indices
            .dropFirst(userIndex + 1)
            .first(where: { appState.chatMessages[$0].role == ChatRole.assistant.rawValue })
        let replacingAssistantID = assistantIndex.flatMap { appState.chatMessages[$0].id }
        let temporaryID = -max(Int64(Date().timeIntervalSince1970 * 1_000_000), 1)
        let placeholderID = replacingAssistantID ?? temporaryID
        let placeholder = ChatMessage(
            id: placeholderID,
            role: ChatRole.assistant.rawValue,
            content: "",
            ts: Date(),
            relatedFileIds: nil,
            sessionId: sessionID
        )

        let attachment = appState.currentChatAttachmentPath
        appState.beginChatExecution(
            sessionID: sessionID,
            userMessage: nil,
            assistantMessage: placeholder,
            progress: ChatProgress(
                phase: attachment == nil ? .planningSearch : .readingFile,
                scope: attachment == nil ? .library : .attachedFile
            )
        )
        let model = currentModel
        activeFallbackRequests[sessionID] = ChatFallbackRequest(
            question: question,
            sessionID: sessionID,
            attachment: attachment,
            replacingAssistantMessageID: replacingAssistantID,
            failureMessage: ""
        )
        sendTasks[sessionID] = Task {
            for await update in appState.chat.retryAnswer(
                question,
                sessionId: sessionID,
                attachedFilePath: attachment,
                replacingAssistantMessageID: replacingAssistantID,
                modelOverride: model
            ) {
                guard !Task.isCancelled else { break }
                handle(update, sessionID: sessionID)
            }
        }
    }

    private var currentModel: String? {
        switch AppSettings.LLMChoice(rawValue: appState.settings.llmChoice) ?? .ollama {
        case .ollama: return appState.settings.ollamaModel
        case .cloud: return appState.settings.cloudModel
        case .none: return nil
        }
    }

    private func handle(_ update: ChatStreamUpdate, sessionID: Int64) {
        switch update {
        case let .userSaved(message):
            appState.updateChatExecutionUserMessage(sessionID: sessionID, message: message)
        case let .progress(progress):
            appState.updateChatExecutionProgress(sessionID: sessionID, progress: progress)
        case let .delta(chunk):
            appState.updateChatExecutionProgress(sessionID: sessionID, progress: nil)
            enqueueStreamDelta(chunk, sessionID: sessionID)
        case let .completed(message):
            discardPendingStreamDelta(sessionID: sessionID)
            appState.completeChatExecution(sessionID: sessionID, message: message)
            finishStreaming(sessionID: sessionID)
        case let .cloudProviderFailed(message):
            handleCloudProviderFailure(message, sessionID: sessionID)
        case .cancelled:
            finishStreaming(sessionID: sessionID, reload: false, completed: false)
        }
    }

    private func finishStreaming(
        sessionID: Int64,
        reload: Bool = true,
        completed: Bool = true
    ) {
        discardPendingStreamDelta(sessionID: sessionID)
        sendTasks.removeValue(forKey: sessionID)
        activeFallbackRequests.removeValue(forKey: sessionID)
        if completed {
            appState.markChatCompleted(sessionID)
        } else {
            appState.markChatStopped(sessionID)
        }
        appState.clearChatExecution(sessionID: sessionID)
        if reload {
            appState.refreshChatSessionsPreservingSelection()
            appState.markStatisticsDirty()
        }
    }

    private func stopStreaming() {
        guard let sessionID = appState.selectedChatSessionID else { return }
        flushPendingStreamDelta(sessionID: sessionID)
        sendTasks.removeValue(forKey: sessionID)?.cancel()
        activeFallbackRequests.removeValue(forKey: sessionID)
        appState.clearChatExecution(sessionID: sessionID)
        appState.markChatStopped(sessionID)
        appState.refreshChatSessionsPreservingSelection()
    }

    private var localChatModels: [OllamaModelInfo] {
        appState.ollama.chatModels(
            embeddingModel: appState.settings.ollamaEmbeddingModel,
            ocrModel: appState.settings.ollamaOCRModel
        )
    }

    private func handleCloudProviderFailure(_ message: String, sessionID: Int64) {
        guard var request = activeFallbackRequests[sessionID] else { return }
        discardPendingStreamDelta(sessionID: sessionID)
        request.failureMessage = message
        sendTasks.removeValue(forKey: sessionID)
        activeFallbackRequests.removeValue(forKey: sessionID)
        appState.clearChatExecution(sessionID: sessionID)
        appState.markChatStopped(request.sessionID)
        appState.refreshChatSessionsPreservingSelection()

        guard !localChatModels.isEmpty else {
            startFallback(request, mode: .vectorOnly(cloudFailure: message))
            return
        }
        pendingCloudFallback = request
    }

    private func switchToLocalAIAndRetry(_ request: ChatFallbackRequest) {
        guard let selected = localChatModels.first(where: {
            OllamaServiceManager.modelNamesMatch($0.name, appState.settings.ollamaModel)
        }) ?? localChatModels.first else {
            startFallback(request, mode: .vectorOnly(cloudFailure: request.failureMessage))
            return
        }
        appState.settings.setOllamaModel(selected.name)
        appState.settings.setLLMChoice(AppSettings.LLMChoice.ollama.rawValue)
        startFallback(request, mode: .local(model: selected.name))
    }

    private func startFallback(_ request: ChatFallbackRequest, mode: ChatProviderMode) {
        pendingCloudFallback = nil
        guard !appState.runningChatSessionIDs.contains(request.sessionID) else { return }
        discardPendingStreamDelta(sessionID: request.sessionID)
        let placeholderID = request.replacingAssistantMessageID
            ?? -max(Int64(Date().timeIntervalSince1970 * 1_000_000), 1)
        let isAttachedFile = !(request.attachment?.isEmpty ?? true)
        let placeholder = ChatMessage(
            id: placeholderID,
            role: ChatRole.assistant.rawValue,
            content: "",
            ts: Date(),
            relatedFileIds: nil,
            sessionId: request.sessionID
        )
        appState.beginChatExecution(
            sessionID: request.sessionID,
            userMessage: nil,
            assistantMessage: placeholder,
            progress: ChatProgress(
                phase: isAttachedFile ? .readingFile : .planningSearch,
                scope: isAttachedFile ? .attachedFile : .library
            )
        )
        activeFallbackRequests[request.sessionID] = request
        sendTasks[request.sessionID] = Task {
            for await update in appState.chat.retryAnswer(
                request.question,
                sessionId: request.sessionID,
                attachedFilePath: request.attachment,
                replacingAssistantMessageID: request.replacingAssistantMessageID,
                providerMode: mode
            ) {
                guard !Task.isCancelled else { break }
                handle(update, sessionID: request.sessionID)
            }
        }
    }

    private func enqueueStreamDelta(_ chunk: String, sessionID: Int64) {
        pendingStreamDeltas[sessionID, default: ""] += chunk
        guard streamFlushTasks[sessionID] == nil else { return }
        streamFlushTasks[sessionID] = Task { @MainActor in
            do {
                // A 100 ms cadence is visually continuous while avoiding a full
                // chat transcript update for every network token.
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            flushPendingStreamDelta(sessionID: sessionID)
        }
    }

    private func flushPendingStreamDelta(sessionID: Int64) {
        streamFlushTasks.removeValue(forKey: sessionID)?.cancel()
        guard let delta = pendingStreamDeltas.removeValue(forKey: sessionID), !delta.isEmpty else { return }
        appState.appendChatExecutionDelta(sessionID: sessionID, delta: delta)
    }

    private func discardPendingStreamDelta(sessionID: Int64) {
        streamFlushTasks.removeValue(forKey: sessionID)?.cancel()
        pendingStreamDeltas.removeValue(forKey: sessionID)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data, .content]
        panel.prompt = appState.settings.localized("Attach File")
        panel.message = appState.settings.localized("Choose a file. FileNest reads it locally and uses it only in this chat.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.attachFileToSelectedChat(url.path)
    }

    private func startDictation() {
        NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
    }

    private func markSelectedChatSeenIfActive() {
        guard let sessionID = appState.selectedChatSessionID else { return }
        appState.markChatSeen(sessionID)
    }

}

private struct ChatFallbackRequest {
    let question: String
    let sessionID: Int64
    let attachment: String?
    let replacingAssistantMessageID: Int64?
    var failureMessage: String
}

private struct ChatEditingContext: Equatable {
    let sessionID: Int64
    let messageID: Int64
    var text: String
}

/// A narrow AppKit bridge for native multiline editing and content-driven height.
/// SwiftUI owns the text and measured height; NSTextView owns layout and key commands.
struct ChatComposerTextView: NSViewRepresentable {
    enum ReturnAction: Equatable {
        case submit
        case insertNewline
    }

    static let font = NSFont.systemFont(ofSize: 14)
    static let minimumLines = 2
    static let maximumLines = 10
    static let verticalInset: CGFloat = 3
    static var defaultHeight: CGFloat {
        clampedHeight(
            usedTextHeight: 0,
            lineHeight: ceil(NSLayoutManager().defaultLineHeight(for: font)),
            verticalInset: verticalInset
        )
    }

    static func returnAction(for modifiers: NSEvent.ModifierFlags) -> ReturnAction {
        modifiers.intersection(.deviceIndependentFlagsMask).contains(.shift)
            ? .insertNewline
            : .submit
    }

    @Binding var text: String
    @Binding var height: CGFloat
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, height: $height, onSubmit: onSubmit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .automatic

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = { context.coordinator.onSubmit() }
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: Self.verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.setAccessibilityLabel(NSLocalizedString("Chat input", comment: "Chat composer accessibility label"))
        scrollView.documentView = textView

        context.coordinator.updateHeight(for: textView, in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.height = $height
        context.coordinator.onSubmit = onSubmit
        guard let textView = scrollView.documentView as? NSTextView else { return }

        if let composerTextView = textView as? ComposerNSTextView {
            composerTextView.onSubmit = { context.coordinator.onSubmit() }
        }

        if textView.string != text {
            textView.string = text
        }
        let width = max(scrollView.contentSize.width, 1)
        if abs(textView.frame.width - width) > 0.5 {
            textView.frame.size.width = width
            textView.textContainer?.containerSize.width = width
        }
        context.coordinator.updateHeight(for: textView, in: scrollView)
    }

    static func clampedHeight(usedTextHeight: CGFloat,
                              lineHeight: CGFloat,
                              verticalInset: CGFloat = ChatComposerTextView.verticalInset) -> CGFloat {
        let contentHeight = max(lineHeight, ceil(usedTextHeight)) + verticalInset * 2
        let minimum = lineHeight * CGFloat(minimumLines) + verticalInset * 2
        let maximum = lineHeight * CGFloat(maximumLines) + verticalInset * 2
        return min(max(contentHeight, minimum), maximum)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var height: Binding<CGFloat>
        var onSubmit: () -> Void

        init(text: Binding<String>, height: Binding<CGFloat>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.height = height
            self.onSubmit = onSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let scrollView = textView.enclosingScrollView else { return }
            text.wrappedValue = textView.string
            updateHeight(for: textView, in: scrollView)
        }

        func updateHeight(for textView: NSTextView, in scrollView: NSScrollView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let lineHeight = ceil(layoutManager.defaultLineHeight(for: ChatComposerTextView.font))
            let desired = ChatComposerTextView.clampedHeight(
                usedTextHeight: usedHeight,
                lineHeight: lineHeight
            )
            let maximum = lineHeight * CGFloat(ChatComposerTextView.maximumLines)
                + ChatComposerTextView.verticalInset * 2
            scrollView.hasVerticalScroller = usedHeight
                + ChatComposerTextView.verticalInset * 2 > maximum + 0.5

            guard abs(height.wrappedValue - desired) > 0.5 else { return }
            let height = self.height
            DispatchQueue.main.async {
                if abs(height.wrappedValue - desired) > 0.5 {
                    height.wrappedValue = desired
                }
            }
        }
    }

    final class ComposerNSTextView: NSTextView {
        var onSubmit: () -> Void = {}

        override func keyDown(with event: NSEvent) {
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            guard isReturn, !hasMarkedText() else {
                super.keyDown(with: event)
                return
            }

            switch ChatComposerTextView.returnAction(for: event.modifierFlags) {
            case .submit:
                onSubmit()
            case .insertNewline:
                insertNewline(nil)
            }
        }
    }
}

private struct ChatComposerModelMenu: View {
    @EnvironmentObject private var appState: AppState
    let openSettings: () -> Void

    private var choice: AppSettings.LLMChoice {
        AppSettings.LLMChoice(rawValue: appState.settings.llmChoice) ?? .ollama
    }

    private var model: String {
        switch choice {
        case .ollama: return appState.settings.ollamaModel
        case .cloud: return appState.settings.cloudModel
        case .none: return "Search Only"
        }
    }

    private var localChatModels: [OllamaModelInfo] {
        appState.ollama.chatModels(
            embeddingModel: appState.settings.ollamaEmbeddingModel,
            ocrModel: appState.settings.ollamaOCRModel
        )
    }

    var body: some View {
        Menu {
            switch choice {
            case .ollama:
                if localChatModels.isEmpty {
                    Text("No local models available")
                } else {
                    ForEach(localChatModels) { item in
                        Button {
                            appState.settings.setOllamaModel(item.name)
                        } label: {
                            if item.name == model {
                                Label(item.name, systemImage: "checkmark")
                            } else {
                                Text(item.name)
                            }
                        }
                    }
                }
            case .cloud:
                Label(model, systemImage: "checkmark")
            case .none:
                Text("Chat model is disabled")
            }
            Divider()
            Button("Manage Models…", action: openSettings)
        } label: {
            HStack(spacing: 5) {
                Text(model)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: 150)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Current model · Streaming")
    }
}

private struct ChatModelMenu: View {
    @EnvironmentObject private var appState: AppState
    let openSettings: () -> Void

    private var choice: AppSettings.LLMChoice {
        AppSettings.LLMChoice(rawValue: appState.settings.llmChoice) ?? .ollama
    }

    private var model: String {
        switch choice {
        case .ollama: return appState.settings.ollamaModel
        case .cloud: return appState.settings.cloudModel
        case .none: return "No Model"
        }
    }

    private var localChatModels: [OllamaModelInfo] {
        appState.ollama.chatModels(
            embeddingModel: appState.settings.ollamaEmbeddingModel,
            ocrModel: appState.settings.ollamaOCRModel
        )
    }

    var body: some View {
        Menu {
            switch choice {
            case .ollama:
                if localChatModels.isEmpty {
                    Text("No local models available")
                } else {
                    ForEach(localChatModels) { item in
                        Button {
                            appState.settings.setOllamaModel(item.name)
                        } label: {
                            if item.name == model {
                                Label(item.name, systemImage: "checkmark")
                            } else {
                                Text(item.name)
                            }
                        }
                    }
                }
            case .cloud:
                Label(model, systemImage: "checkmark")
            case .none:
                Text("Chat model is disabled")
            }
            Divider()
            Button("Manage Models…", action: openSettings)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(choice == .none ? Color.secondary : FileNestTheme.success)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(LocalizedStringKey(model))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(LocalizedStringKey(
                        choice == .ollama ? "Local Ollama · Streaming" : choice == .cloud ? "Cloud API · Streaming" : "Search Only"
                    ))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(FileNestTheme.elevatedSurface.opacity(0.68))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(FileNestTheme.border, lineWidth: 1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// A compact current-file control for the chat header. It keeps preview and remove
/// actions near the page context without occupying conversation or composer space.
private struct FileContextPill: View {
    let path: String
    let preview: () -> Void

    var body: some View {
        Button(action: preview) {
            HStack(spacing: 6) {
                FileIconView(
                    file: FileRecord(
                        id: nil,
                        path: path,
                        name: URL(fileURLWithPath: path).lastPathComponent,
                        ext: URL(fileURLWithPath: path).pathExtension,
                        size: 0,
                        mtime: Date(),
                        category: FileCategory.from(extension: URL(fileURLWithPath: path).pathExtension).rawValue,
                        sourceDir: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                        indexedAt: nil,
                        contentHash: nil,
                        title: nil,
                        contentText: nil
                    ),
                    size: 17
                )
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show file details")
        .pointingHandOnHover()
        .frame(maxWidth: .infinity)
        .background(FileNestTheme.selection.opacity(0.58), in: Capsule())
        .overlay {
            Capsule()
                .stroke(FileNestTheme.accent.opacity(0.18), lineWidth: 1)
        }
        .layoutPriority(0)
    }
}

private struct MessageRow: View {
    @EnvironmentObject private var appState: AppState
    let message: ChatMessage
    let progress: ChatProgress?
    let isStreamingContent: Bool
    let showsRelatedFiles: Bool
    let openSettings: () -> Void
    let retry: () -> Void
    let edit: () -> Void
    let editingText: Binding<String>?
    let cancelEdit: () -> Void
    let resendEditedQuestion: () -> Void
    let showsLastUserActions: Bool
    let startFileChat: (FileRecord) -> Void

    @State private var feedback: MessageFeedback?

    private var isUser: Bool { message.role == ChatRole.user.rawValue }
    private var modelUnavailable: Bool {
        message.content.contains("LLM call failed") ||
            message.content.localizedCaseInsensitiveContains("LLM call failed") ||
            message.content.contains("Local Model Not Connected") ||
            message.content.localizedCaseInsensitiveContains("local model not connected")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            CircularAvatar(kind: isUser ? .user : .assistant)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(LocalizedStringKey(isUser ? "You" : "FileNest"))
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(message.ts.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if let editingText {
                    InlineQuestionEditor(
                        text: editingText,
                        cancel: cancelEdit,
                        resend: resendEditedQuestion
                    )
                } else if modelUnavailable {
                    Text("I found related files that you can open directly:")
                        .font(.system(size: 15))
                    ModelUnavailableBanner(openSettings: openSettings)
                } else if message.content.isEmpty && !isUser {
                    if let progress {
                        ChatProgressSteps(
                            progress: progress,
                            preview: appState.toggleFilePreview,
                            startDocumentChat: startFileChat
                        )
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Preparing…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    if isStreamingContent {
                        StreamingChatText(content: message.content)
                    } else {
                    // Markdown parsing and layout are expensive for long answers.
                    // Keep completed rows stable when unrelated application state
                    // (indexing, service health, file watching) changes.
                    ChatMarkdownText(content: message.content)
                        .equatable()
                    }
                }

                if showsRelatedFiles, !message.relatedFiles.isEmpty {
                    FileCitationGroup(
                        files: message.relatedFiles,
                        matches: message.relatedFileMatches,
                        preview: appState.toggleFilePreview,
                        startDocumentChat: startFileChat
                    )
                }

                if !isUser, message.inputTokens != nil || message.totalResponseDuration != nil {
                    ChatResponseMetricsView(message: message)
                }

                if editingText == nil, isUser || !message.content.isEmpty {
                    MessageActionBar(
                        message: message,
                        feedback: $feedback,
                        retry: retry,
                        edit: edit,
                        showsLastUserActions: showsLastUserActions,
                        startFileChat: message.relatedFiles.first(where: {
                            $0.supportsFileChat(with: appState.settings)
                        }).map { file in
                            { startFileChat(file) }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }
}

private struct InlineQuestionEditor: View {
    @Binding var text: String
    let cancel: () -> Void
    let resend: () -> Void
    @FocusState private var isFocused: Bool

    private var canResend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $text)
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .frame(minHeight: 68, maxHeight: 180)
                .padding(8)
                .background(FileNestTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(FileNestTheme.accent.opacity(0.55), lineWidth: 1)
                }

            HStack(spacing: 8) {
                Text("Edit your question")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(InlineActionButtonStyle(tint: .secondary))
                Button("Resend", action: resend)
                    .buttonStyle(InlineActionButtonStyle(tint: FileNestTheme.accent))
                    .disabled(!canResend)
            }
        }
        .onAppear { isFocused = true }
    }
}

private struct ChatProgressSteps: View {
    @EnvironmentObject private var appState: AppState
    let progress: ChatProgress
    let preview: (FileRecord) -> Void
    let startDocumentChat: (FileRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.scope == .attachedFile {
                progressRow(
                    progress.usesExistingIndex ? "Searching the current file index" : "Reading and parsing the current file",
                    completed: progress.phase != .readingFile
                )
                if progress.phase != .readingFile {
                    progressRow("Current file is ready", completed: true)
                }
            } else {
                progressRow(
                    "AI is analyzing the search criteria",
                    completed: progress.phase != .planningSearch
                )
                if !progress.searchIntent.isEmpty {
                    Text(progress.searchIntent)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.82))
                        .padding(.leading, 24)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                if progress.phase != .planningSearch {
                    progressRow(
                        "Searching the local index",
                        completed: progress.phase != .queryingIndex
                    )
                }

                if progress.phase == .reranking {
                    progressRow("Reranking the strongest matches", completed: false)
                }

                if progress.phase != .planningSearch
                    && progress.phase != .queryingIndex
                    && progress.phase != .reranking {
                    progressRow(
                        appState.settings.localizedFormat(
                            "Matched %d related files",
                            progress.matchedFileCount
                        ),
                        completed: progress.phase == .analyzing
                            || progress.phase == .thinking
                            || progress.phase == .verifying
                    )
                }

                if !progress.matchedFiles.isEmpty
                    && progress.phase != .planningSearch
                    && progress.phase != .queryingIndex {
                    ChatMatchedFilesStrip(
                        files: progress.matchedFiles,
                        preview: preview,
                        startDocumentChat: startDocumentChat
                    )
                    .padding(.top, 2)
                }
            }

            if progress.phase == .analyzing {
                progressRow("AI is analyzing and organizing the answer", completed: false)
            } else if progress.phase == .thinking {
                progressRow("Thinking Mode: performing deeper analysis", completed: false)
            } else if progress.phase == .verifying {
                progressRow("Verifying answer citations", completed: false)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .contain)
    }

    private func progressRow(_ title: String, completed: Bool) -> some View {
        HStack(spacing: 8) {
            if completed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(FileNestTheme.success)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(LocalizedStringKey(title))
        }
    }
}

private struct ChatResponseMetricsView: View {
    @EnvironmentObject private var appState: AppState
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 6) {
            if let model = message.responseModel, !model.isEmpty {
                Label(model, systemImage: "cpu")
            }
            if let input = message.inputTokens {
                metric("≈↑ \(formatTokens(input))")
            }
            if let output = message.outputTokens {
                metric("≈↓ \(formatTokens(output))")
            }
            if let first = message.firstResponseDuration {
                metric(appState.settings.localizedFormat("First response %.2fs", first))
            }
            if let total = message.totalResponseDuration {
                metric(appState.settings.localizedFormat("Total %.2fs", total))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(FileNestTheme.secondarySurface, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func metric(_ value: String) -> some View {
        Divider().frame(height: 11)
        Text(value)
    }

    private func formatTokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}

private struct ChatMatchedFilesStrip: View {
    let files: [FileRecord]
    let preview: (FileRecord) -> Void
    let startDocumentChat: (FileRecord) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(Array(files.enumerated()), id: \.element) { index, file in
                    ChatMatchedFileCard(
                        file: file,
                        isTopMatch: index == 0,
                        preview: { preview(file) },
                        startDocumentChat: { startDocumentChat(file) }
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Matched Files")
    }
}

private struct ChatMatchedFileCard: View {
    @EnvironmentObject private var appState: AppState
    @State private var isHovering = false
    let file: FileRecord
    let isTopMatch: Bool
    let preview: () -> Void
    let startDocumentChat: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            FileIconView(file: file, size: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    if isTopMatch {
                        Label("Best Match", systemImage: "sparkles")
                            .foregroundStyle(FileNestTheme.accent)
                    } else {
                        Text(LocalizedStringKey(file.categoryEnum.label))
                    }
                    Text("·")
                    Text(file.displaySize)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 2)

            if file.supportsFileChat(with: appState.settings) {
                Button(action: startDocumentChat) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(FileNestTheme.accent)
                .background(FileNestTheme.selection, in: Circle())
                .help("Chat with File")
            }

            Button(action: preview) {
                Image(systemName: "eye")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(FileNestTheme.accent)
            .background(FileNestTheme.selection, in: Circle())
            .help(appState.settings.localizedFormat("Preview %@", file.name))
        }
        .padding(.horizontal, 11)
        .frame(width: isTopMatch ? 258 : 238, height: 62)
        .background(
            isTopMatch || isHovering
                ? FileNestTheme.selection
                : FileNestTheme.elevatedSurface.opacity(0.62),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isTopMatch || isHovering ? FileNestTheme.accent.opacity(0.42) : FileNestTheme.border,
                    lineWidth: isTopMatch ? 1.5 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(perform: preview)
        .scaleEffect(isHovering ? 1.01 : 1)
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Preview", action: preview)
            if file.supportsFileChat(with: appState.settings) {
                Button("Chat with File", action: startDocumentChat)
            }
        }
    }
}

struct ChatMarkdownText: View, Equatable {
    let content: String

    var body: some View {
        Markdown(ChatMarkdownNormalizer.normalize(content))
            .markdownTheme(.basic)
            .markdownTextStyle {
                FontSize(15)
                ForegroundColor(.primary)
            }
            .tint(FileNestTheme.accent)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Keeps streamed output cheap and stable while a response is still growing.
/// Markdown is rendered once the answer completes.
private struct StreamingChatText: View {
    let content: String

    var body: some View {
        Text(content)
            .font(.system(size: 15))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum ChatMarkdownNormalizer {
    private static let openingStrongAsterisks = try! NSRegularExpression(
        pattern: #"(?<!\*)\*\*[ \t]+(\S(?:[^*\n]*?\S)?)[ \t]*\*\*(?!\*)"#
    )
    private static let closingStrongAsterisks = try! NSRegularExpression(
        pattern: #"(?<!\*)\*\*([^*\n]*?\S)[ \t]+\*\*(?!\*)"#
    )
    private static let openingStrongUnderscores = try! NSRegularExpression(
        pattern: #"(?<!_)__[ \t]+(\S(?:[^_\n]*?\S)?)[ \t]*__(?!_)"#
    )
    private static let closingStrongUnderscores = try! NSRegularExpression(
        pattern: #"(?<!_)__([^_\n]*?\S)[ \t]+__(?!_)"#
    )

    static func normalize(_ source: String) -> String {
        var insideFence = false
        return source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    insideFence.toggle()
                    return line
                }
                guard !insideFence, !line.contains("`") else { return line }
                return normalizeStrongWhitespace(in: line)
            }
            .joined(separator: "\n")
    }

    private static func normalizeStrongWhitespace(in source: String) -> String {
        [
            (openingStrongAsterisks, "**$1**"),
            (closingStrongAsterisks, "**$1**"),
            (openingStrongUnderscores, "__$1__"),
            (closingStrongUnderscores, "__$1__"),
        ].reduce(source) { text, replacement in
            let (expression, template) = replacement
            return expression.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: template
            )
        }
    }
}

private enum MessageFeedback {
    case helpful, notHelpful
}

private struct MessageActionBar: View {
    let message: ChatMessage
    @Binding var feedback: MessageFeedback?
    let retry: () -> Void
    let edit: () -> Void
    let showsLastUserActions: Bool
    let startFileChat: (() -> Void)?

    private var isUser: Bool { message.role == ChatRole.user.rawValue }

    var body: some View {
        HStack(spacing: 3) {
            actionButton("doc.on.doc", help: "Copy") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(message.content, forType: .string)
            }

            if isUser && showsLastUserActions {
                actionButton("pencil", help: "Edit and resend this question", action: edit)
                actionButton("arrow.clockwise", help: "Retry this question", action: retry)
            }

            if !isUser {
                if let startFileChat {
                    actionButton("doc.text.magnifyingglass", help: "Chat with cited file", action: startFileChat)
                }

                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 3)

                actionButton(
                    feedback == .helpful ? "hand.thumbsup.fill" : "hand.thumbsup",
                    help: "Helpful"
                ) {
                    feedback = feedback == .helpful ? nil : .helpful
                }
                actionButton(
                    feedback == .notHelpful ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    help: "Not helpful"
                ) {
                    feedback = feedback == .notHelpful ? nil : .notHelpful
                }
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    private func actionButton(_ systemImage: String,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 27, height: 25)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.001))
        .help(Text(LocalizedStringKey(help)))
    }
}

private struct FileCitationGroup: View {
    @EnvironmentObject private var appState: AppState
    let files: [FileRecord]
    let matches: [ChatRelatedFileMatch]
    let preview: (FileRecord) -> Void
    let startDocumentChat: (FileRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            FileCitationTableHeader(showsCategory: appState.previewedFile == nil)
            ForEach(Array(files.enumerated()), id: \.element) { index, file in
                FileCitationRow(
                    file: file,
                    isTopMatch: index == 0,
                    confidence: confidence(for: file),
                    preview: { preview(file) },
                    startDocumentChat: { startDocumentChat(file) }
                )
                if index < files.count - 1 {
                    Divider().padding(.leading, LibraryTableLayout.nameColumnLeading)
                }
            }
        }
    }

    private func confidence(for file: FileRecord) -> Double? {
        guard let fileID = file.id else { return nil }
        return matches.first(where: { $0.fileID == fileID })?.confidence
    }
}

/// The chat result table intentionally mirrors the file library: clicking a row
/// controls the shared inspector, while actions are compact and non-destructive.
private struct FileCitationTableHeader: View {
    let showsCategory: Bool

    var body: some View {
        HStack(spacing: LibraryTableLayout.spacing) {
            Color.clear.frame(width: LibraryTableLayout.iconWidth)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            if showsCategory {
                Text("Category").frame(width: LibraryTableLayout.categoryWidth, alignment: .leading)
            }
            Text("Size").frame(width: LibraryTableLayout.sizeWidth, alignment: .leading)
            Text("Modified").frame(width: LibraryTableLayout.modifiedWidth, alignment: .leading)
            Text("Actions").frame(width: LibraryTableLayout.actionsWidth, alignment: .center)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(height: 42)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FileNestTheme.border).frame(height: 1)
        }
    }
}

private struct FileCitationRow: View {
    @EnvironmentObject private var appState: AppState
    @State private var isHovering = false
    let file: FileRecord
    let isTopMatch: Bool
    let confidence: Double?
    let preview: () -> Void
    let startDocumentChat: () -> Void

    private var isSelected: Bool {
        guard let previewedFile = appState.previewedFile else { return false }
        if let fileID = file.id { return previewedFile.id == fileID }
        return previewedFile.path == file.path
    }

    var body: some View {
        HStack(spacing: LibraryTableLayout.spacing) {
            rowContent
            actionButtons
        }
        .font(.system(size: 11))
        .frame(minHeight: 66)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isSelected
                        ? FileNestTheme.contentSelection
                        : (isHovering ? FileNestTheme.contentHover : Color.clear)
                )
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: preview)
        .onHover { hovered in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovered }
        }
        .contextMenu {
            Button("View File Details", action: preview)
            if file.supportsFileChat(with: appState.settings) {
                Button("Chat with File", action: startDocumentChat)
            }
            Button("Open") {
                NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
            }
            Button("Show in Finder") {
                reveal(file)
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: LibraryTableLayout.spacing) {
            FileIconView(file: file, size: LibraryTableLayout.iconWidth)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(file.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if isTopMatch {
                        Label("Best Match", systemImage: "sparkles")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(FileNestTheme.accent)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(FileNestTheme.elevatedSurface.opacity(0.7), in: Capsule())
                    }
                    if let confidence {
                        ConfidenceBadge(confidence: confidence)
                    }
                }
                Text(file.displayPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if appState.previewedFile == nil {
                Text(LocalizedStringKey(file.categoryEnum.label))
                    .frame(width: LibraryTableLayout.categoryWidth, alignment: .leading)
            }
            Text(file.displaySize)
                .frame(width: LibraryTableLayout.sizeWidth, alignment: .leading)
            Text(file.mtime.formatted(date: .abbreviated, time: .shortened))
                .frame(width: LibraryTableLayout.modifiedWidth, alignment: .leading)
        }
        .contentShape(Rectangle())
        .help("Click to view file details")
        .pointingHandOnHover()
        .accessibilityAction(named: Text("View File Details")) {
            preview()
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if file.supportsFileChat(with: appState.settings) {
                LibraryActionButton(
                    systemName: "doc.text.magnifyingglass",
                    tint: FileNestTheme.accent,
                    title: "Chat with File",
                    action: startDocumentChat
                )
            }
            LibraryActionButton(
                systemName: "folder",
                tint: FileNestTheme.accent,
                title: "Show in Finder"
            ) {
                reveal(file)
            }
        }
        .frame(width: LibraryTableLayout.actionsWidth)
    }

    private func reveal(_ file: FileRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
    }
}

private struct ModelUnavailableBanner: View {
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "info.circle")
                .font(.system(size: 22))
                .foregroundStyle(FileNestTheme.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text("Local Model Not Connected")
                    .font(.system(size: 13, weight: .semibold))
                Text("Local semantic search is still available; connect a model for summarized answers.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open AI Settings", action: openSettings)
                .buttonStyle(QuietButtonStyle(compact: true))
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 74)
        .background(FileNestTheme.warningSurface)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(FileNestTheme.warning.opacity(0.25), lineWidth: 1)
        }
    }
}

private struct EmptyChatState: View {
    @EnvironmentObject private var appState: AppState
    let onPick: (String) -> Void
    private let examples = [
        "Find the final contract I downloaded last week",
        "What PDF documents did I use recently?",
        "Find files containing product requirements"
    ]

    var body: some View {
        VStack(spacing: 16) {
            BrandMark(size: 56)
            Text("Describe What You Remember")
                .font(.system(size: 20, weight: .semibold))
            Text("FileNest searches the local index and returns files you can open directly.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button { onPick(appState.settings.localized(example)) } label: {
                        Text(LocalizedStringKey(example))
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                }
            }
        }
        .padding(40)
    }
}

private struct EmptyFileChatState: View {
    @EnvironmentObject private var appState: AppState
    let path: String
    let onPick: (String) -> Void
    private let examples = ["Summarize this file", "Extract key data", "List risks and action items"]

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(FileNestTheme.selection)
                    .frame(width: 68, height: 68)
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(FileNestTheme.accent)
            }
            Text(URL(fileURLWithPath: path).lastPathComponent)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            Text("This chat analyzes only this file and does not search the library.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button { onPick(appState.settings.localized(example)) } label: {
                        Text(LocalizedStringKey(example))
                    }
                    .buttonStyle(QuietButtonStyle(compact: true))
                }
            }
        }
        .padding(40)
    }
}
