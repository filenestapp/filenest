# FileNest — Local-First Intelligent File Management

[English](README.md) · [简体中文](README.zh-CN.md)

FileNest watches the folders you choose and turns stable files and project directories into a local, searchable knowledge base. It extracts content, runs OCR when needed, creates structured chunks and vector indexes, optionally organizes files, and supports regular search, Smart Search, Find with Chat, and Chat with File.

This repository contains two desktop implementations:

- `FileNest/`: the native macOS 13+ SwiftUI app and the current product baseline.
- `FileNestWindows/`: the Windows 11 parity implementation built with Electron, React, and TypeScript.

## Highlights

### Watch and organize safely

- Watch Desktop, Downloads, and any additional folders you choose.
- Wait for new files and directories to reach a stable state before processing them. This avoids temporary downloads, lock files, and incomplete `git clone` directories.
- Reconcile additions and changes that occurred while the app was not running at the next launch.
- Index before organizing. For project directories, README-style files are used as additional classification context.
- Define prioritized extension rules, exclusion rules, AI-generated rules, and time- or count-based batches.
- Skip installers, temporary files, and other content that should not be moved automatically by default.

### Local document processing and RAG

```text
PDF / Office / Images / Other documents
        ↓
Docling first, with native extractors as fallback
        ↓
PaddleOCR first, with GLM-OCR or cloud OCR as fallback
        ↓
Cleaning, structuring, and section-aware chunking
        ↓
qwen3-embedding:0.6b / Apple NLEmbedding / cloud embeddings
        ↓
Parent chunks (600–1000 tokens) + child retrieval chunks (~280 tokens)
        ↓
SQLite + sqlite-vec + keyword/entity/vector RRF fusion
        ↓
Optional local or cloud Qwen3-Reranker reranking
        ↓
Local Ollama or cloud LLM answers
```

- Structured chunks preserve titles, body text, tables, lists, images, notes, section paths, and page information.
- The default parent-chunk target is 600–1000 tokens, with configurable overlap.
- When Docling is available, FileNest records exact Qwen3 tokenizer counts. Other paths use the same versioned estimator and retain tokenizer profile, version, and exact/estimated provenance.
- Retrieval finds smaller child chunks, then provides the complete parent context to the model. Table child chunks repeat their headers.
- Invoice numbers, email addresses, dates, and amounts have a dedicated exact-entity retrieval channel combined with file keywords and vectors through reciprocal-rank fusion.
- A note on an indexed file can be re-embedded without re-parsing the source file.
- Before index commit, FileNest validates the source version again so an obsolete task cannot overwrite newer content.
- Reindexing can target new files, embedding changes, chunk settings, OCR/parser changes, or selected processing stages. Jobs can be paused, resumed, stopped, and restarted.

### Search and chat

- Regular search combines file name, title, path, note, extracted content, date intent, and vector similarity.
- Vector acceptance adapts to each query's score distribution. A local or cloud `/v1/rerank`-compatible reranker can be configured and automatically falls back on failure.
- Search results expose confidence, and users can opt into the more deliberate Smart Search flow.
- Smart Search converts natural-language requests into a semantic query, keywords, file types, date constraints, and sort preferences.
- Find with Chat reuses intelligent retrieval planning and streams planning, matching, and answer-generation progress.
- Chat with File uses only the selected file's existing indexed chunks; an indexed file is not parsed again.
- Conversations and drafts are persisted locally. Switching views does not interrupt an in-progress response.
- If a cloud model fails, FileNest can offer a local-model fallback or return vector search results directly.
- Answers support Markdown, file previews, retry-in-place, token usage, time-to-first-token, and total response time.
- RAG context is capped at eight parent chunks and uses stable `[F#:P#]` evidence identifiers that are verified after generation.

### Local and cloud AI

- Install, start, update, and manage Ollama plus local generation, embedding, OCR, and reranker models.
- The setup wizard recommends `qwen3.5:9b` and defaults embedding to `qwen3-embedding:0.6b`; users can choose alternatives.
- Docling and PaddleOCR live in dedicated Python environments under the FileNest user directory.
- Optional audio and video processing uses FFmpeg for decoding and OpenAI Whisper in an isolated environment for timestamped transcripts, then reuses the existing embedding and RAG pipeline.
- Cloud mode supports OpenAI-compatible and Anthropic APIs. Chat, embedding, and OCR credentials can be configured independently or shared.
- Cloud models can declare their context window. Unknown compatible models are planned with a 612K-token default.

## App experience

- Menu bar operation with background status and quick actions.
- A collapsible sidebar with recent conversations plus watch, indexing, AI, and completion status.
- A file library with a shared right-side preview drawer, full-screen previews, notes, chunk inspection, and Move to Bin actions.
- Settings for general preferences, AI models, indexing, organization rules, statistics, diagnostics, logs, and updates.
- English and Simplified Chinese UI, with system, light, and dark appearance modes.

## OpenAI Build Week / Codex collaboration

FileNest was extended for OpenAI Build Week with Codex powered by GPT-5.6. Codex helped implement, debug, and test local indexing, retrieval, chat, model management, and cross-platform workflows. Product, privacy, architecture, and release decisions remain with the project owner; Codex was used as an engineering collaborator.

## Build and verify

### macOS

The project script builds a Release app, keeps a stable Apple Development signature, installs it at `~/Applications/FileNest.app`, and launches it:

```bash
./script/build_and_run.sh --verify
```

For a debug build:

```bash
./script/build_and_run.sh --debug
```

Run the full test suite:

```bash
xcodebuild -project FileNest.xcodeproj -scheme FileNest \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData test
```

### Windows

```bash
cd FileNestWindows
npm ci
npm run typecheck
npm test
npm run build
```

Windows installer, Explorer/Recycle Bin integration, DPAPI, tray behavior, and auto-update still require release acceptance on real x64/ARM64 Windows 11 systems.

## Data and privacy

- File metadata, structured chunks, vectors, notes, conversations, and statistics are stored locally by default.
- In local mode, document content does not need to leave the device.
- Content is sent to a configured cloud API only when the user explicitly configures cloud Chat, Embedding, or OCR for the relevant operation.
- The app operates within the current macOS user's file permissions. It does not provide accounts, RBAC, or multi-tenant isolation.

## Documentation

- [Product and engineering documentation index](docs/00-index.md)
- [Product overview](docs/01-product-overview.md)
- [Feature map](docs/02-feature-map.md)
- [Technical architecture](docs/03-technical-architecture.md)
- [Verification strategy](docs/09-verification.md)
- [Windows parity status](docs/08-windows-parity.md)
- [Simplified Chinese README](README.zh-CN.md)

The source code and automated tests are the final authority for product behavior. Documentation describes the current product and engineering interpretation of this repository.
