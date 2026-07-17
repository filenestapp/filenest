# Technical Architecture

## Runtime structure

```mermaid
flowchart LR
  User[Desktop user] --> UI[Desktop UI]
  UI --> State[Application state and commands]
  State --> Watcher[Watcher]
  State --> Indexer[Indexer]
  State --> Organizer[Organizer]
  State --> Chat[Chat and search]
  Watcher --> Indexer
  Indexer --> Extract[Extraction, Docling, OCR]
  Indexer --> Embed[Embedding provider]
  Indexer --> DB[(SQLite)]
  Organizer --> FS[Local filesystem]
  Organizer --> DB
  Chat --> Embed
  Chat --> LLM[Local or cloud LLM]
  Chat --> DB
```

## macOS modules

| Layer | Modules | Responsibility |
| --- | --- | --- |
| Application | `FileNestApp`, `AppState`, `AppSettings` | scenes, commands, state, settings, dependency composition |
| UI | `MainView`, `LibraryView`, `ChatView`, `FilePreviewView`, `SettingsView`, `StatisticsView`, `MenuBarView`, `OnboardingView`, `RulesView` | user journeys and native interactions |
| Domain | models, protocols, eligibility and organization policies | portable vocabulary and invariants |
| Services | watcher, indexer, organizer, chat, summaries, model managers, logs, updates | workflow coordination |
| Extraction | native extractors, Docling, OCR processor | content and structured chunks |
| Providers | embedding, LLM, OCR | local/cloud transport adapters |
| Storage | `SQLiteStore`, `AccelerateVectorStore` | durable metadata, chunks, vectors, sessions, usage |

## Windows processes

```mermaid
flowchart LR
  Renderer[Sandboxed React renderer] -->|typed IPC| Preload[Context-isolated preload]
  Preload --> Main[Electron main process]
  Main --> Controller[AppController]
  Controller --> Services[Watcher / Indexer / Organizer / Chat]
  Services --> SQL[(sql.js database file)]
  Services --> Native[Explorer / Recycle Bin / tray / startup]
  Services --> Providers[Ollama / cloud APIs / Docling / OCR]
```

The renderer has no Node.js access. File previews use an allowlisted custom protocol whose path must already exist in the library database. External navigation is denied or routed to the system browser.

## Important flows

### Long-running UI work

`ChatView` remains mounted inside the main window while Library is selected. Visibility and hit testing change, but the streaming task and composer state stay alive. `AppState` tracks running and completed session identifiers so sidebar rows can show a spinner or unread completion dot without persisting transient UI state. Menu bar index animation uses `TimelineView`, keeping display-only animation frames out of application state.

### Watch, index, then organize

```mermaid
sequenceDiagram
  participant W as Watcher
  participant I as Indexer
  participant D as Database
  participant O as Organizer
  participant F as Filesystem
  W->>W: Wait for stable content
  W->>D: Upsert metadata
  W->>I: Index source path
  I->>I: Hash, parse, OCR, chunk, embed
  I->>D: Atomic content/vector commit
  I-->>W: Success only for current source version
  W->>O: Schedule organization
  O->>F: Move with collision protection
  O->>D: Update managed path
  alt database update fails
    O->>F: Roll back physical move
  end
```

### Retrieval and chat

The query planner combines explicit metadata intent, relative/absolute date intent, direct filename/title/note/path matches, keyword content matches, and semantic chunk matches. Evidence is normalized into a confidence score before UI sorting. Normal library search is automatic and debounced; Smart Search is an explicit escalation from completed normal results and streams a short interpreted intent while the AI plan is built. File chat bypasses library retrieval. Context planning keeps recent turns, compresses older turns, and bounds retrieval to the selected model context window.

On Windows, `LibrarySearchService` owns renderer-independent lexical, date, semantic, sorting, and paging behavior. The renderer calls it through the typed preload contract instead of filtering a snapshot locally.

## Configuration and secrets

- Settings persist in SQLite as key/value data.
- macOS uses the local settings store and provider-specific configuration.
- Windows encrypts chat, embedding, and OCR API keys using Electron `safeStorage` when encryption is available.
- No authentication or multi-user boundary exists; OS user access is the security boundary.

## Build and test

### macOS

```bash
xcodebuild -project FileNest.xcodeproj -scheme FileNest -configuration Debug -destination 'platform=macOS' test
```

`script/build_and_run.sh` builds `Release` by default, preserves a stable Apple Development designated requirement, installs one canonical bundle under `~/Applications`, and verifies launch. Debug mode selects the Debug configuration unless `FILENEST_CONFIGURATION` is explicitly set.

### Windows

```bash
cd FileNestWindows
npm ci
npm run typecheck
npm test
npm run build
npm run package:win
```

## Deployment assumptions

- macOS updates require a valid HTTPS Sparkle appcast and publisher signing.
- Windows updates require a valid HTTPS generic feed, `latest.yml`, signed artifacts, and Authenticode for production trust.
- x64 and ARM64 Windows packages are configured; actual runtime validation must occur on Windows hardware or CI runners.
