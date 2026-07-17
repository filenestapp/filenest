# Source Map

| Claim | Source files | Evidence type | Confidence |
| --- | --- | --- | --- |
| macOS source is the current product baseline | `FileNest/App`, `FileNest/UI`, `FileNestTests` | source + test | High |
| Stable watch/index/organize ordering | `FileNest/Services/FileWatcherService.swift` | service + tests | High |
| Files and directories are managed items | `FileNest/Domain/Models.swift`, watcher/indexer tests | model + test | High |
| Structured chunk metadata is durable | `Protocols.swift`, `SQLiteStore.swift`, `AccelerateVectorStoreTests.swift` | model + schema + test | High |
| Index commits reject stale source content | `IndexerService.swift`, `IndexerServiceTests.swift` | service + test | High |
| Rules support organize and ignore | `Models.swift`, `OrganizerService.swift`, rule tests | model + test | High |
| Normal search ranks hybrid evidence by confidence and Smart Search is a result-level escalation | `ChatService.swift`, `ChatServiceTests.swift`, `LibraryView.swift` | service + test + UI | High |
| Smart Search and Find with Chat stream interpreted intent before retrieval | `ChatService.swift`, `ChatView.swift`, `LibraryView.swift` | service + UI + test | High |
| File chat excludes library retrieval | `ChatService.swift`, `ChatServiceTests.swift` | service + test | High |
| Chat generation survives page navigation and exposes running/completed state | `AppState.swift`, `MainView.swift`, `ChatView.swift`, `AppStateTests.swift` | state + UI + test | High |
| Response metrics are persisted | `Models.swift`, `SQLiteStore.swift`, chat/store tests | schema + test | High |
| Independent chat, embedding, and OCR provider selection exists | `AppSettings.swift`, provider implementations/tests | settings + test | High |
| Windows renderer is sandboxed and context isolated | `FileNestWindows/src/main/index.ts` | config | High |
| Windows secrets use safe storage when available | `FileNestWindows/src/main/database.ts` | implementation | High |
| Windows previews require a database allowlist match | `app-controller.ts`, `index.ts` | implementation | High |
| Windows product API is a typed preload bridge | `shared/types.ts`, `ipc.ts`, `preload/index.ts` | contract | High |
| Windows library search and settings normalization live in the main process | `library-search.ts`, `settings-normalization.ts`, `parity.test.ts` | service + test | High |
| Windows packaging targets NSIS and portable x64/ARM64 | `FileNestWindows/package.json` | manifest | High |
| Actual Windows native behavior requires Windows runtime validation | platform constraint | inference | High |
