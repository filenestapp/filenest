# macOS to Windows Parity

## Definition of parity

A capability is complete only when all applicable layers agree:

1. A Windows user can reach the feature from the approved UI.
2. Main-process/domain behavior implements the macOS invariant.
3. Persistence survives restart where macOS persists the feature.
4. Failure and cancellation behavior is safe.
5. Automated tests cover the central success and failure paths.
6. Platform-native behavior is validated on Windows when it cannot be proven on macOS.

## Platform mappings

| macOS concept | Windows equivalent |
| --- | --- |
| Finder | File Explorer |
| Trash | Recycle Bin |
| MenuBarExtra | system tray |
| Quick Look | allowlisted embedded preview plus native open |
| Apple NLEmbedding | built-in offline Windows embedding implementation |
| Sparkle | electron-updater |
| Login/open behavior | Windows login item and close-to-tray |

## Audit matrix

| Capability group | macOS baseline | Windows implementation status | Evidence gate |
| --- | --- | --- | --- |
| App shell and tray | complete | implemented; native behavior pending Windows acceptance | build + Windows smoke |
| Onboarding and watched-folder policy | complete | implemented, including per-folder process/preserve choice and persistent baseline | integration tests passed |
| Stable file/directory watching | complete | implemented, including stop generations and offline arrival reconciliation | watcher tests passed; Windows filesystem smoke pending |
| Extraction, Docling, OCR | complete | implemented with Windows-native legacy Office fallback, iWork package fallback, managed Docling, Tesseract, Ollama, and cloud OCR | code-level tests passed; provider/runtime matrix pending Windows |
| Vector lifecycle | complete | implemented with atomic replacement, structured chunks, per-file generations, mutation guards, recovery splitting, and selective rebuild | index/database tests passed |
| Organization | complete | implemented with priority/ignore/hybrid logic, safe paths, conflicts, cross-volume fallback, and rollback distinction | organizer tests passed; cross-volume Windows smoke pending |
| Library | complete | implemented with lexical/semantic/date search, match evidence, sorting, paging, and inspector | query tests and Electron UI smoke passed |
| Chat | complete | implemented with bounded chunk context, configurable retrieval, file/image chat, retry replacement, progress, metrics, cancellation, and retrieval fallback | chat tests and Electron UI smoke passed |
| Rules | complete | implemented with create/edit/delete/toggle/generate/apply | integration and UI build passed |
| Settings and managed services | complete | implemented with independent providers, connectivity checks, model lifecycle, and selective indexing controls | type check/build passed; provider runtime matrix pending Windows |
| Statistics, logs, updates | complete | implemented with activity/category/storage/model metrics, log lifecycle, and updater configuration | database tests passed; signed update pending publisher infrastructure |
| Localization and theme | complete | English/Chinese/system and light/dark/system implemented; new parity surfaces localized | type check and UI smoke passed |
| Security | native sandbox boundary | renderer sandbox, navigation denial, allowlisted preview, and refusal to persist plaintext secrets implemented | static inspection passed; DPAPI packaged check pending Windows |

## Implementation changes made during the parity pass

- Added structured document chunks with kind, section path, and page range persistence.
- Made file metadata, chunks, and embeddings commit atomically after source hash validation.
- Added per-file task coordination, batch pause/resume/stop, failure counts, recovery splitting, and selective rebuild modes.
- Added persistent existing-item baselines and startup reconciliation for files arriving while the app was stopped.
- Added source-change protection and distinct filesystem/database rollback failures before organization.
- Added smart library retrieval across name, title, path, note, text, vectors, date intent, sort, and paging.
- Added lazy sessions, per-session drafts, structure-aware RAG, neighbor chunks, file/image chat, retry replacement, progress, metrics, and model-failure fallback.
- Added structured chunk inspection, editable generated summaries, expanded preview, watch status, AI connectivity checks, and additional storage statistics.
- Added local OCR fallback through the configured Ollama vision model and legacy Office/iWork best-effort extraction paths.
- Moved library filtering from renderer-only snapshots into a typed main-process search service with lexical, semantic, date, sorting, and paging behavior.
- Added settings normalization for chunk, overlap, RAG limit, context window, scheduling, extensions, folders, and cloud provider defaults.
- Added an integration-oriented parity suite covering structured chunks, note-only reindexing, query intent, safe organization, bounded chat context, retry replacement, metrics, cancellation, and watcher baselines.

## Verification truth

Code-level parity can be verified on macOS with type checking, unit/integration tests, and an Electron production build. The following remain release gates that require a Windows x64/ARM64 machine or CI runner:

- File Explorer, Recycle Bin, login startup, tray lifecycle, and close-to-tray behavior.
- NSIS install/uninstall and portable executable startup.
- DPAPI-backed safe storage in a packaged application.
- Authenticode signatures and reputation.
- Signed auto-update from the production HTTPS feed.

These platform gates must not be reported as passed solely because packaging succeeded on macOS.

Therefore, the source implementation now targets complete functional parity, while the release as a whole remains **not yet certified as 100% parity** until the Windows-native gates above pass on x64 and ARM64 Windows 11.

## Latest code-level verification — 2026-07-17

- TypeScript strict type check: passed.
- Vitest: 16 tests passed across 2 files, 0 failed.
- Electron production build: main, preload, and renderer bundles passed.
- Windows-native installer, shell, DPAPI, tray, startup, and signed update gates remain pending.
