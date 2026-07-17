import { createContext, useContext, useState } from "react";
import {
  Activity,
  Bot,
  Check,
  ChevronRight,
  CircleAlert,
  Database,
  Download,
  FileCog,
  FolderPlus,
  Gauge,
  HardDrive,
  Languages,
  ListChecks,
  LoaderCircle,
  Pause,
  Play,
  Plus,
  RotateCw,
  Save,
  Settings2,
  ShieldCheck,
  Sparkles,
  Trash2,
} from "lucide-react";
import type { AiConnectivityCheck, AppLanguage, AppSnapshot, ReindexMode, Rule, Settings } from "../../shared/types";
import { formatBytes, IconButton } from "./components";
import { translate } from "./i18n";

type Section = "general" | "indexing" | "ai" | "statistics" | "rules";
const SettingsLanguageContext = createContext<AppLanguage>("en");

export function SettingsPage({
  snapshot,
  onRefresh,
}: {
  snapshot: AppSnapshot;
  onRefresh(): Promise<void>;
}): React.JSX.Element {
  const [section, setSection] = useState<Section>("general");
  const t = (value: string): string =>
    translate(value, snapshot.settings.appLanguage);
  const items: Array<{ id: Section; label: string; icon: React.JSX.Element }> =
    [
      { id: "general", label: "General", icon: <Settings2 size={17} /> },
      { id: "indexing", label: "Index & Organize", icon: <FileCog size={17} /> },
      { id: "ai", label: "AI Models", icon: <Bot size={17} /> },
      { id: "statistics", label: "Statistics", icon: <Activity size={17} /> },
      { id: "rules", label: "Organization Rules", icon: <ListChecks size={17} /> },
    ];
  return (
    <SettingsLanguageContext.Provider value={snapshot.settings.appLanguage}>
    <main className="settings-page">
      <header className="page-header">
        <div>
          <h1>{t("Settings")}</h1>
          <p>Manage file watching, organization rules, indexing, AI models, and statistics</p>
        </div>
        <span className="auto-save">
          <Check size={15} />
          Changes save automatically
        </span>
      </header>
      <div className="settings-layout">
        <nav className="settings-nav">
          {items.map((item) => (
            <button
              key={item.id}
              className={section === item.id ? "selected" : ""}
              onClick={() => setSection(item.id)}
            >
              {item.icon}
              {t(item.label)}
              <ChevronRight size={15} />
            </button>
          ))}
        </nav>
        <div className="settings-content">
          {section === "general" && (
            <GeneralSettings snapshot={snapshot} t={t} onRefresh={onRefresh} />
          )}
          {section === "indexing" && (
            <IndexSettings snapshot={snapshot} t={t} onRefresh={onRefresh} />
          )}
          {section === "ai" && (
            <AiSettings snapshot={snapshot} t={t} onRefresh={onRefresh} />
          )}
          {section === "statistics" && <Statistics snapshot={snapshot} t={t} />}
          {section === "rules" && (
            <RulesSettings snapshot={snapshot} t={t} onRefresh={onRefresh} />
          )}
        </div>
      </div>
    </main>
    </SettingsLanguageContext.Provider>
  );
}

type ChildProps = {
  snapshot: AppSnapshot;
  t(value: string): string;
  onRefresh(): Promise<void>;
};

function GeneralSettings({
  snapshot,
  t,
  onRefresh,
}: ChildProps): React.JSX.Element {
  const update = async (patch: Partial<Settings>): Promise<void> => {
    await window.fileNest.updateSettings(patch);
    await onRefresh();
  };
  const addFolders = async (): Promise<void> => {
    const dirs = await window.fileNest.chooseWatchDirectories();
    const added = dirs.filter((path) => !snapshot.settings.watchDirs.includes(path));
    if (!added.length) return;
    await update({ watchDirs: [...snapshot.settings.watchDirs, ...added] });
    const processExisting = confirm(t("Process files already in the newly added folders now? Choose Cancel to preserve them and watch only future changes."));
    if (processExisting) await window.fileNest.scanExisting(added);
    else await window.fileNest.preserveExisting(added);
    await onRefresh();
  };
  return (
    <div className="settings-sections">
      <SettingsSection
        title="Runtime Status"
        subtitle="Control background watching and Windows sign-in behavior"
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
        <SettingRow
          label={t("Launch at Sign-in")}
          hint="Run automatically in the system tray after Windows sign-in"
        >
          <label className="switch">
            <input
              type="checkbox"
              checked={snapshot.settings.launchAtLogin}
              onChange={(event) =>
                void update({ launchAtLogin: event.target.checked })
              }
            />
            <span />
          </label>
        </SettingRow>
      </SettingsSection>
      <SettingsSection
        title={t("Watched Folders")}
        subtitle="FileNest waits for file writes to stabilize before indexing"
      >
        <div className="directory-list">
          {snapshot.settings.watchDirs.map((path) => (
            <div key={path}>
              <HardDrive size={17} />
              <span>{path}<small>{snapshot.watchDirectoryStatuses.find((status) => status.path === path)?.detail}</small></span>
              <IconButton
                label={t("Delete")}
                onClick={() =>
                  void update({
                    watchDirs: snapshot.settings.watchDirs.filter(
                      (item) => item !== path,
                    ),
                  })
                }
              >
                <Trash2 size={15} />
              </IconButton>
            </div>
          ))}
          <button
            className="secondary-button"
            onClick={() => void addFolders()}
          >
            <FolderPlus size={16} />
            {t("Add Folders")}
          </button>
          <button
            className="secondary-button"
            onClick={() => void window.fileNest.scanExisting().then(onRefresh)}
          >
            <Play size={16} />
            Process Existing Files
          </button>
        </div>
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

function IndexSettings({
  snapshot,
  t,
  onRefresh,
}: ChildProps): React.JSX.Element {
  const s = snapshot.settings;
  const [reindexMode, setReindexMode] = useState<ReindexMode>("all");
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
        title={t("Index & Organize")}
        subtitle="Files move only after indexing completes"
      >
        <SettingRow label="Organization Folder" hint={s.organizedRoot}>
          <button
            className="secondary-button"
            onClick={() => void chooseOrganizedRoot()}
          >
            <FolderPlus size={16} />
            Change Location
          </button>
        </SettingRow>
        <SettingRow label="Classification Strategy" hint="Hybrid mode matches rules first, then uses AI to generate a stable topic subfolder">
          <select
            value={s.classifyStrategy}
            onChange={(e) =>
              void update({
                classifyStrategy: e.target.value as Settings["classifyStrategy"],
              })
            }
          >
            <option value="hybrid">Rules + AI Topic Classification</option>
            <option value="rule">Rules Only</option>
          </select>
        </SettingRow>
        <SettingRow label={t("Automatic Organization")} hint="When disabled, files are recorded and indexed but not moved">
          <label className="switch">
            <input
              type="checkbox"
              checked={s.autoOrganize}
              onChange={(e) => void update({ autoOrganize: e.target.checked })}
            />
            <span />
          </label>
        </SettingRow>
        <SettingRow label="Organization Mode">
          <select
            value={s.autoOrganizeMode}
            onChange={(e) =>
              void update({
                autoOrganizeMode: e.target
                  .value as Settings["autoOrganizeMode"],
              })
            }
          >
            <option value="immediate">Organize immediately after indexing</option>
            <option value="batched">Organize on timer or file threshold</option>
          </select>
        </SettingRow>
        {s.autoOrganizeMode === "batched" && (
          <>
            <SettingRow label="Batch Interval (Seconds)">
              <NumberField
                value={s.autoOrganizeIntervalSeconds}
                onCommit={(value) =>
                  update({ autoOrganizeIntervalSeconds: value })
                }
              />
            </SettingRow>
            <SettingRow label="Batch File Count">
              <NumberField
                value={s.autoOrganizeBatchSize}
                onCommit={(value) => update({ autoOrganizeBatchSize: value })}
              />
            </SettingRow>
          </>
        )}
        <SettingRow label="Accepted Extensions" hint="The watcher processes only these file types">
          <input
            className="wide-input"
            defaultValue={s.enabledExtensions.join(", ")}
            onBlur={(e) =>
              void update({ enabledExtensions: e.target.value.split(",") })
            }
          />
        </SettingRow>
        <SettingRow label="Exclude Hidden Files">
          <label className="switch">
            <input
              type="checkbox"
              checked={s.excludeHidden}
              onChange={(e) => void update({ excludeHidden: e.target.checked })}
            />
            <span />
          </label>
        </SettingRow>
      </SettingsSection>
      <SettingsSection title="Vector Index" subtitle="Reindexing is recommended after configuration changes">
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
        <SettingRow label="Chunk tokens">
          <NumberField
            value={s.vectorChunkWords}
            onCommit={(value) => update({ vectorChunkWords: value })}
          />
        </SettingRow>
        <SettingRow label="Overlap">
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
          <select
            value={s.llmChoice}
            onChange={(e) =>
              void update({
                llmChoice: e.target.value as Settings["llmChoice"],
              })
            }
          >
            <option value="ollama">Local Ollama</option>
            <option value="cloud">Cloud API</option>
            <option value="none">Search Only</option>
          </select>
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
