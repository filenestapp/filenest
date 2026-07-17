# Entity Relationship Diagram

```mermaid
erDiagram
  FILE ||--o{ DOCUMENT_CHUNK : contains
  FILE ||--o{ EMBEDDING : has
  CHAT_SESSION ||--o{ CHAT_MESSAGE : contains
  CHAT_SESSION ||--o{ TOKEN_USAGE : records

  FILE {
    integer id PK
    text path UK
    text name
    text category
    text content_hash
    text index_signature
    text note
    datetime discovered_at
    datetime organized_at
  }
  DOCUMENT_CHUNK {
    integer id PK
    integer file_id FK
    integer chunk_idx
    text text
    text contextual_text
    text section_path
    integer page_start
    integer page_end
    text kind
  }
  EMBEDDING {
    integer id PK
    integer file_id FK
    integer chunk_idx
    blob vector
    integer dim
    text model
  }
  RULE {
    integer id PK
    text pattern
    text target_folder
    integer priority
    boolean enabled
    text action
  }
  CHAT_SESSION {
    integer id PK
    text title
    datetime created_at
    datetime updated_at
    text attached_file_path
  }
  CHAT_MESSAGE {
    integer id PK
    integer session_id FK
    text role
    text content
    text related_file_ids
    integer input_tokens
    integer output_tokens
  }
  TOKEN_USAGE {
    integer id PK
    integer session_id
    datetime ts
    text provider
    text model
    integer input_tokens
    integer output_tokens
  }
  SETTING {
    text key PK
    text value
  }
  WATCH_BASELINE_ENTRY {
    text directory_path PK
    text entry_path PK
  }
```

`related_file_ids` is a logical many-to-many relationship stored as JSON, so it is intentionally not drawn as a foreign-key relationship. Rules, settings, and watch baseline entries have no entity foreign key.
