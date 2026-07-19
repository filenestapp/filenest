import { useState } from "react";
import {
  Bot,
  AudioLines,
  CheckCircle2,
  FileText,
  FolderPlus,
  LockKeyhole,
  LoaderCircle,
  ShieldCheck,
  Sparkles,
} from "lucide-react";
import type { AppSnapshot, Settings } from "../../shared/types";
import { translate } from "./i18n";

export function Onboarding({
  snapshot,
  onComplete,
}: {
  snapshot: AppSnapshot;
  onComplete(): Promise<void>;
}): React.JSX.Element {
  const [step, setStep] = useState(0);
  const [organizeExisting, setOrganizeExisting] = useState(false);
  const [doclingBusy, setDoclingBusy] = useState(false);
  const [modelBusy, setModelBusy] = useState(false);
  const [mediaBusy, setMediaBusy] = useState(false);
  const [generationModel, setGenerationModel] = useState(snapshot.settings.ollamaModel);
  const [embeddingModel, setEmbeddingModel] = useState(snapshot.settings.ollamaEmbeddingModel);
  const t = (value: string): string =>
    translate(value, snapshot.settings.appLanguage);
  const update = (patch: Partial<Settings>): Promise<Settings> =>
    window.fileNest.updateSettings(patch);
  const finish = async (): Promise<void> => {
    if (organizeExisting) await window.fileNest.scanExisting();
    else await window.fileNest.preserveExisting();
    await update({ onboardingCompleted: true });
    await window.fileNest.startWatching();
    await onComplete();
  };
  const downloadSelectedModels = async (): Promise<void> => {
    setModelBusy(true);
    try {
      for (const model of [generationModel, embeddingModel]) {
        if (!snapshot.ollama.models.includes(model)) await window.fileNest.pullOllamaModel(model);
      }
      await onComplete();
    } finally {
      setModelBusy(false);
    }
  };
  const setupMediaTranscription = async (): Promise<void> => {
    setMediaBusy(true);
    try {
      await update({ mediaTranscriptionEnabled: true });
      if (snapshot.ffmpeg.state !== "ready") await window.fileNest.installFfmpeg();
      if (snapshot.whisper.version == null) await window.fileNest.installWhisper();
      if (!snapshot.whisper.installedModels.includes(snapshot.settings.whisperModel)) {
        await window.fileNest.downloadWhisperModel(snapshot.settings.whisperModel);
      }
      await onComplete();
    } finally {
      setMediaBusy(false);
    }
  };
  return (
    <div className="onboarding">
      <div className="onboarding-window">
        <aside>
          <img src="./brand-mark.png" alt="" />
          <strong>FileNest</strong>
          <ol>
            {["Welcome", "Folders", "Local AI", "Done"].map((label, index) => (
              <li
                key={label}
                className={
                  step === index ? "active" : step > index ? "done" : ""
                }
              >
                {step > index ? (
                  <CheckCircle2 size={17} />
                ) : (
                  <span>{index + 1}</span>
                )}
                {t(label)}
              </li>
            ))}
          </ol>
          <div className="privacy-note">
            <LockKeyhole size={18} />
            <span>
              {t("Local First")}
              <br />
              {t("Your Files Stay Under Your Control")}
            </span>
          </div>
        </aside>
        <main>
          {step === 0 && (
            <div className="onboarding-step">
              <div className="welcome-mark">
                  <img src="./brand-mark.png" alt="" />
              </div>
              <h1>{t("Welcome to FileNest")}</h1>
              <p>
                {t("Automatically organize files, build a local index, and retrieve content quickly with natural language.")}
              </p>
              <ul>
                <li>
                  <ShieldCheck />
                  {t("The index stays on this PC by default")}
                </li>
                <li>
                  <Sparkles />
                  {t("Supports local Ollama and cloud APIs")}
                </li>
                <li>
                  <FolderPlus />
                  {t("The system tray continuously watches for new files")}
                </li>
              </ul>
            </div>
          )}
          {step === 1 && (
            <div className="onboarding-step">
              <FolderPlus className="step-icon" />
              <h1>{t("Choose Folders to Manage")}</h1>
              <p>{t("Downloads is watched by default. You can add Desktop, Documents, or work folders.")}</p>
              <div className="onboarding-folders">
                {snapshot.settings.watchDirs.map((path) => (
                  <div key={path}>{path}</div>
                ))}
                <button
                  className="secondary-button"
                  onClick={() =>
                    void window.fileNest
                      .chooseWatchDirectories()
                      .then(async (dirs) => {
                        if (!dirs.length) return;
                        await update({
                          watchDirs: [
                            ...new Set([
                              ...snapshot.settings.watchDirs,
                              ...dirs,
                            ]),
                          ],
                        });
                        await onComplete();
                      })
                  }
                >
                  {t("Add Folders")}
                </button>
              </div>
              <label className="check-row">
                <input
                  type="checkbox"
                  checked={organizeExisting}
                  onChange={(e) => setOrganizeExisting(e.target.checked)}
                />
                {t("Index and organize existing files immediately")}
              </label>
            </div>
          )}
          {step === 2 && (
            <div className="onboarding-step">
              <Bot className="step-icon" />
              <h1>{t("Configure Local AI")}</h1>
              <p>
                {t("A lightweight local index requiring no download is used by default. Install Ollama for stronger multilingual semantic search and complete answers.")}
              </p>
              <div className="choice-list">
                <button
                  className={
                    snapshot.settings.embeddingSource === "local"
                      ? "selected"
                      : ""
                  }
                  onClick={() => void update({ embeddingSource: "local" })}
                >
                  <strong>{t("Local Lightweight Index")}</strong>
                  <span>{t("Ready to use · Offline · Low resource usage")}</span>
                </button>
                <button
                  className={
                    snapshot.settings.embeddingSource === "ollama"
                      ? "selected"
                      : ""
                  }
                  onClick={() => void update({ embeddingSource: "ollama" })}
                >
                  <strong>Ollama</strong>
                  <span>{t("Stronger semantic search and local chat")}</span>
                </button>
              </div>
              <button
                className="text-action"
                onClick={() => void window.fileNest.installOllama()}
              >
                {t("Download Ollama for Windows")}
              </button>
              <div className="onboarding-models">
                <label>
                  <span>{t("Generation Model")}</span>
                  <select value={generationModel} onChange={(event) => {
                    const model = event.target.value;
                    setGenerationModel(model);
                    void update({ ollamaModel: model });
                  }}>
                    {["qwen3.5:2b", "qwen3.5:4b", "qwen3.5:9b"].map((model) => <option key={model} value={model}>{model}{model === "qwen3.5:9b" ? ` · ${t("Default")}` : ""}</option>)}
                  </select>
                </label>
                <label>
                  <span>{t("Embedding Model")}</span>
                  <select value={embeddingModel} onChange={(event) => {
                    const model = event.target.value;
                    setEmbeddingModel(model);
                    void update({ ollamaEmbeddingModel: model });
                  }}>
                    {["qwen3-embedding:0.6b", "qwen3-embedding:4b", "qwen3-embedding:8b"].map((model) => <option key={model} value={model}>{model}{model === "qwen3-embedding:0.6b" ? ` · ${t("Default")}` : ""}</option>)}
                  </select>
                </label>
                <button className="secondary-button" disabled={modelBusy || !snapshot.ollama.reachable} onClick={() => void downloadSelectedModels()}>
                  {modelBusy && <LoaderCircle className="spin" size={16} />}
                  {t("Download Selected Models")}
                </button>
              </div>
              <button
                className="text-action"
                disabled={doclingBusy || snapshot.docling.installed}
                onClick={() => {
                  setDoclingBusy(true);
                  void window.fileNest
                    .installDocling()
                    .then(onComplete)
                    .catch((error) =>
                      alert(error instanceof Error ? error.message : String(error)),
                    )
                    .finally(() => setDoclingBusy(false));
                }}
              >
                {doclingBusy ? (
                  <LoaderCircle className="spin" size={16} />
                ) : snapshot.docling.installed ? (
                  <CheckCircle2 size={16} />
                ) : (
                  <FileText size={16} />
                )}
                {snapshot.docling.installed
                  ? `Docling ${snapshot.docling.version ?? ""} Installed`
                  : t("Install Docling Document Parsing (Optional)")}
              </button>
              <button className="text-action" disabled={mediaBusy} onClick={() => void setupMediaTranscription().catch((error) => alert(error instanceof Error ? error.message : String(error)))}>
                {mediaBusy ? <LoaderCircle className="spin" size={16} /> : snapshot.settings.mediaTranscriptionEnabled && snapshot.ffmpeg.state === "ready" && snapshot.whisper.installedModels.includes(snapshot.settings.whisperModel) ? <CheckCircle2 size={16} /> : <AudioLines size={16} />}
                {t("Set Up Audio & Video Transcription")}
              </button>
              <small>{t("Install the local decoder and OpenAI Whisper model used to turn media into searchable transcripts.")}</small>
            </div>
          )}
          {step === 3 && (
            <div className="onboarding-step complete-step">
              <CheckCircle2 className="step-icon success-text" />
              <h1>{t("Ready to Go")}</h1>
              <p>
                {t("FileNest continues running in the system tray. You can pause watching or adjust rules at any time.")}
              </p>
              <div className="ready-summary">
                <span>
                  <strong>{snapshot.settings.watchDirs.length}</strong>{" "}
                  {t("Watched Folders")}
                </span>
                <span>
                  <strong>
                    {snapshot.settings.embeddingSource === "local"
                      ? "Local"
                      : "Ollama"}
                  </strong>{" "}
                  {t("Indexing Engine")}
                </span>
                <span>
                  <strong>
                    {snapshot.settings.autoOrganize ? "On" : "Off"}
                  </strong>{" "}
                  {t("Automatic Organization")}
                </span>
              </div>
            </div>
          )}
          <footer>
            <button
              className="secondary-button"
              disabled={step === 0}
              onClick={() => setStep((value) => value - 1)}
            >
              {t("Back")}
            </button>
            {step < 3 ? (
              <button
                className="primary-button"
                onClick={() => setStep((value) => value + 1)}
              >
                {t("Continue")}
              </button>
            ) : (
              <button className="primary-button" onClick={() => void finish()}>
                {t("Get Started")}
              </button>
            )}
          </footer>
        </main>
      </div>
    </div>
  );
}
