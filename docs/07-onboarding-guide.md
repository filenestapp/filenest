# Engineering Onboarding Guide

## Fastest reading path

1. Read `docs/01-product-overview.md` and `docs/02-feature-map.md`.
2. Read macOS `FileNest/App/AppState.swift` and `FileNest/App/AppSettings.swift`.
3. Read `FileNest/Domain/Models.swift` and `FileNest/Storage/SQLiteStore.swift`.
4. Follow one complete flow through watcher, indexer, organizer, and chat services.
5. Read the corresponding macOS tests before changing behavior.
6. For Windows, start with `src/shared/types.ts`, `src/main/app-controller.ts`, and `src/renderer/src/App.tsx`.

## macOS setup

```bash
xcodegen generate
xcodebuild -project FileNest.xcodeproj -scheme FileNest -configuration Debug -destination 'platform=macOS' test
./script/build_and_run.sh --verify
```

The run script uses a signed Release build by default. Use `./script/build_and_run.sh --debug` for LLDB or set `FILENEST_CONFIGURATION=Debug` explicitly when a non-debug command must install a Debug bundle.

Runtime data is stored in Application Support. Logs are managed by `AppLogService`; do not rely on stale paths documented by the original MVP README.

## Windows setup

```bash
cd FileNestWindows
npm ci
npm run dev
```

Verification:

```bash
npm run typecheck
npm test
npm run build
npm run package:win
```

## Files to understand first

| Change area | macOS source | Windows source |
| --- | --- | --- |
| Settings | `AppSettings.swift`, `SettingsView.swift` | `shared/types.ts`, `defaults.ts`, `SettingsPage.tsx` |
| Discovery | `FileWatcherService.swift` | `watcher.ts` |
| Indexing | `IndexerService.swift`, `AccelerateVectorStore.swift` | `indexer.ts`, `embedding.ts`, `database.ts` |
| Organization | `OrganizerService.swift`, policies | `organizer.ts`, `file-policy.ts` |
| Search/chat | `ChatService.swift`, `ChatContextManager.swift` | `chat.ts`, `llm.ts` |
| Preview | `FilePreviewView.swift` | `components.tsx`, preview protocol in `index.ts` |
| UI navigation | `MainView.swift` | `App.tsx`, `Sidebar.tsx` |

## Safe change rules

1. Treat macOS behavior and tests as the product contract.
2. Preserve the order: stable source → index → organize.
3. Never commit vectors for a source version that was not verified after extraction/embedding.
4. Keep file moves and database paths consistent; distinguish move, database, rollback, and rollback-failure errors.
5. Any settings change that changes the vector space or extracted content must mark or rebuild the affected index scope.
6. Do not expose filesystem paths to the renderer except through typed, allowlisted operations.
7. Keep all source identifiers, comments, logs, errors, prompts, and tests in English. Chinese belongs only in localization resources or explicit language fixtures.
8. Keep Smart Search an explicit escalation from normal results; editing a query must return to normal search semantics.
9. Keep long-running chat tasks owned by persistent state rather than the visibility lifecycle of one page.

## Useful first tasks

- Add one parity test for a behavior already covered on macOS.
- Add a localization key and use it in one renderer surface.
- Improve one IPC validation path without changing product behavior.

## Maintainer input required

- Production signing identities and update hosting.
- Supported Windows versions below Windows 11, if any.
- Release-quality model recommendations by device tier.
- Final privacy policy and telemetry decision; no telemetry is currently specified.
