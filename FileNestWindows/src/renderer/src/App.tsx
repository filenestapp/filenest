import { useCallback, useEffect, useState } from "react";
import type { AppSnapshot, FileRecord } from "../../shared/types";
import { Sidebar, type Page } from "./Sidebar";
import { ChatPage } from "./ChatPage";
import { LibraryPage } from "./LibraryPage";
import { SettingsPage } from "./SettingsPage";
import { FileInspector } from "./components";
import { Onboarding } from "./Onboarding";
import { resolveLanguage } from "./i18n";
import { translate } from "./i18n";
import { QuickSearchPanel } from "./QuickSearchPanel";
import { RefreshCw, X } from "lucide-react";

export default function App(): React.JSX.Element {
  const [snapshot, setSnapshot] = useState<AppSnapshot | null>(null);
  const [page, setPage] = useState<Page>("chat");
  const [inspectedFile, setInspectedFile] = useState<FileRecord | null>(null);
  const [fileChatReturnPage, setFileChatReturnPage] = useState<Page>("library");
  const [dismissedProcessingIds, setDismissedProcessingIds] = useState<Set<number>>(new Set());
  const refresh = useCallback(
    async (): Promise<void> => setSnapshot(await window.fileNest.refresh()),
    [],
  );
  useEffect(() => {
    void window.fileNest.getSnapshot().then(setSnapshot);
    const unsubscribe = window.fileNest.onStateChanged(() => void refresh());
    return () => { if (typeof unsubscribe === "function") unsubscribe(); };
  }, [refresh]);
  useEffect(() => {
    if (!snapshot) return;
    document.documentElement.dataset.theme = snapshot.settings.appearance;
    document.documentElement.lang = resolveLanguage(snapshot.settings.appLanguage) === "en" ? "en" : "zh-CN";
  }, [snapshot?.settings.appearance, snapshot?.settings.appLanguage]);
  useEffect(() => {
    if (snapshot?.pendingLibrarySearch) {
      setPage("library");
      setInspectedFile(null);
    }
  }, [snapshot?.pendingLibrarySearch?.id]);
  const activeProcessingIds = snapshot?.automaticProcessingItems.map((item) => item.id) ?? [];
  useEffect(() => {
    const active = new Set(activeProcessingIds);
    setDismissedProcessingIds((current) => new Set([...current].filter((id) => active.has(id))));
  }, [activeProcessingIds.join(",")]);
  if (location.hash === "#quick-search") return <QuickSearchPanel language={snapshot?.settings.appLanguage ?? "system"} />;
  if (!snapshot)
    return (
      <div className="app-loading">
        <img src="./brand-mark.png" alt="" />
        <span>FileNest</span>
        <div className="loading-line" />
      </div>
    );
  if (!snapshot.settings.onboardingCompleted)
    return <Onboarding snapshot={snapshot} onComplete={refresh} />;
  const selectChat = async (id: number): Promise<void> => {
    await window.fileNest.selectChat(id);
    setPage("chat");
    setInspectedFile(null);
    await refresh();
  };
  const newChat = async (): Promise<void> => {
    await window.fileNest.beginChat();
    setPage("chat");
    setInspectedFile(null);
    await refresh();
  };
  const deleteChat = async (id: number): Promise<void> => {
    await window.fileNest.deleteChat(id);
    await refresh();
  };
  const startFileChat = async (file: FileRecord): Promise<void> => {
    setFileChatReturnPage(page);
    await window.fileNest.beginChat(file.path);
    setPage("chat");
    setInspectedFile(file);
    await refresh();
  };
  const visibleProcessingItems = snapshot.automaticProcessingItems.filter((item) => !dismissedProcessingIds.has(item.id));
  const t = (value: string): string => translate(value, snapshot.settings.appLanguage);
  if (page === "settings") return <div className="settings-shell"><SettingsPage snapshot={snapshot} onRefresh={refresh} onClose={() => setPage("chat")} /></div>;
  return (
    <div className={`app-shell ${inspectedFile ? "with-inspector inspector-focus" : ""}`}>
      {!inspectedFile && <Sidebar
        snapshot={snapshot}
        page={page}
        onPage={(next) => {
          setPage(next);
          if (next === "settings") setInspectedFile(null);
        }}
        onSelectChat={(id) => void selectChat(id)}
        onNewChat={() => void newChat()}
        onDeleteChat={(id) => void deleteChat(id)}
      />}
      <div className="app-content">
        <div className={`persistent-page ${page === "chat" ? "active" : "hidden"}`}>
          <ChatPage
            snapshot={snapshot}
            active={page === "chat"}
            onRefresh={refresh}
            onInspect={setInspectedFile}
            onReturnFromFileChat={() => {
              setPage(fileChatReturnPage);
              setInspectedFile(null);
            }}
          />
        </div>
        {page === "library" && (
          <LibraryPage
            snapshot={snapshot}
            externalSearch={snapshot.pendingLibrarySearch}
            onInspect={setInspectedFile}
            onStartChat={(file) => void startFileChat(file)}
            onRefresh={refresh}
          />
        )}
      </div>
      {inspectedFile && (
        <FileInspector
          file={
            snapshot.files.find((file) => file.id === inspectedFile.id) ??
            inspectedFile
          }
          language={snapshot.settings.appLanguage}
          onClose={() => setInspectedFile(null)}
          onStartChat={(file) => void startFileChat(file)}
        />
      )}
      {visibleProcessingItems.length > 0 && (
        <aside className="automatic-processing-tip" aria-label={t("Automatic processing status")}>
          <header>
            <RefreshCw className="spin" size={15} />
            <strong>{t("Processing files")}</strong>
            <span>{snapshot.automaticProcessingItems.length}</span>
            <button aria-label={t("Dismiss Processing Status")} onClick={() => setDismissedProcessingIds(new Set(activeProcessingIds))}><X size={13} /></button>
          </header>
          {visibleProcessingItems.slice(0, 2).map((item) => (
            <div key={item.id}><RefreshCw className="spin" size={13} /><span>{item.name}</span><small>{t(item.stage === "indexing" ? "Indexing file" : item.stage === "transcribing" ? "Transcribing audio or video" : item.stage === "waiting" ? "Waiting to organize" : "Organizing file")}</small></div>
          ))}
        </aside>
      )}
    </div>
  );
}
