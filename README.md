# FileNest — 本地优先的智能文件管理器

FileNest 监听用户选择的目录，在文件或项目目录进入稳定态后完成内容解析、OCR、结构化切片、向量索引与自动整理，并提供普通搜索、Smart Search、Find with Chat 和 Chat with File。

当前仓库包含两套桌面实现：

- `FileNest/`：原生 macOS 13+ SwiftUI 应用，也是当前产品行为基线。
- `FileNestWindows/`：Electron + React + TypeScript 的 Windows 11 对齐实现。

## 核心能力

### 监听与整理

- 默认可监听 Desktop、Downloads，也支持添加多个目录。
- 对新增文件和目录进行稳定态检测，避免处理下载中间态、锁文件或尚未完成的 `git clone`。
- 应用退出期间产生的新增或变更内容，会在重新启动后通过增量核对发现。
- 先索引再整理；目录会参考 README 等说明文件建立索引和分类上下文。
- 规则支持优先级、忽略动作、AI 生成、定时/数量批处理和安全的子目录目标。
- 默认忽略安装包、临时文件和其他不应自动移动的内容。

### 文档处理与本地 RAG

```text
PDF / Office / 图片 / 其他文档
        ↓
Docling 优先解析；原生解析器作为回退
        ↓
PaddleOCR 优先；GLM-OCR 或云端 OCR 回退
        ↓
清洗、结构化、按章节切片
        ↓
qwen3-embedding:0.6b / Apple NLEmbedding / 云端 Embedding
        ↓
Parent（600–1000 tokens）+ Child（约 280 tokens）检索单元
        ↓
SQLite + sqlite-vec + 关键词/实体/向量 RRF 融合
        ↓
可选 Qwen3-Reranker 本地或云端重排
        ↓
本地 Ollama 或云端 LLM 问答
```

- 结构化切片保留标题、正文、表格、列表、图片、Note、章节与页码信息。
- 默认切片目标为 600–1000 tokens，并支持 overlap 配置。
- Docling 可用时保存 Qwen3 tokenizer 的精确 token 数；其他路径使用同一版本化估算器，并明确记录 profile、version 与 exact/estimated 状态。
- 索引会从章节 Parent 生成更小的检索 Child；命中 Child 后向模型回填完整 Parent，表格 Child 会重复表头。
- 发票号、邮箱、日期、金额等高精度实体会进入独立召回通道，和文件关键词、向量结果通过 RRF 融合。
- 已索引文件的 Note 可独立重新向量化，无需重新解析源文档。
- 索引提交前会再次校验源文件版本，防止旧任务覆盖新内容。
- 重建索引支持仅处理新文件、Embedding 变化、切片设置变化、OCR/解析器变化，以及暂停、恢复、停止和重新开始。

### 搜索与聊天

- 普通搜索融合文件名、标题、路径、Note、内容、日期意图与向量相似度。
- 向量阈值按每次查询的分数分布动态调整；可配置兼容 `/v1/rerank` 的本地或云端重排服务，失败时自动回退。
- 普通结果页按置信度展示，并可按需触发耗时更长的 Smart Search。
- Smart Search 使用 AI 将自然语言转为语义查询、关键词、文件类型、日期和排序条件。
- Find with Chat 复用智能检索规划，并流式展示检索意图、匹配和生成阶段。
- Chat with File 仅使用目标文件已经存在的索引切片；已索引文件不会重复解析。
- 会话和输入草稿本地持久化；切换页面不会中断正在生成的回答。
- 模型失败时可以从云端切换到本地，或直接返回向量检索结果。
- 回答支持 Markdown、引用文件预览、重试替换、token usage、首响与总耗时。
- RAG 上下文限制为最多 8 个 Parent，并使用稳定的 `[F#:P#]` 证据编号；完成后会校验回答引用。

### 本地 AI 与云端 AI

- 本地模式可安装、启动、更新 Ollama，并管理生成、Embedding 和 OCR 模型。
- 初始化向导默认选择 `qwen3.5:9b` 和 `qwen3-embedding:0.6b`，也允许用户调整。
- Docling 与 PaddleOCR 安装在 FileNest 用户目录下的独立 Python 环境中。
- 云端模式支持 OpenAI-compatible 与 Anthropic 格式，并可独立配置 Chat、Embedding、OCR 或复用凭据。
- 云端模型可以手动指定上下文窗口；未知兼容模型默认按 612K tokens 规划。

## 产品形态

- 菜单栏/系统托盘后台运行与快捷状态操作。
- 可收缩侧边栏、最近会话、监听/索引/AI 状态与完成提醒。
- 文件库、右侧统一预览面板、全屏预览、Note、切片查看和回收站操作。
- 设置页包含通用配置、AI 模型、索引、规则、统计、诊断日志与更新。
- 英文、简体中文以及跟随系统的浅色/深色模式。

## 构建与验证

### macOS

项目脚本默认构建 Release、保持稳定 Apple Development 签名、安装到 `~/Applications/FileNest.app` 并启动：

```bash
./script/build_and_run.sh --verify
```

调试构建：

```bash
./script/build_and_run.sh --debug
```

完整测试：

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

Windows 安装包、Explorer/Recycle Bin、DPAPI、托盘与自动更新仍需在真实 x64/ARM64 Windows 11 环境完成发布验收。

## 数据与隐私

- 文件元数据、结构化切片、向量、Note、会话与统计默认保存在本机数据库。
- 本地模式下文档内容不需要发送到云端。
- 只有用户明确配置云端 Chat、Embedding 或 OCR 时，相应请求内容才会发送到配置的 API。
- 应用以当前操作系统用户及其文件权限作为授权边界，不包含账号、RBAC 或多租户系统。

## 文档

- [产品与工程文档索引](docs/00-index.md)
- [产品概览](docs/01-product-overview.md)
- [功能地图](docs/02-feature-map.md)
- [技术架构](docs/03-technical-architecture.md)
- [验证策略](docs/09-verification.md)
- [Windows 对齐状态](docs/08-windows-parity.md)

代码与自动化测试是行为的最终依据；文档记录当前提交的产品与工程解释。
