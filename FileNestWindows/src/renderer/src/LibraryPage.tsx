import { useEffect, useState } from "react";
import {
  Eye,
  FolderOpen,
  MessageCircle,
  Pause,
  Play,
  RefreshCw,
  Search,
  Square,
  Trash2,
  WandSparkles,
} from "lucide-react";
import type { AppSnapshot, FileCategory, FileRecord } from "../../shared/types";
import {
  categoryLabels,
  FileTypeIcon,
  formatBytes,
  formatDate,
  IconButton,
} from "./components";
import { translate } from "./i18n";

export function LibraryPage({
  snapshot,
  onInspect,
  onStartChat,
  onRefresh,
}: {
  snapshot: AppSnapshot;
  onInspect(file: FileRecord): void;
  onStartChat(file: FileRecord): void;
  onRefresh(): Promise<void>;
}): React.JSX.Element {
  const t = (value: string): string =>
    translate(value, snapshot.settings.appLanguage);
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<FileCategory | null>(null);
  const [files, setFiles] = useState(snapshot.files);
  const [busy, setBusy] = useState(false);
  useEffect(() => setFiles(snapshot.files), [snapshot.files]);
  const search = async (): Promise<void> =>
    setFiles(await window.fileNest.searchFiles(query, category));
  useEffect(() => {
    void search();
  }, [category]);
  const run = async (action: () => Promise<void>): Promise<void> => {
    setBusy(true);
    try {
      await action();
      await onRefresh();
    } finally {
      setBusy(false);
    }
  };
  return (
    <main className="library-page">
      <header className="page-header">
        <div>
          <h1>{t("Library")}</h1>
          <p>Search and manage organized files; all indexes stay on this Mac.</p>
        </div>
        <div className="page-actions">
          <button
            className="primary-button"
            disabled={busy}
            onClick={() => void run(() => window.fileNest.organizeNow())}
          >
            <WandSparkles size={17} />
            {t("Organize Now")}
          </button>
          <button
            className="secondary-button"
            disabled={busy || snapshot.indexing}
            onClick={() => void run(() => window.fileNest.reindexAll())}
          >
            <RefreshCw className={snapshot.indexing ? "spin" : ""} size={17} />
            {t("Reindex")}
          </button>
          {snapshot.indexing && (
            <>
              <IconButton
                label={snapshot.indexingPaused ? "Resume Indexing" : "Pause Indexing"}
                onClick={() =>
                  void (snapshot.indexingPaused
                    ? window.fileNest.resumeIndexing()
                    : window.fileNest.pauseIndexing()
                  ).then(onRefresh)
                }
              >
                {snapshot.indexingPaused ? <Play size={17} /> : <Pause size={17} />}
              </IconButton>
              <IconButton
                label="Stop Indexing"
                onClick={() => void window.fileNest.cancelIndexing().then(onRefresh)}
              >
                <Square size={15} />
              </IconButton>
            </>
          )}
        </div>
      </header>
      {snapshot.indexingProgress && (
        <div className="progress-bar">
          <div
            style={{
              width: `${snapshot.indexingProgress.total ? (snapshot.indexingProgress.completed / snapshot.indexingProgress.total) * 100 : 0}%`,
            }}
          />
          <span>{snapshot.indexingProgress.currentName}</span>
        </div>
      )}
      <div className="library-toolbar">
        <div className="search-box">
          <Search size={17} />
          <input
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") void search();
            }}
            placeholder="Search file names, titles, or contents…"
          />
          <button onClick={() => void search()}>{t("Search")}</button>
        </div>
        <div className="category-filters">
          <button
            className={category === null ? "selected" : ""}
            onClick={() => setCategory(null)}
          >
            {t("All")}
          </button>
          {(Object.keys(categoryLabels) as FileCategory[]).map((item) => (
            <button
              key={item}
              className={category === item ? "selected" : ""}
              onClick={() => setCategory(item)}
            >
              {t(categoryLabels[item])}
            </button>
          ))}
        </div>
      </div>
      <div className="file-table" role="table">
        <div className="file-table-header" role="row">
          <span>{t("Name")}</span>
          <span>{t("Category")}</span>
          <span>{t("Size")}</span>
          <span>{t("Modified")}</span>
          <span>{t("Actions")}</span>
        </div>
        <div className="file-table-body">
          {files.length === 0 ? (
            <div className="empty-library">
              <FolderOpen size={38} />
              <strong>{t("No Files Found")}</strong>
              <span>Adjust the search criteria or place files in a watched folder.</span>
            </div>
          ) : (
            files.map((file) => (
              <div
                key={file.id}
                className="file-row"
                role="row"
                onDoubleClick={() => void window.fileNest.openFile(file.path)}
              >
                <div className="file-name-cell">
                  <FileTypeIcon file={file} size={22} />
                  <div>
                    <strong>{file.name}</strong>
                    <span>{file.title ?? file.path}</span>
                  </div>
                  {file.indexedAt && <small>● {t("Indexed")}</small>}
                </div>
                <span>{t(categoryLabels[file.category])}</span>
                <span>{formatBytes(file.size)}</span>
                <span>
                  {formatDate(file.mtime, snapshot.settings.appLanguage)}
                </span>
                <div className="row-actions">
                  <IconButton
                    label={t("File Preview")}
                    onClick={() => onInspect(file)}
                  >
                    <Eye size={16} />
                  </IconButton>
                  {file.category === "documents" && (
                    <IconButton
                      label={t("Find with Chat")}
                      onClick={() => onStartChat(file)}
                    >
                      <MessageCircle size={16} />
                    </IconButton>
                  )}
                  <IconButton
                    label={t("Show in File Explorer")}
                    onClick={() =>
                      void window.fileNest.showInExplorer(file.path)
                    }
                  >
                    <FolderOpen size={16} />
                  </IconButton>
                  <IconButton
                    label="Move to Recycle Bin"
                    onClick={() => {
                      if (confirm(`${file.name}?`))
                        void window.fileNest.trashFile(file.id).then(onRefresh);
                    }}
                  >
                    <Trash2 size={16} />
                  </IconButton>
                </div>
              </div>
            ))
          )}
        </div>
      </div>
    </main>
  );
}
