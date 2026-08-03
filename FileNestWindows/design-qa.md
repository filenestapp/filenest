# Windows-to-macOS Workspace Design QA

## Scope

This review covers the Windows Electron Settings workspace and the Find with Chat / Chat with File experience.

## Reference visual truth

- macOS Settings implementation reference: `FileNest/UI/SettingsView.swift`.
- macOS settings section model: `FileNest/App/AppState.swift` (`SettingsSection` and `SettingsSectionGroup`).
- User-provided macOS Find with Chat reference: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-d74cac3d-cbb4-4323-9b15-a957f4825bda.png`.
- macOS chat implementation reference: `FileNest/UI/ChatView.swift`.
- The matching installed macOS Settings workspace could not be captured in this pass because the local desktop session is unavailable for Computer Use.

## Implemented alignment

- The settings shell now mirrors macOS: a 220px sidebar owns the brand/back action, local search, and grouped navigation; the detail pane owns the icon-led 76px title header and automatic-save status.
- Navigation labels, grouping, descriptions, and conditional Reindex Task entry align with the macOS section model.
- General now groups runtime state, interface, startup, quick search, automatic organization, and destination location as on macOS.
- Index & Organize now groups watched folders, manual path entry, watched types, vectorization, and index maintenance controls.
- AI Models uses a segmented local/cloud/search-only source selector, matching the macOS source selection pattern while retaining Windows provider operations.
- Find with Chat now uses the macOS brand-led empty state, natural-language explanation, and direct-send suggestion actions.
- Chat with File now has a file-specific empty state, direct-send file analysis suggestions, an expanded attachment summary, and a file-only retrieval scope that hides library citation cards.
- The compact file context pill, Back action, New Chat reset, and rounded composer controls match the macOS ChatView hierarchy more closely.

## Functional verification

- `npm run typecheck` passed.
- `npm test -- --run` passed: 47 tests.
- `npm run build` passed.

## Visual verification status

No rendered Windows Settings or Chat screenshot at the matching macOS viewport is available in this pass. The implementation is grounded in the supplied macOS Chat reference and macOS source layout, but the required visual artifact, matched viewport, pixel dimensions, density normalization, full-view comparison, and focused-region comparison cannot be produced while the local desktop session is unavailable.

## Final result

**blocked** — capture the installed macOS and rebuilt Windows Settings, Find with Chat, and Chat with File states at the same viewport. Compare sidebar width, header geometry, grouped-form spacing, composer geometry, empty states, file-context pill, attachment card, citations, typography, icons, and localized copy before marking these workspaces as visually accepted.
