import { useCallback, useEffect, useRef, useState } from "react";
import {
  ChevronLeft,
  ChevronRight,
  Eye,
  FolderOpen,
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
  externalSearch: { id: string; query: string } | null;
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
  }, [category, offset, query, sortDirection, sortField]);

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
    setQuery(externalSearch.query);
    void window.fileNest.consumeLibrarySearch(externalSearch.id);
  }, [externalSearch]);

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

  return (
    <main className="library-page">
      <header className="page-header">
        <div>
          <h1>{t("Library")}</h1>
          <p>{t("Search and manage organized files; all indexes stay on this PC.")}</p>
        </div>
        <div className="page-actions">
          <button className="primary-button" disabled={busy} onClick={() => void run(() => window.fileNest.organizeNow())}>
            <WandSparkles size={17} />
            {t("Organize Now")}
          </button>
          <button className="secondary-button" disabled={busy || snapshot.indexing} onClick={() => void run(() => window.fileNest.reindexAll())}>
            <RefreshCw className={snapshot.indexing ? "spin" : ""} size={17} />
            {t("Reindex")}
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
            onChange={(event) => setQuery(event.target.value)}
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
                {file.category === "documents" && <IconButton label={t("Find with Chat")} onClick={() => onStartChat(file)}><MessageCircle size={16} /></IconButton>}
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
    </main>
  );
}
