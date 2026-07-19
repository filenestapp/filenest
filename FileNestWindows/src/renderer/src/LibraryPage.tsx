import { useCallback, useEffect, useRef, useState } from "react";
import {
  ChevronLeft,
  ChevronRight,
  Eye,
  Files,
  FolderOpen,
  FolderPlus,
  MessageCircle,
  Pause,
  Play,
  RefreshCw,
  Search,
  Sparkles,
  Square,
  Trash2,
  WandSparkles,
} from "lucide-react";
import type {
  AppSnapshot,
  FileCategory,
  FileRecord,
  LibrarySearchResult,
  LibrarySortField,
  ReindexMode,
  SortDirection,
} from "../../shared/types";
import {
  categoryLabels,
  FileTypeIcon,
  formatBytes,
  formatDate,
  IconButton,
} from "./components";
import { translate } from "./i18n";

const PAGE_SIZE = 50;

export function LibraryPage({
  snapshot,
  externalSearch,
  onInspect,
  onStartChat,
  onRefresh,
}: {
  snapshot: AppSnapshot;
  externalSearch: { id: string; query: string; includeSemantic?: boolean } | null;
  onInspect(file: FileRecord): void;
  onStartChat(file: FileRecord): void;
  onRefresh(): Promise<void>;
}): React.JSX.Element {
  const t = (value: string): string => translate(value, snapshot.settings.appLanguage);
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState<FileCategory | null>(null);
  const [sortField, setSortField] = useState<LibrarySortField>("relevance");
  const [sortDirection, setSortDirection] = useState<SortDirection>("descending");
  const [offset, setOffset] = useState(0);
  const [results, setResults] = useState<LibrarySearchResult[]>([]);
  const [total, setTotal] = useState(0);
  const [interpretedQuery, setInterpretedQuery] = useState("");
  const [busy, setBusy] = useState(false);
  const [smartSearchEnabled, setSmartSearchEnabled] = useState(false);
  const [smartIntent, setSmartIntent] = useState("");
  const [searchError, setSearchError] = useState("");
  const [includeSemantic, setIncludeSemantic] = useState(true);
  const [duplicatesOpen, setDuplicatesOpen] = useState(false);
  const [selectedDuplicatePaths, setSelectedDuplicatePaths] = useState<Set<string>>(new Set());
  const [reindexOpen, setReindexOpen] = useState(false);
  const [reindexMode, setReindexMode] = useState<ReindexMode>("all");
  const [reindexCategories, setReindexCategories] = useState<Set<FileCategory>>(new Set());
  const activeSearchRequest = useRef<string | null>(null);
  const handledExternalSearch = useRef<string | null>(null);

  const search = useCallback(async (smart = false): Promise<void> => {
    const requestId = crypto.randomUUID();
    activeSearchRequest.current = requestId;
    setBusy(true);
    setSearchError("");
    try {
      const response = await window.fileNest.searchLibrary({
        query,
        smart,
        includeSemantic: smart || includeSemantic,
        requestId,
        category,
        sortField,
        sortDirection,
        offset,
        limit: PAGE_SIZE,
      });
      if (activeSearchRequest.current === requestId) {
        setResults(response.results);
        setTotal(response.total);
        setInterpretedQuery(response.interpretedQuery);
        setSmartIntent(response.intent ?? "");
        setSmartSearchEnabled(smart);
      }
    } catch (error) {
      if (activeSearchRequest.current === requestId) setSearchError(error instanceof Error ? error.message : String(error));
    } finally {
      if (activeSearchRequest.current === requestId) setBusy(false);
    }
  }, [category, includeSemantic, offset, query, sortDirection, sortField]);

  useEffect(() => {
    setSmartSearchEnabled(false);
    setSmartIntent("");
    const timer = window.setTimeout(() => void search(false), 250);
    return () => window.clearTimeout(timer);
  }, [search, snapshot.files]);
  useEffect(() => window.fileNest.onLibrarySearchProgress((event) => {
    if (event.requestId === activeSearchRequest.current) setSmartIntent(event.intent);
  }), []);
  useEffect(() => {
    if (!externalSearch || handledExternalSearch.current === externalSearch.id) return;
    handledExternalSearch.current = externalSearch.id;
    setCategory(null);
    setOffset(0);
    setIncludeSemantic(externalSearch.includeSemantic !== false);
    setQuery(externalSearch.query);
    void window.fileNest.consumeLibrarySearch(externalSearch.id);
  }, [externalSearch]);
  useEffect(() => {
    if (!duplicatesOpen) return;
    setSelectedDuplicatePaths(new Set(snapshot.duplicateFileGroups.flatMap((group) => group.duplicateFiles.map((file) => file.path))));
  }, [duplicatesOpen, snapshot.duplicateFileGroups]);

  const run = async (action: () => Promise<void>): Promise<void> => {
    setBusy(true);
    try {
      await action();
      await onRefresh();
      await search(smartSearchEnabled);
    } finally {
      setBusy(false);
    }
  };

  const setFilterCategory = (next: FileCategory | null): void => {
    setCategory(next);
    setOffset(0);
  };

  const organizeSelectedFolders = async (): Promise<void> => {
    const directories = await window.fileNest.chooseOrganizationDirectories();
    if (!directories.length) return;
    const recursively = confirm(t("Include subfolders? Click OK to include nested folders, or Cancel to process the selected folders only."));
    if (!confirm(t("Organize files in selected folders? These folders will not be added to monitoring."))) return;
    await run(() => window.fileNest.organizeDirectoriesOnce(directories, recursively));
  };

  return (
    <main className="library-page">
      <header className="page-header">
        <div>
          <h1>{t("Library")}</h1>
          <p>{t("Search and manage organized files; all indexes stay on this PC.")}</p>
        </div>
        <div className="page-actions">
          <button className="primary-button" disabled={busy || snapshot.organizing} onClick={() => void run(() => window.fileNest.organizeNow())}>
            <WandSparkles size={17} />
            {t("Organize Now")}
          </button>
          <button className="secondary-button" disabled={busy || snapshot.organizing} onClick={() => void organizeSelectedFolders()}>
            <FolderPlus size={17} />
            {t("Choose Folders to Organize…")}
          </button>
          {snapshot.organizing && <>
            <IconButton label={snapshot.organizationPaused ? t("Resume Organization") : t("Pause Organization")} onClick={() => void (snapshot.organizationPaused ? window.fileNest.resumeOrganization() : window.fileNest.pauseOrganization()).then(onRefresh)}>{snapshot.organizationPaused ? <Play size={17} /> : <Pause size={17} />}</IconButton>
            <IconButton label={t("Stop Organization")} onClick={() => void window.fileNest.cancelOrganization().then(onRefresh)}><Square size={15} /></IconButton>
          </>}
          <button className="secondary-button" disabled={busy || snapshot.indexing} onClick={() => setReindexOpen(true)}>
            <RefreshCw className={snapshot.indexing ? "spin" : ""} size={17} />
            {t("Reindex")}
          </button>
          <button className="secondary-button" disabled={busy || snapshot.duplicateScanProgress != null || snapshot.duplicateTrashProgress != null} onClick={() => setDuplicatesOpen(true)}>
            <Files size={17} /> {t("Find Duplicates")}
          </button>
          {snapshot.indexing && (
            <>
              <IconButton
                label={snapshot.indexingPaused ? "Resume Indexing" : "Pause Indexing"}
                onClick={() => void (snapshot.indexingPaused ? window.fileNest.resumeIndexing() : window.fileNest.pauseIndexing()).then(onRefresh)}
              >
                {snapshot.indexingPaused ? <Play size={17} /> : <Pause size={17} />}
              </IconButton>
              <IconButton label="Stop Indexing" onClick={() => void window.fileNest.cancelIndexing().then(onRefresh)}>
                <Square size={15} />
              </IconButton>
            </>
          )}
        </div>
      </header>
      {snapshot.indexingProgress && (
        <div className="progress-bar">
          <div style={{ width: `${snapshot.indexingProgress.total ? (snapshot.indexingProgress.completed / snapshot.indexingProgress.total) * 100 : 0}%` }} />
          <span>
            {snapshot.indexingProgress.stage}: {snapshot.indexingProgress.currentName} · {snapshot.indexingProgress.completed}/{snapshot.indexingProgress.total}
            {snapshot.indexingProgress.failed ? ` · ${snapshot.indexingProgress.failed} failed` : ""}
          </span>
        </div>
      )}
      <div className="library-toolbar">
        <div className="search-box">
          <Search size={17} />
          <input
            value={query}
            onChange={(event) => { setIncludeSemantic(true); setQuery(event.target.value); }}
            onKeyDown={(event) => {
              if (event.key === "Enter") { setOffset(0); void search(false); }
            }}
            placeholder={t("Search names, contents, notes, or dates such as 'last week'…")}
          />
          <button onClick={() => { setOffset(0); void search(false); }}>{t("Search")}</button>
        </div>
        <div className="category-filters">
          <button className={category === null ? "selected" : ""} onClick={() => setFilterCategory(null)}>{t("All")}</button>
          {(Object.keys(categoryLabels) as FileCategory[]).map((item) => (
            <button key={item} className={category === item ? "selected" : ""} onClick={() => setFilterCategory(item)}>
              {t(categoryLabels[item])}
            </button>
          ))}
          <select
            aria-label={t("Sort files")}
            value={`${sortField}:${sortDirection}`}
            onChange={(event) => {
              const [field, direction] = event.target.value.split(":") as [LibrarySortField, SortDirection];
              setSortField(field);
              setSortDirection(direction);
              setOffset(0);
            }}
          >
            <option value="relevance:descending">{t("Best match")}</option>
            <option value="modified:descending">{t("Newest modified")}</option>
            <option value="modified:ascending">{t("Oldest modified")}</option>
            <option value="size:descending">{t("Largest size")}</option>
            <option value="size:ascending">{t("Smallest size")}</option>
            <option value="name:ascending">{t("Name A–Z")}</option>
            <option value="name:descending">{t("Name Z–A")}</option>
          </select>
        </div>
        {interpretedQuery && interpretedQuery !== query.trim() && (
          <small className="query-interpretation">{t("Interpreted as")}: {interpretedQuery}</small>
        )}
        {searchError && <small className="search-error">{searchError}</small>}
        {query.trim() && !smartSearchEnabled && !busy && (
          <div className="smart-search-suggestion">
            <Sparkles size={16} />
            <span><strong>{t("Not finding what you need?")}</strong><small>{t("Smart Search uses AI to understand your request more precisely and may take a little longer.")}</small></span>
            <button onClick={() => void search(true)}>{t("Try Smart Search")}</button>
          </div>
        )}
        {smartSearchEnabled && smartIntent && <div className="smart-search-intent"><Sparkles size={14} /><span>{smartIntent}</span></div>}
      </div>
      <div className="file-table" role="table">
        <div className="file-table-header" role="row">
          <span>{t("Name")}</span><span>{t("Category")}</span><span>{t("Size")}</span><span>{t("Modified")}</span><span>{t("Actions")}</span>
        </div>
        <div className="file-table-body">
          {results.length === 0 ? (
            <div className="empty-library">
              <FolderOpen size={38} /><strong>{t("No Files Found")}</strong><span>{t("Adjust the search criteria or place files in a watched folder.")}</span>
            </div>
          ) : results.map(({ file, matchKind, snippet, confidence }) => (
            <div key={file.id} className="file-row" role="row" onDoubleClick={() => void window.fileNest.openFile(file.path)}>
              <div className="file-name-cell">
                <FileTypeIcon file={file} size={22} />
                <div>
                  <strong>{file.name}</strong>
                  <span>{snippet || file.title || file.path}</span>
                </div>
                {file.indexedAt && <small>● {t(matchKind)} · {t("Confidence")} {Math.round(Math.min(1, Math.max(0, confidence)) * 100)}%</small>}
              </div>
              <span>{t(categoryLabels[file.category])}</span>
              <span>{formatBytes(file.size)}</span>
              <span>{formatDate(file.mtime, snapshot.settings.appLanguage)}</span>
              <div className="row-actions">
                <IconButton label={t("File Preview")} onClick={() => onInspect(file)}><Eye size={16} /></IconButton>
                {(file.category === "documents" || snapshot.settings.mediaTranscriptionEnabled && (file.category === "audio" || file.category === "videos")) && <IconButton label={t("Find with Chat")} onClick={() => onStartChat(file)}><MessageCircle size={16} /></IconButton>}
                <IconButton label={t("Show in File Explorer")} onClick={() => void window.fileNest.showInExplorer(file.path)}><FolderOpen size={16} /></IconButton>
                <IconButton label={t("Move to Recycle Bin")} onClick={() => { if (confirm(`${file.name}?`)) void window.fileNest.trashFile(file.id).then(onRefresh); }}><Trash2 size={16} /></IconButton>
              </div>
            </div>
          ))}
        </div>
      </div>
      {total > PAGE_SIZE && (
        <div className="library-pagination">
          <button disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - PAGE_SIZE))}><ChevronLeft size={16} /> {t("Previous")}</button>
          <span>{offset + 1}–{Math.min(offset + PAGE_SIZE, total)} / {total}</span>
          <button disabled={offset + PAGE_SIZE >= total} onClick={() => setOffset(offset + PAGE_SIZE)}>{t("Next")} <ChevronRight size={16} /></button>
        </div>
      )}
      {reindexOpen && <ReindexDialog language={snapshot.settings.appLanguage} mode={reindexMode} categories={reindexCategories} onMode={setReindexMode} onCategories={setReindexCategories} onClose={() => setReindexOpen(false)} onStart={(mode, categories) => { setReindexOpen(false); void run(() => window.fileNest.reindexAll(mode, categories)); }} />}
      {duplicatesOpen && <DuplicateDialog snapshot={snapshot} selectedPaths={selectedDuplicatePaths} onSelectedPaths={setSelectedDuplicatePaths} onClose={() => setDuplicatesOpen(false)} onRefresh={onRefresh} />}
    </main>
  );
}

function ReindexDialog({ language, mode, categories, onMode, onCategories, onClose, onStart }: {
  language: AppSnapshot["settings"]["appLanguage"];
  mode: ReindexMode;
  categories: Set<FileCategory>;
  onMode(value: ReindexMode): void;
  onCategories(value: Set<FileCategory>): void;
  onClose(): void;
  onStart(mode: ReindexMode, categories: FileCategory[]): void;
}): React.JSX.Element {
  const t = (value: string): string => translate(value, language);
  return <div className="modal-backdrop" role="presentation" onMouseDown={onClose}>
    <section className="modal-card" role="dialog" aria-modal="true" aria-label={t("Reindex Library")} onMouseDown={(event) => event.stopPropagation()}>
      <header><div><h2>{t("Reindex Library")}</h2><p>{t("Rebuild all files or limit the operation to selected file types.")}</p></div><button className="icon-button" onClick={onClose}>×</button></header>
      <label className="field-label">{t("Reindex Mode")}<select value={mode} onChange={(event) => onMode(event.target.value as ReindexMode)}><option value="all">{t("Full content and vector index")}</option><option value="unindexed">{t("Unindexed files only")}</option><option value="embeddings">{t("Embeddings only")}</option><option value="media">{t("Affected media only")}</option></select></label>
      <fieldset className="scope-grid" disabled={mode === "embeddings"}><legend>{t("Limit Reindex to File Types")}</legend>{(Object.keys(categoryLabels) as FileCategory[]).map((item) => <label key={item}><input type="checkbox" checked={categories.has(item)} onChange={(event) => { const next = new Set(categories); event.target.checked ? next.add(item) : next.delete(item); onCategories(next); }} />{t(categoryLabels[item])}</label>)}<small>{categories.size ? [...categories].map((item) => t(categoryLabels[item])).join(", ") : t("All file types")}</small></fieldset>
      <footer><button className="secondary-button" onClick={onClose}>{t("Cancel")}</button><button className="primary-button" onClick={() => onStart(mode, mode === "embeddings" ? [] : [...categories])}>{t("Start Reindex")}</button></footer>
    </section>
  </div>;
}

function DuplicateDialog({ snapshot, selectedPaths, onSelectedPaths, onClose, onRefresh }: {
  snapshot: AppSnapshot;
  selectedPaths: Set<string>;
  onSelectedPaths(value: Set<string>): void;
  onClose(): void;
  onRefresh(): Promise<void>;
}): React.JSX.Element {
  const t = (value: string): string => translate(value, snapshot.settings.appLanguage);
  const progress = snapshot.duplicateScanProgress;
  return <div className="modal-backdrop" role="presentation" onMouseDown={onClose}>
    <section className="modal-card duplicate-manager" role="dialog" aria-modal="true" aria-label={t("Duplicate Files")} onMouseDown={(event) => event.stopPropagation()}>
      <header><div><h2>{t("Duplicate Files")}</h2><p>{t("Files are compared by SHA-256 content. The oldest copy is always kept.")}</p></div><button className="icon-button" onClick={onClose}>×</button></header>
      {progress && <div className="progress-bar"><div style={{ width: `${progress.totalCount ? progress.scannedCount / progress.totalCount * 100 : 0}%` }} /><span>{t("Scanning files")} · {progress.scannedCount}/{progress.totalCount}</span></div>}
      {snapshot.duplicateScanError && <p className="search-error">{snapshot.duplicateScanError}</p>}
      <div className="duplicate-toolbar"><button className="secondary-button" disabled={progress != null} onClick={() => void window.fileNest.scanDuplicateFiles().then(onRefresh)}><RefreshCw className={progress ? "spin" : ""} size={15} />{t(snapshot.duplicateFileGroups.length ? "Rescan" : "Scan Now")}</button><span>{snapshot.duplicateFileGroups.length} {t("groups")} · {formatBytes(snapshot.duplicateFileGroups.reduce((sum, group) => sum + group.reclaimableBytes, 0))} {t("reclaimable")}</span></div>
      <div className="duplicate-list">{!progress && !snapshot.duplicateFileGroups.length && <div className="empty-library"><Files size={34} /><strong>{t("No Duplicate Files Found")}</strong><span>{t("Run a scan to compare the current bytes of every file.")}</span></div>}{snapshot.duplicateFileGroups.map((group) => <article className="duplicate-group" key={group.contentHash}><header><strong>{group.retainedFile.name}</strong><span>{formatBytes(group.reclaimableBytes)} {t("reclaimable")}</span></header>{group.files.map((file, index) => <label key={file.path} className={index === 0 ? "retained-file" : "duplicate-file"}><input type="checkbox" disabled={index === 0} checked={index === 0 ? false : selectedPaths.has(file.path)} onChange={(event) => { const next = new Set(selectedPaths); event.target.checked ? next.add(file.path) : next.delete(file.path); onSelectedPaths(next); }} /><FileTypeIcon file={file} size={18} /><span><strong>{file.name}</strong><small>{file.path}</small></span><em>{t(index === 0 ? "Keep" : "Duplicate copy")}</em></label>)}</article>)}</div>
      <footer><button className="secondary-button" onClick={onClose}>{t("Close")}</button><button className="danger-button" disabled={!selectedPaths.size || snapshot.duplicateTrashProgress != null} onClick={() => { if (!confirm(t("Move the selected duplicate copies to the Recycle Bin? The kept originals will not be removed."))) return; void window.fileNest.trashDuplicateFiles([...selectedPaths]).then(async (result) => { if (result.failedFileNames.length) alert(`${t("Some files could not be removed")}: ${result.failedFileNames.join(", ")}`); await onRefresh(); }); }}><Trash2 size={15} />{snapshot.duplicateTrashProgress ? `${snapshot.duplicateTrashProgress.completedCount}/${snapshot.duplicateTrashProgress.totalCount}` : t("Move Duplicates to Recycle Bin")}</button></footer>
    </section>
  </div>;
}
