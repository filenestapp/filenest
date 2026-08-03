# macOS to Windows 1:1 Parity Plan

## Baseline and acceptance rule

The current macOS `FileNest` application is the normative product baseline. The Windows Electron application is complete only when each user-reachable macOS behavior has an equivalent Windows behavior, persistence model, failure state, and native Windows replacement where the operating system differs.

This plan is based on a live macOS audit on 2026-07-31 and current source comparison. Audit screenshots are retained locally in `tmp/macos-parity-audit/` while implementation is in progress.

An item is not marked complete merely because a similarly named control exists. It must have:

1. A matching entry point and hierarchy.
2. Equivalent behavior and persisted state.
3. Equivalent loading, empty, failure, pause, resume, and retry behavior where applicable.
4. Automated coverage for the underlying behavior.
5. A Windows UI capture reviewed against the macOS source state at the same content density.

## Audited experience gaps

| Area | macOS baseline | Current Windows state | Required parity work |
| --- | --- | --- | --- |
| Main shell | Compact three-mode sidebar, chat history, persistent processing strip, native toolbar and contextual inspector | Similar pages but different hierarchy, density, and state presentation | Rebuild shared shell, sidebar, header actions, status rail, and inspector around the macOS information architecture. |
| Library | Search, AI planning toggle, history, category/date filters, sortable result table, per-row file actions, duplicates and reindex flows | Search history, category/date filters, sortable table, result-set feedback, duplicates, and reindex flows are implemented; header/action density and inspector remain different | Match control order, table columns, item inspector, duplicate workflow, and empty/loading states. |
| Chat | Conversation-first layout, session states, attachment return path, progress stages, citations, feedback editor, long-document workflow | Base chat and structured answer feedback are available; result-level annotations and several presentation states remain incomplete | Port result-level feedback, complete long-document state machine, session state continuity, and message actions. |
| Settings workspace | Full-window workspace with searchable grouped navigation: General, Index & Organize, AI Models, AI Skills, Reindex Activity, Statistics, Rules | Dedicated searchable Windows workspace and grouped navigation are implemented; section content still needs visual-by-visual refinement | Align all service cards, details, empty states, and Windows-native labels/actions. |
| AI Models | Separate chat/embedding/OCR/transcription/reranker/Docling service cards with status, lifecycle, update checks, profiles, and advanced controls | Most service operations exist, but presentation and several status/update surfaces differ | Align service state model and all UI cards; preserve Electron-managed runtimes. |
| AI Skills | Built-in, FileNest Learning, Shared tabs; diagnostics; feedback-analysis history and retry | Structured feedback, constrained managed-skill learning, analysis states, retry, and source grouping are implemented | Refine source tabs and visual density, then add result-level annotations outside chat. |
| Reindex Activity | Durable job queue with per-file state, filters, selection, retry, pause/resume/stop | Persistent jobs, progress, file filters, pause/resume/stop, and retry are implemented | Add failed-file multi-selection and resume semantics that retain one historical job rather than creating a retry job. |
| Insights and statistics | Separate reporting surfaces with index health, storage, activity, and recently organized content | Statistics is compressed into current Settings | Separate routes and align metric cards, charts, freshness state, and empty states. |
| File management | Watched-folder inventory/status/retry, custom type selector, index-change confirmation, one-time organization flow | Core watching/indexing exists but workflow and UI are simplified | Port inventories, eligibility/type selector, change detection, confirmations, and recovery surfaces. |

## Delivery sequence

### Phase 1 — shared domain contracts and persistence

- Add RAG feedback records, ratings, reasons, selected best files, analysis states, analysis errors, and retry semantics.
- Add managed learned-skill records and the built-in feedback-learning package.
- Replace the JSON-only reindex recovery marker with durable reindex jobs and per-file queue states.
- Add settings-section selection, search, and persisted page state.
- Add explicit view models for service/update status rather than renderer-derived state.

### Phase 2 — macOS-equivalent navigation and settings workspace

- Rebuild the Windows Settings page as a dedicated searchable workspace using the same grouped navigation and section order as macOS.
- Port General, Index & Organize, AI Models, AI Skills, Reindex Activity, Statistics, and Rules surfaces.
- Keep Windows-specific labels accurate: Explorer, Recycle Bin, sign-in, tray, NSIS, and Electron updater.

### Phase 3 — library, inspector, and organization flows

- Align Library header, query controls, history, filters, sorting, table, action cells, selection, and inspector.
- Port duplicate-manager progress, destructive confirmation, error handling, and result summary states.
- Align one-time organization, watched-directory inventory, and index-change confirmation flows.

### Phase 4 — chat and learning flows

- Port structured feedback editor and result-level feedback.
- Implement safe AI-assisted feedback analysis that can create/evolve only FileNest-managed skills.
- Align long-document preparation, map/reduce, coverage, cancellation, recovery, and visible progress.
- Align session-running/completed states, citation interactions, attachment return behavior, and message action menus.

### Phase 5 — visual QA and release verification

- Capture matching Windows UI states at the same window dimensions as the audited macOS states.
- Review every state side by side; fix density, spacing, typography, empty states, focus states, and disabled states.
- Run strict TypeScript, unit/integration tests, Electron production build, Windows x64/ARM64 packaging, and native Windows smoke tests.

## Explicit non-substitutions

- Finder is implemented as File Explorer; Trash is implemented as Recycle Bin.
- Menu bar behaviors are implemented as Windows tray behaviors.
- Sparkle is implemented as `electron-updater` with the same visible update lifecycle.
- Apple NLEmbedding is implemented as the existing Windows offline embedding provider.
- Mac-only privacy permissions are replaced by Windows folder-access/error explanations; they are not silently omitted.

## Current implementation status

Implemented in the active parity pass:

- Durable persisted reindex jobs and per-file queue state, including pause/resume/stop, progress, errors, and retry entry points.
- Structured answer feedback with accuracy, reason, best-file evidence, analysis state, and local persistence.
- Safe feedback learning: only validated, FileNest-managed skill packages can be created or evolved; bundled and shared sources remain untouched.
- A dedicated searchable Settings workspace whose navigation matches the macOS File Management, Artificial Intelligence, and Insights grouping.
- Library search history, date/category filters, and result-set evaluations, including selected best-file evidence.

The project is not yet accepted as 1:1 parity. Library, chat, inspector, settings-detail, result-level feedback, visual-density, and Windows release acceptance work remain governed by the acceptance rule above.

## Current visual and interaction audit — 2026-08-01

The following audit compares the installed macOS application with the current Windows Electron development build at equivalent desktop sizes. Current captures are retained in `tmp/macos-windows-parity-audit-2026-08-01/` during this implementation pass. The macOS source build could not be used as the live baseline because its Build Information phase currently fails while opening a generated `Info.plist`; the installed FileNest application was used instead.

| Priority | Experience | Remaining mismatch | Required completion condition |
| --- | --- | --- | --- |
| P0 | Chat landing state | Windows still needs final visual QA against the macOS conversation-first landing state: sidebar density, session list density, composer controls, and localized copy must be reviewed together at the same viewport. | A side-by-side capture matches macOS hierarchy: compact status rail, `Describe What You Remember` landing prompt, suggestion actions, single `New Chat` header action, and integrated composer privacy state. |
| P0 | Library toolbar and list | The Windows library now has the macOS control order, Use AI switch, history, date filter, Date Added sort, and an Organize Now menu. Remaining work is visual/density review of result actions, menu positioning, loading state, and empty state. | The toolbar, columns, row density, actions, and filter popovers are visually verified against the macOS Library capture. |
| P0 | Reindex recovery | Windows now supports selecting a subset of failed files before retrying. Retrying currently creates a replacement durable job; macOS resumes the existing historical job. | Retry selected failures while retaining and resuming the same job identity, with correct state history and restart recovery. |
| P1 | File inspector | Windows now provides Open, Copy Path, and Chat with File. Its information order, relevance presentation, preview fallbacks, and note/index-status density still differ. | Inspector matches the macOS Quick Actions, file facts, preview behavior, notes, index state, and delete confirmation hierarchy. |
| P1 | Settings structure | Windows has the required sections and durable task views, but the top-level Settings title, navigation density, grouping cards, General-section order, and active-task visibility differ from macOS. | Section-specific headers, compact settings sidebar, matching General/AI skill/model information order, and conditional Reindex Activity navigation are captured and approved. |
| P1 | AI Models and Skills | Core operations exist, including managed feedback learning. Service lifecycle/status cards, update states, and built-in/learning/shared tab density have not yet completed a fresh visual comparison. | Each macOS AI Models and AI Skills substate has an equivalent Windows entry point, status, empty/error/retry state, and reviewed capture. |
| P1 | Chat result annotations | Structured answer and result-set evaluation are available, but the macOS per-result annotation placement and all visible post-answer states are not fully matched. | Each retrieved-file card and answer action exposes equivalent evaluation and correction paths without obscuring file actions. |
| P2 | Insights and organization management | Windows presents Statistics and organization controls inside Settings; macOS has more distinct reporting and watched-folder recovery surfaces. | Match metrics, storage/activity visuals, recent organization state, watched-folder inventory, type selection, confirmations, and recovery flows. |
| P2 | Platform and release acceptance | Windows-specific native behavior cannot be pixel-identical, but all replacements must be explicit and verified. | Explorer/Recycle Bin/tray/updater behaviors pass native Windows x64 and ARM64 smoke tests; packaged installers launch the installed executable correctly. |

### Audit conclusion

The implementation has moved beyond the earlier missing-core-function stage. It is not yet a 1:1 release candidate: the remaining work is primarily high-fidelity layout, information hierarchy, recovery semantics, and complete state-by-state visual validation. No feature is considered aligned solely because a similarly named button exists.

## Initial setup alignment — 2026-08-01

The macOS setup assistant was captured directly from the installed application in the local-mode path. The accepted reference set is retained in `tmp/macos-onboarding-audit-2026-08-01/`:

1. Welcome
2. Basic Setup
3. Local Components
4. Model Downloads
5. Audio & Video
6. Get Started

The Windows setup assistant now follows the same conditional sequence:

- Local path: Welcome → Basic Setup → Local Components → Model Downloads → optional Audio & Video → Get Started.
- Cloud path: Welcome → Basic Setup → Cloud API → optional Audio & Video → Get Started.
- Basic Setup persists language, appearance, AI mode, media-transcription choice, and watched folders before navigation proceeds; it supports adding, removing, and restoring the default Desktop and Downloads folders.
- Cloud configuration exposes distinct Chat Model, Embedding, and OCR service forms.
- The final step preserves the same safe default: keep existing files in place and process only new files, with an explicit alternative to organize existing files now.
- Settings now provides an `Open Setup Assistant Again` entry point matching the macOS recovery path.

Windows-specific replacement: the local-components screen labels the existing bundled Windows local OCR runtime rather than presenting macOS PaddleOCR installation. This preserves the available Windows behavior without claiming that the macOS package is installed.

Remaining validation: capture the rebuilt Windows flow at the same viewport once the local desktop session is unlocked, then compare the local path, cloud branch, installation/error states, and finish choices side by side before marking initialization setup as accepted parity.

## Main workspace alignment — 2026-08-01

The current Windows main workspace now follows the macOS interaction model more closely:

- Inspecting a file collapses the sidebar so the primary content and inspector own the workspace; closing it restores the navigation rail.
- The sidebar status rail is compact and interactive: watching, index status, and AI mode each expose a contextual popover, with Settings as the detail destination.
- File chat keeps the attached file visible in the chat header and includes a back action to the originating Library or Chat context.
- The Chat landing state uses the macOS conversation-first title, instruction, suggested prompts, and single prominent New Chat action.

The corresponding visual QA record is `FileNestWindows/design-qa.md`. Its result remains blocked until the local desktop is unlocked and a rebuilt Windows capture is reviewed against the macOS reference at a matching viewport.

## Settings workspace alignment — 2026-08-03

The Windows Settings workspace now uses the same structural model as macOS:

- A compact left rail owns the brand/back action, settings search, and the File Management, Artificial Intelligence, and Insights groups.
- The detail pane has a dedicated icon, title, supporting description, and automatic-save status header.
- General now contains runtime status, interface, startup, quick search, automatic organization, and organization location.
- Index & Organize now contains watched folders, manual path entry, watched file types, automatic vectorization, and index maintenance.
- AI source selection is presented as a Local Ollama / Cloud API / Search Only segmented choice, matching the macOS interaction hierarchy.

The Windows-specific controls remain explicit: login startup uses Windows sign-in and system tray behavior, and folder paths use Windows paths. Source-level and automated functional validation are complete; visual acceptance remains blocked pending same-viewport captures of both applications.

## Find with Chat and Chat with File alignment — 2026-08-03

The Windows chat workspace now follows the macOS ChatView split between a library search and a focused file analysis:

- Find with Chat uses the branded empty state, local-index explanation, direct-send suggested questions, and the compact rounded composer.
- Chat with File exposes the active file in the header and composer, offers file-specific direct-send suggestions, and returns to the originating context through Back.
- File chat suppresses library citation cards so its conversation is scoped to the attached file, matching the macOS promise that it does not search or mix in library content.
- Choosing a file refreshes its index record before rendering the file context; New Chat clears the current attachment before starting a fresh conversation.

Automated TypeScript, test, and production-build checks pass. Visual acceptance remains blocked until matching Windows and macOS states can be captured and reviewed side by side.
