import { useState } from "react";
import {
  Bot,
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
  const t = (value: string): string =>
    translate(value, snapshot.settings.appLanguage);
  const update = (patch: Partial<Settings>): Promise<Settings> =>
    window.fileNest.updateSettings(patch);
  const finish = async (): Promise<void> => {
    await update({ onboardingCompleted: true });
    if (organizeExisting) await window.fileNest.scanExisting();
    await window.fileNest.startWatching();
    await onComplete();
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
                {label}
              </li>
            ))}
          </ol>
          <div className="privacy-note">
            <LockKeyhole size={18} />
            <span>
              Local First
              <br />
              Your Files Stay Under Your Control
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
                Automatically organize files, build a local index, and retrieve content quickly with natural language.
              </p>
              <ul>
                <li>
                  <ShieldCheck />
                  The index stays on this PC by default
                </li>
                <li>
                  <Sparkles />
                  Supports local Ollama and cloud APIs
                </li>
                <li>
                  <FolderPlus />
                  The system tray continuously watches for new files
                </li>
              </ul>
            </div>
          )}
          {step === 1 && (
            <div className="onboarding-step">
              <FolderPlus className="step-icon" />
              <h1>{t("Choose Folders to Manage")}</h1>
              <p>Downloads is watched by default. You can add Desktop, Documents, or work folders.</p>
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
                Index and organize existing files immediately
              </label>
            </div>
          )}
          {step === 2 && (
            <div className="onboarding-step">
              <Bot className="step-icon" />
              <h1>{t("Configure Local AI")}</h1>
              <p>
                A lightweight local index requiring no download is used by default. Install Ollama
                for stronger multilingual semantic search and complete answers.
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
                  <span>Ready to use · Offline · Low resource usage</span>
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
                  <span>Stronger semantic search and local chat</span>
                </button>
              </div>
              <button
                className="text-action"
                onClick={() => void window.fileNest.installOllama()}
              >
                Download Ollama for Windows
              </button>
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
                  : "Install Docling Document Parsing (Optional)"}
              </button>
            </div>
          )}
          {step === 3 && (
            <div className="onboarding-step complete-step">
              <CheckCircle2 className="step-icon success-text" />
              <h1>{t("Ready to Go")}</h1>
              <p>
                FileNest continues running in the system tray. You can pause watching or adjust rules at any time.
              </p>
              <div className="ready-summary">
                <span>
                  <strong>{snapshot.settings.watchDirs.length}</strong>{" "}
                  itemsWatched Folders
                </span>
                <span>
                  <strong>
                    {snapshot.settings.embeddingSource === "local"
                      ? "Local"
                      : "Ollama"}
                  </strong>{" "}
                  Indexing Engine
                </span>
                <span>
                  <strong>
                    {snapshot.settings.autoOrganize ? "On" : "Off"}
                  </strong>{" "}
                  Automatic Organization
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
