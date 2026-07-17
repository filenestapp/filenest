# Product Overview

## Summary

FileNest is a local-first desktop file manager that watches user-selected folders, waits for new content to stabilize, extracts and indexes supported content, organizes items using deterministic rules plus optional AI topic classification, and lets users retrieve or discuss files using natural language.

The product has two coordinated surfaces:

- A persistent background companion for watching, indexing, organizing, and quick status actions.
- A full desktop application for the library, natural-language retrieval, file chat, rules, settings, preview, model management, statistics, logs, and updates.

## Actors

| Actor | What they do | Evidence | Confidence |
| --- | --- | --- | --- |
| Desktop user | Selects folders, searches files, previews content, adds notes, and manages organization | `FileNest/UI/*`, `FileNest/App/AppState.swift` | High |
| Privacy-conscious user | Uses local parsing, embeddings, Ollama, and local OCR without cloud transfer | settings factories and provider implementations | High |
| Cloud AI user | Configures OpenAI-compatible or Anthropic chat/OCR and cloud embeddings | `AppSettings.swift`, provider implementations | High |
| Background watcher | Detects stable files and directories, indexes first, then schedules organization | `FileWatcherService.swift` | High |
| Local AI runtime | Provides chat, embeddings, topic classification, and vision/OCR models | `OllamaServiceManager.swift` and providers | High |
| Release operator | Signs, publishes, and hosts app/update artifacts | Sparkle and electron-builder configuration | High |

## Core value

1. Reduce manual filing by organizing new files after safe indexing.
2. Make file contents searchable, not only file names.
3. Let users ask questions about the library or one attached file.
4. Keep indexes, notes, chat history, and credentials on the local device by default.
5. Offer explicit cloud use rather than silently uploading content.

## Domain vocabulary

| Term | Meaning |
| --- | --- |
| Watched folder | User-selected source folder monitored for stable additions and changes |
| Managed item | A file or top-level directory recorded in the FileNest library |
| Organized root | Destination root containing primary category and optional topic folders |
| Rule | Priority-ordered deterministic pattern with organize or ignore action |
| Hybrid classification | Rules first; unmatched items fall back to category and optional AI topic |
| Index signature | Fingerprint of settings that affect extraction, chunking, OCR, or embeddings |
| Document chunk | Searchable text segment with optional section, page, and kind metadata |
| Retrieval-only mode | Local search results without a generative model response |
| File chat | A session restricted to one attached file, without library retrieval |

## Primary workflows

### First run

1. Choose language, appearance, watched folders, and AI mode.
2. Optionally install local Ollama, model packages, Docling, and local OCR support.
3. Choose whether pre-existing folder entries should remain untouched or be processed.
4. Start background watching.

### New item processing

1. The watcher observes a file or directory until its content is stable.
2. Eligibility policy rejects hidden, temporary, lock, partial-download, and unsupported items.
3. Metadata is persisted.
4. Extraction, OCR/Docling, chunking, and embedding run according to settings.
5. The index commit is accepted only if the source still matches the indexed version.
6. Automatic organization runs immediately or through a timer/count batch.
7. The database path is updated only after a successful physical move; rollback is attempted on persistence failure.

### Find with chat

1. The query is analyzed into local or AI-assisted retrieval criteria while the interpreted search intent is streamed to the user.
2. Metadata, keyword, date, filename, and semantic matches are merged, assigned a confidence value, and ranked.
3. Relevant chunks and neighbors form bounded model context.
4. The selected local/cloud model streams an answer with cited files, or retrieval-only mode returns files directly.
5. The session continues running when the user visits another page; the sidebar shows running and completed states.
6. The session, references, token estimates, response timing, provider, and model are persisted.

### Library search escalation

1. The normal search bar runs the lower-latency hybrid local search path.
2. Results show confidence rather than implementation-oriented match or index badges.
3. A result-level suggestion offers Smart Search when the user needs a more precise interpretation and explicitly warns that it takes longer.
4. Smart Search converts the same query into semantic, keyword, type, date, and ordering constraints, then replaces the result set.
5. Editing the query or pressing Search starts a new normal search instead of leaving the library in a hidden persistent Smart Search mode.

### File inspection

1. Select a library row or cited file.
2. Review identity, location, metadata, preview, notes, indexed chunks, and index state.
3. Open, reveal, copy path, start document chat, generate a summary, reindex, or move to the recycle facility.

## Assumptions and unknowns

- Observed: the application is single-user and has no account or authorization model.
- Observed: secrets are local; Windows encrypts configured API keys with Electron safe storage when available.
- Unknown: the production publisher identity, signed update endpoints, and release hosting.
- Platform validation required: actual Windows shell, installer, startup, and update behavior on x64 and ARM64 hardware.

## Product measurement and access model

- No account, role, plan, quota, billing, or multi-tenant entitlement system was detected.
- No product analytics SDK or remote event pipeline was detected. Local statistics measure file, index, storage, and token activity for the user, but the product team cannot yet measure activation, search success, retention, or conversion across installations.
- The current activation milestone inferred from code is: onboarding completed, at least one watched folder attached, and at least one file successfully indexed and retrievable.
- This positioning and activation definition are code-derived and have not been confirmed against production customer research.
