function FileNestMarketingNav({ dark = false }) {
  return (
    <header className={`marketing-nav ${dark ? "marketing-nav--dark" : ""}`}>
      <span className="marketing-wordmark"><img src="assets/app-icon.png" alt="" /><strong>FileNest</strong></span>
      <nav><span>Product</span><span>Privacy</span><span>Platforms</span><span>Questions</span></nav>
      <button type="button">Release updates</button>
    </header>
  );
}

function NativeStageDirection({ mode, phase, onModeChange }) {
  return (
    <article className="site-artboard site-artboard--native" data-screen-label="Direction A — Native Product Stage">
      <FileNestMarketingNav />
      <div className="native-hero-grid">
        <div className="native-hero-copy">
          <span className="availability-mark"><i></i> Local AI · Built for macOS 13+ and Windows 11</span>
          <h1>Your files,<br /><em>understood.</em></h1>
          <p>Index, search, and chat with the files already on your computer using local AI. In local mode, content, indexes, notes, and conversations stay on this device.</p>
          <div className="hero-actions"><button type="button">Explore local AI</button><span>No account · Cloud only when you configure it</span></div>
          <div className="native-trust-grid" aria-label="Local AI and privacy guarantees">
            <span><strong>Local AI</strong><small>Ollama, OCR, and embeddings</small></span>
            <span><strong>Private index</strong><small>Stored on this device</small></span>
            <span><strong>Security boundary</strong><small>Your operating-system account</small></span>
          </div>
        </div>
        <div className="native-hero-product">
          <FileNestNativeWindow mode={mode} phase={phase} scale={0.61} />
          <div className="native-product-proof">
            <span><i></i><strong>Local AI running</strong></span>
            <span>Your files</span><b>→</b><span>Private index</span><b>→</b><span>Grounded answers</span>
          </div>
        </div>
      </div>
      <div className="native-hero-workflows">
        <div><strong>Private intelligence, five real workflows.</strong><span>The native app shell stays stable while each local workflow advances.</span></div>
        <FileNestWorkflowRail mode={mode} onChange={onModeChange} />
      </div>
    </article>
  );
}

function ProductFirstDirection({ mode, phase, onModeChange }) {
  return (
    <article className="site-artboard site-artboard--product" data-screen-label="Direction B — Product-First Canvas">
      <FileNestMarketingNav />
      <div className="product-first-heading">
        <span>Local-first intelligent file management</span>
        <h1>Stop remembering where.<br />Start asking what.</h1>
        <p>Search, organize, and chat with the knowledge already on your Mac.</p>
      </div>
      <div className="product-first-stage">
        <FileNestNativeWindow mode={mode} phase={phase} scale={0.78} />
        <div className="product-first-caption"><span><i></i> Mock workspace</span><strong>Northstar Studio</strong></div>
      </div>
      <FileNestWorkflowRail mode={mode} onChange={onModeChange} />
    </article>
  );
}

function PrivacyProofDirection({ mode, phase, onModeChange }) {
  return (
    <article className="site-artboard site-artboard--privacy" data-screen-label="Direction C — Privacy as Proof">
      <FileNestMarketingNav dark />
      <div className="privacy-hero-grid">
        <div className="privacy-hero-copy">
          <span className="privacy-symbol"><img src="assets/brand-mark.png" alt="" /></span>
          <p className="privacy-lead">Your computer is the boundary.</p>
          <h1>Useful AI.<br />Private files.<br /><em>Same place.</em></h1>
          <p>Indexing, semantic search, and grounded chat can run locally. Cloud providers remain an explicit choice.</p>
          <button type="button">Explore the local workflow</button>
        </div>
        <div className="privacy-product-stage">
          <FileNestNativeWindow mode={mode} phase={phase} scale={0.58} />
          <div className="boundary-proof">
            <span><i></i><strong>On this Mac</strong></span>
            <span>Your files</span><b>→</b><span>Private index</span><b>→</b><span>Local AI</span>
          </div>
        </div>
      </div>
      <div className="privacy-workflow-bar"><FileNestWorkflowRail mode={mode} onChange={onModeChange} /><span>Mock data · no real user files</span></div>
    </article>
  );
}

function PrototypeReviewApp() {
  const query = new URLSearchParams(window.location.search);
  const requestedDirection = query.get("variant");
  const captureMode = query.get("capture") === "1";
  const initialDirection = fileNestDirections.some((item) => item.id === requestedDirection)
    ? requestedDirection
    : localStorage.getItem("filenest-review-direction") || "native-stage";
  const requestedMode = query.get("mode");
  const initialMode = fileNestWorkflowData.some((item) => item.id === requestedMode)
    ? requestedMode
    : fileNestWorkflowData.some((item) => item.id === localStorage.getItem("filenest-review-mode"))
      ? localStorage.getItem("filenest-review-mode")
    : "find-chat";
  const requestedPhase = Number(query.get("phase"));
  const initialPhase = Number.isFinite(requestedPhase) && query.has("phase")
    ? requestedPhase
    : Number(localStorage.getItem("filenest-review-phase")) || 0;

  const [direction, setDirection] = React.useState(initialDirection);
  const [mode, setMode] = React.useState(initialMode);
  const [phase, setPhase] = React.useState(initialPhase);
  const [playing, setPlaying] = React.useState(!captureMode && query.get("paused") !== "1");
  const [showNotes, setShowNotes] = React.useState(false);
  const [artboardScale, setArtboardScale] = React.useState(1);

  React.useEffect(() => {
    const updateScale = () => {
      if (captureMode) return setArtboardScale(1);
      const availableWidth = Math.max(320, window.innerWidth - 40);
      const availableHeight = Math.max(400, window.innerHeight - 112);
      setArtboardScale(Math.min(1, availableWidth / 1440, availableHeight / 900));
    };
    updateScale();
    window.addEventListener("resize", updateScale);
    return () => window.removeEventListener("resize", updateScale);
  }, [captureMode]);

  React.useEffect(() => {
    localStorage.setItem("filenest-review-direction", direction);
    localStorage.setItem("filenest-review-mode", mode);
    localStorage.setItem("filenest-review-phase", String(phase));
  }, [direction, mode, phase]);

  React.useEffect(() => {
    if (!playing || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return undefined;
    const timer = window.setTimeout(() => {
      if (phase < 3) {
        setPhase((value) => value + 1);
      } else {
        const index = fileNestWorkflowData.findIndex((item) => item.id === mode);
        setMode(fileNestWorkflowData[(index + 1) % fileNestWorkflowData.length].id);
        setPhase(0);
      }
    }, phase < 3 ? 900 : 1800);
    return () => window.clearTimeout(timer);
  }, [mode, phase, playing]);

  const changeMode = (nextMode) => {
    setMode(nextMode);
    setPhase(0);
  };

  const directions = {
    "native-stage": <NativeStageDirection mode={mode} phase={phase} onModeChange={changeMode} />,
    "product-first": <ProductFirstDirection mode={mode} phase={phase} onModeChange={changeMode} />,
    "privacy-proof": <PrivacyProofDirection mode={mode} phase={phase} onModeChange={changeMode} />,
  };

  return (
    <main className={`prototype-review ${captureMode ? "is-capture" : ""}`}>
      {!captureMode && (
        <header className="review-toolbar">
          <div className="review-title"><strong>FileNest website review</strong><span>Three directions grounded in the current native UI</span></div>
          <div className="direction-switcher" role="tablist" aria-label="Website directions">
            {fileNestDirections.map((item) => <button type="button" role="tab" aria-selected={item.id === direction} onClick={() => setDirection(item.id)} key={item.id}><b>{item.short}</b><span><strong>{item.name}</strong><small>{item.note}</small></span></button>)}
          </div>
          <div className="review-actions"><button type="button" onClick={() => setPlaying((value) => !value)}>{playing ? "Pause" : "Play"}</button><button type="button" onClick={() => setShowNotes((value) => !value)}>Review notes</button></div>
        </header>
      )}

      <div className="artboard-viewport" style={{ width: 1440 * artboardScale, height: 900 * artboardScale }}>
        <div className="artboard-transform" style={{ transform: `scale(${artboardScale})` }}>{directions[direction]}</div>
      </div>

      {!captureMode && showNotes && (
        <aside className="review-notes">
          <button type="button" onClick={() => setShowNotes(false)}>×</button>
          <h2>What changed</h2>
          <dl>
            <div><dt>Image geometry</dt><dd>Every product image keeps its intrinsic aspect ratio. No fixed HTML height survives into the rendered layout.</dd></div>
            <div><dt>Native shell</dt><dd>The demo now mirrors FileNest: 255px sidebar, page header, compact table rows, chat progress steps, matched-file cards, and attached-file chat.</dd></div>
            <div><dt>Motion</dt><dd>Animation advances real product states inside one stable app window instead of swapping unrelated marketing cards.</dd></div>
            <div><dt>Trust hierarchy</dt><dd>Direction A now foregrounds local AI, the private on-device index, the operating-system security boundary, and explicit cloud choice.</dd></div>
            <div><dt>Data</dt><dd>Northstar Studio and Project Aurora remain explicitly fictional.</dd></div>
          </dl>
        </aside>
      )}
    </main>
  );
}

ReactDOM.createRoot(document.getElementById("root")).render(<PrototypeReviewApp />);
