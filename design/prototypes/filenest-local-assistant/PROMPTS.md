# Generation prompts

所有图片使用 Codex 内置图片生成工具，并将 `selected-direction-reference.png` 作为视觉参考。

## App icon

```text
Use case: logo-brand
Asset type: macOS app icon concept for FileNest
Input images: Image 1 is the selected FileNest "本地智能助手" UI direction and the sole visual style reference.
Primary request: Design a distinctive native macOS app icon for FileNest, an intelligent local file organizer and semantic file finder. Build a simple symbol that combines a tidy nest of three stacked document layers with a subtle folded folder shape and a centered negative-space path suggesting retrieval. It should communicate files becoming organized and easy to find, not cloud storage.
Style/medium: polished vector-friendly macOS icon, geometric, minimal, crisp silhouette, approachable but professional.
Composition/framing: one centered rounded-square macOS app icon filling a square canvas with generous safe padding; front-facing; no environment or device mockup.
Color palette: match Image 1 exactly—indigo to violet-blue with a restrained cool-cyan highlight, warm off-white internal details, no green except none.
Materials/textures: mostly flat with very subtle macOS depth and soft internal layering; strong at 16px and 1024px.
Constraints: no text, no letters, no robot, no bird, no cloud, no magnifying-glass cliché, no photorealism, no excessive glow, no floating pieces, no watermark, no presentation board, only one app icon.
```

## Menu bar icon states

```text
Use case: logo-brand
Asset type: macOS menu bar status icon state sheet for FileNest
Input images: Image 1 is the selected FileNest UI direction and provides the underlying nest/layer brand idea only.
Primary request: Create a tiny, highly legible monochrome menu bar glyph system for FileNest. The core glyph is a compact tray/nest made from two nested horizontal document folds. Show exactly three states in a single clean horizontal state sheet: normal listening, active processing, and paused. Normal uses the pure nest glyph; active adds one minimal circular progress cue without changing the core silhouette; paused adds a tiny pause cue.
Style/medium: SF Symbols-compatible vector glyph aesthetic, black single-color strokes and fills on plain white, optical balance for macOS menu bar at 16–18px.
Composition/framing: three evenly spaced isolated glyphs, large enough to inspect, same size and baseline, generous white margin. No macOS desktop, no menu bar UI, no labels.
Color palette: pure black on white only.
Constraints: one consistent icon family, bold enough for Retina small sizes, no gradients, no shadows, no text, no letters, no color, no full folder outline, no bird, no cloud, no watermark.
```

## Menu bar popover

```text
Use case: ui-mockup
Asset type: expanded macOS menu bar popover for FileNest
Input images: Image 1 is the selected FileNest "本地智能助手" direction; preserve its SF Pro typography, warm off-white surfaces, indigo-violet accent, restrained green status, and native macOS spacing.
Primary request: Create the production-quality expanded menu bar UI for FileNest. It should make current monitoring status and recent automatic organization instantly understandable in a compact popover.
Target dimensions: natural macOS menu bar popover, approximately 380 x 520 points, rendered large and crisp without a browser or device frame.
Content hierarchy: header with FileNest mark and exact text "FileNest"; healthy green status "监听中" and supporting line "已索引 68 个文件"; a native toggle labeled "自动监听整理"; one prominent compact action "立即整理" and one quiet action "重新索引"; section title "最近整理"; four lightweight file rows with icons and exact filenames "合同终稿.docx", "产品需求文档.pdf", "app_notes.md", "Q3预算.xlsx", each with a short destination such as "文档 / 合同"; footer actions "打开主窗口", "设置…", and "退出 FileNest".
Style/medium: native macOS SwiftUI popover, realistic controls, subtle translucency and one continuous surface, SF Pro, selected direction's friendly local-intelligence feel.
Color palette: warm paper-white, translucent graphite gray, indigo-violet accent, green only for listening/success.
Constraints: accurate readable Chinese, no cards inside cards, no giant logo, no dashboard metrics, no excessive glass or gradients, no browser chrome, no desktop wallpaper, no clipped text, no watermark, render a single expanded popover only.
```

## Main window

```text
Use case: ui-mockup
Asset type: final standalone macOS main window prototype for FileNest
Input images: Image 1 is the selected direction; treat it as a strict style and information-hierarchy reference while refining spacing and production readiness.
Primary request: Create the definitive standalone main interface for FileNest in the "本地智能助手" direction. The hero use case is describing a vaguely remembered file and opening the best cited result.
Target dimensions: 1440 x 1024 natural macOS window, light appearance, no browser or device chrome.
Current date anchor: 2026-07-14.
Screen content: native translucent sidebar with FileNest mark and navigation "文件库", selected "聊天找文件", "整理规则"; lower sidebar status "监听中" and "已索引 68 个文件". Main header exact title "聊天找文件" and subtitle "用自然语言查找文件，所有内容仅在本地处理。". Conversation shows user query "帮我找上周下载的合同终稿". Assistant answers concisely and presents one primary cited file "合同终稿.docx", path "~/FileNestOrganized/文档/合同/合同终稿.docx", modified "7月12日 11:08", and action "在 Finder 中显示"; below, two lightweight alternative rows. Bottom input placeholder "描述你想找的文件…" and trust line "本地语义检索 · 文件内容不会上传".
Style/medium: production-quality native macOS SwiftUI, SF Pro, warm intelligent assistant—not a generic chatbot.
Layout: conversation and file citations on one continuous surface; whitespace and dividers first; citations look like file rows, not marketing cards.
Color palette: warm off-white, graphite, subtle indigo-violet accent, restrained green.
Constraints: Chinese text accurate and legible, body 14–16px, no oversized bubbles, no card stack, no feature inventory, no robot mascot, no sparkle overload, no clipped content, no watermark.
```

## Organizing interaction

```text
Use case: ui-mockup
Asset type: FileNest interaction-state prototype—automatic organization in progress
Input images: Image 1 is the selected FileNest UI direction; preserve its visual system exactly.
Primary request: Show the FileNest macOS main window during a live automatic organization interaction. The user should understand progress, what is happening to each file, and that pausing is safe.
Target dimensions: 1440 x 1024 native macOS window, light appearance.
Screen content: sidebar with "文件库" selected and normal navigation. Main header exact title "正在整理 4 个新文件". Directly below, a clear three-stage sequence "发现文件 → 建立本地索引 → 移动到目标文件夹", with the second stage active. Use a single grouped list of four files. "采购合同_ABC科技有限公司.pdf" shows completed local indexing and destination "文档 / 合同"; "项目需求说明.txt" shows subtle progress with status "正在建立索引"; "data_processor.py" and "README.md" show "等待中". Provide one quiet button "暂停整理" and helper text "暂停后不会移动尚未完成索引的文件". Avoid fake percentages unless needed.
Style/medium: production-quality native macOS SwiftUI interaction state, SF Pro, operational clarity with calm motion implied through one spinner/progress indicator.
Color palette: selected indigo-violet accent, graphite, warm white, green for completed, restrained amber for waiting.
Constraints: keep one continuous work surface, no charts, no dashboard cards, no technical logs, no destructive warning tone, no clipped text, no browser chrome, no watermark.
```

## Rule editor interaction

```text
Use case: ui-mockup
Asset type: FileNest interaction-state prototype—create organization rule modal
Input images: Image 1 is the selected FileNest UI direction; preserve its native macOS materials, typography, and indigo-violet accent.
Primary request: Show the "整理规则" main screen with a focused native sheet for adding a rule. Make the extension-based rule interaction easy to understand and safely validated.
Target dimensions: 1440 x 1024 native macOS window with a centered 500 x 520 point sheet.
Background screen: sidebar with "整理规则" selected and a lightweight existing rule list visible but de-emphasized.
Sheet content: exact title "新增整理规则"; fields "规则名" with value "合同文档", read-only type "规则（按扩展名）", "匹配扩展名" with value "pdf, doc, docx", "目标文件夹" with value "合同", stepper "优先级 80", toggle "启用". Add a subtle explanation "扩展名用逗号分隔；优先级越高越先匹配". Show a small live summary line "PDF、DOC、DOCX 文件将移动到 文档 / 合同". Footer buttons "取消" and primary "保存规则".
Style/medium: production-quality SwiftUI Form sheet, SF Pro, clear labels, native focus ring, practical spacing.
Color palette: warm neutral surfaces, indigo-violet primary action, graphite text, restrained green confirmation cue.
Constraints: do not invent AI semantic classification controls because that feature is not implemented; no complex condition builder, no card grid, no clipped text, no browser chrome, no watermark.
```

## Model fallback interaction

```text
Use case: ui-mockup
Asset type: FileNest interaction-state prototype—local model unavailable graceful fallback
Input images: Image 1 is the selected FileNest UI direction; preserve its visual system and trust-forward tone.
Primary request: Show how FileNest gracefully handles an unavailable Ollama model while still returning useful local semantic search results. The state must feel recoverable and never alarming.
Target dimensions: 1440 x 1024 native macOS window, light appearance.
Screen content: "聊天找文件" selected. User query exact text "找一下最近的产品需求文档". Above results, show a compact inline notice with exact title "本地模型未连接" and explanation "仍可使用本地语义检索；连接模型后可获得摘要回答。". Provide two actions: primary quiet button "打开 AI 设置" and secondary text button "重试连接". Below, show three relevant local file rows led by "产品需求文档.pdf", each with location and "在 Finder 中显示". Bottom input remains enabled. Trust line says "检索仍在本地完成，文件内容未上传".
Style/medium: production-quality native macOS SwiftUI edge state, SF Pro, calm and actionable, inline notice integrated into the conversation surface.
Color palette: selected warm off-white and graphite, indigo-violet controls, restrained amber only for the unavailable notice, green nowhere except other healthy status.
Constraints: no blocking full-screen error, no red danger styling, no terminal logs, no API key exposed, no generic error code, no extra feature inventory, no clipped text, no browser chrome, no watermark.
```
