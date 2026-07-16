# FileNest UI/UX 原型：本地智能助手

## 产品理解

FileNest 是一个 macOS 原生文件管家，核心闭环是：监听下载/桌面目录 → 等待文件写入稳定 → 本地抽取与向量索引 → 按规则或扩展名归类移动 → 通过文件库或自然语言检索找回文件。

产品有两个主要入口：

- 菜单栏：查看监听状态、暂停/恢复、立即整理、重新索引和最近整理文件。
- 独立主窗口：文件库、聊天找文件、整理规则，以及设置中的监听目录和模型配置。

体验的关键不是展示“AI”，而是建立三层信任：自动整理过程可见、搜索结果有真实文件引用、本地模型不可用时仍能完成本地语义检索。

## 视觉方向

选定“本地智能助手”方向：原生 macOS SwiftUI 质感、SF Pro、暖白与石墨灰作为基础、靛蓝到紫罗兰作为交互强调色、绿色仅表达健康监听或成功状态。界面以连续表面、轻分隔线和留白为主，避免通用聊天机器人和仪表盘式卡片堆叠。

## 交付物

| 文件 | 内容 |
|---|---|
| `app-icon.png` | macOS App 图标概念 |
| `menubar-icon-states.png` | 菜单栏监听、处理中、暂停三种图标状态 |
| `menubar-popover.png` | 菜单栏展开 UI |
| `main-window.png` | 独立主窗口：聊天找文件与引用结果 |
| `interaction-organizing.png` | 自动整理进行中 |
| `interaction-rule-editor.png` | 新增整理规则 Sheet |
| `interaction-model-fallback.png` | 本地模型未连接时的优雅降级 |
| `selected-direction-reference.png` | 用户选定的第 3 套视觉方向原图 |

所有图片均由 Codex 内置图片生成工具生成。完整生成提示词见 `PROMPTS.md`。

## 实现提示

这些图片用于视觉和交互定向。正式实现时，菜单栏图标应重绘为单色 template image；App 图标应按 macOS AppIcon 规格输出多尺寸资源；界面图中的中文文案和间距应在 SwiftUI 中按真实字体重新校准。
