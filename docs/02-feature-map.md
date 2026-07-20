# Feature Map

The macOS implementation is the normative baseline. “Platform equivalent” means native Finder/Trash behavior on macOS and Explorer/Recycle Bin behavior on Windows.

## Setup and application shell

| Feature | User value | Entry point | Domain/service | Data | Confidence |
| --- | --- | --- | --- | --- | --- |
| First-run onboarding | Guided safe setup with explicit local generation and embedding model selection | Onboarding window | `AppState`, model/service managers | settings, watch baseline | High |
| Background companion | Continuous operation and quick actions | Menu bar or system tray | app entry point, watcher, indexer | runtime state | High |
| Single main window | Predictable desktop navigation | app/window activation | app entry point | none | High |
| Language and appearance | English/Chinese and system/light/dark UI | General settings | settings + localization | settings | High |
| Login startup | Start background companion with the OS | General settings | Windows login item / macOS launch behavior | settings | Platform-specific |
| Global Quick Search | Open a centered search box from any app and route the submitted query into Library | configurable global shortcut / tray command | global shortcut service + quick-search window | settings + transient request | Platform-specific |

## Watched folders and eligibility

| Feature | User value | Entry point | Domain/service | Data | Confidence |
| --- | --- | --- | --- | --- | --- |
| Multiple watched folders | Cover Desktop, Downloads, and work folders | Onboarding, Settings | watcher | settings | High |
| Existing-item choice | Avoid unexpectedly moving existing files | Onboarding and folder-add flow | watcher baseline | baseline table | High |
| Stable file detection | Avoid partial indexing and moves | background watcher | stability tracker | runtime snapshot | High |
| Stable directory detection | Treat a project folder as one managed item without unbounded tree enumeration | background watcher | budgeted directory inspector/tracker | files | High |
| Managed-content audit | Detect byte changes even when size and modification time were preserved | bounded daily startup audit | organizer/store | files, vectors, audit cursor | High |
| Offline reconciliation | Detect changes while the app was stopped | watcher restart/manual reconcile | watcher + organizer | files, vectors | High |
| Eligibility policy | Ignore locks, hidden files, temporary downloads, and unsupported types | watcher | policy | settings | High |
| Watch status and recovery | Explain missing or inaccessible folders | sidebar/menu/settings | watcher status | runtime status | High |

## Indexing and content processing

| Feature | User value | Entry point | Domain/service | Data | Confidence |
| --- | --- | --- | --- | --- | --- |
| Native extraction | Search PDF, Office, OpenDocument, EPUB, RTF, text, code, and image metadata | automatic/manual indexing | extractor | files, chunks | High |
| Docling parsing | Better structured document parsing | Index settings | Docling manager/processor | chunks | High |
| OCR | Search scanned pages and images | Index settings | local/Ollama/cloud OCR | files, chunks | High |
| Audio/video transcription | Turn supported media into time-coded searchable text before embedding | onboarding, AI settings, automatic/manual indexing | FFmpeg + managed OpenAI Whisper runtime | files, transcript chunks, embeddings | High on macOS and Windows |
| Configurable index scope | Limit indexed extensions | Index settings | indexer/settings | settings | High |
| Configurable chunks | Control chunk size and overlap | Index settings | indexer | settings, chunks | High |
| Structured chunks | Preserve title/text/table/list/picture/transcript/note metadata, section, page range, and media time range | inspector and retrieval | vector store | document chunks | High |
| Parent–Child retrieval | Retrieve compact children and return complete source sections to the answer model | indexing/chat | indexer/vector store | document parents, chunks, embeddings | High on macOS and Windows |
| Exact entity lane | Recover identifiers, emails, dates, and amounts that semantic similarity can miss | search/chat | indexer/ChatService | chunk entity terms | High on macOS and Windows |
| Atomic replacement | Keep old vectors if a rebuild fails | indexer | vector store | embeddings, chunks | High |
| Content mutation guard | Reject stale results if source changes during indexing | indexer | hash/snapshot | files | High |
| Per-file concurrency control | Prevent older work from overwriting newer work | indexer | task coordinator/revisions | runtime + vectors | High |
| Pause/resume/stop/restart | Control long rebuilds | command/menu/settings/library | indexer gate | runtime state | High |
| Selective reindex | Re-embed, index new files, rebuild selected processing categories, or limit source rebuilds to selected file categories | confirmation flow | AppState/indexer | settings signatures | High |
| Progress and failure counts | Show stage, file, completed, total, and failures | global status UI | indexer | runtime state | High |

## Organization

| Feature | User value | Entry point | Domain/service | Data | Confidence |
| --- | --- | --- | --- | --- | --- |
| Priority rules | Deterministic filing | Rules settings | classifier/organizer | rules | High |
| Organize/ignore actions | Explicitly move or preserve matches | Rule editor | organizer | rules | High |
| AI rule generation | Convert natural language into editable rules | Rules settings | AI rule generator | rules | High |
| Hybrid topic folders | File type / topic / item hierarchy | automatic organization | subfolder classifier | files | High |
| Safe relative targets | Block path traversal and invalid folder names | rule editor + organizer | organization policy | rules | High |
| Conflict-safe move | Preserve both files on naming conflicts | organizer | filesystem | files | High |
| Cross-volume move | Work across drives | organizer | filesystem copy/delete fallback | files | Platform-specific |
| Batched scheduling | Avoid disruptive one-by-one moves | Index settings | organizer scheduler | settings | High |
| Rollback and error distinction | Avoid database/filesystem drift | organizer | transaction/rollback | files, logs | High |

## Library and preview

| Feature | User value | Entry point | Domain/service | Data | Confidence |
| --- | --- | --- | --- | --- | --- |
| Keyword/content search | Find by name, path, title, note, or extracted text | Library | store/chat search | files | High |
| Hybrid confidence search | Rank filename, title, path, note, extracted content, date, and vector evidence with a user-facing confidence value | Library | `ChatService`, library query | files, vectors, chunks | High |
| Smart Search escalation | Keep the normal search bar simple while offering slower AI interpretation from completed results | Library result tip | `ChatService`, `LibraryView` | runtime plan | High |
| Streaming search intent | Explain what Smart Search or Find with Chat understood before retrieval completes | Library/chat progress | `ChatService` | runtime state | High |
| Category filters | Narrow by content type | Library | query | files | High |
| Created/modified date ranges | Browse time-bounded files | Library | query | files | High |
| Size/modified sorting | Sort ascending or descending | Library headers | query | files | High |
| Incremental paging | Keep large libraries responsive | Library | view query | files | High |
| Unified right inspector | Keep context in the main window | Library/chat result | preview state | files, chunks | High |
| Native/secure preview | Preview supported local files | inspector | Quick Look / allowlisted protocol | filesystem | Platform-specific |
| Expanded preview | Inspect content at full display size | inspector | preview presenter | filesystem | High |
| Notes and note-only index update | Make user knowledge searchable without reparsing the file | inspector | summary/indexer | files, vectors | High |
| AI summary | Generate an editable concise note | inspector | summary service | files | High |
| Indexed chunk inspection | Inspect chunk kinds and locations | inspector | store | document chunks | High |
| Open/reveal/copy path/trash | Perform native file actions | row/inspector | shell integration | files | Platform-specific |
| Duplicate management | Find byte-identical files, keep the original, and safely reclaim duplicate copies | Library duplicate manager | content hasher/store/native trash | files, content hashes, duplicate links | High on macOS and Windows |

## Chat and retrieval

| Feature | User value | Entry point | Domain/service | Data | Confidence |
| --- | --- | --- | --- | --- | --- |
| Persistent sessions | Continue prior conversations | sidebar | ChatService/store | sessions, messages | High |
| Paged chat history | Load the latest 40 messages first and request older pages on demand | conversation | ChatService/store | messages | High on macOS and Windows |
| Local answer feedback | Retain helpful/not-helpful ratings across restarts and confirm successful message copying | assistant response actions | ChatService/store | message feedback | High on macOS and Windows |
| Background conversation continuity | Keep streaming when navigating away and surface running/completed state in the sidebar | main window/sidebar | `AppState`, `MainView`, `ChatView` | runtime state | High |
| Lazy chat creation | Avoid empty sessions | New Chat/composer | AppState/ChatService | sessions | High |
| Streaming answers | Immediate feedback | Chat composer | LLM provider | messages | High |
| Retrieval progress | Explain search and AI stages | conversation | ChatService | runtime state | High |
| File citations | Open matched files from answers and retain the confidence shown when the answer was produced | assistant response | ChatService | related IDs + confidence matches | High |
| Retrieval-only fallback | Keep file finding useful without a model | composer/fallback dialog | ChatService | messages | High |
| Cloud failure fallback | Offer local results after configured cloud failure | composer alert | ChatService | messages | High |
| Configurable result count | Tune RAG breadth from 1 to 30 files | AI settings | ChatService | settings | High |
| Fused retrieval and reranking | Combine lexical, entity, and semantic ranks with RRF; optionally rerank through a compatible managed-local/cloud API | AI settings/search/chat | ChatService/reranker provider | settings, search traces | High on macOS and Windows |
| Stable citations | Bind answer claims to selected file/parent evidence and validate citation IDs | Find with Chat | prompt/context/verifier | runtime context | High on macOS and Windows |
| Bounded model context | Respect known/overridden context windows | AI settings | context planner | settings | High |
| Retry/regenerate | Replace the answer for the same question | message actions | ChatService | messages | High |
| Cancel generation | Stop active streaming | composer | provider task | runtime state | High |
| File attachment and drag/drop | Chat with a file outside the library | composer | attachment indexing | files, session | High |
| File-only context | Do not mix library results into attached-file chat | ChatService | retrieval | session | High |
| Markdown rendering | Read structured answers | message view | Markdown renderer | message content | High |
| Voice dictation | Enter questions by voice | composer | OS speech/dictation | draft only | Platform-specific |
| Response metrics | Show/provider-model/token/timing evidence | message metadata/statistics | ChatService/store | messages, token usage | High |

## AI, diagnostics, statistics, and updates

| Feature | User value | Entry point | Domain/service | Data | Confidence |
| --- | --- | --- | --- | --- | --- |
| Independent chat/embedding/OCR providers | Mix local and cloud capabilities | AI settings | provider factories | settings | High |
| OpenAI-compatible and Anthropic chat | Use selected cloud service | AI settings | providers | settings | High |
| Model discovery/pull/delete | Manage Ollama locally and cache model metadata for fast display | AI settings/onboarding | Ollama manager | model files + runtime cache | High |
| Onboarding model choice | Select generation and embedding downloads, defaulting to Qwen 9B and Qwen Embedding 0.6B | onboarding | settings/Ollama manager | settings | High |
| Docling and local OCR install/update | Manage isolated local tools | AI/index settings | managed service managers | service files | High |
| FFmpeg and Whisper management | Detect/install media decoding, install the isolated OpenAI Whisper runtime, and download/delete transcription models | onboarding and AI settings | managed media service managers | service files + model files | High on macOS and Windows |
| Verified managed updates | Resolve official Ollama assets and verify Ollama, Docling, and PaddleOCR updates before activation | AI/index settings | update/service managers | service files | High |
| Connectivity checks | Test every configured capability | AI settings | connectivity tester | none | High |
| Statistics | Understand files, index health, tokens, activity, categories, and storage | Statistics | store | files, vectors, usage | High |
| Structured logs | Diagnose by category and severity | diagnostics | log service | log files | High |
| Export/clear logs | Share or reset diagnostics | General settings | log service | log files | High |
| Secure update feed | Check/download application updates | app menu/general settings | Sparkle/electron-updater | settings | Platform-specific |
