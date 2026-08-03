import { useState } from "react";
import {
  Cpu,
  FileSearch,
  Folder,
  MessageCircle,
  LoaderCircle,
  PlusSquare,
  Settings as SettingsIcon,
  Wifi,
  WifiOff,
  X,
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
}: {
  snapshot: AppSnapshot;
  page: Page;
  onPage(page: Page): void;
  onSelectChat(id: number): void;
  onNewChat(): void;
  onDeleteChat(id: number): void;
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
          onClick={onNewChat}
        >
          <MessageCircle size={19} />
          {t("Find with Chat")}
        </button>
      </nav>
      <div className="recent-heading">
        <span>{t("Recent")}</span>
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
      <div className="sidebar-footer">
        <SidebarStatusControls snapshot={snapshot} t={t} onOpenSettings={() => onPage("settings")} />
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

function SidebarStatusControls({
  snapshot,
  t,
  onOpenSettings,
}: {
  snapshot: AppSnapshot;
  t(value: string): string;
  onOpenSettings(): void;
}): React.JSX.Element {
  const [open, setOpen] = useState<"watching" | "indexing" | "ai" | null>(null);
  const usesCloud = snapshot.settings.llmChoice === "cloud" || snapshot.settings.embeddingSource === "cloud" || snapshot.settings.ocrSource === "cloud";
  const status = open === "watching"
    ? { title: snapshot.watching ? t("Watching") : t("Paused"), detail: snapshot.settings.watchDirs.length ? `${snapshot.settings.watchDirs.length} ${t("watched folders")}` : t("No watched folders"), action: snapshot.watching ? t("Pause Watching") : t("Start Watching"), run: () => snapshot.watching ? window.fileNest.stopWatching() : window.fileNest.startWatching() }
    : open === "indexing"
      ? { title: snapshot.indexing ? t("Indexing") : t("Index Status"), detail: snapshot.indexingProgress ? `${snapshot.indexingProgress.completed}/${snapshot.indexingProgress.total} · ${snapshot.indexingProgress.currentName}` : t("Your local index is ready"), action: t("Open Settings"), run: onOpenSettings }
      : { title: usesCloud ? t("Cloud Mode") : t("Local AI"), detail: usesCloud ? t("Cloud features send the content they need") : t("File contents are not uploaded"), action: t("Open Settings"), run: onOpenSettings };
  const toggle = (value: "watching" | "indexing" | "ai"): void => setOpen((current) => current === value ? null : value);
  return <div className="sidebar-status-controls">
    <IconButton label={snapshot.watching ? t("Watching") : t("Paused")} className={open === "watching" ? "active" : ""} onClick={() => toggle("watching")}>{snapshot.watching ? <Wifi size={16} className="active-green" /> : <WifiOff size={16} />}</IconButton>
    <IconButton label={snapshot.indexing ? t("Indexing") : t("Index Status")} className={open === "indexing" ? "active" : ""} onClick={() => toggle("indexing")}><FileSearch size={16} className={snapshot.indexing ? "spin active-blue" : ""} /></IconButton>
    <IconButton label={usesCloud ? t("Cloud Mode") : t("Local AI")} className={open === "ai" ? "active" : ""} onClick={() => toggle("ai")}><Cpu size={16} className={usesCloud ? "active-blue" : "active-green"} /></IconButton>
    {open && <section className="sidebar-status-popover" role="dialog" aria-label={status.title}><header><div><strong>{status.title}</strong><span>{status.detail}</span></div><button aria-label={t("Close")} onClick={() => setOpen(null)}><X size={15} /></button></header><button className="text-action" onClick={() => { void status.run(); setOpen(null); }}>{status.action}</button></section>}
  </div>;
}
