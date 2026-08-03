import { createContext, useContext, useEffect, useMemo, useState } from "react";
import {
  Activity,
  Bot,
  Check,
  CircleAlert,
  Database,
  Download,
  FileCog,
  FolderOpen,
  FolderPlus,
  Gauge,
  HardDrive,
  ArrowLeft,
  Languages,
  ListChecks,
  LoaderCircle,
  Pause,
  Play,
  Plus,
  RotateCw,
  Save,
  Search,
  Settings2,
  ShieldCheck,
  Square,
  Sparkles,
  Trash2,
  WandSparkles,
  X,
} from "lucide-react";
import type { AiConnectivityCheck, AppLanguage, AppSnapshot, ReindexMode, Rule, Settings } from "../../shared/types";
import { formatBytes, IconButton } from "./components";
import { translate } from "./i18n";

type Section = "general" | "indexing" | "reindex" | "ai" | "skills" | "statistics" | "rules";
const SettingsLanguageContext = createContext<AppLanguage>("en");

export function SettingsPage({
  snapshot,
  onRefresh,
  onClose,
}: {
  snapshot: AppSnapshot;
  onRefresh(): Promise<void>;
  onClose?(): void;
}): React.JSX.Element {
  const [section, setSection] = useState<Section>("general");
  const [query, setQuery] = useState("");
  const t = (value: string): string =>
    translate(value, snapshot.settings.appLanguage);
  const items: Array<{ id: Section; label: string; detail: string; group: string; icon: React.JSX.Element }> =
    [
      { id: "general", label: "General", detail: "General settings and application behavior", group: "File Management", icon: <Settings2 size={17} /> },
      { id: "indexing", label: "Index & Organize", detail: "Control indexing, organization, and file processing", group: "File Management", icon: <FileCog size={17} /> },
      ...(snapshot.reindexJobSummary ? [{ id: "reindex" as const, label: "Reindex Task", detail: "Monitor the active reindex queue and control its progress", group: "File Management", icon: <RotateCw size={17} /> }] : []),
      { id: "ai", label: "AI Models", detail: "Configure chat, embedding, OCR, and local services", group: "Artificial Intelligence", icon: <Bot size={17} /> },
      { id: "skills", label: "AI Skills", detail: "Review and manage learned AI skills", group: "Artificial Intelligence", icon: <Sparkles size={17} /> },
      { id: "statistics", label: "Statistics", detail: "Review file, index, token, and storage activity", group: "Insights", icon: <Activity size={17} /> },
      { id: "rules", label: "Organization Rules", detail: "Create and manage file organization rules", group: "Insights", icon: <ListChecks size={17} /> },
    ];
  const visibleItems = useMemo(() => {
    const normalizedQuery = query.trim().toLowerCase();
    if (!normalizedQuery) return items;
    return items.filter((item) => [item.label, item.detail, item.group].some((value) => value.toLowerCase().includes(normalizedQuery)));
  }, [items, query]);
  const groups = [...new Set(visibleItems.map((item) => item.group))];
  const selectedItem = items.find((item) => item.id === section) ?? items[0];
  return (
    <SettingsLanguageContext.Provider value={snapshot.settings.appLanguage}>
    <main className="settings-page settings-workspace">
      <aside className="settings-sidebar">
        <div className="settings-sidebar-title">
          {onClose ? <button className="settings-back" aria-label={t("Back to FileNest")} onClick={onClose}><ArrowLeft size={16} />{t("Back to FileNest")}</button> : <><img src="./brand-mark.png" alt="" /><strong>FileNest {t("Settings")}</strong></>}
        </div>
        <label className="settings-search"><Search size={14} /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder={t("Search Settings")} />{query && <button type="button" aria-label={t("Clear Search")} onClick={() => setQuery("")}><X size={14} /></button>}</label>
        <nav className="settings-nav">
          {groups.map((group) => <div className="settings-nav-group" key={group}><small>{group}</small>{visibleItems.filter((item) => item.group === group).map((item) => (
            <button key={item.id} className={section === item.id ? "selected" : ""} onClick={() => setSection(item.id)}>{item.icon}{t(item.label)}</button>
          ))}</div>)}
          {!visibleItems.length && <p className="empty-state">No settings found.</p>}
        </nav>
      </aside>
      <section className="settings-detail">
        <header className="settings-detail-header">
          <span className="settings-detail-icon">{selectedItem.icon}</span>
          <div><h1>{t(selectedItem.label)}</h1><p>{t(selectedItem.detail)}</p></div>
          <span className="auto-save"><Check size={15} />{t("Changes save automatically")}</span>
        </header>
        <div className="settings-content">
          {section === "general" && (
            <GeneralSettings snapshot={snapshot} t={t} onRefresh={onRefresh} />
          )}
          {section === "indexing" && (
            <IndexSettings snapshot={snapshot} t={t} onRefresh={onRefresh} />
          )}
          {section === "reindex" && <ReindexActivity snapshot={snapshot} t={t} onRefresh={onRefresh} />}
          {section === "ai" && (
            <AiSettings snapshot={snapshot} t={t} onRefresh={onRefresh} />
          )}
          {section === "skills" && (
            <AgentSkillsSettings snapshot={snapshot} t={t} onRefresh={onRefresh} />
          )}
          {section === "statistics" && <Statistics snapshot={snapshot} t={t} />}
          {section === "rules" && (
            <RulesSettings snapshot={snapshot} t={t} onRefresh={onRefresh} />
          )}
        </div>
      </section>
    </main>
    </SettingsLanguageContext.Provider>
  );
}

function ReindexActivity({ snapshot, t, onRefresh }: ChildProps): React.JSX.Element {
  const summary = snapshot.reindexJobSummary;
  const [filter, setFilter] = useState<"all" | "queued" | "processing" | "completed" | "failed">("all");
  const [selectedFailedIds, setSelectedFailedIds] = useState<Set<number>>(new Set());
  useEffect(() => {
    setSelectedFailedIds(new Set(summary?.files.filter((file) => file.state === "failed").map((file) => file.fileId) ?? []));
  }, [summary?.id, summary?.failed]);
  if (!summary) return <div className="settings-sections"><SettingsSection title="Reindex Activity" subtitle="Durable indexing tasks and individual file recovery"><div className="reindex-empty"><Check size={30} /><strong>No Reindex Task</strong><span>There is no reindex task to monitor.</span></div></SettingsSection></div>;
  const files = summary.files.filter((file) => filter === "all" || file.state === filter);
  const processing = summary.files.filter((file) => file.state === "processing").length;
  const queued = summary.files.filter((file) => file.state === "queued").length;
  const settled = summary.completed + summary.failed;
  const progress = summary.total ? Math.min(1, settled / summary.total) : 0;
  const active = ["running", "paused", "stopping"].includes(summary.status);
  const statusTitle = summary.status === "running" ? "Reindexing" : summary.status === "paused" ? "Reindex Paused" : summary.status === "completed" ? "Reindex Complete" : summary.status === "completedWithErrors" ? "Reindex Completed with Errors" : summary.status === "interrupted" ? "Reindex Interrupted" : "Reindex Ready to Resume";
  const retryFailed = async (fileIds = [...selectedFailedIds]): Promise<void> => { await window.fileNest.retryReindexFiles(fileIds); await onRefresh(); };
  return <div className="settings-sections"><SettingsSection title="Reindex Activity" subtitle="The task remains visible across restarts and failed files can be retried individually">
    <section className="reindex-progress-card"><div className="reindex-progress-head"><div><span className={`reindex-status-icon ${summary.status}`}><RotateCw size={19} /></span><div><strong>{statusTitle}</strong><small>{summary.currentFileName || (active ? "Preparing the next file" : "The reindex task is retained locally")}</small></div></div><div className="button-row">{summary.status === "running" && <button className="secondary-button" onClick={() => void window.fileNest.pauseIndexing().then(onRefresh)}><Pause size={16} />Pause</button>}{summary.status === "paused" && <button className="primary-button" onClick={() => void window.fileNest.resumeIndexing().then(onRefresh)}><Play size={16} />Resume</button>}{active && <button className="secondary-button danger" onClick={() => void window.fileNest.cancelIndexing().then(onRefresh)}><Square size={16} />Stop</button>}{summary.failed > 0 && <button className="primary-button" disabled={!selectedFailedIds.size} onClick={() => void retryFailed()}><RotateCw size={16} />Retry Selected ({selectedFailedIds.size})</button>}</div></div><div className="reindex-progress-track"><span style={{ width: `${progress * 100}%` }} /></div><div className="reindex-progress-meta"><span>{settled} of {summary.total} files</span><span>{Math.round(progress * 100)}%</span></div>{summary.failed > 0 && <p className="reindex-warning">Select the failed files to retry from this queue.</p>}</section>
    <div className="reindex-summary"><button onClick={() => setFilter("queued")}><strong>{queued + processing}</strong><small>Pending</small></button><button onClick={() => setFilter("completed")}><strong>{summary.completed}</strong><small>Completed</small></button><button onClick={() => setFilter("failed")}><strong>{summary.failed}</strong><small>Failed</small></button><button onClick={() => setFilter("all")}><strong>{summary.total}</strong><small>Total</small></button></div>
    <div className="reindex-queue-header"><div><strong>Reindex Queue</strong><small>{files.length} visible file{files.length === 1 ? "" : "s"}</small></div><div className="reindex-filter">{(["all", "queued", "processing", "completed", "failed"] as const).map((item) => <button key={item} className={filter === item ? "selected" : ""} onClick={() => setFilter(item)}>{t(item === "all" ? "All" : item)}</button>)}</div></div>
    <div className="reindex-file-list">{files.length ? files.map((file) => <div key={file.fileId}>{file.state === "failed" ? <label className="reindex-select"><input type="checkbox" checked={selectedFailedIds.has(file.fileId)} onChange={(event) => setSelectedFailedIds((current) => { const next = new Set(current); event.target.checked ? next.add(file.fileId) : next.delete(file.fileId); return next; })} /><span /></label> : <span className="reindex-select-placeholder" />}<span className={`reindex-state ${file.state}`}>{file.state}</span><div><b>{file.name}</b><small>{file.error || file.ext}</small></div>{file.state === "failed" && <button className="secondary-button" onClick={() => void retryFailed([file.fileId])}>Retry</button>}</div>) : <p className="empty-state">No files in this view.</p>}</div>
  </SettingsSection></div>;
}

type ChildProps = {
  snapshot: AppSnapshot;
  t(value: string): string;
  onRefresh(): Promise<void>;
};

function AgentSkillsSettings({ snapshot, t, onRefresh }: ChildProps): React.JSX.Element {
  const [sourceTab, setSourceTab] = useState<"bundled" | "managed" | "sharedUser">("bundled");
  const run = async (action: () => Promise<unknown>): Promise<void> => {
    try { await action(); await onRefresh(); }
    catch (error) { alert(error instanceof Error ? error.message : String(error)); }
  };
  const groups = [
    { origin: "bundled", title: "Built-in", hint: "Always enabled product workflows" },
    { origin: "managed", title: "FileNest Learning", hint: "Imported or feedback-created packages" },
    { origin: "sharedUser", title: "Shared Skills", hint: "Packages found in your shared Agent Skills folder" },
  ] as const;
  const selectedGroup = groups.find((group) => group.origin === sourceTab)!;
  const selectedSkills = snapshot.agentSkills.filter((skill) => skill.origin === selectedGroup.origin);
  return <div className="settings-sections">
    <SettingsSection title="AI Skills" subtitle="Reusable local AI instructions are discovered progressively and cannot execute arbitrary scripts">
      <div className="button-row">
        <button className="secondary-button" onClick={() => void run(() => window.fileNest.openAgentSkillsFolder())}><FolderOpen size={16} />Open Skills Folder</button>
        <button className="secondary-button" onClick={() => void run(() => window.fileNest.importAgentSkill())}><Download size={16} />Import Skill…</button>
        <button className="secondary-button" onClick={() => void run(() => window.fileNest.refreshAgentSkills())}><RotateCw size={16} />Refresh Skills</button>
      </div>
      <div className="skill-source-tabs">{groups.map((group) => <button key={group.origin} className={sourceTab === group.origin ? "selected" : ""} onClick={() => setSourceTab(group.origin)}>{t(group.title)}</button>)}</div>
      <div className="skill-tab-detail"><div><strong>{t(selectedGroup.title)}</strong><small>{selectedGroup.hint}</small></div><span>{selectedSkills.length} skills</span></div>
      <div className="skill-group">
          {selectedSkills.length ? selectedSkills.map((skill) => <div className="skill-row" key={skill.skillFilePath}>
            <div><b>{skill.name}</b><small>{skill.description}</small></div>
            {skill.origin === "bundled" ? <span className="success-text">Always On</span> : <div className="skill-actions"><label className="switch"><input type="checkbox" checked={skill.enabled} onChange={(event) => void run(() => window.fileNest.setAgentSkillEnabled(skill.skillFilePath, event.target.checked))} /><span /></label>{skill.origin === "managed" && <IconButton label={`Delete ${skill.name}`} onClick={() => { if (confirm(`Delete ${skill.name}?`)) void run(() => window.fileNest.deleteAgentSkill(skill.skillFilePath)); }}><Trash2 size={15} /></IconButton>}</div>}
          </div>) : <p className="empty-state">No {selectedGroup.title.toLowerCase()} skills found.</p>}
      </div>
      {snapshot.agentSkillDiagnostics.length > 0 && <div className="connection-banner warning"><CircleAlert size={18} /><div>{snapshot.agentSkillDiagnostics.slice(0, 4).map((item) => <p key={`${item.path}:${item.message}`}>{item.message}</p>)}</div></div>}
      <div className="skill-feedback-history">
        <strong>Feedback Analysis</strong>
        <small>Saved result evaluations are queued locally for FileNest Learning. Analysis only changes FileNest-managed skills.</small>
        {snapshot.ragFeedbackRecords.length ? snapshot.ragFeedbackRecords.slice(0, 8).map((feedback) => <div className="feedback-history-row" key={feedback.id}><span className={`feedback-status ${feedback.analysisStatus}`}>{feedback.analysisStatus}</span><div><b>{feedback.rating === "accurate" ? "Accurate result" : "Needs improvement"}</b><small>{feedback.analysisError || feedback.analysisSummary || feedback.reason || "No explanation provided."}</small></div>{(feedback.analysisStatus === "pending" || feedback.analysisStatus === "failed") && <button className="secondary-button" onClick={() => void run(() => window.fileNest.analyzeRagFeedback(feedback.id))}>Analyze Again</button>}</div>) : <p className="empty-state">No answer or search feedback has been saved.</p>}
      </div>
    </SettingsSection>
  </div>;
}

function GeneralSettings({
  snapshot,
  t,
  onRefresh,
}: ChildProps): React.JSX.Element {
  const update = async (patch: Partial<Settings>): Promise<void> => {
    await window.fileNest.updateSettings(patch);
    await onRefresh();
  };
  const chooseOrganizedRoot = async (): Promise<void> => {
    const path = await window.fileNest.chooseOrganizedRoot();
    if (path) await update({ organizedRoot: path });
  };
  return (
    <div className="settings-sections">
      <SettingsSection
        title="Runtime Status"
        subtitle="Control background watching and its current state"
      >
        <SettingRow
          label={t("File Watching")}
          hint={snapshot.watching ? t("Watching") : t("Paused")}
        >
          <label className="switch">
            <input
              type="checkbox"
              checked={snapshot.watching}
              onChange={() =>
                void (
                  snapshot.watching
                    ? window.fileNest.stopWatching()
                    : window.fileNest.startWatching()
                ).then(onRefresh)
              }
            />
            <span />
          </label>
        </SettingRow>
        <SettingRow label={t("Current Status")} hint={snapshot.watching ? t("FileNest is monitoring watched folders") : t("Start watching to monitor watched folders")}>
          <span className={snapshot.watching ? "success-text" : "warning-text"}>{snapshot.watching ? t("Watching") : t("Paused")}</span>
        </SettingRow>
      </SettingsSection>
      <SettingsSection title="Interface" subtitle="Language and appearance changes apply immediately">
        <SettingRow label={t("Language")}>
          <select
            value={snapshot.settings.appLanguage}
            onChange={(event) =>
              void update({
                appLanguage: event.target.value as Settings["appLanguage"],
              })
            }
          >
            <option value="system">{t("System")}</option>
            <option value="zh-Hans">Simplified Chinese</option>
            <option value="en">English</option>
          </select>
        </SettingRow>
        <SettingRow label={t("Appearance")}>
          <select
            value={snapshot.settings.appearance}
            onChange={(event) =>
              void update({
                appearance: event.target.value as Settings["appearance"],
              })
            }
          >
            <option value="system">{t("System")}</option>
            <option value="light">{t("Light")}</option>
            <option value="dark">{t("Dark")}</option>
          </select>
        </SettingRow>
        <SettingRow
          label={t("Setup Assistant")}
          hint={t("Review watched folders and AI choices again")}
        >
          <button
            className="secondary-button"
            onClick={() => void update({ onboardingCompleted: false })}
          >
            <WandSparkles size={16} />
            {t("Open Setup Assistant Again")}
          </button>
        </SettingRow>
      </SettingsSection>
      <SettingsSection title={t("Startup")} subtitle={t("Open FileNest automatically after you sign in to Windows.")}>
        <SettingRow label={t("Launch at Sign-in")}>
          <label className="switch">
            <input type="checkbox" checked={snapshot.settings.launchAtLogin} onChange={(event) => void update({ launchAtLogin: event.target.checked })} />
            <span />
          </label>
        </SettingRow>
      </SettingsSection>
      <SettingsSection title={t("Quick Search")} subtitle={t("Use this shortcut from any app to open a centered FileNest search box.")}>
        <SettingRow label={t("Quick Search Shortcut")} hint={snapshot.quickSearchShortcutError ?? undefined}>
          <div className="shortcut-controls">
            <ShortcutRecorder value={snapshot.settings.quickSearchShortcut} onChange={(value) => update({ quickSearchShortcut: value })} />
            <button className="secondary-button" onClick={() => void update({ quickSearchShortcut: "CommandOrControl+Alt+Space" })}>{t("Reset to Default")}</button>
          </div>
        </SettingRow>
      </SettingsSection>
      <SettingsSection title={t("Automatic Organization")} subtitle={t("New files are indexed before they are organized.")}>
        <SettingRow label={t("Automatically classify and move new files")} hint={t("When disabled, files remain in place after indexing")}>
          <label className="switch"><input type="checkbox" checked={snapshot.settings.autoOrganize} onChange={(event) => void update({ autoOrganize: event.target.checked })} /><span /></label>
        </SettingRow>
        {snapshot.settings.autoOrganize && <>
          <SettingRow label={t("Trigger")}>
            <select value={snapshot.settings.autoOrganizeMode} onChange={(event) => void update({ autoOrganizeMode: event.target.value as Settings["autoOrganizeMode"] })}>
              <option value="immediate">{t("Organize immediately after indexing")}</option>
              <option value="batched">{t("Organize on timer or file threshold")}</option>
            </select>
          </SettingRow>
          {snapshot.settings.autoOrganizeMode === "batched" && <>
            <SettingRow label={t("Maximum wait")}><NumberField value={snapshot.settings.autoOrganizeIntervalSeconds} onCommit={(value) => update({ autoOrganizeIntervalSeconds: value })} /></SettingRow>
            <SettingRow label={t("File threshold")}><NumberField value={snapshot.settings.autoOrganizeBatchSize} onCommit={(value) => update({ autoOrganizeBatchSize: value })} /></SettingRow>
          </>}
        </>}
        <SettingRow label={t("Skip hidden files")}>
          <label className="switch"><input type="checkbox" checked={snapshot.settings.excludeHidden} onChange={(event) => void update({ excludeHidden: event.target.checked })} /><span /></label>
        </SettingRow>
        <SettingRow label={t("Classification Strategy")} hint={snapshot.settings.classifyStrategy === "rule" ? t("Only matching enabled rules organize files") : t("Matching rules take priority; unmatched files use type and AI topic")}>
          <select value={snapshot.settings.classifyStrategy} onChange={(event) => void update({ classifyStrategy: event.target.value as Settings["classifyStrategy"] })}>
            <option value="hybrid">{t("Rules first, with automatic fallback")}</option>
            <option value="rule">{t("Organization rules only")}</option>
          </select>
        </SettingRow>
      </SettingsSection>
      <SettingsSection title={t("Organization Location")}>
        <SettingRow label={t("Destination Folder")} hint={snapshot.settings.organizedRoot}>
          <button className="secondary-button" onClick={() => void chooseOrganizedRoot()}><FolderPlus size={16} />{t("Change Location")}</button>
        </SettingRow>
      </SettingsSection>
      <SettingsSection title="Version and Diagnostics">
        <SettingRow label="HTTPS Update URL" hint="Points to the release folder containing latest.yml">
          <input
            className="wide-input"
            type="url"
            placeholder="https://updates.example.com/filenest/windows/"
            value={snapshot.settings.updateFeedUrl}
            onChange={(event) =>
              void update({ updateFeedUrl: event.target.value })
            }
          />
        </SettingRow>
        <SettingRow label="Automatically check for updates">
          <label className="switch">
            <input
              type="checkbox"
              checked={snapshot.settings.automaticUpdateChecks}
              onChange={(event) =>
                void update({ automaticUpdateChecks: event.target.checked })
              }
            />
            <span />
          </label>
        </SettingRow>
        <SettingRow label="Automatically Download Updates" hint="Install completed downloads on exit">
          <label className="switch">
            <input
              type="checkbox"
              checked={snapshot.settings.automaticallyDownloadsUpdates}
              onChange={(event) =>
                void update({ automaticallyDownloadsUpdates: event.target.checked })
              }
            />
            <span />
          </label>
        </SettingRow>
        <div className="button-row">
          <button
            className="secondary-button"
            onClick={() => void window.fileNest.checkForUpdates().then(alert)}
          >
            <RotateCw size={16} />
            {t("Check for Updates")}
          </button>
          <button
            className="secondary-button"
            onClick={() => void window.fileNest.exportLogs()}
          >
            <Download size={16} />
            {t("Export Logs")}
          </button>
          <button
            className="secondary-button danger"
            onClick={() => void window.fileNest.clearLogs()}
          >
            <Trash2 size={16} />
            {t("Clear Logs")}
          </button>
        </div>
      </SettingsSection>
    </div>
  );
}

function ShortcutRecorder({ value, onChange }: { value: string; onChange(value: string): Promise<void> }): React.JSX.Element {
  const [recording, setRecording] = useState(false);
  return (
    <button
      className={`shortcut-recorder ${recording ? "recording" : ""}`}
      onClick={() => setRecording(true)}
      onBlur={() => setRecording(false)}
      onKeyDown={(event) => {
        if (!recording) return;
        event.preventDefault();
        if (event.key === "Escape") { setRecording(false); return; }
        const shortcut = acceleratorFromEvent(event);
        if (!shortcut) return;
        setRecording(false);
        void onChange(shortcut);
      }}
    >
      {recording ? "Press a shortcut…" : value.replace("CommandOrControl", "Ctrl")}
    </button>
  );
}

function acceleratorFromEvent(event: React.KeyboardEvent): string | null {
  if (!event.ctrlKey && !event.altKey && !event.metaKey) return null;
  const ignored = new Set(["Control", "Alt", "Shift", "Meta"]);
  if (ignored.has(event.key)) return null;
  const key = event.key === " " ? "Space" : event.key.length === 1 ? event.key.toUpperCase() : event.key;
  return [event.ctrlKey || event.metaKey ? "CommandOrControl" : null, event.altKey ? "Alt" : null, event.shiftKey ? "Shift" : null, key].filter(Boolean).join("+");
}

function IndexSettings({
  snapshot,
  t,
  onRefresh,
}: ChildProps): React.JSX.Element {
  const s = snapshot.settings;
  const [reindexMode, setReindexMode] = useState<ReindexMode>("all");
  const [mediaBusy, setMediaBusy] = useState(false);
  const [customExtensionDraft, setCustomExtensionDraft] = useState("");
  const [manualWatchDir, setManualWatchDir] = useState("");
  const update = async (patch: Partial<Settings>): Promise<void> => {
    await window.fileNest.updateSettings(patch);
    await onRefresh();
  };
  const addFolders = async (): Promise<void> => {
    const dirs = await window.fileNest.chooseWatchDirectories();
    const added = dirs.filter((path) => !s.watchDirs.includes(path));
    if (!added.length) return;
    await update({ watchDirs: [...s.watchDirs, ...added] });
    const processExisting = confirm(t("Process files already in the newly added folders now? Choose Cancel to preserve them and watch only future changes."));
    if (processExisting) await window.fileNest.scanExisting(added);
    else await window.fileNest.preserveExisting(added);
    await onRefresh();
  };
  const addManualFolder = async (): Promise<void> => {
    const path = manualWatchDir.trim();
    if (!path || s.watchDirs.includes(path)) return;
    await update({ watchDirs: [...s.watchDirs, path] });
    setManualWatchDir("");
  };
  const runMediaAction = async (action: () => Promise<void>): Promise<void> => {
    setMediaBusy(true);
    try {
      await action();
      await onRefresh();
    } catch (error) {
      alert(error instanceof Error ? error.message : String(error));
    } finally {
      setMediaBusy(false);
    }
  };
  const addCustomExtension = async (): Promise<void> => {
    const extension = customExtensionDraft.replace(/^\.+/, "").trim().toLowerCase();
    if (!/^[a-z0-9][a-z0-9+_-]{0,31}$/.test(extension)) {
      alert("Enter a file extension using letters, numbers, +, _, or -.");
      return;
    }
    await update({
      customFileExtensions: [...new Set([...s.customFileExtensions, extension])],
      enabledExtensions: [...new Set([...s.enabledExtensions, extension])],
    });
    setCustomExtensionDraft("");
  };
  return (
    <div className="settings-sections">
      <SettingsSection title={t("Watched Folders")} subtitle={t("FileNest waits for file writes to stabilize before indexing")}>
        <div className="directory-list">
          {s.watchDirs.length === 0 && <p className="empty-state">{t("No watched folders added")}</p>}
          {s.watchDirs.map((path) => {
            const status = snapshot.watchDirectoryStatuses.find((item) => item.path === path);
            return <div key={path}>
              <HardDrive size={17} className={status?.state === "watching" ? "success-text" : "warning-text"} />
              <span>{path}<small>{status?.detail}</small></span>
              <IconButton label={t("Remove watched folder")} onClick={() => void update({ watchDirs: s.watchDirs.filter((item) => item !== path) })}><Trash2 size={15} /></IconButton>
            </div>;
          })}
          <div className="directory-actions"><button className="secondary-button" onClick={() => void addFolders()}><FolderPlus size={16} />{t("Add Watched Folder…")}</button><button className="secondary-button" disabled={!s.watchDirs.length} onClick={() => void window.fileNest.organizeExisting().then(onRefresh)}><WandSparkles size={16} />{t("Organize Existing Files in Watched Folders…")}</button></div>
          <details className="settings-disclosure"><summary>{t("Enter Path Manually")}</summary><div className="inline-field"><input value={manualWatchDir} placeholder={t("C:\\Users\\name\\Folder")} onChange={(event) => setManualWatchDir(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") void addManualFolder(); }} /><button className="secondary-button" disabled={!manualWatchDir.trim()} onClick={() => void addManualFolder()}>{t("Add")}</button></div></details>
        </div>
      </SettingsSection>
      <SettingsSection title={t("Watched File Types")} subtitle={t("Choose the file types FileNest monitors in watched folders")}>
        <SettingRow label={t("File types to watch")} hint={t("The watcher processes only these file types")}>
          <input
            className="wide-input"
            defaultValue={s.enabledExtensions.join(", ")}
            onBlur={(e) =>
              void update({ enabledExtensions: e.target.value.split(",") })
            }
          />
        </SettingRow>
        <SettingRow label={t("Custom File Type")} hint={t("Add a type to the watcher; enable it for vector indexing separately if needed")}>
          <div className="inline-field">
            <input value={customExtensionDraft} placeholder="e.g. log" onChange={(event) => setCustomExtensionDraft(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") void addCustomExtension(); }} />
            <button className="secondary-button" onClick={() => void addCustomExtension()}>Add</button>
          </div>
        </SettingRow>
        {s.customFileExtensions.length > 0 && <SettingRow label="Custom Types">
          <div className="extension-chips">
            {s.customFileExtensions.map((extension) => <button key={extension} className="extension-chip" onClick={() => void update({ customFileExtensions: s.customFileExtensions.filter((item) => item !== extension), enabledExtensions: s.enabledExtensions.filter((item) => item !== extension), vectorizeExtensions: s.vectorizeExtensions.filter((item) => item !== extension) })}>.{extension} ×</button>)}
          </div>
        </SettingRow>}
      </SettingsSection>
      <SettingsSection title={t("Automatic Vectorization")} subtitle={t("Reindexing is recommended after configuration changes")}>
        <SettingRow label={t("Automatic Vectorization")}>
          <label className="switch">
            <input
              type="checkbox"
              checked={s.autoVectorize}
              onChange={(e) => void update({ autoVectorize: e.target.checked })}
            />
            <span />
          </label>
        </SettingRow>
        <SettingRow label={t("ModelSource")}>
          <select
            value={s.embeddingSource}
            onChange={(e) =>
              void update({
                embeddingSource: e.target.value as Settings["embeddingSource"],
              })
            }
          >
            <option value="local">{t("Local Lightweight Index")}</option>
            <option value="ollama">Ollama Embedding</option>
            <option value="cloud">OpenAI Compatible</option>
          </select>
        </SettingRow>
        {s.embeddingSource === "cloud" && (
          <>
            <SettingRow label="Embedding Base URL">
              <input
                className="wide-input"
                value={s.cloudEmbeddingBaseUrl}
                onChange={(e) =>
                  void update({ cloudEmbeddingBaseUrl: e.target.value })
                }
              />
            </SettingRow>
            <SettingRow label="Embedding API Key">
              <input
                className="wide-input"
                type="password"
                value={s.cloudEmbeddingApiKey}
                onChange={(e) =>
                  void update({ cloudEmbeddingApiKey: e.target.value })
                }
              />
            </SettingRow>
            <SettingRow label="Embedding Model">
              <input
                value={s.cloudEmbeddingModel}
                onChange={(e) =>
                  void update({ cloudEmbeddingModel: e.target.value })
                }
              />
            </SettingRow>
            <SettingRow label="Reuse Chat API Credentials">
              <label className="switch">
                <input
                  type="checkbox"
                  checked={s.cloudEmbeddingReuseChatCredentials}
                  onChange={(e) =>
                    void update({
                      cloudEmbeddingReuseChatCredentials: e.target.checked,
                    })
                  }
                />
                <span />
              </label>
            </SettingRow>
          </>
        )}
        <SettingRow label="Parent chunk maximum" hint="Complete answer-time section target, from 600 to 1,000 tokens">
          <NumberField
            value={s.vectorChunkWords}
            onCommit={(value) => update({ vectorChunkWords: value })}
          />
        </SettingRow>
        <SettingRow label="Retrieval chunk target" hint="Smaller searchable children, from 120 tokens up to the parent maximum">
          <NumberField
            value={s.vectorRetrievalChunkTokens}
            onCommit={(value) => update({ vectorRetrievalChunkTokens: value })}
          />
        </SettingRow>
        <SettingRow label="Semantic overlap" hint="Maximum complete-unit overlap between retrieval children">
          <NumberField
            value={s.vectorChunkOverlap}
            onCommit={(value) => update({ vectorChunkOverlap: value })}
          />
        </SettingRow>
        <SettingRow label="Chat Retrieval Results" hint="Maximum related files supplied to chat, from 1 to 30">
          <NumberField value={s.ragResultLimit} onCommit={(value) => update({ ragResultLimit: value })} />
        </SettingRow>
        <SettingRow label="Extensions Included in Indexing">
          <input
            className="wide-input"
            defaultValue={s.vectorizeExtensions.join(", ")}
            onBlur={(e) =>
              void update({ vectorizeExtensions: e.target.value.split(",") })
            }
          />
        </SettingRow>
        <div className="button-row">
          <select aria-label={t("Reindex scope")} value={reindexMode} onChange={(event) => setReindexMode(event.target.value as ReindexMode)}>
            <option value="unindexed">{t("Index new files only")}</option>
            <option value="embeddings">{t("Rebuild embeddings from stored chunks")}</option>
            <option value="all">{t("Reparse files and rebuild all indexes")}</option>
          </select>
          <button
            className="primary-button"
            disabled={snapshot.indexing}
            onClick={() => void window.fileNest.reindexAll(reindexMode).then(onRefresh)}
          >
            <RotateCw className={snapshot.indexing ? "spin" : ""} size={16} />
            {t("Reindex")}
          </button>
          {snapshot.indexing && (
            <>
              <button
                className="secondary-button"
                onClick={() =>
                  void (snapshot.indexingPaused
                    ? window.fileNest.resumeIndexing()
                    : window.fileNest.pauseIndexing()
                  ).then(onRefresh)
                }
              >
                {snapshot.indexingPaused ? <Play size={16} /> : <Pause size={16} />}
                {snapshot.indexingPaused ? "Resume" : "Pause"}
              </button>
              <button
                className="secondary-button danger"
                onClick={() => void window.fileNest.cancelIndexing().then(onRefresh)}
              >
                {t("Stop")}
              </button>
            </>
          )}
        </div>
      </SettingsSection>
      <SettingsSection title="Document Processing">
        <div
          className={`connection-banner ${snapshot.docling.installed ? "ok" : "warning"}`}
        >
          {snapshot.docling.installed ? (
            <ShieldCheck size={18} />
          ) : (
            <CircleAlert size={18} />
          )}
          <strong>{snapshot.docling.message}</strong>
          {!snapshot.docling.installed && (
            <button
              className="secondary-button"
              disabled={snapshot.docling.installing}
              onClick={() =>
                void window.fileNest.installDocling().then(onRefresh).catch((error) =>
                  alert(error instanceof Error ? error.message : String(error)),
                )
              }
            >
              {snapshot.docling.installing ? (
                <LoaderCircle className="spin" size={16} />
              ) : (
                <Download size={16} />
              )}
              Install Docling
            </button>
          )}
        </div>
        <SettingRow label="Docling" hint="Optional advanced structured parsing for PDF and Office files">
          <label className="switch">
            <input
              type="checkbox"
              checked={s.doclingEnabled}
              onChange={(e) =>
                void update({ doclingEnabled: e.target.checked })
              }
            />
            <span />
          </label>
        </SettingRow>
        <SettingRow label="Docling Service Endpoints">
          <input
            className="wide-input"
            value={s.doclingEndpoint}
            onChange={(e) => void update({ doclingEndpoint: e.target.value })}
          />
        </SettingRow>
        <SettingRow label="OCR">
          <select
            value={s.ocrSource}
            onChange={(e) =>
              void update({
                ocrSource: e.target.value as Settings["ocrSource"],
              })
            }
          >
            <option value="local">Local Tesseract OCR</option>
            <option value="ollama">Ollama Vision</option>
            <option value="cloud">Cloud Vision Model</option>
            <option value="disabled">Disabled</option>
          </select>
        </SettingRow>
        {s.ocrSource === "cloud" && (
          <>
            <SettingRow label="OCR API Format">
              <select
                value={s.cloudOcrFormat}
                onChange={(e) =>
                  void update({
                    cloudOcrFormat: e.target.value as Settings["cloudOcrFormat"],
                  })
                }
              >
                <option value="openai">OpenAI Compatible</option>
                <option value="anthropic">Anthropic</option>
              </select>
            </SettingRow>
            <SettingRow label="OCR Base URL">
              <input
                className="wide-input"
                value={s.cloudOcrBaseUrl}
                onChange={(e) => void update({ cloudOcrBaseUrl: e.target.value })}
              />
            </SettingRow>
            <SettingRow label="OCR API Key">
              <input
                className="wide-input"
                type="password"
                value={s.cloudOcrApiKey}
                onChange={(e) => void update({ cloudOcrApiKey: e.target.value })}
              />
            </SettingRow>
            <SettingRow label="OCR Model">
              <input
                value={s.cloudOcrModel}
                onChange={(e) => void update({ cloudOcrModel: e.target.value })}
              />
            </SettingRow>
            <SettingRow label="Reuse Chat API Credentials">
              <label className="switch">
                <input
                  type="checkbox"
                  checked={s.cloudOcrReuseChatCredentials}
                  onChange={(e) =>
                    void update({ cloudOcrReuseChatCredentials: e.target.checked })
                  }
                />
                <span />
              </label>
            </SettingRow>
          </>
        )}
      </SettingsSection>
      <SettingsSection title="Audio & Video Transcription" subtitle="FFmpeg decoding and OpenAI Whisper transcription run locally on this PC">
        <SettingRow label="Transcribe audio and video for search and chat" hint="Creates time-coded transcript chunks and sends only the resulting text through the configured embedding pipeline">
          <label className="switch">
            <input type="checkbox" checked={s.mediaTranscriptionEnabled} onChange={(event) => void update({ mediaTranscriptionEnabled: event.target.checked })} />
            <span />
          </label>
        </SettingRow>
        <SettingRow label="FFmpeg" hint="Required to decode audio tracks before local transcription">
          <div className="button-row">
            <span className={snapshot.ffmpeg.state === "ready" ? "success-text" : snapshot.ffmpeg.state === "failed" ? "warning-text" : ""}>{t(snapshot.ffmpeg.message)}</span>
            {snapshot.ffmpeg.state !== "ready" && <button className="secondary-button" disabled={mediaBusy || snapshot.ffmpeg.installing} onClick={() => void runMediaAction(() => window.fileNest.installFfmpeg())}><Download size={16} />{t("Install FFmpeg")}</button>}
          </div>
        </SettingRow>
        <SettingRow label="Whisper Runtime" hint="Installed in an isolated FileNest Python environment">
          <div className="button-row">
            <span className={snapshot.whisper.state === "ready" ? "success-text" : snapshot.whisper.state === "failed" ? "warning-text" : ""}>{t(snapshot.whisper.message)}</span>
            {snapshot.whisper.version == null && <button className="secondary-button" disabled={mediaBusy || snapshot.whisper.installing} onClick={() => void runMediaAction(() => window.fileNest.installWhisper())}><Download size={16} />{t("Install Whisper")}</button>}
          </div>
        </SettingRow>
        {(snapshot.ffmpeg.installing || snapshot.whisper.installing) && <progress value={snapshot.ffmpeg.progress ?? snapshot.whisper.progress ?? undefined} max={1} />}
        {(snapshot.ffmpeg.error || snapshot.whisper.error) && <p className="settings-note warning-text">{snapshot.ffmpeg.error ?? snapshot.whisper.error}</p>}
        <SettingRow label="Whisper Model">
          <select value={s.whisperModel} onChange={(event) => void update({ whisperModel: event.target.value })}>
            {[
              ["tiny", "Fastest; suitable for clear speech"],
              ["base", "Recommended multilingual default"],
              ["small", "Higher accuracy on 16 GB or more"],
              ["medium", "High accuracy; slower locally"],
              ["turbo", "Fast large-model transcription"],
            ].map(([model, detail]) => <option key={model} value={model}>{model} · {t(detail)}</option>)}
          </select>
        </SettingRow>
        <div className="button-row">
          {snapshot.whisper.installedModels.includes(s.whisperModel)
            ? <button className="secondary-button danger" disabled={mediaBusy} onClick={() => { if (confirm(t("Delete Whisper Model?"))) void runMediaAction(() => window.fileNest.deleteWhisperModel(s.whisperModel)); }}><Trash2 size={15} />{t("Delete")}</button>
            : <button className="primary-button" disabled={mediaBusy || snapshot.whisper.version == null} onClick={() => void runMediaAction(() => window.fileNest.downloadWhisperModel(s.whisperModel))}><Download size={16} />{t("Download Model")}</button>}
          <button className="secondary-button" disabled={snapshot.indexing || !s.mediaTranscriptionEnabled} onClick={() => void window.fileNest.reindexAll("media").then(onRefresh)}><RotateCw size={16} />{t("Reindex Audio & Video")}</button>
        </div>
        <p className="settings-note">{t("Media decoding and transcription run locally. Only the resulting text chunks follow your configured Embedding provider.")}</p>
      </SettingsSection>
    </div>
  );
}

function AiSettings({ snapshot, t, onRefresh }: ChildProps): React.JSX.Element {
  const s = snapshot.settings;
  const [pullModel, setPullModel] = useState("qwen3.5:9b");
  const [busy, setBusy] = useState(false);
  const [connectionResults, setConnectionResults] = useState<AiConnectivityCheck[]>([]);
  const update = async (patch: Partial<Settings>): Promise<void> => {
    await window.fileNest.updateSettings(patch);
    await onRefresh();
  };
  const run = async (action: () => Promise<unknown>): Promise<void> => {
    setBusy(true);
    try {
      await action();
      await onRefresh();
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="settings-sections">
      <SettingsSection
        title="Chat Model"
        subtitle="Local Ollama, OpenAI/DeepSeek-compatible APIs, or retrieval only"
      >
        <SettingRow label={t("ModelSource")}>
          <div className="segmented-control" role="group" aria-label={t("ModelSource")}>
            {(["ollama", "cloud", "none"] as const).map((choice) => <button key={choice} className={s.llmChoice === choice ? "selected" : ""} onClick={() => void update({ llmChoice: choice })}>{t(choice === "ollama" ? "Local Ollama" : choice === "cloud" ? "Cloud API" : "Search Only")}</button>)}
          </div>
        </SettingRow>
        <SettingRow label="Deep Thinking">
          <label className="switch">
            <input
              type="checkbox"
              checked={s.thinkingMode}
              onChange={(e) => void update({ thinkingMode: e.target.checked })}
            />
            <span />
          </label>
        </SettingRow>
        <div className="button-row">
          <button className="secondary-button" disabled={busy} onClick={() => void run(async () => setConnectionResults(await window.fileNest.testAiConnections()))}>
            {busy ? <LoaderCircle className="spin" size={16} /> : <Activity size={16} />}
            Test Chat, Embedding, and OCR
          </button>
        </div>
        {connectionResults.length > 0 && <div className="connection-results">{connectionResults.map((result) => <div key={result.capability} className={result.success ? "success-text" : "warning-text"}>{result.success ? "✓" : "!"} {result.capability}: {result.provider} · {result.detail}</div>)}</div>}
      </SettingsSection>
      {s.llmChoice === "ollama" && (
        <SettingsSection title="Ollama" subtitle="Models and files stay on this computer">
          <div
            className={`connection-banner ${snapshot.ollama.reachable ? "ok" : "warning"}`}
          >
            {snapshot.ollama.reachable ? (
              <ShieldCheck size={18} />
            ) : (
              <CircleAlert size={18} />
            )}
            <strong>
              {snapshot.ollama.reachable ? t("Connected") : t("Not Connected")}
            </strong>
            <span>{s.ollamaHost}</span>
          </div>
          <SettingRow label="Service Endpoints">
            <input
              className="wide-input"
              defaultValue={s.ollamaHost}
              onBlur={(e) => void update({ ollamaHost: e.target.value })}
            />
          </SettingRow>
          <SettingRow label="Chat Model">
            <select
              value={s.ollamaModel}
              onChange={(e) => void update({ ollamaModel: e.target.value })}
            >
              {[...new Set([s.ollamaModel, ...snapshot.ollama.models])].map(
                (model) => (
                  <option key={model}>{model}</option>
                ),
              )}
            </select>
          </SettingRow>
          <SettingRow label="Flash Attention" hint="Used when supported by the installed Ollama runtime">
            <label className="switch"><input type="checkbox" checked={s.ollamaFlashAttentionEnabled} onChange={(e) => void update({ ollamaFlashAttentionEnabled: e.target.checked })} /><span /></label>
          </SettingRow>
          <SettingRow label="Embedding Model">
            <input
              value={s.ollamaEmbeddingModel}
              onChange={(e) =>
                void update({ ollamaEmbeddingModel: e.target.value })
              }
            />
          </SettingRow>
          <SettingRow label="OCR Model">
            <input
              value={s.ollamaOcrModel}
              onChange={(e) => void update({ ollamaOcrModel: e.target.value })}
            />
          </SettingRow>
          <div className="model-pull">
            <input
              value={pullModel}
              onChange={(e) => setPullModel(e.target.value)}
            />
            <button
              className="primary-button"
              disabled={busy}
              onClick={() =>
                void run(() => window.fileNest.pullOllamaModel(pullModel))
              }
            >
              {busy ? (
                <LoaderCircle className="spin" size={16} />
              ) : (
                <Download size={16} />
              )}
              {t("Download Model")}
            </button>
          </div>
          {snapshot.ollama.models.length > 0 && (
            <div className="ollama-model-list">
              {snapshot.ollama.models.map((model) => (
                <div key={model}>
                  <span>{model}</span>
                  <IconButton
                    label={`Delete ${model}`}
                    disabled={busy}
                    onClick={() => {
                      if (confirm(`Delete model ${model}?`))
                        void run(() => window.fileNest.deleteOllamaModel(model));
                    }}
                  >
                    <Trash2 size={15} />
                  </IconButton>
                </div>
              ))}
            </div>
          )}
          <div className="button-row">
            <button
              className="secondary-button"
              onClick={() => void run(() => window.fileNest.refreshOllama())}
            >
              {t("Check Connection")}
            </button>
            {!snapshot.ollama.reachable && (
              <button
                className="secondary-button"
                disabled={busy}
                onClick={() => void run(() => window.fileNest.installOllama())}
              >
                {busy && <LoaderCircle className="spin" size={16} />}
                {t("Install Ollama")}
              </button>
            )}
          </div>
        </SettingsSection>
      )}
      {s.llmChoice === "cloud" && (
        <SettingsSection title="Cloud API" subtitle="Supports OpenAI and compatible endpoints">
          <SettingRow label="API Format">
            <select
              value={s.cloudApiFormat}
              onChange={(e) =>
                void update({
                  cloudApiFormat: e.target.value as Settings["cloudApiFormat"],
                })
              }
            >
              <option value="openai">OpenAI Compatible</option>
              <option value="anthropic">Anthropic</option>
            </select>
          </SettingRow>
          <SettingRow label="Base URL">
            <input
              className="wide-input"
              value={s.cloudBaseUrl}
              onChange={(e) => void update({ cloudBaseUrl: e.target.value })}
            />
          </SettingRow>
          <SettingRow label="API Key">
            <input
              className="wide-input"
              type="password"
              value={s.cloudApiKey}
              onChange={(e) => void update({ cloudApiKey: e.target.value })}
            />
          </SettingRow>
          <SettingRow label="Model">
            <input
              value={s.cloudModel}
              onChange={(e) => void update({ cloudModel: e.target.value })}
            />
          </SettingRow>
          <SettingRow label="Context Window" hint="Use 0 for automatic model defaults">
            <NumberField value={s.cloudContextWindowTokens} onCommit={(value) => update({ cloudContextWindowTokens: value })} />
          </SettingRow>
        </SettingsSection>
      )}
      <SettingsSection title="Retrieval Reranker" subtitle="Optional query-time reranking; fused local retrieval remains available if the service fails">
        <SettingRow label="Source">
          <select value={s.rerankerSource} onChange={(event) => void update({ rerankerSource: event.target.value as Settings["rerankerSource"] })}>
            <option value="disabled">{t("Disabled")}</option>
            <option value="local">{t("Managed Local Qwen")}</option>
            <option value="cloud">{t("Cloud API")}</option>
          </select>
        </SettingRow>
        {s.rerankerSource !== "disabled" && (
          <>
            {s.rerankerSource === "cloud" && (
              <SettingRow label="Reuse Chat API Credentials">
                <label className="switch"><input type="checkbox" checked={s.rerankerReuseChatCredentials} onChange={(event) => void update({ rerankerReuseChatCredentials: event.target.checked })} /><span /></label>
              </SettingRow>
            )}
            {(s.rerankerSource === "local" || !s.rerankerReuseChatCredentials) && (
              <>
                <SettingRow label="Reranker Base URL" hint={s.rerankerSource === "local" ? "Default managed-compatible endpoint: 127.0.0.1:11435" : undefined}>
                  <input className="wide-input" value={s.rerankerBaseUrl} onChange={(event) => void update({ rerankerBaseUrl: event.target.value })} />
                </SettingRow>
                {s.rerankerSource === "cloud" && <SettingRow label="Reranker API Key"><input className="wide-input" type="password" value={s.rerankerApiKey} onChange={(event) => void update({ rerankerApiKey: event.target.value })} /></SettingRow>}
              </>
            )}
            {s.rerankerSource === "local" && (
              <>
                <SettingRow label="Local Status" hint={`Qwen3-Reranker-0.6B · ${snapshot.reranker.modelDiskBytes ? `${(snapshot.reranker.modelDiskBytes / 1_000_000_000).toFixed(2)} GB` : "about 1.25 GB download"}`}>
                  <span className={snapshot.reranker.state === "running" ? "success-text" : snapshot.reranker.state === "failed" ? "warning-text" : ""}>{t(snapshot.reranker.message)}</span>
                </SettingRow>
                {snapshot.reranker.installing && <progress value={snapshot.reranker.progress ?? undefined} max={1} />}
                {snapshot.reranker.error && <p className="settings-note warning-text">{snapshot.reranker.error}</p>}
                <div className="button-row">
                  {snapshot.reranker.state === "unavailable" || snapshot.reranker.state === "failed" && snapshot.reranker.modelDiskBytes === 0
                    ? <button className="primary-button" disabled={snapshot.reranker.installing} onClick={() => void run(() => window.fileNest.installReranker())}><Download size={16} />{t("Download Reranker")}</button>
                    : snapshot.reranker.state === "running"
                      ? <button className="secondary-button" onClick={() => void run(() => window.fileNest.stopReranker())}>{t("Stop Service")}</button>
                      : <button className="secondary-button" onClick={() => void run(() => window.fileNest.startReranker())}>{t("Start Service")}</button>}
                  {snapshot.reranker.modelDiskBytes > 0 && <button className="secondary-button danger" onClick={() => { if (confirm(t("Delete the local reranker model?"))) void run(() => window.fileNest.deleteReranker()) }}><Trash2 size={15} />{t("Delete")}</button>}
                </div>
              </>
            )}
            <SettingRow label="Reranker Model">
              <input className="wide-input" value={s.rerankerModel} onChange={(event) => void update({ rerankerModel: event.target.value })} />
            </SettingRow>
            <p className="settings-note">{t("The service must implement the OpenAI/Jina-compatible rerank contract. Only the strongest retrieval candidates are sent.")}</p>
          </>
        )}
      </SettingsSection>
    </div>
  );
}

function Statistics({
  snapshot,
  t,
}: Omit<ChildProps, "onRefresh">): React.JSX.Element {
  const s = snapshot.statistics;
  const max = Math.max(
    1,
    ...s.dailyActivity.map((day) => day.addedFiles + day.indexedFiles),
  );
  return (
    <div className="settings-sections">
      <div className="metrics-row">
        <Metric
          icon={<Database />}
          value={s.totalFiles.toLocaleString()}
          label={t("Total Files")}
        />
        <Metric
          icon={<Gauge />}
          value={s.indexedFiles.toLocaleString()}
          label={t("Indexed Files")}
        />
        <Metric
          icon={<Activity />}
          value={s.todayAddedFiles.toLocaleString()}
          label={t("Added Today")}
        />
        <Metric
          icon={<Sparkles />}
          value={s.totalTokens.toLocaleString()}
          label={t("Token Usage")}
        />
      </div>
      <SettingsSection title="Activity in the Last 14 Days">
        <div className="activity-chart">
          {s.dailyActivity.map((day) => (
            <div
              key={day.day}
              className="chart-column"
              title={`${day.day}: ${day.addedFiles}/${day.indexedFiles}`}
            >
              <div className="chart-bars">
                <span style={{ height: `${(day.addedFiles / max) * 100}%` }} />
                <span
                  style={{ height: `${(day.indexedFiles / max) * 100}%` }}
                />
              </div>
              <small>{day.day.slice(5)}</small>
            </div>
          ))}
        </div>
      </SettingsSection>
      <SettingsSection title="Local Storage">
        <div className="storage-list">
          <div>
            <span>{t("Database")}</span>
            <strong>{formatBytes(s.databaseBytes)}</strong>
          </div>
          <div>
            <span>{t("Vector Index")}</span>
            <strong>{formatBytes(s.vectorBytes)}</strong>
          </div>
          <div>
            <span>Extracted Text</span>
            <strong>{formatBytes(s.extractedTextBytes)}</strong>
          </div>
          <div>
            <span>Managed Files</span>
            <strong>{formatBytes(s.managedFileBytes)}</strong>
          </div>
          <div>
            <span>Local AI Models</span>
            <strong>{formatBytes(s.localModelBytes)}</strong>
          </div>
        </div>
      </SettingsSection>
      <SettingsSection title="Storage by Category">
        <div className="storage-list">
          {s.categoryStorage.filter((item) => item.fileCount > 0).map((item) => <div key={item.category}><span>{t(item.category)} · {item.fileCount}</span><strong>{formatBytes(item.bytes)}</strong></div>)}
        </div>
      </SettingsSection>
    </div>
  );
}

function RulesSettings({
  snapshot,
  t,
  onRefresh,
}: ChildProps): React.JSX.Element {
  const empty: Omit<Rule, "id"> = {
    name: "",
    type: "rule",
    pattern: "*.pdf",
    targetFolder: "Documents",
    priority: 50,
    enabled: true,
    action: "organize",
  };
  const [editing, setEditing] = useState<Rule | Omit<Rule, "id"> | null>(null);
  const [prompt, setPrompt] = useState("Put invoice PDFs in Documents/Invoices");
  const save = async (): Promise<void> => {
    if (!editing) return;
    if ("id" in editing) await window.fileNest.updateRule(editing);
    else await window.fileNest.createRule(editing);
    setEditing(null);
    await onRefresh();
  };
  const generate = async (): Promise<void> => {
    const rules = await window.fileNest.generateRules(prompt);
    for (const rule of rules) await window.fileNest.createRule(rule);
    await onRefresh();
  };
  return (
    <div className="settings-sections">
      <SettingsSection
        title={t("Organization Rules")}
        subtitle="Higher-priority rules match first; ignore rules do not move files"
      >
        <div className="rules-toolbar">
          <button className="primary-button" onClick={() => setEditing(empty)}>
            <Plus size={16} />
            {t("Add Rule")}
          </button>
          <div>
            <input value={prompt} onChange={(e) => setPrompt(e.target.value)} />
            <button
              className="secondary-button"
              onClick={() => void generate()}
            >
              <Sparkles size={16} />
              {t("Generate Rules with AI")}
            </button>
          </div>
        </div>
        <div className="rules-list">
          {snapshot.rules.map((rule) => (
            <button
              key={rule.id}
              className="rule-row"
              onClick={() => setEditing(rule)}
            >
              <label className="switch" onClick={(e) => e.stopPropagation()}>
                <input
                  type="checkbox"
                  checked={rule.enabled}
                  onChange={(e) =>
                    void window.fileNest
                      .updateRule({ ...rule, enabled: e.target.checked })
                      .then(onRefresh)
                  }
                />
                <span />
              </label>
              <div>
                <strong>{rule.name}</strong>
                <span>
                  {rule.pattern} →{" "}
                  {rule.action === "ignore" ? t("Ignore") : rule.targetFolder}
                </span>
              </div>
              <small>P{rule.priority}</small>
            </button>
          ))}
        </div>
      </SettingsSection>
      {editing && (
        <SettingsSection title={"id" in editing ? "Edit Rule" : t("Add Rule")}>
          <div className="rule-editor">
            <label>
              {t("Rule Name")}
              <input
                value={editing.name}
                onChange={(e) =>
                  setEditing({ ...editing, name: e.target.value })
                }
              />
            </label>
            <label>
              {t("Pattern")}
              <input
                value={editing.pattern}
                onChange={(e) =>
                  setEditing({ ...editing, pattern: e.target.value })
                }
              />
            </label>
            <label>
              {t("Destination Folder")}
              <input
                value={editing.targetFolder}
                onChange={(e) =>
                  setEditing({ ...editing, targetFolder: e.target.value })
                }
              />
            </label>
            <label>
              {t("Priority")}
              <input
                type="number"
                value={editing.priority}
                onChange={(e) =>
                  setEditing({ ...editing, priority: Number(e.target.value) })
                }
              />
            </label>
            <label>
              Action
              <select
                value={editing.action}
                onChange={(e) =>
                  setEditing({
                    ...editing,
                    action: e.target.value as Rule["action"],
                  })
                }
              >
                <option value="organize">{t("Organize")}</option>
                <option value="ignore">{t("Ignore")}</option>
              </select>
            </label>
            <div className="button-row">
              <button className="primary-button" onClick={() => void save()}>
                <Save size={16} />
                {t("Save")}
              </button>
              <button
                className="secondary-button"
                onClick={() => setEditing(null)}
              >
                {t("Cancel")}
              </button>
              {"id" in editing && (
                <button
                  className="secondary-button danger"
                  onClick={() =>
                    void window.fileNest.deleteRule(editing.id).then(() => {
                      setEditing(null);
                      return onRefresh();
                    })
                  }
                >
                  <Trash2 size={16} />
                  {t("Delete")}
                </button>
              )}
            </div>
          </div>
        </SettingsSection>
      )}
    </div>
  );
}

function SettingsSection({
  title,
  subtitle,
  children,
}: {
  title: string;
  subtitle?: string;
  children: React.ReactNode;
}): React.JSX.Element {
  const language = useContext(SettingsLanguageContext);
  return (
    <section className="settings-section">
      <header>
        <h2>{translate(title, language)}</h2>
        {subtitle && <p>{translate(subtitle, language)}</p>}
      </header>
      <div className="section-body">{children}</div>
    </section>
  );
}
function SettingRow({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: React.ReactNode;
}): React.JSX.Element {
  const language = useContext(SettingsLanguageContext);
  return (
    <div className="setting-row">
      <div>
        <strong>{translate(label, language)}</strong>
        {hint && <span>{translate(hint, language)}</span>}
      </div>
      <div>{children}</div>
    </div>
  );
}
function NumberField({
  value,
  onCommit,
}: {
  value: number;
  onCommit(value: number): Promise<void>;
}): React.JSX.Element {
  const [draft, setDraft] = useState(String(value));
  return (
    <input
      className="number-input"
      type="number"
      value={draft}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={() => void onCommit(Number(draft))}
    />
  );
}
function Metric({
  icon,
  value,
  label,
}: {
  icon: React.JSX.Element;
  value: string;
  label: string;
}): React.JSX.Element {
  return (
    <div className="metric">
      <span>{icon}</span>
      <strong>{value}</strong>
      <small>{label}</small>
    </div>
  );
}
