import {
  Archive,
  FileSearch,
  Folder,
  MessageCircle,
  LoaderCircle,
  MoreHorizontal,
  PlusSquare,
  Settings as SettingsIcon,
  ShieldCheck,
  Wifi,
  WifiOff,
} from "lucide-react";
import type { AppSnapshot } from "../../shared/types";
import { formatDate, IconButton } from "./components";
import { translate } from "./i18n";

export type Page = "library" | "chat" | "settings";

export function Sidebar({
  snapshot,
  page,
  onPage,
  onSelectChat,
  onNewChat,
  onDeleteChat,
  onClearChats,
}: {
  snapshot: AppSnapshot;
  page: Page;
  onPage(page: Page): void;
  onSelectChat(id: number): void;
  onNewChat(): void;
  onDeleteChat(id: number): void;
  onClearChats(): void;
}): React.JSX.Element {
  const t = (value: string): string =>
    translate(value, snapshot.settings.appLanguage);
  const usesCloud =
    snapshot.settings.llmChoice === "cloud" ||
    snapshot.settings.embeddingSource === "cloud" ||
    snapshot.settings.ocrSource === "cloud";
  return (
    <aside className="sidebar">
      <div className="brand">
        <img src="./brand-mark.png" alt="" />
        <strong>FileNest</strong>
      </div>
      <nav className="primary-nav" aria-label="Primary Navigation">
        <button
          className={page === "library" ? "selected" : ""}
          onClick={() => onPage("library")}
        >
          <Folder size={19} />
          {t("Library")}
        </button>
        <button
          className={page === "chat" ? "selected" : ""}
          onClick={() => onPage("chat")}
        >
          <MessageCircle size={19} />
          {t("Find with Chat")}
        </button>
      </nav>
      <div className="recent-heading">
        <span>{t("Recent")}</span>
        <IconButton label="Clear Chat History" onClick={onClearChats}>
          <MoreHorizontal size={15} />
        </IconButton>
        <IconButton label={t("New Chat")} onClick={onNewChat}>
          <PlusSquare size={15} />
        </IconButton>
      </div>
      <div className="recent-list">
        {snapshot.chatSessions.length === 0 && (
          <div className="recent-empty">{t("No Conversations Yet")}</div>
        )}
        {snapshot.chatSessions.slice(0, 30).map((session) => (
          <div className="recent-session" key={session.id}>
            <button
              className={
                page === "chat" && snapshot.selectedSessionId === session.id
                  ? "recent-item selected"
                  : "recent-item"
              }
              onClick={() => onSelectChat(session.id)}
              title={session.title}
            >
              {session.attachedFilePath ? (
                <FileSearch size={14} />
              ) : (
                <MessageCircle size={14} />
              )}
              <span>{session.title}</span>
              <time>
                {snapshot.runningChatSessionIds.includes(session.id) && <LoaderCircle className="spin active-blue" size={12} />}
                {!snapshot.runningChatSessionIds.includes(session.id) && snapshot.completedChatSessionIds.includes(session.id) && <i className="chat-complete-dot" />}
                {formatDate(
                  session.updatedAt,
                  snapshot.settings.appLanguage,
                  true,
                )}
              </time>
            </button>
            <button
              className="recent-delete"
              aria-label="Delete Chat"
              title="Delete Chat"
              onClick={() => onDeleteChat(session.id)}
            >
              ×
            </button>
          </div>
        ))}
      </div>
      <div className="sidebar-status">
        <div className="status-line">
          {snapshot.watching ? <Wifi size={16} /> : <WifiOff size={16} />}
          <div>
            <strong>{snapshot.watching ? t("Watching") : t("Paused")}</strong>
            <span>{snapshot.settings.watchDirs[0] ?? "—"}</span>
          </div>
        </div>
        <div className="status-line">
          <ShieldCheck size={16} />
          <div>
            <strong>{usesCloud ? t("Cloud Mode") : t("Local file access")}</strong>
            <span>
              {usesCloud
                ? t("Cloud features send the content they need")
                : t("File contents are not uploaded")}
            </span>
          </div>
        </div>
      </div>
      <div className="sidebar-footer">
        <div className="footer-indicators">
          <Wifi size={16} className={snapshot.watching ? "active-green" : ""} />
          <FileSearch
            size={16}
            className={snapshot.indexing ? "spin active-blue" : ""}
          />
          <Archive size={16} />
        </div>
        <IconButton
          label={t("Settings")}
          className={page === "settings" ? "active" : ""}
          onClick={() => onPage("settings")}
        >
          <SettingsIcon size={17} />
        </IconButton>
      </div>
    </aside>
  );
}
