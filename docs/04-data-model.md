# Data Model

## Storage

Both platforms persist product state in a local SQLite-compatible database. macOS uses GRDB and a compiled SQLite vector extension plus an in-memory retrieval layer. Windows uses sql.js and persists the exported database to the application data directory.

| Entity | Source | Key fields | Purpose | Relationships | Confidence |
| --- | --- | --- | --- | --- | --- |
| File | `files` | id, path, name, category, timestamps, hash, note, index signature | Managed library item | owns chunks and embeddings | High |
| Document chunk | `document_chunks` | file_id, chunk_idx, text, context, section, pages, kind | Structured searchable content | belongs to file | High on macOS and Windows |
| Embedding | `embeddings` | file_id, chunk index, vector, dimension, model | Semantic search vector | belongs to file/chunk | High |
| Rule | `rules` | name, pattern, target, priority, enabled, action | Deterministic organization behavior | independent configuration | High |
| Chat session | `chat_sessions` | title, timestamps, attached path | Conversation boundary | owns messages | High |
| Chat message | `chat_messages` | role, content, timestamp, related IDs, response metrics | Persistent conversation turn | belongs to session; references files by JSON IDs | High |
| Token usage | `token_usage` | timestamp, provider, model, token estimates, session | Aggregate model activity | optionally belongs to session | High |
| Setting | `settings` | key, value | Persistent application configuration | independent | High |
| Watch baseline entry | `watch_directory_baseline_entries` | directory path, entry path | Preserve existing items when a folder is added | grouped by watched directory | High on macOS and Windows |

## File lifecycle

1. Discovery creates or updates metadata while preserving first discovery, organization time, note, and subfolder.
2. Indexing computes a content hash and index signature.
3. Successful parsing stores title/content and structured chunks.
4. Successful embedding atomically replaces the file vector space.
5. Organization updates path, name, organization timestamp, and subfolder.
6. Trash/removal deletes the file row and cascades chunks/vectors.

## Chunk kinds

The macOS schema supports `title`, `text`, `table`, `list`, `picture`, `note`, and `metadata`. Page ranges and section paths are optional. The note is independently re-embeddable so editing a note does not require reparsing the source document.

Windows now persists the same structured chunk vocabulary and contextual text instead of treating the full extracted body as an opaque single field. Windows migrations are additive and preserve existing file, embedding, session, and message rows.

## Runtime-only state

- Library search score, confidence, match evidence, interpreted intent, sorting, and pagination are derived results and are not persisted.
- Running/completed chat indicators are process-memory state. Sessions, drafts, messages, references, response metrics, and token usage remain durable where specified by their stores.
- Index pause/stop state and progress counters are runtime coordination state; committed file/chunk/vector versions remain durable.

## Relationships

| Parent | Child | Cardinality | Enforcement |
| --- | --- | --- | --- |
| File | Document chunk | one-to-many | foreign key cascade on macOS |
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
