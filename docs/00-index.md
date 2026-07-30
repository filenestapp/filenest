# FileNest Product and Engineering Documentation

- Repository: `mactools`
- Repository path: `/Users/la230048/work/ai.prompt/mactools`
- Product baseline: current macOS implementation under `FileNest/`
- Windows implementation: `FileNestWindows/`
- Last synchronized: 2026-07-24 (Asia/Singapore)
- Code baseline: `91848e2` plus the Agent Skills and RAG learning update documented below

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
11. [Semantic chunking and reindexing](11-semantic-chunking-and-reindexing.md)
12. [Release process](12-release-process.md)
13. [Source map](source-map.md)
14. [2026-07-17 change analysis](changes/0cda7bf-to-2026-07-17.md)

The deterministic inventory used as a starting point is retained under `_inventory/`. It includes build products and dependencies, so it is not used as primary product evidence.

## Supplemental analysis

- [macOS product and business analysis snapshot](../analysis/README.md) records the July 16, 2026 decision report, its reproducible notebook, source artifact, and test-run evidence. It is historical product research rather than the current engineering specification.

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
| 2026-07-24 | Agent Skills and RAG learning update | Standard `SKILL.md` runtime, progressive capability routing, managed skill precedence, feedback-driven skill evolution, safety validation, settings management, and end-to-end tests |
| 2026-07-20 | Latest working-tree macOS product update | Persistent assistant-answer feedback, copy-success state, localized feedback actions, and Windows parity implementation; macOS preview modes recorded as platform-specific QA tooling |
| 2026-07-19 | Latest working-tree macOS product update | SHA-256 duplicate management, persisted retrieval confidence, 40-message chat paging, file-category reindex scope, creation-date backfill, budgeted directory inspection, managed-content audit, one-time migrations, and Windows parity implementation |
| 2026-07-17 | `839c410` | Semantic boundary chunking, parent/child terminology, runner EOF recovery, parent-row cleanup, and selective reindex behavior |
| 2026-07-17 | `0cda7bf` → current product update | Search and Smart Search presentation, confidence ranking, persistent chat execution, model onboarding, managed service updates, selective indexing, Windows parity, build and verification records |
| 2026-07-16 | Initial repository analysis | Product overview, architecture, data model, integration map, onboarding, Windows parity, and verification baseline |
