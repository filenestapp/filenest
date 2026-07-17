# FileNest Product and Engineering Documentation

- Repository: `mactools`
- Repository path: `/Users/la230048/work/ai.prompt/mactools`
- Product baseline: current macOS implementation under `FileNest/`
- Windows implementation: `FileNestWindows/`
- Last synchronized: 2026-07-17 (Asia/Singapore)
- Code baseline: `0cda7bf` plus the 2026-07-17 product update

## Reading order

1. [Product overview](01-product-overview.md)
2. [Feature map](02-feature-map.md)
3. [Technical architecture](03-technical-architecture.md)
4. [Data model](04-data-model.md)
5. [ER diagram](05-er-diagram.md)
6. [API and integration map](06-api-and-integration-map.md)
7. [Onboarding guide](07-onboarding-guide.md)
8. [macOS to Windows parity](08-windows-parity.md)
9. [Verification strategy](09-verification.md)
10. [RAG evaluation](10-rag-evaluation.md)
11. [Source map](source-map.md)
12. [2026-07-17 change analysis](changes/0cda7bf-to-2026-07-17.md)

The deterministic inventory used as a starting point is retained under `_inventory/`. It includes build products and dependencies, so it is not used as primary product evidence.

## Stack summary

| Runtime | UI | Persistence | Retrieval | Packaging |
| --- | --- | --- | --- | --- |
| macOS 13+ / Swift | SwiftUI, AppKit, Quick Look | GRDB + SQLite | SQLite-backed vectors, Accelerate, Apple/Ollama/cloud embeddings | Xcode project, Sparkle |
| Windows 11 / Electron | React + TypeScript | sql.js + SQLite file | Local/Ollama/cloud embeddings | electron-builder, NSIS, portable EXE |

## Confidence

- High: user-visible macOS behavior, domain models, persistence schema, service boundaries, and automated test intent.
- High: Windows IPC surface, current renderer entry points, and implemented service behavior.
- Inferred: exact performance limits on large libraries and model-specific quality.
- Platform validation required: Windows shell integration, installer behavior, DPAPI storage, tray behavior, and auto-update against a real signed release feed.

## Review rule

The macOS source is the normative feature specification. Existing overview files are supporting context only where they agree with current source and tests.

## Change history

| Date | Baseline | Documentation synchronized |
| --- | --- | --- |
| 2026-07-17 | `0cda7bf` → current product update | Search and Smart Search presentation, confidence ranking, persistent chat execution, model onboarding, managed service updates, selective indexing, Windows parity, build and verification records |
| 2026-07-16 | Initial repository analysis | Product overview, architecture, data model, integration map, onboarding, Windows parity, and verification baseline |
