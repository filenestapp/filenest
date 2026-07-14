import SwiftUI

/// 聊天视图：输入框 + 消息流（含引用文件卡片）
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @State private var input = ""
    @State private var sending = false
    @State private var suggestion: String? = nil

    var messages: [ChatMessage] { appState.chatMessages }

    var body: some View {
        VStack(spacing: 0) {
            // 消息流
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if messages.isEmpty {
                            EmptyChatState(onPick: { q in input = q; send() })
                                .padding(.top, 40)
                        }
                        ForEach(messages) { m in
                            MessageBubble(message: m)
                                .id(m.id)
                        }
                        if sending {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("正在检索并思考…").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 16)
                }
                .onChange(of: messages.count) { _ in
                    if let last = messages.last?.id {
                        withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }

            Divider()

            // 输入区
            HStack(alignment: .bottom, spacing: 8) {
                Button { appState.chat.clearHistory(); appState.chatMessages = [] } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("清空对话")

                TextField("描述你想找的文件，例如「上周下载的那份合同」", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { send() }

                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            }
            .padding(12)
        }
        .onAppear {
            appState.chatMessages = appState.chat.loadHistory()
        }
    }

    private func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !sending else { return }
        input = ""
        sending = true
        // 先乐观插入用户消息
        let userMsg = ChatMessage(id: Int64(messages.count * -1 - 1), role: ChatRole.user.rawValue,
                                  content: q, ts: Date(), relatedFileIds: nil)
        appState.chatMessages.append(userMsg)
        Task {
            let reply = await appState.chat.ask(q)
            await MainActor.run {
                appState.chatMessages.append(reply)
                sending = false
            }
        }
    }
}

struct EmptyChatState: View {
    let onPick: (String) -> Void
    private let examples = [
        "我最近的 PDF 文档有哪些？",
        "找一下包含「合同」的文件",
        "上周下载的图片",
        "帮我找 swift 代码文件",
    ]
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40)).foregroundStyle(.tint)
            Text("用自然语言找文件").font(.title3.bold())
            Text("FileNest 会从你已索引的文件中检索相关内容并回答")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(examples, id: \.self) { ex in
                    Button { onPick(ex) } label: {
                        Text(ex).padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    private var isUser: Bool { message.role == ChatRole.user.rawValue }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(isUser ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                // 引用文件卡片
                if !message.relatedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("📎 引用文件").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(message.relatedFiles) { f in
                            FileRefCard(file: f)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            if !isUser { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 16)
    }
}

struct FileRefCard: View {
    let file: FileRecord
    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
        } label: {
            HStack(spacing: 8) {
                Image(systemName: file.categoryEnum.icon).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).font(.caption).lineLimit(1)
                    Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.right.circle").foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.tertiary, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
