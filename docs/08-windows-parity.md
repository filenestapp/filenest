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
| Carbon global hot key + NSPanel | Electron `globalShortcut` + frameless always-on-top search window |
| Quick Look | allowlisted embedded preview plus native open |
| Apple NLEmbedding | built-in offline Windows embedding implementation |
| Sparkle | electron-updater |
| Login/open behavior | Windows login item and close-to-tray |

## Audit matrix

| Capability group | macOS baseline | Windows implementation status | Evidence gate |
| --- | --- | --- | --- |
| App shell, tray, and Quick Search | complete | implemented, including configurable global shortcut, centered floating search, and routing into Library; native shortcut conflicts pending Windows acceptance | build + Windows smoke |
| Onboarding and watched-folder policy | complete | implemented, including per-folder process/preserve choice and persistent baseline | integration tests passed |
| Stable file/directory watching | complete | implemented, including stop generations, budgeted directory inspection, offline arrival reconciliation, and a bounded 24-hour managed-content hash audit | watcher and directory-budget tests passed; Windows filesystem smoke pending |
| Extraction, Docling, OCR, media transcription | complete | implemented with Windows-native legacy Office fallback, iWork package fallback, managed Docling, Tesseract, Ollama, cloud OCR, managed FFmpeg, and isolated OpenAI Whisper with time-coded transcript chunks | code-level tests passed; provider/runtime matrix pending Windows |
| Vector lifecycle | complete | implemented with atomic replacement, semantic parent/child chunks, entity terms, per-file generations, mutation guards, recovery splitting, media scope, file-category-scoped rebuild, and a persisted retry queue that resumes interrupted/failed reindex items after restart | index/database tests passed |
| Organization | complete | implemented with priority/ignore/hybrid logic, safe paths, conflicts, cross-volume fallback, rollback distinction, and restart-safe one-time multi-folder organization with optional recursion and repository exclusion | organizer tests passed; cross-volume Windows smoke pending |
| Library | complete | implemented with complete Smart Search filters, lexical/entity/semantic RRF, dynamic semantic acceptance, optional reranking, the 50%/minimum-three display policy, duplicate management, sorting, paging, creation dates, and inspector | query/duplicate tests and Electron UI build passed |
| Chat | complete | implemented with parent evidence expansion, stable citation validation, per-provider/endpoint/model context windows, persisted related-file confidence and answer feedback, copy-success state, immediate durable questions, 40-message history pages, configurable retrieval, document/image/transcribed-media chat, complete-document batch processing with source coverage, retry replacement, progress, metrics, cancellation, and retrieval fallback | chat/database tests and Electron UI build passed |
| Standard Agent Skills | complete | implemented with bundled, shared-user, and FileNest-managed `SKILL.md` discovery; precedence/diagnostics; opt-in shared packages; import, enable, disable, remove, reveal, progressive activation, and search/attached-document routing | Agent Skills tests and Electron UI build passed |
| Rules | complete | implemented with create/edit/delete/toggle/generate/apply | integration and UI build passed |
| Settings and managed services | complete | implemented with independent providers, connectivity checks, model lifecycle, managed Qwen3 reranker lifecycle, FFmpeg/Whisper setup and model management, and selective indexing controls | type check/build passed; provider runtime matrix pending Windows |
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
- Added configurable global Quick Search with registration-conflict reporting, a centered floating query window, and automatic main-window Library routing.
- Added an integration-oriented parity suite covering structured chunks, note-only reindexing, query intent, safe organization, bounded chat context, retry replacement, metrics, cancellation, and watcher baselines.
- Added the current semantic retrieval pipeline: 600-token parents, 300-token retrieval children, whole-unit overlap, table-header repetition, parent evidence expansion, and exact entity terms.
- Added weighted reciprocal-rank fusion across lexical, semantic, and entity lanes, query-relative semantic thresholds, fail-open OpenAI/Jina-compatible reranking, and bounded local retrieval traces.
- Added the isolated managed Qwen3-Reranker-0.6B runtime for Windows, including download, verification, health, start, stop, delete, status, and cloud-compatible configuration.
- Added stable `[F#:P#]` evidence IDs, centralized AI prompts, invalid-citation removal, and the complete macOS Smart Search filter schema.
- Added provider-aware Ollama automatic startup for local loopback hosts, an idempotent cold-start wait, and managed-process shutdown.
- Added a dismissible automatic processing status tip that follows active indexing, queued organization, and file moves without hiding later work.
- Added managed Windows FFmpeg and an isolated pinned OpenAI Whisper runtime, selectable model download/delete, serialized local transcription, time-coded transcript chunks, transcribed-media search/chat, and media-only reindexing.
- Added one-time multi-folder organization without changing watch settings, optional recursive traversal, source-control repository exclusion, pending queue presentation, pause/resume/stop, and interrupted-job recovery.
- Added adaptive indexing concurrency, initial unpersisted blank chat behavior, mixed CamelCase/Chinese lexical boundaries, and paged inspector chunk loading.
- Added SHA-256 duplicate discovery, indexed-original links, automatic duplicate vector suppression, retained-original protection, pre-delete hash verification, progress, and Windows Recycle Bin cleanup.
- Added durable related-file confidence, immediate question persistence, 40-message chat history pages, and the shared confidence display policy that keeps all results at or above 50% and uses weaker results only to reach three.
- Added file creation-date backfill, file-type-scoped reindex controls, bounded directory inspection, a 24-hour/cursor/256 MB managed-content audit, and one-time schema migration markers.
- Added Ollama embedding requests with truncation and an explicit 32,000-token context window.
- Added locally persisted helpful/not-helpful answer feedback, localized feedback actions, and a temporary copied-success state matching the latest macOS conversation actions.
- Added the current standard Agent Skills runtime: bundled packages are shipped as application resources; shared packages are discovered from the standard user directory but remain opt-in; managed packages can be imported, enabled, disabled, deleted, refreshed, and inspected from settings. Skills are activated only by capability, explicit `$skill-name`, or a matching long-document intent.
- Added per-cloud-provider/endpoint/model context-window overrides, automatic restoration of the value for the active model scope, and normalized persistence.
- Added complete attached-document processing for explicit full-document translation and summary requests. Ordered parent sections are processed in safe context-window batches, streamed with progress, and returned with a source-coverage statement.
- Added a durable reindex job descriptor. Interrupted work and failed file IDs are retained locally and resume on the next eligible application launch instead of silently being dropped.
- Added custom file-type registration in Settings; custom types are normalized, join the watch scope immediately, and can independently be included in the vector-index scope.

The latest macOS changes also add launch arguments for deterministic UI screenshot fixtures. Those are macOS development/QA tooling rather than a shipped product capability; Windows keeps its existing Electron runtime/CDP smoke path instead of reproducing AppKit-specific preview windows.

## Verification truth

Code-level parity can be verified on macOS with type checking, unit/integration tests, and an Electron production build. The following remain release gates that require a Windows x64/ARM64 machine or CI runner:

- File Explorer, Recycle Bin, login startup, tray lifecycle, and close-to-tray behavior.
- NSIS install/uninstall and portable executable startup.
- DPAPI-backed safe storage in a packaged application.
- Authenticode signatures and reputation.
- Signed auto-update from the production HTTPS feed.

These platform gates must not be reported as passed solely because packaging succeeded on macOS.

Therefore, the source implementation now targets complete functional parity, while the release as a whole remains **not yet certified as 100% parity** until the Windows-native gates above pass on x64 and ARM64 Windows 11.

## Latest code-level verification — 2026-07-29

- Current macOS XCTest baseline: 339 tests passed, 0 failed.
- TypeScript strict type check: passed.
- Vitest: 43 tests passed across 2 files, 0 failed.
- Electron production build: main, preload, and renderer bundles passed.
- Windows packaging cross-build: passed with one x64/ARM64 Universal NSIS Setup and separate x64/ARM64 Portable executables; native installation acceptance and Authenticode signing remain pending.
- Windows-native installer, shell, DPAPI, tray, startup, managed FFmpeg/Whisper runtime, and signed update gates remain pending.
