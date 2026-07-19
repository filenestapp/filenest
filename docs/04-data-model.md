# Data Model

## Storage

Both platforms persist product state in a local SQLite-compatible database. macOS uses GRDB and a compiled SQLite vector extension plus an in-memory retrieval layer. Windows uses sql.js and persists the exported database to the application data directory.

| Entity | Source | Key fields | Purpose | Relationships | Confidence |
| --- | --- | --- | --- | --- | --- |
| File | `files` | id, path, name, category, discovery/creation/organization timestamps, hash, note, index signature, duplicate original/detection fields | Managed library item | owns chunks and embeddings unless linked as a duplicate | High |
| Document chunk | `document_chunks` | file_id, chunk_idx, text, context, section, pages, kind, parent_idx, token metadata | Structured searchable content | belongs to file | High on macOS and Windows |
| Document parent | `document_parents` | file_id, parent_idx, text, context, section, pages, kind, token metadata | Complete answer-time evidence unit | owns retrieval children logically | High on macOS and Windows |
| Embedding | `embeddings` | file_id, chunk index, vector, dimension, model | Semantic search vector | belongs to file/chunk | High |
| Rule | `rules` | name, pattern, target, priority, enabled, action | Deterministic organization behavior | independent configuration | High |
| Chat session | `chat_sessions` | title, timestamps, attached path | Conversation boundary | owns messages | High |
| Chat message | `chat_messages` | role, content, timestamp, related IDs, related-file confidence, response metrics | Persistent conversation turn | belongs to session; references files by JSON IDs | High |
| Token usage | `token_usage` | timestamp, provider, model, token counts, tokenizer profile, accuracy, session | Aggregate model activity | optionally belongs to session | High |
| Setting | `settings` | key, value | Persistent application configuration | independent | High |
| Watch baseline entry | `watch_directory_baseline_entries` | directory path, entry path | Preserve existing items when a folder is added | grouped by watched directory | High on macOS and Windows |
| RAG search trace | `rag_search_traces` | query, candidate counts, threshold, reranker, latency | Local retrieval evaluation and diagnostics | bounded independent history | High on macOS and Windows |
| Schema migration | `schema_migrations` | name, applied timestamp | Prevent expensive historical backfills from repeating at every launch | independent | High on Windows |

## File lifecycle

1. Discovery creates or updates metadata while preserving first discovery, organization time, note, and subfolder.
2. Indexing computes a content hash and index signature.
3. Successful parsing stores title/content and structured chunks.
4. Successful embedding atomically replaces the file vector space.
5. Organization updates path, name, organization timestamp, and subfolder.
6. Trash/removal deletes the file row and cascades chunks/vectors.
7. Byte-identical arrivals link to the indexed original and intentionally own no chunks or vectors; manual removal rehashes the selected copy before using the platform trash facility.

## Chunk kinds

Both schemas support `title`, `text`, `table`, `list`, `picture`, `transcript`, `note`, and `metadata`. Page ranges and section paths are optional. Whisper transcript chunks use section paths such as `Transcript › 00:00–03:15`, with the same time range retained in the chunk body and contextual embedding text. Each retrieval chunk records its searchable body in `text`, its actual embedding input in `contextual_text`, a parent index, extracted entity terms, `token_count`, `tokenizer_profile`, `tokenizer_version`, and `token_count_accuracy`. Parent rows preserve the larger section returned to the answer model. Exact Docling tokenizer counts take precedence; legacy estimates migrate to the shared versioned estimator in place without changing chunk boundaries or vectors. Legacy chunks migrate by treating each old chunk as its own parent. The note is independently re-embeddable so editing a note does not require reparsing the source document.

`document_parents` is backfilled from legacy chunks only when the table is first created. On later starts, parent rows without a matching `(file_id, parent_idx)` child reference are deleted. This prevents obsolete parent copies from accumulating after replacement or interrupted historical rebuilds.

Windows now persists the same structured chunk vocabulary and contextual text instead of treating the full extracted body as an opaque single field. Windows migrations are additive and preserve existing file, embedding, session, and message rows.

## Runtime-only state

- Library search score, interpreted intent, sorting, and pagination are derived results. Assistant-message related-file confidence is persisted so historical answers retain their original match evidence.
- Running/completed chat indicators are process-memory state. Sessions, drafts, messages, references, response metrics, and token usage remain durable where specified by their stores.
- Index pause/stop state and progress counters are runtime coordination state; committed file/chunk/vector versions remain durable.

## Relationships

| Parent | Child | Cardinality | Enforcement |
| --- | --- | --- | --- |
| File | Document chunk | one-to-many | foreign key cascade on macOS |
| File | Document parent | one-to-many | foreign key cascade on macOS |
| Document parent | Document chunk | one-to-many logical | matching `file_id` and `parent_idx`; orphan parents are removed at startup |
| File | Embedding | one-to-many | foreign key cascade |
| Chat session | Chat message | one-to-many | session foreign key/cascade in Windows; application migration on macOS |
| Chat message | File | many-to-many logical reference | JSON array of file IDs, not a foreign-key join table |
| Chat session | Token usage | one-to-many optional | session ID without strict FK |

## Data locations

- macOS database: Application Support `FileNest/filenest.sqlite` with legacy-location migration.
- Windows database: `%APPDATA%/FileNest/filenest-windows.sqlite`.
- Windows logs and managed service environments also live under the Electron user-data directory.

## Unresolved operational questions

- Production retention policy for chat history and token usage is not specified.
- Database backup/restore and schema downgrade policy are not implemented as user-facing workflows.
- Windows must keep migrations additive because sql.js writes a complete database snapshot.
