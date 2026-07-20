const { useEffect, useState } = React;

const directionData = {
  minimal: { number: "01", title: "Editorial minimal", note: "Quiet confidence. A refined, reading-first product story where the actual app UI does the convincing.", mode: "Minimal surface · typographic authority" },
  future: { number: "02", title: "Future AI", note: "High-contrast local intelligence. A bolder launch treatment with energy, depth, and visible AI signal.", mode: "Dark field · luminous computation" },
  native: { number: "03", title: "macOS native", note: "A product-led desktop narrative. Familiar system tactility makes privacy and control feel immediately credible.", mode: "Desktop-native · calm precision" }
};

function Brand() {
  return <span className="concept-brand"><img src="assets/app-icon.png" alt="" />FileNest</span>;
}

function PreviewNav({ onDemo }) {
  return <div className="concept-nav"><Brand /><div className="concept-links"><span>Product</span><span>Local AI</span><span>Privacy</span><span>Release</span></div><button className="concept-cta" type="button" onClick={onDemo}>View live demo</button></div>;
}

function MinimalDirection({ onDemo, active }) {
  return <section className={`concept minimal ${active ? "is-active" : ""}`} data-screen-label="01 Editorial minimal"><div className="concept-shell"><PreviewNav onDemo={onDemo} /><div className="minimal__hero"><div className="minimal__copy"><p className="eyebrow">Local-first file intelligence</p><h2>Your files,<br /><em>understood.</em></h2><p>Search, organize, and ask better questions of the files already on your computer. Local by default. Cloud only when you decide.</p><div className="minimal__action-row"><button type="button" onClick={onDemo}>Explore the workflow</button><span>How privacy works</span></div></div><div className="minimal__visual"><img src="assets/filenest-chat-current.webp" alt="FileNest product UI" /><div className="minimal__caption"><span>Actual product UI</span><span>Mock workspace · local AI</span></div></div></div><div className="minimal__proof"><div><b>Local model</b><span>Ollama, OCR, and embeddings run beside your files.</span></div><div><b>Private index</b><span>Content, notes, and vectors stay on this device.</span></div><div><b>Clear choice</b><span>Cloud providers appear only when you configure them.</span></div></div></div></section>;
}

function FutureDirection({ onDemo, active }) {
  return <section className={`concept future ${active ? "is-active" : ""}`} data-screen-label="02 Future AI"><div className="concept-shell"><PreviewNav onDemo={onDemo} /><div className="future__hero"><div className="future__copy"><div className="future__signal"><i></i> Local intelligence online</div><h2>Find the thought<span>behind the file.</span></h2><p>FileNest turns a private library into a working memory: meaning, evidence, and answers stay close to the desktop where your work lives.</p><div className="future__buttons"><button type="button" onClick={onDemo}>Launch the live demo</button><button type="button" onClick={onDemo}>See private retrieval</button></div></div><div className="future__visual"><div className="future__orb"></div><div className="future__nodes"><i></i><i></i><i></i></div><div className="future__window"><img src="assets/filenest-chat-current.webp" alt="FileNest product UI" /></div></div></div><div className="future__lower"><div><strong>Private by architecture, not by marketing copy.</strong><p>Your file index, local models, and conversations are contained on the device by default.</p></div><div className="future__chips"><span>Hybrid retrieval</span><span>Local OCR</span><span>Grounded chat</span><span>Optional cloud</span></div></div></div></section>;
}

function NativeDirection({ onDemo, active }) {
  return <section className={`concept native ${active ? "is-active" : ""}`} data-screen-label="03 macOS native"><div className="concept-shell"><PreviewNav onDemo={onDemo} /><div className="native__hero"><div className="native__copy"><p className="eyebrow">File intelligence for your desktop</p><h2>Everything you need.<br /><b>Nothing leaves home.</b></h2><p>FileNest feels at home next to Finder: a clear private index, native previews, and local AI that works with the folders you choose.</p><div className="native__button-row"><button type="button" onClick={onDemo}>Try the product flow</button><button type="button" onClick={onDemo}>See supported files</button></div></div><div className="native__visual"><div className="native__window"><div className="native__chrome"><span className="native__dots"><i></i><i></i><i></i></span><span>Find with Chat</span><span>Local</span></div><img src="assets/filenest-chat-current.webp" alt="FileNest product UI" /></div><div className="native__sync"><i></i> Local AI ready</div></div></div><div className="native__tiles"><div className="native__tile"><span>SEARCH</span><b>Remember the idea, not the name.</b></div><div className="native__tile"><span>ORGANIZE</span><b>Index first. Move only when rules say so.</b></div><div className="native__tile"><span>CHAT</span><b>Answers include the file evidence.</b></div></div></div></section>;
}

function App() {
  const initial = localStorage.getItem("filenest-design-direction") || "minimal";
  const [selected, setSelected] = useState(directionData[initial] ? initial : "minimal");
  const [showWorkflow, setShowWorkflow] = useState(false);
  useEffect(() => {
    localStorage.setItem("filenest-design-direction", selected);
    document.querySelectorAll("[data-direction]").forEach((button) => button.setAttribute("aria-pressed", String(button.dataset.direction === selected)));
  }, [selected]);
  useEffect(() => {
    const onDirection = (event) => { const key = event.currentTarget.dataset.direction; setSelected(key); setShowWorkflow(false); };
    const buttons = [...document.querySelectorAll("[data-direction]")];
    buttons.forEach((button) => button.addEventListener("click", onDirection));
    return () => buttons.forEach((button) => button.removeEventListener("click", onDirection));
  }, []);
  const openWorkflow = () => setShowWorkflow(true);
  return <><section className="design-brief"><div><p className="eyebrow">Design review · main site only</p><h1>Three distinct ways FileNest can feel unmistakably itself.</h1></div><div className="design-brief__copy"><p><strong>Shared truth:</strong> the real FileNest product UI, an English-first audience, and a local-AI privacy promise. The concepts change the emotional frame—not the product claims.</p><p style={{ marginTop: "16px" }}>Use the direction picker above or the comparison cards below. Each preview is interactive and remembers the latest choice.</p></div></section><div className="design-stage"><MinimalDirection active={selected === "minimal"} onDemo={openWorkflow} /><FutureDirection active={selected === "future"} onDemo={openWorkflow} /><NativeDirection active={selected === "native"} onDemo={openWorkflow} /></div><section className="preview-footer" aria-label="Design direction comparison">{Object.entries(directionData).map(([key, item]) => <button type="button" className={`preview-card ${selected === key ? "is-active" : ""}`} key={key} onClick={() => { setSelected(key); setShowWorkflow(false); }}><span className="preview-card__number">{item.number}</span><strong>{item.title}</strong><span>{item.note}</span></button>)}</section>{showWorkflow && <aside className="workflow-popover"><strong>FileNest workflow preview</strong><p>{selected === "future" ? "The future-AI route opens with the live product simulation and makes the local index visible before the result." : selected === "native" ? "The macOS-native route guides visitors from familiar desktop controls into the five working product flows." : "The editorial route lets the real app screen lead, then uses concise privacy proof to earn trust."}</p><button type="button" onClick={() => setShowWorkflow(false)}>Close preview</button></aside>}</>;
}

ReactDOM.createRoot(document.getElementById("root")).render(<App />);
