function FileNestFileIcon({ type = "pdf", size = 34 }) {
  const labels = { pdf: "P", word: "W", slides: "S", sheet: "X" };
  return (
    <span className={`file-icon file-icon--${type}`} style={{ width: size, height: size + 6 }}>
      <span>{labels[type] || "F"}</span>
    </span>
  );
}

function FileNestTrafficLights() {
  return (
    <span className="traffic-lights" aria-hidden="true">
      <i></i><i></i><i></i>
    </span>
  );
}

function FileNestSidebar({ mode }) {
  const libraryActive = ["indexing", "search", "smart"].includes(mode);
  const chatActive = !libraryActive;
  return (
    <aside className="native-sidebar">
      <div className="native-sidebar__chrome">
        <FileNestTrafficLights />
        <span className="sidebar-toggle">▤</span>
      </div>
      <div className="native-brand">
        <img src="assets/app-icon.png" alt="" />
        <strong>FileNest</strong>
      </div>
      <nav className="native-nav" aria-label="FileNest prototype navigation">
        <button className={libraryActive ? "is-selected" : ""} type="button"><span>▱</span>Library</button>
        <button className={chatActive ? "is-selected" : ""} type="button"><span>◌</span>Find with Chat</button>
      </nav>
      <div className="recent-label"><span>Recent</span><span>□</span></div>
      <div className="recent-list">
        <span className={mode === "find-chat" ? "is-selected" : ""}>▢ Find the launch research</span>
        <span className={mode === "file-chat" ? "is-selected" : ""}>▧ Chat with Aurora brief</span>
        <span>▢ Recently modified PDFs</span>
        <span>▢ Organize launch materials</span>
        <span>▢ Customer meeting notes</span>
        <span>▢ Project archive materials</span>
      </div>
      <div className="sidebar-status">
        <span title="Watching folders">▱</span>
        <span className={mode === "indexing" ? "is-active is-spinning" : "is-ready"} title="Index status">↻</span>
        <span className="is-ai-ready" title="Local AI">◉</span>
        <span className="status-spacer"></span>
        <span title="Settings">⚙</span>
      </div>
    </aside>
  );
}

function FileNestPageHeader({ mode }) {
  const workflow = fileNestWorkflowData.find((item) => item.id === mode);
  const fileChat = mode === "file-chat";
  return (
    <header className="native-page-header">
      <div>
        <h2>{workflow.title}</h2>
        <p>{workflow.subtitle}</p>
      </div>
      <div className="native-header-actions">
        {fileChat && <button type="button">‹&nbsp; Back</button>}
        {!fileChat && ["indexing", "search", "smart"].includes(mode) && <button className="native-primary" type="button">Organize Now</button>}
        {!["indexing", "search", "smart"].includes(mode) && <button type="button">□&nbsp; New Chat</button>}
        {["indexing", "search", "smart"].includes(mode) && <button type="button">↻&nbsp; Reindex</button>}
      </div>
    </header>
  );
}

function FileNestSearchBar({ query, smart = false, loading = false }) {
  return (
    <div className={`library-search ${smart ? "is-smart" : ""}`}>
      <span className={loading ? "search-spinner" : "search-icon"}>{loading ? "" : "⌕"}</span>
      <span className="search-query">{query || "Search file names, titles, or contents…"}</span>
      {query && <span className="search-clear">×</span>}
      <button type="button">All Files&nbsp;⌄</button>
      <button type="button">Modified&nbsp;⌄</button>
    </div>
  );
}

function FileNestFileRow({ file, selected = false }) {
  return (
    <div className={`library-row ${selected ? "is-selected" : ""}`}>
      <FileNestFileIcon type={file.type} size={34} />
      <span className="library-file-name">
        <strong>{file.name}</strong>
        <small>{file.path}</small>
      </span>
      <span className="confidence-badge">{file.confidence}</span>
      <span className="library-category">{file.category}</span>
      <span className="library-size">{file.size}</span>
      <span className="library-modified">{file.modified}</span>
      <span className="library-actions"><button type="button">▧</button><button type="button">▱</button><button type="button">⌫</button></span>
    </div>
  );
}

function FileNestLibraryTable({ files, selectedIndex = 0 }) {
  return (
    <div className="library-table">
      <div className="library-table__head">
        <span>Name</span><span>Category</span><span>Size</span><span>Modified</span><span>Actions</span>
      </div>
      {files.map((file, index) => <FileNestFileRow file={file} selected={index === selectedIndex} key={file.name} />)}
    </div>
  );
}

function FileNestIndexingView({ phase }) {
  const progress = [18, 46, 78, 100][phase] || 18;
  return (
    <div className="native-content library-content">
      <div className="processing-banner">
        <div className="processing-banner__top">
          <span className="index-symbol">↻</span>
          <span><strong>Indexing Project Aurora</strong><small>{phase < 3 ? "Extracting content and creating local vectors" : "Indexing complete"}</small></span>
          <span>{phase < 3 ? `${Math.min(12, phase * 4 + 2)} of 12` : "12 of 12"}</span>
        </div>
        <div className="native-progress"><span style={{ transform: `scaleX(${progress / 100})` }}></span></div>
        <div className="processing-files">
          <span className={phase >= 1 ? "is-complete" : "is-current"}>Aurora Product Brief.pdf <b>{phase >= 1 ? "Ready" : "Extracting text"}</b></span>
          <span className={phase >= 2 ? "is-complete" : phase === 1 ? "is-current" : ""}>Customer Research Synthesis.docx <b>{phase >= 2 ? "Ready" : "Creating embeddings"}</b></span>
          <span className={phase >= 3 ? "is-complete" : phase === 2 ? "is-current" : ""}>Launch Budget.xlsx <b>{phase >= 3 ? "Ready" : "Reading tables"}</b></span>
        </div>
      </div>
      <FileNestSearchBar />
      <FileNestLibraryTable files={fileNestMockFiles.slice(0, 3)} selectedIndex={-1} />
    </div>
  );
}

function FileNestSearchView({ phase }) {
  const files = phase >= 1 ? fileNestMockFiles.filter((file) => file.name.includes("Aurora") || file.name.includes("Launch")) : [];
  return (
    <div className="native-content library-content">
      <FileNestSearchBar query="Aurora launch plan" loading={phase === 0} />
      <div className="result-summary"><span>{phase === 0 ? "Searching names, titles, and file contents…" : `${files.length} files · File Keywords + Vector Semantic Ranking`}</span><button type="button">Search History</button></div>
      {phase === 0 ? <div className="native-empty"><span className="search-spinner"></span><p>Searching the private index</p></div> : <FileNestLibraryTable files={files} selectedIndex={0} />}
    </div>
  );
}

function FileNestSmartSearchView({ phase }) {
  return (
    <div className="native-content library-content">
      <FileNestSearchBar query="The deck from our spring offsite about Aurora pricing" smart loading={phase === 0} />
      <div className="smart-plan">
        <span className="smart-plan__icon">✦</span>
        <span><strong>{phase === 0 ? "AI is analyzing the search criteria" : "Smart Search plan"}</strong><small>{phase === 0 ? "Creating precise retrieval conditions on this Mac" : "Semantic: Aurora pricing · Type: Presentation · Dates: Mar–May 2026"}</small></span>
        <span className="local-pill">Local AI</span>
      </div>
      {phase < 2 ? <div className="native-empty"><span className="search-spinner"></span><p>{phase === 0 ? "Understanding your request" : "Searching the local index"}</p></div> : <FileNestLibraryTable files={[fileNestMockFiles[2], fileNestMockFiles[0]]} selectedIndex={0} />}
    </div>
  );
}

function FileNestMatchedCard({ file, best = false }) {
  return (
    <div className={`matched-card ${best ? "is-best" : ""}`}>
      <FileNestFileIcon type={file.type} size={28} />
      <span><strong>{file.name}</strong><small>{best ? "✦ Best Match" : file.category} · {file.size}</small></span>
      <button type="button">▧</button><button type="button">◉</button>
    </div>
  );
}

function FileNestChatProgress({ phase }) {
  const steps = [
    "AI is analyzing the search criteria",
    "Searching the local index",
    "Matched 3 related files",
    "AI is analyzing and organizing the answer",
  ];
  return (
    <div className="chat-progress-steps">
      {steps.slice(0, Math.min(4, phase + 2)).map((step, index) => (
        <span key={step} className={index < phase + 1 ? "is-complete" : "is-current"}><i>{index < phase + 1 ? "✓" : ""}</i>{step}</span>
      ))}
    </div>
  );
}

function FileNestFindChatView({ phase }) {
  return (
    <div className="native-content chat-content">
      <div className="chat-message chat-message--user">
        <span className="chat-avatar chat-avatar--you">You</span>
        <div><strong>You</strong><p>Find the research that changed our onboarding plan.</p><small>11:26 AM</small></div>
      </div>
      <div className="chat-divider"></div>
      <div className="chat-message chat-message--assistant">
        <img className="chat-avatar" src="assets/brand-mark.png" alt="" />
        <div><strong>FileNest</strong><FileNestChatProgress phase={phase} />
          {phase >= 1 && <div className="matched-strip"><FileNestMatchedCard file={fileNestMockFiles[1]} best /><FileNestMatchedCard file={fileNestMockFiles[0]} /></div>}
          {phase >= 3 && <p className="assistant-answer">These files connect the customer research findings to the revised onboarding flow. The synthesis is the primary source; the product brief records the resulting decision.</p>}
        </div>
      </div>
      <div className="chat-composer"><span>Ask about your files…</span><button type="button">↑</button></div>
    </div>
  );
}

function FileNestFileChatView({ phase }) {
  return (
    <div className="native-content chat-content">
      <div className="chat-message chat-message--user">
        <span className="chat-avatar chat-avatar--you">You</span>
        <div><strong>You</strong><p>What are the launch risks, and who owns each one?</p><small>11:26 AM</small></div>
      </div>
      <div className="chat-divider"></div>
      <div className="chat-message chat-message--assistant">
        <img className="chat-avatar" src="assets/brand-mark.png" alt="" />
        <div><strong>FileNest</strong>
          {phase === 0 && <div className="chat-progress-steps"><span className="is-current"><i></i>Searching the current file index</span></div>}
          {phase >= 1 && <div className="file-answer"><p>The brief identifies three launch risks:</p><ol><li><strong>Enterprise migration readiness</strong><span>Owner: Maya Chen · Product</span><button type="button">p. 9</button></li><li><strong>Support coverage during rollout</strong><span>Owner: Leo Martin · Customer Success</span><button type="button">p. 12</button></li><li><strong>Pricing page dependencies</strong><span>Owner: Priya Shah · Growth</span><button type="button">p. 14</button></li></ol></div>}
        </div>
      </div>
      <div className="attached-file"><FileNestFileIcon type="pdf" size={24} /><span><strong>Aurora Product Brief.pdf</strong><small>Chatting with this file</small></span><button type="button">×</button></div>
    </div>
  );
}

function FileNestNativeWindow({ mode, phase = 0, scale = 1 }) {
  const views = {
    indexing: <FileNestIndexingView phase={phase} />,
    search: <FileNestSearchView phase={phase} />,
    smart: <FileNestSmartSearchView phase={phase} />,
    "find-chat": <FileNestFindChatView phase={phase} />,
    "file-chat": <FileNestFileChatView phase={phase} />,
  };
  return (
    <div className="native-window-scale" style={{ width: 1120 * scale, height: 680 * scale }}>
      <div className={`native-window native-mode-${mode} native-phase-${phase}`} style={{ transform: `scale(${scale})` }} data-screen-label={`FileNest ${mode}`}>
        <FileNestSidebar mode={mode} />
        <main className="native-main"><FileNestPageHeader mode={mode} />{views[mode]}</main>
      </div>
    </div>
  );
}

function FileNestWorkflowRail({ mode, onChange }) {
  return (
    <div className="workflow-rail" role="tablist" aria-label="FileNest workflows">
      {fileNestWorkflowData.map((item, index) => (
        <button type="button" role="tab" aria-selected={item.id === mode} className={item.id === mode ? "is-active" : ""} onClick={() => onChange(item.id)} key={item.id}>
          <span>{String(index + 1).padStart(2, "0")}</span>{item.label}
        </button>
      ))}
    </div>
  );
}

Object.assign(window, {
  FileNestFileIcon,
  FileNestNativeWindow,
  FileNestWorkflowRail,
});
