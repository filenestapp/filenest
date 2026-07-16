# macOS → Windows parity

| Capability | Windows implementation |
| --- | --- |
| Stable file monitoring | Chokidar with write-stability delay; handles add, change, delete and top-level directory arrivals |
| Existing-file scan | Manual/onboarding scan of configured watch directories |
| Eligibility policy | Extension allowlist, hidden/system/partial-download exclusions and directory handling |
| Rules | Ordered wildcard/keyword rules, ignore actions, enable/edit/delete, safe relative targets and AI rule generation |
| Hybrid classification | Rule-first classification, then current LLM provider generates a stable topic subfolder, with deterministic category fallback |
| Safe moves | Collision suffixes, cross-volume copy/delete, path traversal checks and database rollback |
| Batch organization | Immediate or timed/count-based queue, plus manual “organize now” |
| Native extraction | PDF, DOCX/DOCM, XLSX/XLSM, PPTX/PPSX, EPUB, ODF, RTF, text, code and directories |
| Advanced extraction | Managed isolated Docling Python environment or an optional external Docling endpoint |
| OCR | Bundled local Tesseract pipeline, Ollama vision, OpenAI-compatible vision and Anthropic vision |
| Embeddings | Built-in offline multilingual 384-dimension index, Ollama embeddings or OpenAI-compatible embeddings |
| Index lifecycle | Atomic metadata/vector replacement, hash-before/hash-after stability check, full/single reindex, progress, pause, resume and stop |
| Search | Filename, title and extracted-text search; category filters; semantic retrieval with keyword fallback |
| Chat | Streaming Ollama/OpenAI/Anthropic responses, retrieval-only mode, cancellation, retry, model/thinking controls and token accounting |
| File chat | File picker and drag/drop; files outside the library are extracted/indexed locally before chat |
| Sessions | Recent sessions, create/select/delete/clear, attached-file sessions and persisted messages |
| File inspector | Secure allowlisted preview, metadata, Explorer reveal, open, copy path, notes, summary, single-file reindex and Recycle Bin |
| Library | Search/filter table, preview, file chat, Explorer reveal, open and delete |
| Statistics | Total/today files, indexing, token usage, 14-day activity and category/storage breakdown |
| Local services | Ollama discovery/install/model pull/delete and managed Docling install/status |
| Windows integration | System tray, close-to-tray, recent organized files, Explorer, Recycle Bin, login startup, NSIS and portable builds |
| Updates and diagnostics | Configurable HTTPS feed, automatic check/download options, log export/clear and blockmap generation |
| Privacy/security | Context isolation, sandboxed renderer, strict CSP, preview path allowlist, no renderer Node access and DPAPI-encrypted API keys |
| Localization/theme | Simplified Chinese/English/system language and light/dark/system appearance |

## Verification gates

- TypeScript strict typecheck
- Core policy, chunking and deterministic embedding tests
- Database/index/semantic-search/AI-subfolder/move/chat integration test
- Electron production build and runtime screenshot smoke test
- Windows x64 and ARM64 PE packaging
- Production dependency audit at high severity

Authenticode signing and hosting the update feed require the publisher's certificate and release URL; these are release credentials, not source-code defaults.
