import { useMemo, useState } from "react";
import {
  Check,
  CheckCircle2,
  Cloud,
  Cpu,
  Download,
  FileSearch,
  Folder,
  FolderPlus,
  HardDrive,
  Languages,
  LoaderCircle,
  LockKeyhole,
  Mic2,
  Package,
  Settings2,
  ShieldCheck,
  Sparkles,
  TextSearch,
  WandSparkles,
} from "lucide-react";
import type { AppSnapshot, Settings } from "../../shared/types";
import { translate } from "./i18n";

type SetupStep = "welcome" | "basics" | "local-runtime" | "local-models" | "cloud-api" | "media-runtime" | "finish";
type CloudService = "chat" | "embedding" | "ocr";

const stepMetadata: Record<SetupStep, { label: string; icon: React.ElementType }> = {
  welcome: { label: "Welcome", icon: Sparkles },
  basics: { label: "Basic Setup", icon: Settings2 },
  "local-runtime": { label: "Local Components", icon: Package },
  "local-models": { label: "Model Downloads", icon: Download },
  "cloud-api": { label: "Cloud API", icon: Cloud },
  "media-runtime": { label: "Audio & Video", icon: Mic2 },
  finish: { label: "Get Started", icon: CheckCircle2 },
};

export function Onboarding({
  snapshot,
  onComplete,
}: {
  snapshot: AppSnapshot;
  onComplete(): Promise<void>;
}): React.JSX.Element {
  const [step, setStep] = useState<SetupStep>("welcome");
  const [cloudService, setCloudService] = useState<CloudService>("chat");
  const [organizeExisting, setOrganizeExisting] = useState(false);
  const [modelBusy, setModelBusy] = useState(false);
  const [componentBusy, setComponentBusy] = useState<"ollama" | "docling" | "ffmpeg" | "whisper" | "whisper-model" | null>(null);
  const t = (value: string): string => translate(value, snapshot.settings.appLanguage);
  const usesCloud = snapshot.settings.llmChoice === "cloud";
  const steps = useMemo<SetupStep[]>(() => [
    "welcome",
    "basics",
    ...(usesCloud ? ["cloud-api" as const] : ["local-runtime" as const, "local-models" as const]),
    ...(snapshot.settings.mediaTranscriptionEnabled ? ["media-runtime" as const] : []),
    "finish",
  ], [snapshot.settings.mediaTranscriptionEnabled, usesCloud]);
  const currentIndex = Math.max(0, steps.indexOf(step));
  const currentStep = steps[currentIndex] ?? "welcome";

  const save = async (patch: Partial<Settings>): Promise<void> => {
    await window.fileNest.updateSettings(patch);
    await onComplete();
  };
  const setAiMode = async (mode: "ollama" | "cloud"): Promise<void> => {
    await save(mode === "cloud"
      ? { llmChoice: "cloud", embeddingSource: "cloud", ocrSource: "cloud" }
      : { llmChoice: "ollama", embeddingSource: "ollama", ocrSource: "local" });
  };
  const move = (direction: -1 | 1): void => {
    const next = steps[currentIndex + direction];
    if (next) setStep(next);
  };
  const finish = async (processExisting: boolean): Promise<void> => {
    if (processExisting) await window.fileNest.scanExisting();
    else await window.fileNest.preserveExisting();
    await window.fileNest.updateSettings({ onboardingCompleted: true });
    await window.fileNest.startWatching();
    await onComplete();
  };
  const downloadModels = async (): Promise<void> => {
    setModelBusy(true);
    try {
      for (const model of [snapshot.settings.ollamaModel, snapshot.settings.ollamaEmbeddingModel]) {
        if (!snapshot.ollama.models.includes(model)) await window.fileNest.pullOllamaModel(model);
      }
      await onComplete();
    } finally {
      setModelBusy(false);
    }
  };
  const runComponent = async (
    name: NonNullable<typeof componentBusy>,
    action: () => Promise<void>,
  ): Promise<void> => {
    setComponentBusy(name);
    try {
      await action();
      await onComplete();
    } finally {
      setComponentBusy(null);
    }
  };

  return (
    <div className="onboarding">
      <div className="onboarding-window onboarding-macos-flow">
        <header className="onboarding-header">
          <div className="onboarding-product-title">
            <img src="./brand-mark.png" alt="" />
            <div><strong>FileNest Setup</strong><span>{t("Set up file watching and AI in a few minutes")}</span></div>
          </div>
          <div className="onboarding-progress"><span>{t(`Step ${currentIndex + 1} of ${steps.length}`)}</span><i><b style={{ width: `${((currentIndex + 1) / steps.length) * 100}%` }} /></i></div>
        </header>
        <div className="onboarding-layout">
          <aside className="setup-rail">
            <small>{t("Setup Progress")}</small>
            <ol>
              {steps.map((item, index) => {
                const metadata = stepMetadata[item];
                const Icon = metadata.icon;
                return <li key={item} className={item === currentStep ? "active" : index < currentIndex ? "done" : ""}>
                  <span>{index < currentIndex ? <Check size={14} /> : <Icon size={14} />}</span>
                  {t(metadata.label)}
                </li>;
              })}
            </ol>
            <div className="setup-rail-note"><CheckCircle2 size={15} /><strong>{t("Settings save automatically")}</strong><span>{t("You can change these later in Settings.")}</span></div>
          </aside>
          <main className="onboarding-content">
            {currentStep === "welcome" && <WelcomeStep t={t} />}
            {currentStep === "basics" && <BasicsStep snapshot={snapshot} t={t} onSave={save} onSetAiMode={setAiMode} />}
            {currentStep === "local-runtime" && <LocalRuntimeStep snapshot={snapshot} t={t} busy={componentBusy} onRun={runComponent} />}
            {currentStep === "local-models" && <LocalModelsStep snapshot={snapshot} t={t} busy={modelBusy} onSave={save} onDownload={downloadModels} />}
            {currentStep === "cloud-api" && <CloudApiStep snapshot={snapshot} t={t} service={cloudService} onService={setCloudService} onSave={save} />}
            {currentStep === "media-runtime" && <MediaRuntimeStep snapshot={snapshot} t={t} busy={componentBusy} onRun={runComponent} onSave={save} />}
            {currentStep === "finish" && <FinishStep snapshot={snapshot} t={t} organizeExisting={organizeExisting} onOrganizeExisting={setOrganizeExisting} />}
          </main>
        </div>
        <footer className="onboarding-navigation">
          <button className="setup-later" onClick={() => void finish(false)}>{t("Set Up Later")}</button>
          <div>{currentIndex > 0 && <button className="secondary-button" onClick={() => move(-1)}>{t("Back")}</button>}{currentIndex < steps.length - 1 ? <button className="primary-button" onClick={() => move(1)}>{t("Continue")}</button> : <button className="primary-button" onClick={() => void finish(organizeExisting)}>{t("Finish Setup")}</button>}</div>
        </footer>
      </div>
    </div>
  );
}

function WelcomeStep({ t }: { t(value: string): string }): React.JSX.Element {
  return <section className="setup-welcome"><div className="setup-welcome-mark"><img src="./brand-mark.png" alt="" /></div><h1>{t("Automate file organization and retrieval")}</h1><p>{t("Choose which folders to watch and whether to use local models or cloud APIs. FileNest will prepare only what is needed.")}</p><SetupSection><Feature icon={FolderPlus} title="Watch & Organize" detail="Desktop and Downloads are watched by default, and you can add more folders." t={t} /><Feature icon={Sparkles} title="Choose How AI Runs" detail="Local mode keeps data private; cloud mode avoids large model downloads." t={t} /><Feature icon={FileSearch} title="Document Parsing & Vector Search" detail="Understand different file types with Docling, embeddings, and OCR." t={t} /></SetupSection><small className="setup-time">{t("About 2–5 minutes; model downloads depend on network speed")}</small></section>;
}

function BasicsStep({ snapshot, t, onSave, onSetAiMode }: { snapshot: AppSnapshot; t(value: string): string; onSave(patch: Partial<Settings>): Promise<void>; onSetAiMode(mode: "ollama" | "cloud"): Promise<void> }): React.JSX.Element {
  const addFolders = async (): Promise<void> => {
    const folders = await window.fileNest.chooseWatchDirectories();
    if (folders.length) await onSave({ watchDirs: [...new Set([...snapshot.settings.watchDirs, ...folders])] });
  };
  return <SetupStep title="Basic Setup" subtitle="Configure appearance, watched folders, and how AI runs." icon={Settings2} t={t}>
    <SetupSection title="Interface Preferences" t={t}><SetupRow label="Language" t={t}><select value={snapshot.settings.appLanguage} onChange={(event) => void onSave({ appLanguage: event.target.value as Settings["appLanguage"] })}><option value="system">{t("System")}</option><option value="en">English</option><option value="zh-Hans">简体中文</option></select></SetupRow><SetupRow label="Appearance" t={t}><div className="appearance-choice">{(["system", "light", "dark"] as const).map((value) => <button key={value} className={snapshot.settings.appearance === value ? "selected" : ""} onClick={() => void onSave({ appearance: value })}>{t(value === "system" ? "System" : value === "light" ? "Light" : "Dark")}</button>)}</div></SetupRow></SetupSection>
    <SetupSection title="AI Mode" t={t}><div className="ai-mode-choices"><ChoiceCard icon={Cpu} title="Local Ollama" detail="Data stays on this PC; models are required" selected={snapshot.settings.llmChoice !== "cloud"} onClick={() => void onSetAiMode("ollama")} t={t} /><ChoiceCard icon={Cloud} title="Cloud API" detail="No model download; API keys are required" selected={snapshot.settings.llmChoice === "cloud"} onClick={() => void onSetAiMode("cloud")} t={t} /></div></SetupSection>
    <SetupSection title="Audio & Video" t={t}><label className="setup-toggle-row"><span className="setup-icon"><Mic2 size={18} /></span><span><strong>{t("Transcribe audio and video for search and chat")}</strong><small>{t("Adds an FFmpeg and OpenAI Whisper setup step, then indexes time-coded transcripts for RAG.")}</small></span><input type="checkbox" checked={snapshot.settings.mediaTranscriptionEnabled} onChange={(event) => void onSave({ mediaTranscriptionEnabled: event.target.checked })} /></label></SetupSection>
    <SetupSection title="Watched Folders" t={t}><div className="setup-folder-list">{snapshot.settings.watchDirs.length ? snapshot.settings.watchDirs.map((path) => <div key={path}><Folder size={16} /><span title={path}>{path}</span><button aria-label={`${t("Remove")} ${path}`} onClick={() => void onSave({ watchDirs: snapshot.settings.watchDirs.filter((item) => item !== path) })}>×</button></div>) : <p>{t("No watched folders added")}</p>}<footer><button className="text-action" onClick={() => void addFolders()}><FolderPlus size={15} />{t("Add Folder…")}</button><button className="text-action" onClick={() => void window.fileNest.defaultWatchDirectories().then((watchDirs) => onSave({ watchDirs }))}>{t("Restore Default Folders")}</button></footer></div></SetupSection>
  </SetupStep>;
}

function LocalRuntimeStep({ snapshot, t, busy, onRun }: { snapshot: AppSnapshot; t(value: string): string; busy: string | null; onRun(name: "ollama" | "docling" | "ffmpeg" | "whisper" | "whisper-model", action: () => Promise<void>): Promise<void> }): React.JSX.Element {
  return <SetupStep title="Install Local Components" subtitle="Ollama runs local AI, while Docling is preferred for document parsing." icon={Package} t={t}><SetupSection><DependencyRow icon={Cpu} title="Ollama" detail={snapshot.ollama.reachable ? "Local AI service is running" : "Install and start the local AI service"} ready={snapshot.ollama.reachable} busy={busy === "ollama"} actionLabel={snapshot.ollama.reachable ? "Ready" : "Install & Start Automatically"} onAction={() => void onRun("ollama", () => window.fileNest.installOllama())} t={t} /><DependencyRow icon={FileSearch} title="Docling" detail={snapshot.docling.installed ? `Docling ${snapshot.docling.version ?? ""}` : "Preferred document parsing is not installed"} ready={snapshot.docling.installed} busy={busy === "docling"} actionLabel={snapshot.docling.installed ? "Ready" : "Install Docling"} onAction={() => void onRun("docling", () => window.fileNest.installDocling())} t={t} /><DependencyRow icon={TextSearch} title="Local OCR" detail="Bundled Windows OCR is available with Ollama fallback" ready busy={false} actionLabel="Ready" onAction={() => undefined} t={t} /></SetupSection><SetupNotice icon={ShieldCheck} text="Components are installed in an isolated FileNest user environment without requiring administrator access." tone="success" t={t} /></SetupStep>;
}

function LocalModelsStep({ snapshot, t, busy, onSave, onDownload }: { snapshot: AppSnapshot; t(value: string): string; busy: boolean; onSave(patch: Partial<Settings>): Promise<void>; onDownload(): Promise<void> }): React.JSX.Element {
  const models = [
    { role: "Generation", key: "ollamaModel" as const, values: ["qwen3.5:2b", "qwen3.5:4b", "qwen3.5:9b"] },
    { role: "Embedding Model", key: "ollamaEmbeddingModel" as const, values: ["qwen3-embedding:0.6b", "qwen3-embedding:4b", "qwen3-embedding:8b"] },
  ];
  const missing = models.filter((item) => !snapshot.ollama.models.includes(snapshot.settings[item.key]));
  return <SetupStep title="Download Local Models" subtitle="Choose the generation and embedding models FileNest downloads; Qwen 9B and 0.6B are selected by default." icon={Download} t={t}><ResourceStrip t={t} /><SetupSection title="Required Models" t={t}>{models.map((item) => <SetupRow key={item.key} label={item.role} t={t}><select value={snapshot.settings[item.key]} onChange={(event) => void onSave({ [item.key]: event.target.value })}>{item.values.map((model) => <option key={model} value={model}>{model}</option>)}</select></SetupRow>)}<div className="model-readiness">{models.map((item) => { const model = snapshot.settings[item.key]; const downloaded = snapshot.ollama.models.includes(model); return <div key={item.key}><Sparkles size={16} /><span><small>{t(item.role)}</small><strong>{model}</strong></span><b className={downloaded ? "ready" : "pending"}>{t(downloaded ? "Downloaded" : "Not Downloaded")}</b></div>; })}</div></SetupSection><div className="setup-download-summary"><span><HardDrive size={15} />{t(missing.length ? `Estimated remaining download: ${missing.length} model${missing.length === 1 ? "" : "s"}` : "Estimated remaining download: Zero KB")}</span></div><button className="primary-button setup-download-button" disabled={busy || !snapshot.ollama.reachable || missing.length === 0} onClick={() => void onDownload()}>{busy && <LoaderCircle className="spin" size={16} />}{t("Download All Required Models")}</button></SetupStep>;
}

function CloudApiStep({ snapshot, t, service, onService, onSave }: { snapshot: AppSnapshot; t(value: string): string; service: CloudService; onService(value: CloudService): void; onSave(patch: Partial<Settings>): Promise<void> }): React.JSX.Element {
  const fields = service === "chat" ? { title: "Chat Model", base: "cloudBaseUrl" as const, key: "cloudApiKey" as const, model: "cloudModel" as const } : service === "embedding" ? { title: "Embedding", base: "cloudEmbeddingBaseUrl" as const, key: "cloudEmbeddingApiKey" as const, model: "cloudEmbeddingModel" as const } : { title: "OCR", base: "cloudOcrBaseUrl" as const, key: "cloudOcrApiKey" as const, model: "cloudOcrModel" as const };
  return <SetupStep title="Configure Cloud APIs" subtitle="Configure chat, embedding, and OCR services separately. You can change them later in Settings." icon={Cloud} t={t}><div className="cloud-service-tabs">{(["chat", "embedding", "ocr"] as const).map((item) => <button key={item} className={service === item ? "selected" : ""} onClick={() => onService(item)}>{t(item === "chat" ? "Chat Model" : item === "embedding" ? "Embedding" : "OCR")}</button>)}</div><SetupSection title={fields.title} t={t}><SetupRow label="Base URL" t={t}><input key={`${service}-base`} defaultValue={snapshot.settings[fields.base]} onBlur={(event) => void onSave({ [fields.base]: event.target.value })} /></SetupRow><SetupRow label="API Key" t={t}><input key={`${service}-key`} type="password" defaultValue={snapshot.settings[fields.key]} placeholder={t("Enter API key") as string} onBlur={(event) => void onSave({ [fields.key]: event.target.value })} /></SetupRow><SetupRow label="Model" t={t}><input key={`${service}-model`} defaultValue={snapshot.settings[fields.model]} onBlur={(event) => void onSave({ [fields.model]: event.target.value })} /></SetupRow></SetupSection>{!snapshot.settings[fields.key] && <SetupNotice icon={LockKeyhole} text="The API key is empty. You can set it later, but the related AI feature will remain unavailable." tone="warning" t={t} />}<SetupNotice icon={ShieldCheck} text="When using cloud services, relevant prompts, document chunks, or images are sent to the configured API. The index database remains on this PC." tone="info" t={t} /></SetupStep>;
}

function MediaRuntimeStep({ snapshot, t, busy, onRun, onSave }: { snapshot: AppSnapshot; t(value: string): string; busy: string | null; onRun(name: "ollama" | "docling" | "ffmpeg" | "whisper" | "whisper-model", action: () => Promise<void>): Promise<void>; onSave(patch: Partial<Settings>): Promise<void> }): React.JSX.Element {
  const modelReady = snapshot.whisper.installedModels.includes(snapshot.settings.whisperModel);
  const whisperReady = snapshot.whisper.state === "ready";
  return <SetupStep title="Set Up Audio & Video Transcription" subtitle="Install the local decoder and OpenAI Whisper model used to turn media into searchable transcripts." icon={Mic2} t={t}><ResourceStrip t={t} /><SetupSection title="Local Components" t={t}><DependencyRow icon={Package} title="FFmpeg" detail={snapshot.ffmpeg.message} ready={snapshot.ffmpeg.state === "ready"} busy={busy === "ffmpeg"} actionLabel={snapshot.ffmpeg.state === "ready" ? "Ready" : "Install FFmpeg"} onAction={() => void onRun("ffmpeg", () => window.fileNest.installFfmpeg())} t={t} /><DependencyRow icon={Mic2} title="OpenAI Whisper" detail={snapshot.whisper.message} ready={whisperReady} busy={busy === "whisper"} actionLabel={whisperReady ? "Ready" : "Install Whisper"} onAction={() => void onRun("whisper", () => window.fileNest.installWhisper())} t={t} /></SetupSection><SetupSection title="Transcription Model" t={t}><SetupRow label="Model" t={t}><select value={snapshot.settings.whisperModel} onChange={(event) => void onSave({ whisperModel: event.target.value })}>{["tiny", "base", "small", "medium", "large-v3"].map((model) => <option key={model} value={model}>{model}</option>)}</select></SetupRow><DependencyRow icon={Download} title="Whisper Model" detail={`${snapshot.settings.whisperModel} model for local transcription`} ready={modelReady} busy={busy === "whisper-model"} actionLabel={modelReady ? "Ready" : "Download Model"} onAction={() => void onRun("whisper-model", () => window.fileNest.downloadWhisperModel(snapshot.settings.whisperModel))} t={t} /></SetupSection><SetupNotice icon={ShieldCheck} text="Media decoding and transcription run locally. Only the resulting text chunks follow your configured Embedding provider." tone="success" t={t} /></SetupStep>;
}

function FinishStep({ snapshot, t, organizeExisting, onOrganizeExisting }: { snapshot: AppSnapshot; t(value: string): string; organizeExisting: boolean; onOrganizeExisting(value: boolean): void }): React.JSX.Element {
  const statusByPath = new Map(snapshot.watchDirectoryStatuses.map((item) => [item.path, item]));
  return <SetupStep title="Ready to Start" subtitle="Review the watched folders and decide whether to organize files already in them." icon={CheckCircle2} t={t}><SetupSection title="Watched Folders" t={t}><div className="finish-folders">{snapshot.settings.watchDirs.length ? snapshot.settings.watchDirs.map((path) => <div key={path}><Folder size={16} /><span>{path}</span><small>{statusByPath.get(path)?.detail ?? t("Ready")}</small></div>) : <p>{t("No watched folders added")}</p>}</div></SetupSection><SetupSection title="Existing Files" t={t}><FinishChoice icon={ShieldCheck} title="Keep Existing Files, Process New Files Only" detail="Existing files will not be indexed or moved. Files added after setup will be processed automatically." selected={!organizeExisting} onClick={() => onOrganizeExisting(false)} t={t} /><FinishChoice icon={WandSparkles} title="Organize Existing Files Now" detail="Process the current items and organize them using your rules." selected={organizeExisting} onClick={() => onOrganizeExisting(true)} t={t} /></SetupSection><SetupNotice icon={organizeExisting ? WandSparkles : ShieldCheck} text={organizeExisting ? "Organizing now indexes existing files and may move them according to your organization rules." : "This choice is saved. You can process these files later in Settings → Index & Organize."} tone={organizeExisting ? "warning" : "success"} t={t} /></SetupStep>;
}

function SetupStep({ title, subtitle, icon: Icon, t, children }: { title: string; subtitle: string; icon: React.ElementType; t(value: string): string; children: React.ReactNode }): React.JSX.Element { return <section className="setup-step"><header><span className="setup-heading-icon"><Icon size={21} /></span><div><h1>{t(title)}</h1><p>{t(subtitle)}</p></div></header>{children}</section>; }
function SetupSection({ title, t, children }: { title?: string; t?: (value: string) => string; children: React.ReactNode }): React.JSX.Element { return <section className="setup-section">{title && <header>{t ? t(title) : title}</header>}<div>{children}</div></section>; }
function SetupRow({ label, t, children }: { label: string; t(value: string): string; children: React.ReactNode }): React.JSX.Element { return <label className="setup-row"><span>{t(label)}</span>{children}</label>; }
function Feature({ icon: Icon, title, detail, t }: { icon: React.ElementType; title: string; detail: string; t(value: string): string }): React.JSX.Element { return <div className="setup-feature"><Icon size={18} /><span><strong>{t(title)}</strong><small>{t(detail)}</small></span></div>; }
function ChoiceCard({ icon: Icon, title, detail, selected, onClick, t }: { icon: React.ElementType; title: string; detail: string; selected: boolean; onClick(): void; t(value: string): string }): React.JSX.Element { return <button className={selected ? "selected" : ""} onClick={onClick}><Icon size={18} /><span><strong>{t(title)}</strong><small>{t(detail)}</small></span><i>{selected ? <CheckCircle2 size={16} /> : ""}</i></button>; }
function DependencyRow({ icon: Icon, title, detail, ready, busy, actionLabel, onAction, t }: { icon: React.ElementType; title: string; detail: string; ready: boolean; busy: boolean; actionLabel: string; onAction(): void; t(value: string): string }): React.JSX.Element { return <div className="dependency-row"><span className={ready ? "dependency-icon ready" : "dependency-icon"}><Icon size={18} /></span><span><strong>{t(title)} {ready && <b>{t("Ready")}</b>}</strong><small>{t(detail)}</small></span><button className="secondary-button" disabled={busy || ready} onClick={onAction}>{busy && <LoaderCircle className="spin" size={15} />}{t(actionLabel)}</button></div>; }
function SetupNotice({ icon: Icon, text, tone, t }: { icon: React.ElementType; text: string; tone: "success" | "warning" | "info"; t(value: string): string }): React.JSX.Element { return <p className={`setup-notice ${tone}`}><Icon size={15} />{t(text)}</p>; }
function ResourceStrip({ t }: { t(value: string): string }): React.JSX.Element { return <div className="resource-strip"><span><Cpu size={16} /><small>{t("Platform")}</small><strong>Windows</strong></span><span><HardDrive size={16} /><small>{t("Local storage")}</small><strong>{t("Required for model downloads")}</strong></span><span><ShieldCheck size={16} /><small>{t("Privacy")}</small><strong>{t("Local-first")}</strong></span></div>; }
function FinishChoice({ icon: Icon, title, detail, selected, onClick, t }: { icon: React.ElementType; title: string; detail: string; selected: boolean; onClick(): void; t(value: string): string }): React.JSX.Element { return <button className={`finish-choice ${selected ? "selected" : ""}`} onClick={onClick}><span><Icon size={18} /></span><span><strong>{t(title)}</strong><small>{t(detail)}</small></span><i>{selected ? <CheckCircle2 size={17} /> : ""}</i></button>; }
