import { useEffect, useMemo, useRef, useState } from "react";
import {
  CheckCircle2,
  Clipboard,
  FilePlus2,
  FolderOpen,
  MessageCircle,
  Mic,
  MoreHorizontal,
  Paperclip,
  RotateCcw,
  Send,
  ShieldCheck,
  SlidersHorizontal,
  Sparkles,
  Square,
  ThumbsDown,
  ThumbsUp,
  X,
} from "lucide-react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type {
  AppSnapshot,
  ChatMessage,
  ChatStreamEvent,
  FileRecord,
} from "../../shared/types";
import {
  FileTypeIcon,
  formatBytes,
  formatDate,
  IconButton,
} from "./components";
import { translate } from "./i18n";

export function ChatPage({
  snapshot,
  onRefresh,
  onInspect,
}: {
  snapshot: AppSnapshot;
  onRefresh(): Promise<void>;
  onInspect(file: FileRecord): void;
}): React.JSX.Element {
  const t = (value: string): string =>
    translate(value, snapshot.settings.appLanguage);
  const [drafts, setDrafts] = useState<Record<string, string>>(() => {
    try { return JSON.parse(sessionStorage.getItem("filenest-chat-drafts") ?? "{}") as Record<string, string>; }
    catch { return {}; }
  });
  const [attachment, setAttachment] = useState<string | null>(
    () =>
      snapshot.chatSessions.find(
        (item) => item.id === snapshot.selectedSessionId,
      )?.attachedFilePath ?? snapshot.pendingChatAttachmentPath,
  );
  const [streaming, setStreaming] = useState("");
  const [requestId, setRequestId] = useState<string | null>(null);
  const [pendingQuestion, setPendingQuestion] = useState<string | null>(null);
  const [progressStage, setProgressStage] = useState<ChatStreamEvent["stage"]>();
  const endRef = useRef<HTMLDivElement>(null);
  const selectedSession = snapshot.chatSessions.find(
    (item) => item.id === snapshot.selectedSessionId,
  );
  const draftKey = selectedSession ? `session:${selectedSession.id}` : `new:${snapshot.pendingChatAttachmentPath ?? "library"}`;
  const input = drafts[draftKey] ?? "";
  const setInput = (value: string | ((current: string) => string)): void => {
    setDrafts((current) => ({ ...current, [draftKey]: typeof value === "function" ? value(current[draftKey] ?? "") : value }));
  };
  useEffect(() => { sessionStorage.setItem("filenest-chat-drafts", JSON.stringify(drafts)); }, [drafts]);
  useEffect(() => {
    setAttachment(selectedSession?.attachedFilePath ?? snapshot.pendingChatAttachmentPath);
  }, [selectedSession?.id, selectedSession?.attachedFilePath, snapshot.pendingChatAttachmentPath]);
  useEffect(() => {
      const unsubscribe = window.fileNest.onChatStream((event: ChatStreamEvent) => {
        if (requestId && event.requestId !== requestId) return;
        if (event.type === "delta")
          setStreaming((value) => value + (event.delta ?? ""));
        if (event.type === "progress") setProgressStage(event.stage);
        if (event.type === "done") {
          setStreaming("");
          setPendingQuestion(null);
          setRequestId(null);
          setProgressStage(undefined);
          void onRefresh();
        }
        if (event.type === "error") {
          setStreaming(event.error ?? "Generation failed");
          setRequestId(null);
          setProgressStage(undefined);
        }
      });
      return () => { if (typeof unsubscribe === "function") unsubscribe(); };
    }, [onRefresh, requestId]);
  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
  }, [snapshot.messages.length, streaming, pendingQuestion]);
  const attachedFile = useMemo(
    () => snapshot.files.find((file) => file.path === attachment) ?? null,
    [attachment, snapshot.files],
  );
  const sendQuestion = async (
    value: string,
    retryAssistantMessageId?: number,
  ): Promise<void> => {
    const question = value.trim();
    if (!question || requestId) return;
    setDrafts((current) => ({ ...current, [draftKey]: "" }));
    setPendingQuestion(question);
    setStreaming("");
    setProgressStage("searching");
    const result = await window.fileNest.sendChat({
      sessionId: snapshot.selectedSessionId,
      content: question,
      attachedFilePath: attachment,
      retryAssistantMessageId,
    });
    setRequestId(result.requestId);
  };
  const send = (): Promise<void> => sendQuestion(input);
  const retryMessage = (message: ChatMessage): void => {
    const index = snapshot.messages.findIndex((item) => item.id === message.id);
    const question = snapshot.messages
      .slice(0, index)
      .reverse()
      .find((item) => item.role === "user")?.content;
    if (question) void sendQuestion(question, message.id);
  };
  const startDictation = (): void => {
    type Result = { 0: { transcript: string } };
    type Recognition = {
      lang: string;
      interimResults: boolean;
      onresult: ((event: { results: ArrayLike<Result> }) => void) | null;
      onerror: (() => void) | null;
      start(): void;
    };
    type RecognitionConstructor = new () => Recognition;
    const speechWindow = window as Window & {
      SpeechRecognition?: RecognitionConstructor;
      webkitSpeechRecognition?: RecognitionConstructor;
    };
    const Constructor =
      speechWindow.SpeechRecognition ?? speechWindow.webkitSpeechRecognition;
    if (!Constructor) {
      alert("Speech recognition is unavailable here. Press Win + H to use Windows dictation.");
      return;
    }
    const recognition = new Constructor();
    recognition.lang = snapshot.settings.appLanguage === "en" ? "en-US" : "zh-CN";
    recognition.interimResults = false;
    recognition.onresult = (event) => {
      const transcript = Array.from(event.results)
        .map((result) => result[0]?.transcript ?? "")
        .join("");
      setInput((value) => `${value}${value ? " " : ""}${transcript}`);
    };
    recognition.onerror = () => alert("Voice input did not complete. Press Win + H to use Windows dictation.");
    recognition.start();
  };
  const chooseFile = async (): Promise<void> => {
    const path = await window.fileNest.chooseChatFile();
    if (path) setAttachment(path);
  };
  const heading = attachment ? t("Chat with File") : t("Find with Chat");
  const subtitle = attachment
    ? t("Analyze only the current file without searching or mixing in content from the library.")
    : t("Find files with natural language. The index remains on this PC.");
  const usesCloud =
    snapshot.settings.llmChoice === "cloud" ||
    snapshot.settings.embeddingSource === "cloud" ||
    snapshot.settings.ocrSource === "cloud";
  return (
    <main
      className="chat-page"
      onDragOver={(event) => {
        event.preventDefault();
        event.dataTransfer.dropEffect = "copy";
      }}
      onDrop={(event) => {
        event.preventDefault();
        const file = event.dataTransfer.files[0];
        if (file) {
          const path = window.fileNest.pathForDroppedFile(file);
          if (path) setAttachment(path);
        }
      }}
    >
      <header className="page-header">
        <div>
          <h1>{heading}</h1>
          <p>{subtitle}</p>
        </div>
        <div className="page-actions">
          <button
            className="secondary-button"
            onClick={() =>
              void window.fileNest.beginChat().then(() => onRefresh())
            }
          >
            <PlusSquareIcon />
            {t("New Chat")}
          </button>
          <span className="mode-control">
            <CheckCircle2 size={16} />
            {snapshot.settings.llmChoice === "ollama"
              ? t("Local Mode")
              : snapshot.settings.llmChoice === "cloud"
                ? t("Cloud Mode")
                : t("Search Only")}
          </span>
          <IconButton label="More">
            <MoreHorizontal size={18} />
          </IconButton>
        </div>
      </header>
      <div className="chat-scroll">
        {snapshot.messages.length === 0 && !pendingQuestion ? (
          <EmptyChat t={t} onChoose={() => void chooseFile()} />
        ) : (
          <div className="conversation">
            {snapshot.messages.map((message) => (
              <Message
                key={message.id}
                message={message}
                files={snapshot.files}
                language={snapshot.settings.appLanguage}
                onInspect={onInspect}
                onRetry={retryMessage}
              />
            ))}
            {pendingQuestion && (
              <Message
                message={{
                  id: -1,
                  sessionId: -1,
                  role: "user",
                  content: pendingQuestion,
                  timestamp: new Date().toISOString(),
                  relatedFileIds: [],
                }}
                files={snapshot.files}
                language={snapshot.settings.appLanguage}
                onInspect={onInspect}
                onRetry={() => undefined}
              />
            )}
            {(streaming || requestId) && (
              <div className="assistant-message">
                <div className="assistant-avatar">
                  <img src="./brand-mark.png" alt="" />
                </div>
                <div className="message-body">
                  <div className="message-meta">
                    <strong>FileNest</strong>
                    <span className="streaming-dot" />
                  </div>
                  {streaming ? (
                    <ReactMarkdown remarkPlugins={[remarkGfm]}>
                      {streaming}
                    </ReactMarkdown>
                  ) : (
                    <div className="thinking-line">
                      <span />
                      <span />
                      <span /> {progressStage === "generating"
                        ? t("Generating response…")
                        : progressStage === "retrieved"
                          ? t("Preparing relevant context…")
                          : t("Searching local files…")}
                    </div>
                  )}
                </div>
              </div>
            )}
            <div ref={endRef} />
          </div>
        )}
      </div>
      <div className="composer-wrap">
        {attachedFile && (
          <div className="attachment-chip">
            <FileTypeIcon file={attachedFile} size={16} />
            <span>{attachedFile.name}</span>
            <IconButton label={t("Cancel")} onClick={() => setAttachment(null)}>
              <X size={14} />
            </IconButton>
          </div>
        )}
        <div className="composer">
          <textarea
            aria-label={
              attachment ? t("Ask about this file…") : t("Describe the file you're looking for…")
            }
            placeholder={
              attachment ? t("Ask about this file…") : t("Describe the file you're looking for…")
            }
            value={input}
            onChange={(event) => setInput(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && !event.shiftKey) {
                event.preventDefault();
                void send();
              }
            }}
          />
          <div className="composer-tools">
            <div>
              <IconButton
                label={t("Choose File")}
                onClick={() => void chooseFile()}
              >
                <Paperclip size={19} />
              </IconButton>
              <span className="privacy-badge">
                <ShieldCheck size={15} />
                {usesCloud ? t("Cloud features send the content they need") : t("Local file access")}
              </span>
            </div>
            <div>
              <button
                className={`model-button ${snapshot.settings.thinkingMode ? "active" : ""}`}
                onClick={() =>
                  void window.fileNest
                    .updateSettings({
                      thinkingMode: !snapshot.settings.thinkingMode,
                    })
                    .then(onRefresh)
                }
              >
                <Sparkles size={15} />
                {t(snapshot.settings.thinkingMode ? "Thinking" : "Fast")}⌄
              </button>
              <select
                className="model-button model-select"
                aria-label="Chat Model"
                value={
                  snapshot.settings.llmChoice === "ollama"
                    ? snapshot.settings.ollamaModel
                    : snapshot.settings.llmChoice === "cloud"
                      ? snapshot.settings.cloudModel
                      : "none"
                }
                disabled={snapshot.settings.llmChoice === "none"}
                onChange={(event) =>
                  void window.fileNest
                    .updateSettings(
                      snapshot.settings.llmChoice === "ollama"
                        ? { ollamaModel: event.target.value }
                        : { cloudModel: event.target.value },
                    )
                    .then(onRefresh)
                }
              >
                {snapshot.settings.llmChoice === "ollama" ? (
                  [...new Set([
                    snapshot.settings.ollamaModel,
                    ...snapshot.ollama.models,
                  ])].map((model) => (
                    <option key={model} value={model}>
                      {model}
                    </option>
                  ))
                ) : snapshot.settings.llmChoice === "cloud" ? (
                  <option value={snapshot.settings.cloudModel}>
                    {snapshot.settings.cloudModel}
                  </option>
                ) : (
                  <option value="none">{t("Search Only")}</option>
                )}
              </select>
              <IconButton label="Voice Input" onClick={startDictation}>
                <Mic size={18} />
              </IconButton>
              {requestId ? (
                <button
                  className="send-button stop"
                  onClick={() => {
                    void window.fileNest.cancelChat(requestId);
                    setRequestId(null);
                    setPendingQuestion(null);
                    setProgressStage(undefined);
                  }}
                >
                  <Square size={16} />
                </button>
              ) : (
                <button
                  className="send-button"
                  disabled={!input.trim()}
                  onClick={() => void send()}
                >
                  <Send size={18} />
                </button>
              )}
            </div>
          </div>
        </div>
        <div className="composer-foot">
          <span className="active-green">●</span>
          {snapshot.settings.embeddingSource === "local"
            ? t("Local Lightweight Index")
            : snapshot.settings.embeddingSource === "ollama"
              ? t("Local Semantic Search")
              : t("Cloud Semantic Search")}
          <span>·</span>
          {usesCloud ? t("Cloud features send the content they need") : t("File contents are not uploaded")}
        </div>
      </div>
    </main>
  );
}

function Message({
  message,
  files,
  language,
  onInspect,
  onRetry,
}: {
  message: ChatMessage;
  files: FileRecord[];
  language: AppSnapshot["settings"]["appLanguage"];
  onInspect(file: FileRecord): void;
  onRetry(message: ChatMessage): void;
}): React.JSX.Element {
  const t = (value: string): string => translate(value, language);
  const [feedback, setFeedback] = useState<"helpful" | "not-helpful" | null>(null);
  const related = message.relatedFileIds
    .map((id) => files.find((file) => file.id === id))
    .filter((file): file is FileRecord => Boolean(file));
  if (message.role === "user")
    return (
      <div className="user-message">
        <div className="user-avatar">{t("You")}</div>
        <div className="message-body">
          <div className="message-meta">
            <strong>{t("You")}</strong>
            <time>{formatDate(message.timestamp, language)}</time>
          </div>
          <p>{message.content}</p>
        </div>
      </div>
    );
  return (
    <div className="assistant-message">
      <div className="assistant-avatar">
        <img src="./brand-mark.png" alt="" />
      </div>
      <div className="message-body">
        <div className="message-meta">
          <strong>FileNest</strong>
          <time>{formatDate(message.timestamp, language)}</time>
        </div>
        <div className="markdown">
          <ReactMarkdown remarkPlugins={[remarkGfm]}>
            {message.content}
          </ReactMarkdown>
        </div>
        {related.map((file, index) => (
          <button
            key={file.id}
            className="matched-file"
            onClick={() => onInspect(file)}
          >
            <FileTypeIcon file={file} size={24} />
            <div>
              <strong>{file.name}</strong>
              <span>{file.path}</span>
              <small>
                {formatDate(file.mtime, language)} · {formatBytes(file.size)}
              </small>
            </div>
            {index === 0 && <span className="relevance">✦ {t("Best Match")}</span>}
            <span
              className="file-action"
              role="button"
              tabIndex={0}
              onClick={(event) => {
                event.stopPropagation();
                void window.fileNest.showInExplorer(file.path);
              }}
              onKeyDown={(event) => {
                if (event.key === "Enter" || event.key === " ") {
                  event.preventDefault();
                  event.stopPropagation();
                  void window.fileNest.showInExplorer(file.path);
                }
              }}
            >
              <FolderOpen size={16} />
              {t("Show in File Explorer")}
            </span>
          </button>
        ))}
        <div className="message-actions">
          {message.totalResponseDuration != null && (
            <span className="response-metrics">
              {message.responseProvider} · {message.outputTokens ?? 0} {t("tokens")} · {message.totalResponseDuration.toFixed(2)}s
            </span>
          )}
          <IconButton
            label="Copy"
            onClick={() => void navigator.clipboard.writeText(message.content)}
          >
            <Clipboard size={15} />
          </IconButton>
          <IconButton label="Regenerate" onClick={() => onRetry(message)}>
            <RotateCcw size={15} />
          </IconButton>
          <IconButton
            label="Helpful"
            className={feedback === "helpful" ? "active" : ""}
            onClick={() =>
              setFeedback((value) => (value === "helpful" ? null : "helpful"))
            }
          >
            <ThumbsUp size={15} />
          </IconButton>
          <IconButton
            label="Not helpful"
            className={feedback === "not-helpful" ? "active" : ""}
            onClick={() =>
              setFeedback((value) =>
                value === "not-helpful" ? null : "not-helpful",
              )
            }
          >
            <ThumbsDown size={15} />
          </IconButton>
        </div>
      </div>
    </div>
  );
}

function EmptyChat({
  t,
  onChoose,
}: {
  t(value: string): string;
  onChoose(): void;
}): React.JSX.Element {
  return (
    <div className="empty-chat">
      <div className="empty-brand">
        <img src="./brand-mark.png" alt="" />
      </div>
      <h2>{t("Find with Chat")}</h2>
      <p>{t("Attach a file or describe what you want to find.")}</p>
      <button className="secondary-button" onClick={onChoose}>
        <FilePlus2 size={16} />
        {t("Choose File")}
      </button>
    </div>
  );
}

function PlusSquareIcon(): React.JSX.Element {
  return <MessageCircle size={16} />;
}
