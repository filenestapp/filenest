# Verification Strategy

## Required local gates

### macOS baseline

- Build the current app target.
- Run the complete `FileNestTests` suite.
- Treat existing failures as blockers unless proven unrelated and documented.

### Windows code-level gates

- Strict TypeScript type check.
- Unit tests for pure policy, query, chunking, context, normalization, and localization behavior.
- Integration tests using a temporary database and filesystem for indexing, organization, sessions, metrics, and rollback behavior.
- Electron production build.
- No root-level generated bundles.

## Parity test families

| Family | Required assertions |
| --- | --- |
| Eligibility | categories, hidden/lock/partial files, directories |
| Watcher | stability, duplicate events, bounded directory inspection, managed-content audit, retry, stop generation, restart reconciliation, baselines |
| Indexer | hashing, unchanged skip, mutation rejection, per-file concurrency, atomic replacement, pause/stop |
| Extraction | each supported family, malformed fallback, image/OCR routing |
| Organization | priority, ignore, hybrid topic, traversal, conflicts, cross-volume, rollback |
| Search | literal SQL wildcard handling, path/note/content, semantic ranking, confidence display policy, date intent, sorting |
| Chat | context budget, retrieval count, file-only mode, immediate question durability, 40-message history paging, related-file confidence, retry replacement, cancellation, metrics, fallback |
| Duplicates | SHA-256 grouping, oldest/original retention, vector suppression, revalidation before Recycle Bin removal |
| Settings | defaults, normalization, independent providers, signature changes, secret persistence |
| UI contract | each API entry point reachable, no stale macOS copy in Windows surfaces |

## Windows release gates

Run on x64 and ARM64 Windows 11:

1. Install signed NSIS build and launch from Start Menu.
2. Verify portable build without installation.
3. Add watched folders, process or preserve existing entries, and restart.
4. Verify stable file and directory processing.
5. Verify Explorer, Recycle Bin, preview, startup, tray, and close-to-tray.
6. Verify local Ollama/Docling/OCR installation and model lifecycle.
7. Verify managed FFmpeg installation, Whisper runtime/model lifecycle, and audio/video transcription on CPU and supported GPU configurations.
8. Verify DPAPI ciphertext does not contain plaintext API keys.
9. Verify signed update discovery, download, restart, and rollback behavior.

## Reporting rule

The final report must separate `Passed locally`, `Passed on Windows`, and `Requires publisher infrastructure`. “100% parity” is reserved for the point where all applicable gates pass.

## Verification record — 2026-07-19

### Passed locally

| Gate | Result |
| --- | --- |
| macOS baseline XCTest | 339 tests passed on the latest rerun, 0 failed |
| Semantic chunking and persistence regression tests | passed: paragraph/sentence boundaries, whole-word emergency fallback, semantic overlap, parent retention, table headers, Docling sentence repair, and orphan-parent cleanup |
| Windows TypeScript type check | passed |
| Windows Vitest | 36 tests passed, 0 failed |
| Signed macOS Release build and launch verification | passed; installed app satisfies its designated requirement |
| Windows Electron production build | passed for main, preload, and renderer bundles |
| Windows Electron runtime UI smoke on the development host | passed; an existing database migrated successfully, the application shell and Library rendered, and the duplicate-file dialog opened with no renderer error |
| Windows source language scan outside localization resources | passed |
| Root generated-JavaScript scan | passed; generated Electron bundles remain inside `FileNestWindows/out/` |

Commands used:

```bash
xcodebuild -project FileNest.xcodeproj -scheme FileNest -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData test
cd FileNestWindows
npm run typecheck
npm test
npm run build
cd ..
./script/build_and_run.sh --verify
```

The semantic chunking checks are concentrated in the macOS `IndexerServiceTests`, `SQLiteStoreTests`, `AppSettingsTests`, and `AppStateTests`, plus the Windows parity suite. Windows now additionally verifies parent retention, retrieval children, entity extraction, weighted fusion, compatible reranker endpoints, full Smart Search filters, stable citation validation, bounded retrieval traces, transcript chunk construction, Whisper setting normalization, adaptive indexing concurrency, chunk pagination, mixed-script lexical boundaries, recursive one-time organization with repository exclusion, SHA-256 duplicate linking, directory inspection budgets, confidence result policy, and 40-message history pages. A 268-page financial filing was also used as a private macOS runtime probe. The pre-repair semantic pass produced 1,424 retrieval children from 854 parents and removed the known mid-word prefixes from the earlier index. A later adjacent-Docling-fragment repair was verified by unit test; the full private fixture was not rerun after that final repair, so the 1,424 count is not presented as a final post-repair benchmark.

### Not yet passed on Windows

- x64 and ARM64 installation and portable launch.
- NTFS watcher behavior under real browser/download workloads and cross-volume moves.
- File Explorer, Recycle Bin, startup registration, tray lifecycle, and close-to-tray.
- Installed Office COM fallback for legacy DOC/XLS/PPT files.
- Packaged DPAPI secret encryption and Ollama/Docling/Tesseract/FFmpeg/Whisper managed-runtime behavior.

### Requires publisher infrastructure

- Authenticode signing and reputation checks.
- Production HTTPS update feed, signed update download, restart, and rollback.
