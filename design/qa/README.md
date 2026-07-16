# FileNest UI Design QA

This document records the visual acceptance evidence stored in this directory.

## Library sorting, calendar, and expanded preview QA — 2026-07-16

- Written source truth: default to the 20 most recently modified files, incrementally load 20 more, support ascending/descending Size and Modified sorting, date browsing by Created or Modified, unified right inspector, and temporary sidebar collapse while previewing.
- Existing inspector visual reference: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-19710190-875b-4b30-a3a3-40fc0e7c5c78.png`.
- Native implementation render: `/Users/la230048/work/ai.prompt/mactools/design/qa/current-library/implementation-library-sort-calendar.png`.
- Existing inspector comparison evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/file-preview-reference-comparison.png`.
- Viewport: native SwiftUI hierarchy rendered at 1180 × 840 pt, English locale, light appearance, with 25 realistic local documents.

### Findings

- No actionable P0, P1, or P2 visual issue remains in the tested library state.
- The Modified column is visibly active with a descending chevron, while Size and Modified retain stable widths and remain available when the right inspector is open.
- The date control sits at the end of the existing category-chip row and uses the same capsule, border, spacing, SF Symbol, and semantic-accent treatment as the established FileNest design system.
- The initial list renders only the first 20 records; the next 20 are appended by a lazy end sentinel. The viewport shows a dense first page without exposing a premature loading row.
- The inspector contains one Reveal in Finder action, keeps Quick Look as the visual preview surface, and adds a full-area expanded-preview hit target with a hover affordance.
- The library and inspector scroll views use overlay mini scrollers with automatic hiding, avoiding persistent heavy scroll gutters.
- The source inspector comparison remains structurally valid: identity, location, metadata, quick actions, preview, notes, index status, and deletion retain the approved hierarchy.

### Primary interactions verified

- Verified default Modified descending order, Modified ascending order, and Size descending order with deterministic unit tests.
- Verified Created-date and Modified-date filters independently with a fixed calendar/time zone.
- Verified opening a preview collapses an expanded left sidebar and closing it restores that prior state; a sidebar that began collapsed remains collapsed.
- Verified full-screen preview uses a key-capable borderless native window on the current display, with a visible Exit action and Escape keyboard shortcut.
- Verified sortable headers and previewable rows expose pointing-hand hover feedback.
- Ran 218 unit/integration/localization tests with zero failures, built and installed the signed app, and deep-verified its designated requirement.

### Comparison history

- Iteration 1 — corrected: SwiftUI `fullScreenCover` is unavailable on macOS; replaced it with a focused native full-display preview window.
- Iteration 2 — passed: sorting hierarchy, date control alignment, inspector density, and destructive/action separation are correct.

## Final result

passed

## Version and software-update QA — 2026-07-15

- Implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-version-updates.jpeg`.
- Viewport: native FileNest settings window at 1080 × 768 px, English system locale, light appearance.
- State: FileNest 0.2.0 build 2, generated build timestamp, no update source configured.

### Findings

- No actionable P0, P1, or P2 issue remains in the tested settings state.
- The version card follows the existing grouped Form rhythm, uses the real app icon, and keeps version, build number, build time, source state, toggles, and the primary update action within one scannable section.
- The initial nested TextField label produced a wrapped URL outside the control. It was replaced with a dedicated prompt and accessibility label; the final field stays on one line and aligns with the surrounding settings rows.
- The Check for Updates action is visibly disabled until a valid HTTPS appcast URL is configured.
- The application menu exposes the same update action and disabled state as the settings page.
- Build metadata inside the app bundle reports marketing version 0.2.0, build 2, and an ISO 8601 UTC build timestamp.
- Sparkle.framework is embedded in the app bundle; production installation remains gated by the publisher's Developer ID, EdDSA key, signed appcast, and HTTPS release hosting.

### Primary interactions tested

- Opened the General settings tab and verified the version/build timestamp rendered from the built app rather than hard-coded view copy.
- Verified the update-source TextField exposes a single accessible `Update Source` control with an HTTPS appcast prompt.
- Verified Save URL and Check for Updates disabled states with an empty source.
- Opened the FileNest application menu and verified Check for Updates is present and linked to the same service state.
- Ran three focused persistence, secure-URL validation, and localization tests with zero failures.
- Built and deep-signature-verified the Debug app with Sparkle embedded.

### Comparison history

- Iteration 1 — blocked: P2 appcast placeholder wrapped outside the editable field because the nested TextField contributed a second form label.
- Fixes made: used a prompt-only TextField, hid its internal label, added an explicit accessibility label, and rechecked the live native render.
- Iteration 2 — passed: field alignment, version hierarchy, disabled states, and menu integration are correct.

## Final result

passed

## Unified right-side file preview QA — 2026-07-16

- Source visual truth path: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-19710190-875b-4b30-a3a3-40fc0e7c5c78.png`.
- Native implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-right-file-inspector.png`.
- Focused implementation crop: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-right-file-inspector-crop.png`.
- Same-input comparison evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/file-preview-reference-comparison.png` (reference left, implementation right).
- Viewport: native FileNest window at 1180 × 840 pt on a 2× display; light appearance; 334 pt inspector width.
- State: Documents filter selected, a real indexed PDF selected from the live local library, and its first page rendered with Quick Look.

### Findings

- No actionable P0, P1, or P2 visual difference remains.
- The inspector enters from the right, keeps a fixed narrow information hierarchy, and preserves the reference order for file identity, location, metadata, quick actions, and preview.
- The selected file row remains visibly highlighted while the inspector is open. At the narrower remaining table width, secondary Category, Size, and Modified columns collapse so names and actions do not wrap or overlap.
- The production inspector adds the requested editable Note section and destructive Move to Trash section below the reference content; both stay reachable through the inspector's independent vertical scroll.
- Actual PDF content is rendered through Quick Look rather than a placeholder. File type icons and all action glyphs use native macOS assets.
- P3-only differences: the implementation uses FileNest's existing material surface and stronger semantic accent, while the supplied crop uses a plain white Windows-style surface. These preserve the native app design system and do not alter hierarchy or behavior.

### Primary interactions tested

- Selected the Documents filter and invoked the row's named Preview File accessibility action once; the right inspector opened without a sheet or separate window.
- Verified the file-list Action column contains Document Chat, Reveal in Finder, and Move to Trash only; Preview and Note icons are absent.
- Verified every remaining preview entry point routes through the shared `AppState` inspector state; no standalone preview sheet remains in the SwiftUI source.
- Verified destructive removal uses a second confirmation, cancels active indexing for that file, moves the source with the macOS Trash API, removes its database/vector records, closes the inspector, and refreshes the live list.
- Ran 216 unit/integration/localization tests with zero failures, built with the stable Apple Development identity, deep-verified the signature, and installed `/Users/la230048/Applications/FileNest.app`.

### Comparison history

- Iteration 1 — passed: the first native comparison matched the supplied panel's hierarchy and density with no P0/P1/P2 correction required.

## Final result

passed

## Chat retrieval cards and Markdown answer QA — 2026-07-15

- Source visual truth paths: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-90a7f6a3-f4e8-46e3-b2a3-fd6162a53ff7.png` and `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-cffa72a6-05cb-4fcc-8eef-76fe5124254d.png`.
- Matched-files implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-chat-matched-files.jpeg`.
- File-preview implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-chat-matched-file-preview.jpeg`.
- Formatted-answer implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-chat-markdown-answer.jpeg`.
- Viewport: native FileNest main window at 1232 × 768 px; native preview sheet at 860 × 680 px; light appearance.
- State: a live local-index query matched five real files, local Ollama was generating a streamed answer, and the selected PDF preview was opened from the matched-file strip.
- Full-view evidence: the three implementation screenshots above cover retrieval progress, preview, and final response.
- Focused comparison evidence: the supplied references are already cropped to the exact progress and answer defects; they were compared side-by-side with the corresponding full-window implementation captures.

### Findings

- No actionable P0, P1, or P2 differences remain.
- Retrieval progress: the original status hierarchy and green completion treatment are preserved. Real matched files now appear between the match count and AI-analysis status as a compact horizontal strip.
- File cards: each card uses the real file-type icon, truncated filename, category, size, and a preview affordance. The strip scrolls horizontally without wrapping or increasing message height.
- Preview behavior: clicking the PDF card opens the existing production preview sheet with rendered pages, Finder action, note editor, AI summary, and save/reindex action.
- Answer formatting: new responses render native Markdown blocks with headings, paragraphs, lists, block quotes, and code styling. The live answer is concise and no longer exposes retrieval indexes, `File:` markers, raw delimiters, or duplicated source metadata.
- Prompt quality: the retrieval prompt now requests the user's language, clean Markdown, short labels, readable locations, and factual grounding while reserving exact paths for explicit requests.
- Accessibility: the matched-files group exposes a labelled horizontal scroll area and individual `Preview <filename>` buttons.
- Responsiveness: four complete cards plus a clipped fifth-card edge make horizontal overflow discoverable at the tested width; surrounding progress and composer controls do not shift or overlap.

### Primary interactions tested

- Submitted a real indexed-file query and verified search, match, matched-card, and AI-analysis stages in the live app.
- Clicked the `00000394-SNH9727U.pdf` result while generation was active and verified that its two-page PDF preview opened successfully.
- Closed the preview during generation and verified the progress state remained intact.
- Waited for streaming completion and verified that the regenerated answer used clean Markdown and omitted internal retrieval syntax.
- Verified the full automated test suite and localization coverage with zero failures.

### Comparison history

- Iteration 1 — passed: the requested horizontal file results, clickable preview behavior, prompt cleanup, and formatted response rendering are present with no remaining P0/P1/P2 issue.

## Final result

passed

## Top-level sidebar controls and retry QA — 2026-07-15

- Source visual truth path: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-0b99780b-a6aa-4e37-af76-79d3329f3028.png`.
- Implementation screenshot path: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/com.openai.sky.CUAService/FileNest Screenshot 2026-07-15 at 6.20.40 PM.jpeg`.
- Viewport: native FileNest main window at 1080 × 768 px, light appearance.
- State: sidebar fully collapsed, existing conversation selected, last user question visible.
- Full-view comparison evidence: the implementation screenshot verifies that the sidebar and divider are absent and the chat content expands to the full window width.
- Focused-region evidence: the supplied source is already a focused 410 × 62 px title-bar crop; it was compared directly with the implementation title bar. A second crop was unnecessary.

### Findings

- No actionable P0, P1, or P2 visual difference remains.
- The sidebar toggle now lives in the native top toolbar beside the macOS traffic-light controls, matching the supplied placement and using a system SF Symbol at native toolbar scale.
- In collapsed state, the entire sidebar is removed. The top toolbar exposes Expand Sidebar, New Chat, Watching, Indexing, AI, and Settings controls in one horizontal row.
- Bottom status controls use the same 16 × 16 pt inner symbol canvas and 32 × 32 pt hit target, giving them consistent optical size while preserving accessible targets.
- Back and Forward controls shown in the generic source crop are intentionally not reproduced; the requested FileNest-specific New Chat and status controls occupy that area instead.
- The last user question exposes Copy and Retry actions. Existing assistant responses retain their own Regenerate action.
- Reopening the setup assistant uses one app-level window instead of one sheet per main-window instance. Opening and dismissing it was responsive, and only one setup window appeared.

### Primary interactions tested

- Collapsed and expanded the sidebar and verified that the sidebar divider and all sidebar content disappear and return together.
- Verified the collapsed toolbar accessibility tree exposes Expand Sidebar, Create a New Chat, Watching, Indexing, Local AI, and Settings as separate buttons.
- Opened Settings, launched the setup assistant again, confirmed one window opened without the prior pause, and dismissed it with Set Up Later.
- Verified the final user question exposes Retry This Question in the live accessibility tree.
- Built and launched `/Users/la230048/Applications/FileNest.app`, then ran 148 automated tests with zero failures.

### Comparison history

- Iteration 1 — passed: the native top-toolbar placement, true collapsed state, compact control row, icon sizing, and retry affordance matched the requested behavior without an actionable P0/P1/P2 correction.

## Final result

passed

## Comparison target

- Source visual truth path: `/Users/la230048/work/ai.prompt/mactools/design/prototypes/filenest-local-assistant/main-window.png`
- Secondary source visual truth: `/Users/la230048/work/ai.prompt/mactools/design/prototypes/filenest-local-assistant/menubar-popover.png`
- Interaction source: `/Users/la230048/work/ai.prompt/mactools/design/prototypes/filenest-local-assistant/interaction-rule-editor.png`
- Implementation screenshot path: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-main-window-v3.png`
- Menu implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-menubar-popover-final-crop.png`
- Rule editor implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-rule-editor.png`
- Settings implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-settings-optimized.jpeg`
- Local model management screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-model-management.jpeg`
- Viewport: main window configured at 1180 × 840 pt; Computer Use captured a 1078 × 768 raster and it was normalized to the source's 1487 × 1058 raster at the same 1.405 aspect ratio.
- State: light theme, local mode, listening enabled, 68 indexed files, chat result for “帮我找上周下载的合同终稿”.

## Evidence

- Full-view comparison: `/Users/la230048/work/ai.prompt/mactools/design/qa/main-comparison-v3.png`
- Focused chat/detail comparison: `/Users/la230048/work/ai.prompt/mactools/design/qa/chat-detail-comparison-v3.png`
- Menu-bar popover comparison: `/Users/la230048/work/ai.prompt/mactools/design/qa/menubar-comparison-final.png`
- Focused regions were required because file-row typography, icon scale, button tint, status-card spacing, and menu density were not reliably readable in the full-view comparison.

## Findings

- No actionable P0, P1, or P2 visual differences remain.
- Fonts and typography: the implementation uses the native macOS system font with matched hierarchy and strengthened file-row weights. Text remains readable without clipping or unwanted wrapping. The generated source's rasterized glyphs are slightly softer/larger in isolated areas; this is classified as P3 because the hierarchy and density match after normalization.
- Spacing and layout rhythm: sidebar width, header height, chat row structure, first-result emphasis, composer position, status-card position, popover sections, dividers, radii, and footer alignment match the source composition.
- Colors and tokens: the indigo-to-violet primary gradient, lavender selection state, green listening/relevance states, warm white surfaces, borders, and semantic warning surface are consistently tokenized and visually aligned.
- Image quality and assets: app, brand, and menu-bar assets are real raster assets from the generated design suite; file icons are native high-resolution macOS icons. No emoji, placeholder drawing, inline SVG, or CSS-style substitute is used.
- Copy and content: screen titles, local privacy copy, file names, paths, timestamps, counts, menu actions, and rule-editor summary are coherent and match the design state.
- Icons and affordances: SF Symbols are used consistently for standard controls, with the generated brand assets reserved for product identity. Buttons, toggles, menus, fields, row actions, and keyboard shortcut for adding a rule have native focus and accessibility semantics.
- Accessibility and resilience: controls expose accessibility labels/roles, disabled states remain legible, persistent composer/footer controls do not overflow at the configured minimum window size, and scroll views protect dense content.

## Comparison history

### Iteration 1 — blocked

- Earlier findings: P1 file results were wrapped in one large card instead of separate rows; preview showed cloud mode and live index count; file hierarchy was too compact.
- Fixes made: separated the first emphasized result from subsequent rows, matched local-mode and 68-file showcase data, corrected timestamps/sizes/paths, and increased row heights.
- Post-fix evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/main-comparison-v2.png`.

### Iteration 2 — blocked

- Earlier findings: P2 sidebar brand/navigation and status card were vertically too low; composer was about 40 px too low after normalization; file-row typography and Finder actions lacked source emphasis.
- Fixes made: recalibrated sidebar top/bottom spacing, expanded status-card section rhythm, moved the composer to the source baseline, increased file typography/icons, tinted Finder actions, and restored the active violet send affordance.
- Post-fix evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/main-comparison-v3.png` and `/Users/la230048/work/ai.prompt/mactools/design/qa/chat-detail-comparison-v3.png`.

### Iteration 3 — passed

- Earlier findings: P2 menu preview was too short, clipped the quit row, repeated file content because showcase IDs collided, used a cooler material surface, and did not match source timestamps.
- Fixes made: increased the production popover to 380 × 660 pt, created stable unique showcase IDs, added all four source files and exact times, applied the violet toggle tint, and matched the near-white surface and typography.
- Post-fix evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/menubar-comparison-final.png`.

## Primary interactions tested

- Main navigation between chat, file library, and rules.
- Search/filter controls and Finder affordances exposed in the live accessibility tree.
- Menu popover status, toggle, organize, reindex, recent-file, main-window, settings, and quit controls rendered with accessible roles.
- Rule editor fields, stepper, toggle, validation summary, cancel, and save controls rendered with accessible roles; `⌘N` is also wired to the add-rule action.
- Final app launch verified through `/Users/la230048/work/ai.prompt/mactools/script/build_and_run.sh --verify`.

## Optimization follow-up

- Reduced the production menu-bar status icon from 18 × 18 pt to 14 × 14 pt so it aligns with standard macOS menu extras.
- Corrected the menu-bar asset's 128 pt intrinsic-size regression shown in the supplied status-bar screenshot by passing a copied template `NSImage` whose intrinsic size is explicitly 14 × 14 pt; the SwiftUI label frame remains constrained to the same size.
- Replaced the rules navigation symbol with `list.bullet.rectangle` to communicate a structured rule list instead of generic settings.
- Added a visible Settings entry in the main sidebar and a native three-tab Settings scene for general behavior, indexing/organization, and AI model configuration.
- Verified all three Settings tabs through the live accessibility tree, including persisted values, directory management, index maintenance, model selection, and local embedding status.

## Local model and AI rule follow-up

- Replaced the responder-selector Settings opener with a dedicated `Window(id: "settings")` and `openWindow` actions from the sidebar, chat, menu popover, and app command. A live click opened the distinct `FileNest 设置` window.
- Restored the menu-bar icon to a standard 16 × 16 pt intrinsic and layout size.
- Added Ollama executable detection, managed service start/stop, server refresh, installed-model listing and selection, streamed pull progress, and confirmed deletion.
- Added an AI rule generator that returns a validated, editable extension rule. AI-generated rules now use the same deterministic priority matcher and watcher-driven automatic execution path as manual rules.
- Live accessibility verification covered the model service controls, download field, installed-model empty state, and the complete AI-rule composer surface. No model download or file move was triggered during QA.

## Follow-up polish

- P3: the implementation deliberately uses the approved generated square app mark consistently inside the app, while the source mock shows a flatter woven mark in a few placements.
- P3: inactive-window traffic-light color and screenshot antialiasing differ from the generated raster and are controlled by macOS.

## Model recommendation dropdown QA — 2026-07-14

- Source visual truth path: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-90d72a58-8d8f-4995-a2e7-74a589b3e18e.png`.
- Implementation screenshot path: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-model-recommendation.png`.
- Viewport: native FileNest Settings window, 760 × 732 px capture, light theme.
- State: AI 模型 → 本地 Ollama; host computer detected as 32GB; recommended profile selected.
- Full-view evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-model-recommendation.png`.
- Focused comparison evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/model-recommendation-comparison.png`.
- Focused comparison was required because the dropdown summary, four configuration fields, and recommendation copy are too small to judge reliably in the full settings-window capture.

### Findings

- No actionable P0, P1, or P2 differences were found in the first comparison pass.
- Fonts and typography: native macOS system typography preserves the reference hierarchy and compact table-like density; model identifiers, Embedding size, and context range remain readable without truncation.
- Spacing and layout rhythm: the reference table is intentionally collapsed into one native menu row plus a four-field selected-profile summary, matching the requested dropdown interaction while preserving the original column order.
- Colors and visual tokens: the control stays on the existing neutral settings surface; indigo identifies detected memory and green identifies the active recommendation without reducing contrast.
- Image quality and asset fidelity: this component contains no raster illustration or custom identity asset; the memory and recommendation affordances use appropriate native SF Symbols.
- Copy and content: all five reference memory tiers, generation models, Embedding sizes, and context ranges are represented exactly. The 32GB profile shows `qwen3.5:9b`, `4b`, and `16K–32K`.

### Interaction evidence

- Opened the model configuration menu and verified the first item is `推荐 · 32GB 内存 — qwen3.5:9b`.
- Verified all remaining tiers are present once, in reference order after the recommendation: 8GB, 16GB, 24GB, and 64GB 以上.
- Selected the 8GB profile and verified the summary changed to `qwen3.5:2b`, `0.6b`, and `4K–8K`, then restored the automatic 32GB recommendation.
- No model download action was triggered during QA.

### Comparison history

- Iteration 1 — passed: no P0/P1/P2 mismatch required a visual correction after rendering. The table-to-dropdown difference is the explicit requested interaction change, not design drift.

## Final result

passed

## File-list actions, indexing controls, and collapsible-sidebar QA — 2026-07-15

- File-list source path: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-bcb6c182-50e7-4ffe-82dc-88b20c01a610.png`.
- File-list hover screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-library-actions-hover.jpeg`.
- File-list preview screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-library-row-preview.jpeg`.
- Expanded menu indexing screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-indexing-menu-status.jpeg`.
- Collapsed sidebar screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-collapsed-sidebar-indexing.jpeg`.
- Viewport: native FileNest main window and system menu-bar panel, light appearance.
- State: a live automatic indexing run, including running, paused, stopped, and restarted states.

### Findings

- No actionable P0, P1, or P2 issue remains in the tested states.
- File-list rows use a consistent action column, retain one-line headers, expose a restrained hover surface, and open the native preview from the row body when the format is supported.
- The menu-bar glyph, expanded menu panel, main-sidebar status button, settings controls, library control, and command-menu actions all consume the same indexing state and progress.
- Active reindex actions show the task state, animate, and remain disabled until the task is stopped or completed.
- Pause, resume, stop, and restart preserve completed work and transition at safe per-file checkpoints, avoiding a partially committed document index.
- The sidebar collapses to a compact 76 pt rail while keeping file, chat, listening, indexing, AI, and settings entry points accessible through icons and tooltips.
- The menu-bar activity animation uses a low-frequency discrete frame from app state. A TimelineView-based label implementation was rejected after profiling exposed a main-thread update loop; the final idle build measured approximately 0% CPU and 26 MB memory, while a real indexing run measured approximately 25% CPU and 106 MB including extraction and embedding work.
- New indexing and sidebar copy has English localization coverage.

### Primary interactions tested

- Opened the system menu while indexing and verified live count, progress bar, current filename, Pause, Stop, and disabled reindex actions.
- Paused at 4/849, confirmed progress held and Resume appeared, then resumed and confirmed the current filename advanced.
- Stopped at a safe checkpoint, confirmed Restart appeared, restarted the remaining workload, and stopped the QA run before handoff.
- Collapsed and expanded the main sidebar and verified the compact rail retained all bottom status controls.
- Opened the sidebar indexing popover and verified it showed the same progress and controls as the menu panel.
- Hovered file rows and individual actions, clicked a supported row, and verified the exact document opened in the preview sheet.
- Ran five focused state-machine, pause/resume/stop, progress, cancellation, and localization tests with zero failures.

### Comparison history

- Iteration 1 — blocked: the first animated menu-bar label caused continuous SwiftUI label evaluation and excessive CPU/memory usage.
- Fixes made: moved menu-bar animation to a shared 550 ms state frame, retained smooth TimelineView animation only inside ordinary window content, and profiled the rebuilt app in idle and active states.
- Iteration 2 — passed: synchronized controls, file-row interactions, collapsed layout, and runtime performance all behaved as intended.

## Final result

passed

## File-library row interactions QA — 2026-07-15

- Source visual truth: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-bcb6c182-50e7-4ffe-82dc-88b20c01a610.png`.
- List implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-library-actions-hover.jpeg`.
- Row-click preview screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-library-row-preview.jpeg`.
- Viewport: native FileNest main window at 1080 × 768 px, light appearance.
- State: populated local file library with image rows and the consolidated action column.

### Findings

- No actionable P0, P1, or P2 differences remain for the requested list changes.
- The former Preview and Note headers plus the unlabeled Finder column are consolidated into one fixed-width Actions column, eliminating the narrow Preview-header wrap while keeping all three controls aligned.
- Row hover uses the existing semantic selection surface; each action gets an additional elevated hover surface, small scale response, and native help/accessibility label.
- The file metadata area is a single-click preview target when Quick Look is supported. Action controls remain independent, and unsupported file types retain a disabled preview affordance.
- Existing native file icons, typography, separators, localization, dark-mode tokens, note editor, Finder action, and context menu are preserved.

### Primary interactions tested

- Opened the live file library and verified the `操作` header stays on one line with Preview, Note, and Finder controls aligned beneath it.
- Clicked the second file row by its row target and verified the Quick Look preview sheet opened for that exact file.
- Verified the accessibility tree exposes the row preview action and distinct Preview, Note, and Finder buttons.
- Built the Debug app successfully after the change.

### Comparison history

- Iteration 1 — passed: the consolidated action column removed the supplied wrapping defect without changing the existing table density or metadata hierarchy.

## Final result

passed

## Global recent-chat sidebar and Settings consolidation QA — 2026-07-14

- Source visual truth paths: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-d36b7068-d054-4c42-b611-07481feb123c.png` and `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-8df18434-5466-49c5-b0d5-359c2dc6420a.png`.
- Main implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-sidebar-recent-final.jpeg`.
- Loaded-session screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-sidebar-recent-loaded.jpeg`.
- AI Models direct-entry screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-settings-ai-direct.jpeg`.
- Statistics Settings screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-settings-statistics.jpeg`.
- Rules Settings screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-settings-rules.jpeg`.
- Viewport: native FileNest main window at 1079 × 768 px and native Settings window at 1040 × 760 px, dark appearance.
- State: chat selected; first ten recent local sessions visible; bottom utility column pinned; populated statistics/rules; local Ollama AI Models tab selected.
- Full-view comparison evidence: the two supplied sidebar references and `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-sidebar-recent-final.jpeg` were opened in the same comparison input.
- Focused-region evidence was not needed because both source references are already tightly cropped sidebar regions and the final full-window capture preserves the entire 255 pt sidebar at a readable scale.

### Findings

- No actionable P0, P1, or P2 differences remain.
- Fonts and typography: native macOS system type preserves the compact project-list hierarchy from the reference. `最近` is a quiet section label; chat titles use one-line truncation; bottom status copy remains readable without competing with primary navigation.
- Spacing and layout rhythm: the nested 190 pt chat sidebar is removed. Navigation, a bounded recent-chat scroller, and the consolidated Settings/status/index panel now form one stable 255 pt global sidebar. The bottom utility panel stays pinned while sessions scroll independently.
- Colors and visual tokens: existing semantic surfaces, indigo selection, green listening status, dividers, and system dark-mode tokens are preserved. The source images are light-mode structural references; the tested dark appearance is an intentional existing user preference rather than design drift.
- Image quality and asset fidelity: the FileNest brand asset remains sharp and native SF Symbols provide the reference-style folder, chat, settings, compose, chart, and chevron affordances. No placeholder, handcrafted SVG, or code-drawn asset was introduced.
- Copy and content: Statistics and Rules are removed from primary navigation and exposed as named Settings tabs. Recent-session, loading, and status labels are concise and have English localization entries.
- Icons and accessibility: sidebar glyphs share a consistent 15 pt optical size and 20 pt alignment slot. Navigation, recent chats, settings links, tab controls, model menu, and rule controls expose native accessibility roles and labels.
- Responsive behavior: the chat detail receives the full area to the right of the global sidebar; the bounded session list protects the bottom utility column from being pushed off-screen.

### Primary interactions tested

- Verified exactly ten recent sessions are created in the initial accessibility tree.
- Scrolled the recent-chat region downward and verified the next batch is appended only after a downward scroll.
- Selected recent chat rows and verified they route to the global Chat surface; delete remains available from the row context menu.
- Opened the composer model menu, selected `管理模型…`, and verified the Settings window opened with `AI 模型` selected.
- Switched the Settings window to Statistics and Rules and verified their charts, tables, controls, scrolling, AI rule action, and native tab selection.
- Ran 83 unit/integration tests with zero failures.

### Comparison history

- Iteration 1 — blocked: P2 SwiftUI lazy prefetch instantiated more than the requested first ten recent sessions before a user scroll.
- Fixes made: replaced the eager visibility sentinel with a native scroll-bounds observer that only appends another ten sessions when the recent-chat scroller moves downward.
- Post-fix evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-sidebar-recent-final.jpeg`, `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-sidebar-recent-loaded.jpeg`, and the final accessibility capture showing ten initial rows followed by the appended batch after scrolling.
- Iteration 2 — passed: no actionable P0/P1/P2 mismatch remains across the sidebar, Settings tabs, or model-management transition.

## Final result

passed

## Chat sessions, streaming, and file-chat QA — 2026-07-14

- Source visual truth path: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-84058d03-2a1e-40b7-a49f-47c569bac32d.png`.
- Implementation screenshot path: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-chat-sessions-streaming.jpeg`.
- Narrow-window screenshot path: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-chat-narrow.jpeg`.
- Viewport: native FileNest main window, 1185 × 840 pt regular state and 1079 × 768 px compact-window capture, light appearance.
- State: local preview conversation, selected `deepseek-r1:14b` Ollama model, streamed-answer controls, three file citations, and an empty composer.
- Full-view evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-chat-sessions-streaming.jpeg`.
- Focused comparison evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/chat-composer-whitespace-comparison.png` (source above, final composer below).
- Focused comparison was required because the source request specifically concerns the input field's internal vertical whitespace, which is hard to judge in the full-window capture.

### Findings

- No actionable P0, P1, or P2 differences remain.
- Fonts and typography: native macOS system text preserves the existing product hierarchy; session titles, model metadata, message copy, and file metadata remain readable without unintended multiline dates.
- Spacing and layout rhythm: the composer is fixed to a compact 104 pt height, its placeholder is top aligned, and its action row stays pinned to the bottom. The large empty band in the supplied source is removed.
- Colors and visual tokens: semantic surfaces, separators, secondary text, green streaming/local-state indicators, and the indigo send accent remain consistent with the established light/dark token system.
- Image quality and asset fidelity: existing app artwork and file-type icons are retained at native scale; new controls use crisp SF Symbols rather than additional raster assets.
- Copy and content: the active model and streaming state are visible, local-storage behavior is explicit, attachment copy explains file-chat behavior, and all new visible strings have English localization entries.
- Responsive behavior: regular width shows relevance details and a labeled Finder action; compact width drops the optional relevance block and uses an icon-only Finder action while keeping file date and size on one line.

### Primary interactions tested

- Opened the current-model menu and verified the selected model, installed Ollama alternatives, and model-management entry.
- Opened and cancelled the native file picker from the attachment button without changing user files.
- Verified accessible controls below each response for copy, regenerate, file chat, helpful, and not helpful actions.
- Verified new-session creation, session isolation, attached-file context, persistence, and all three native streaming response formats through automated tests.
- Ran 77 unit/integration tests with zero failures.

### Comparison history

- Iteration 1 — blocked: P2 composer text was vertically centered and left too much space above the placeholder; compact width also allowed citation dates to wrap vertically.
- Fixes made: top-aligned the editor inside a 104 pt composer and introduced responsive citation rows with compact metadata and an icon-only Finder action.
- Post-fix evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/chat-composer-whitespace-comparison.png`, `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-chat-sessions-streaming.jpeg`, and `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-chat-narrow.jpeg`.
- Iteration 2 — passed: no actionable P0/P1/P2 difference remains in the regular or compact rendering.

## Final result

passed

## Menu icon, localization, and dark-mode QA — 2026-07-14

- Source visual truth path: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-713f10a8-5f1d-4428-a6ec-16be13ac266d.png`.
- Menu implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-menubar-icons-focused.png`.
- Light localized settings screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-settings-language-light.png`.
- Dark localized settings screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-settings-language-dark.png`.
- Viewport: native menu bar at 2× density; native Settings window at 760 × 732 px.
- State: listening menu icon; English locale; System and Dark appearance states.
- Full-view comparison evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/menubar-icon-size-comparison.png` (source on the left, implementation on the right).
- Focused-region evidence: the supplied source and implementation are already tightly cropped to the menu-bar icon row, so a second crop was not needed.

### Findings

- No actionable P0, P1, or P2 differences remain.
- Fonts and typography: Settings uses the native macOS system family, weights, and compact form hierarchy in both themes. English labels fit without clipping or unwanted wrapping.
- Spacing and layout rhythm: the FileNest status glyph now has the same optical width and vertical center as the adjacent Sparkle and Telegram glyphs; the larger WeChat mark remains naturally wider because it contains two bubbles.
- Colors and visual tokens: system semantic surfaces, foregrounds, dividers, disabled controls, green status, and indigo brand accents adapt cleanly between light and dark modes with readable contrast.
- Image quality and asset fidelity: the real FileNest raster status asset remains a template image. Runtime alpha-bound cropping removes uneven transparent padding without stretching or substituting the mark.
- Copy and content: the English Settings surface, dynamic watching status, model page, and helper copy are localized. The language menu exposes System, Simplified Chinese, and English.
- Icons and affordances: all three status assets render on a normalized 16 × 16 pt canvas with a 15.5 pt optical width and preserved aspect ratio.
- Accessibility and behavior: language and appearance controls expose native popup/radio semantics. Locale and theme changes apply immediately; System appearance was restored after QA.

### Primary interactions tested

- Opened the standalone Settings window and switched between General and AI Models.
- Opened the Language menu, changed English to Simplified Chinese, verified the entire visible Settings surface updated, and restored English.
- Switched System appearance to Dark, captured the rendered state, and restored System.
- Verified the menu-bar glyph next to live third-party status items at native display scale.
- Ran 72 unit/integration tests with zero failures.

### Comparison history

- Iteration 1 — passed: the normalized FileNest glyph matches the neighboring single-glyph icons in optical size and baseline; no P0/P1/P2 visual correction was required after the rendered comparison.

## Final result

passed

## Temporary-file filtering, composer, and statistics QA — 2026-07-14

- Source visual truth paths: `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-2c45b647-6b32-4d18-82ee-1bc9bf4d7465.png` and `/var/folders/33/36dkdkyj78v0h0kz9rtjsp4c0000gn/T/codex-clipboard-9495c81d-45ee-437c-bbef-86ea9354ee0a.png`.
- Chat implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-chat-composer-v2.jpeg`.
- Statistics implementation screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-statistics.jpeg`.
- Narrow statistics screenshot: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-statistics-narrow.jpeg`.
- Viewport: native FileNest main window at 1079 × 768 px; compact statistics pass at 1005 × 768 px; light appearance.
- State: local Ollama model selected, empty chat composer, 14-day statistics range, populated file/index/token/storage showcase data.
- Full-view evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-chat-composer-v2.jpeg` and `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-statistics.jpeg`.
- Focused comparison evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/chat-composer-v2-comparison.png` (source above, final implementation below).
- Focused comparison was required because the source target is a tightly cropped composer whose placeholder opacity, corner radius, action alignment, and disabled-send treatment cannot be judged reliably in the full-window capture.

### Findings

- No actionable P0, P1, or P2 differences remain.
- Fonts and typography: the composer uses native system typography with a light placeholder matching the reference hierarchy. Statistics use rounded numeric figures, compact labels, and consistent weights without clipping at either tested width.
- Spacing and layout rhythm: the input is a single 100 pt rounded surface with top-aligned copy and a bottom action row. The statistics grid preserves card rhythm and chart legibility down to the app's compact window size.
- Colors and visual tokens: the composer retains the reference's neutral surface and shadow while mapping file access to orange and model/send actions to FileNest semantic accents. Statistics use the existing indigo, blue, green, and neutral system tokens.
- Image quality and asset fidelity: no new raster assets were required; the supplied references contain standard UI glyphs only. Production uses native SF Symbols plus the existing FileNest brand and file-type assets at device scale.
- Copy and content: the reference's generic permission label is adapted to the truthful `本地文件访问`; the active model remains visible in the composer. Statistics label Token values as estimates and distinguish managed files, local models, database, vectors, and extracted text.
- Responsiveness: regular and 1005 px captures show no overlapping cards, clipped controls, broken chart labels, or unreachable scroll content.
- Temporary-file behavior: Office `~$` lock files, AppleDouble files, editor backups, partial downloads, swap files, locks, and common temporary extensions are excluded before stability tracking. Previously stored transient records are purged with cascading vector cleanup.

### Primary interactions tested

- Verified the composer exposes attachment, local-access state, current-model menu, system dictation, and guarded send controls through the accessibility tree.
- Verified the Statistics navigation item, 7/14/30-day range menu, refresh action, scroll surface, charts, and storage rows through the live native app.
- Resized the statistics window to the app's compact width and confirmed all primary metrics and charts remain readable.
- Verified transient filtering, legacy cleanup, daily file/index aggregation, storage totals, and Token aggregation through automated tests.
- Ran 82 unit/integration tests with zero failures.

### Comparison history

- Iteration 1 — blocked: P2 composer placeholder was too dark and the disabled send control was visually too faint relative to the reference.
- Fixes made: replaced the system prompt treatment with a controlled light placeholder overlay and increased the disabled circular send affordance contrast while retaining disabled semantics.
- Post-fix evidence: `/Users/la230048/work/ai.prompt/mactools/design/qa/chat-composer-v2-comparison.png` and `/Users/la230048/work/ai.prompt/mactools/design/qa/implementation-chat-composer-v2.jpeg`.
- Iteration 2 — passed: no actionable P0/P1/P2 differences remain in the focused composer comparison or regular/compact statistics captures.

## Final result

passed
