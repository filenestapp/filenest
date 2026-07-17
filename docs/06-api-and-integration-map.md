# API and Integration Map

FileNest has no public network server. The Windows renderer uses a typed IPC API exposed through the context-isolated preload bridge.

## Windows renderer API

| Group | Operations | Purpose |
| --- | --- | --- |
| State | snapshot, refresh, state-changed subscription | Read application state |
| Settings | update settings, choose watched folders, choose organized root | Configure the product |
| Watcher | start, stop, scan existing, preserve existing | Manage discovery and per-folder baseline policy |
| Organizer | organize now | Run filing manually |
| Indexer | reindex all/new/embedding scope, reindex file, pause, resume, stop/restart | Manage vector lifecycle |
| Files | legacy file search, structured library search, open, reveal, trash, note, summary, chunks, preview URL | Library and inspector actions |
| Rules | create, update, delete, generate | Rule management |
| Chat | begin lazy chat, create/select/delete/clear, send, retry replacement, cancel, stream subscription | Conversation lifecycle |
| Ollama | refresh, install, pull, delete | Local model management |
| Docling/OCR | status, install, update | Local processing management |
| AI diagnostics | test chat, embedding, and OCR connections | Validate configured providers |
| Updates/logs | check updates, export logs, clear logs | Operations |

The exact TypeScript contract is `FileNestWindows/src/shared/types.ts`; handlers are registered in `src/main/ipc.ts`, and renderer exposure is in `src/preload/index.ts`.

## External integrations

| Integration | Direction | Data sent | Security boundary | Evidence |
| --- | --- | --- | --- | --- |
| Ollama | local HTTP | prompts, chunks, optional images | loopback/configured host | LLM, embedding, OCR providers |
| OpenAI-compatible chat | HTTPS/configured | prompt and retrieved context | API key + configured endpoint | LLM provider |
| Anthropic messages | HTTPS/configured | prompt and retrieved context | API key + configured endpoint | LLM provider |
| Cloud embeddings | HTTPS/configured | document/query text | API key + configured endpoint | embedding provider |
| Cloud OCR | HTTPS/configured | page/image data | API key + configured endpoint | OCR provider |
| Docling | managed process or optional endpoint | local source path or file upload to explicit endpoint | isolated user environment / configured endpoint | Docling processor |
| Sparkle | HTTPS feed | version/update metadata | signed macOS update framework | update service |
| GitHub Releases | HTTPS API and official DMG asset | Ollama release metadata and installer | verified managed Ollama update | managed service update API |
| electron-updater | HTTPS feed | version/update metadata | generic provider + signed Windows release | app controller |
| Finder/Explorer | local OS | file path | desktop user session | preview/library actions |
| Trash/Recycle Bin | local OS | file path | desktop user session | AppState/AppController |

## Security controls

- Windows renderer sandbox and context isolation are enabled.
- Node integration is disabled.
- Navigation is blocked; external HTTP(S) URLs open through the OS shell.
- Preview URLs are generated only for database allowlisted paths.
- Windows API keys are encrypted with DPAPI-backed Electron safe storage when available.
- Update feeds must use HTTPS.
- Organization targets are validated as descendants of the configured root.

## Authentication

There is no product account, role, or remote session. The operating-system user account and filesystem permissions are the authorization boundary.
