import { useEffect, useRef, useState } from "react";
import { ArrowRight, Search } from "lucide-react";
import type { AppLanguage } from "../../shared/types";
import { translate } from "./i18n";

export function QuickSearchPanel({ language }: { language: AppLanguage }): React.JSX.Element {
  const [query, setQuery] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const t = (value: string): string => translate(value, language);
  const submit = async (): Promise<void> => {
    const value = query.trim();
    if (!value) return;
    await window.fileNest.submitQuickSearch(value);
    setQuery("");
  };
  useEffect(() => {
    document.body.classList.add("quick-search-body");
    const unsubscribe = window.fileNest.onQuickSearchFocus(() => {
      setQuery("");
      window.setTimeout(() => inputRef.current?.focus(), 0);
    });
    return () => {
      document.body.classList.remove("quick-search-body");
      unsubscribe();
    };
  }, []);
  return (
    <main className="quick-search-panel" onKeyDown={(event) => {
      if (event.key === "Escape") window.close();
    }}>
      <div className="quick-search-box">
        <Search size={20} />
        <input
          ref={inputRef}
          autoFocus
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={(event) => { if (event.key === "Enter") void submit(); }}
          placeholder={t("Search file names, titles, or contents…")}
        />
        <button disabled={!query.trim()} aria-label={t("Search")} onClick={() => void submit()}><ArrowRight size={17} /></button>
      </div>
      <footer><strong>{t("Search FileNest")}</strong><span>{t("Press Enter to search · Esc to close")}</span></footer>
    </main>
  );
}
