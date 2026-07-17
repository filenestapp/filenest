import { useCallback, useEffect, useState } from "react";
import type { AppSnapshot, FileRecord } from "../../shared/types";
import { Sidebar, type Page } from "./Sidebar";
import { ChatPage } from "./ChatPage";
import { LibraryPage } from "./LibraryPage";
import { SettingsPage } from "./SettingsPage";
import { FileInspector } from "./components";
import { Onboarding } from "./Onboarding";
import { resolveLanguage } from "./i18n";
import { QuickSearchPanel } from "./QuickSearchPanel";

export default function App(): React.JSX.Element {
  const [snapshot, setSnapshot] = useState<AppSnapshot | null>(null);
  const [page, setPage] = useState<Page>("chat");
  const [inspectedFile, setInspectedFile] = useState<FileRecord | null>(null);
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
  const clearChats = async (): Promise<void> => {
    if (!confirm("Clear all chat history?")) return;
    await window.fileNest.clearChats();
    setInspectedFile(null);
    await refresh();
  };
  const startFileChat = async (file: FileRecord): Promise<void> => {
    await window.fileNest.beginChat(file.path);
    setPage("chat");
    setInspectedFile(file);
    await refresh();
  };
  return (
    <div className={`app-shell ${inspectedFile ? "with-inspector" : ""}`}>
      <Sidebar
        snapshot={snapshot}
        page={page}
        onPage={(next) => {
          setPage(next);
          if (next === "settings") setInspectedFile(null);
        }}
        onSelectChat={(id) => void selectChat(id)}
        onNewChat={() => void newChat()}
        onDeleteChat={(id) => void deleteChat(id)}
        onClearChats={() => void clearChats()}
      />
      <div className="app-content">
        <div className={`persistent-page ${page === "chat" ? "active" : "hidden"}`}>
          <ChatPage
            snapshot={snapshot}
            active={page === "chat"}
            onRefresh={refresh}
            onInspect={setInspectedFile}
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
        {page === "settings" && (
          <SettingsPage snapshot={snapshot} onRefresh={refresh} />
        )}
      </div>
      {inspectedFile && page !== "settings" && (
        <FileInspector
          file={
            snapshot.files.find((file) => file.id === inspectedFile.id) ??
            inspectedFile
          }
          language={snapshot.settings.appLanguage}
          onClose={() => setInspectedFile(null)}
        />
      )}
    </div>
  );
}
