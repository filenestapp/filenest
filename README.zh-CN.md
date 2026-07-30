# FileNest — 本地优先的智能文件管理器

[English](README.md) · [简体中文](README.zh-CN.md)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Continuous Integration](https://github.com/filenestapp/filenest/actions/workflows/ci.yml/badge.svg)](https://github.com/filenestapp/filenest/actions/workflows/ci.yml)
[![Windows Release](https://github.com/filenestapp/filenest/actions/workflows/windows-release.yml/badge.svg)](https://github.com/filenestapp/filenest/actions/workflows/windows-release.yml)

FileNest 监听用户选择的目录，并在文件或项目目录进入稳定态后完成内容解析、OCR、结构化切片、向量索引与可选的自动整理。它提供普通搜索、Smart Search、Find with Chat 和 Chat with File。

本仓库包含两套桌面实现：

- `FileNest/`：原生 macOS 13+ SwiftUI 应用，也是当前产品行为基线。
- `FileNestWindows/`：使用 Electron、React 与 TypeScript 实现的 Windows 11 对齐版本。

## 核心能力

### 监听与安全整理

- 可监听 Desktop、Downloads 以及用户添加的任意目录。
- 等待新增文件与目录进入稳定态后再处理，避免下载中间态、锁文件和未完成的 `git clone` 目录。
- 应用未运行期间产生的新增或修改内容，会在下次启动时通过增量核对发现。
- 先索引再整理；项目目录会参考 README 等说明文件作为额外的分类上下文。
- 支持优先级、按扩展名、忽略规则、AI 生成规则，以及按时间或数量触发的批处理。
- 默认跳过安装包、临时文件和其他不应自动移动的内容。

### 文档处理与本地 RAG

```text
PDF / Office / 图片 / 其他文档
        ↓
Docling 优先解析；原生解析器作为回退
        ↓
PaddleOCR 优先；GLM-OCR 或云端 OCR 回退
        ↓
清洗、结构化与按章节切片
        ↓
qwen3-embedding:0.6b / Apple NLEmbedding / 云端 Embedding
        ↓
Parent（600–1000 tokens）+ Child（约 280 tokens）检索单元
        ↓
SQLite + sqlite-vec + 关键词/实体/向量 RRF 融合
        ↓
可选本地或云端 Qwen3-Reranker 重排
        ↓
本地 Ollama 或云端 LLM 问答
```

- 结构化切片会保留标题、正文、表格、列表、图片、Note、章节路径与页码信息。
- 默认 Parent 切片目标为 600–1000 tokens，并支持 overlap 配置。
- Docling 可用时会记录 Qwen3 tokenizer 的精确 token 数；其他路径使用同一版本化估算器，并保留 profile、version 与 exact/estimated 状态。
- 检索先定位较小的 Child 切片，再向模型提供完整 Parent 上下文；表格 Child 会重复表头。
- 发票号、邮箱、日期和金额等高精度实体会进入独立召回通道，并与文件关键词、向量结果通过 RRF 融合。
- 已索引文件的 Note 可以独立重新向量化，无需重新解析源文件。
- 索引提交前会再次验证源文件版本，避免旧任务覆盖新内容。
- 重建索引可针对新文件、Embedding 变化、切片设置、OCR/解析器变化或选定处理阶段；任务支持暂停、恢复、停止和重新开始。

### 搜索与聊天

- 普通搜索融合文件名、标题、路径、Note、提取内容、日期意图与向量相似度。
- 向量召回阈值会根据每次查询的分数分布动态调整；可配置本地或云端兼容 `/v1/rerank` 的重排服务，失败时自动回退。
- 搜索结果展示置信度，并可按需使用耗时更长的 Smart Search。
- Smart Search 会将自然语言请求转换为语义查询、关键词、文件类型、日期条件与排序偏好。
- Find with Chat 复用智能检索规划，并流式展示规划、匹配和回答生成进度。
- Chat with File 只使用目标文件已有的索引切片；已索引文件不会重复解析。
- 会话和输入草稿均保存在本地；切换页面不会中断正在生成的回答。
- 云端模型失败时，可以切换到本地模型，或直接返回向量检索结果。
- 回答支持 Markdown、文件预览、原位重试、token usage、首 token 时间和总响应时间。
- RAG 上下文最多保留八个 Parent，并使用稳定的 `[F#:P#]` 证据编号，在生成后进行校验。

### Agent Skills 与反馈学习

- FileNest 将搜索规划、基于证据的文件库回答、单文件聊天和反馈分析拆分为标准 `SKILL.md` Agent Skills，不再依赖一个巨大的固定 Prompt。
- Skill 会从 App 内置目录、`~/.agents/skills` 共享用户目录和 FileNest 受管目录发现。受管 Skill 优先级最高，因此学习结果可以覆盖并演进内置能力，而不修改 App 包。
- RAG Agent 采用“理解 → 检索 → 排序 → 回答 → 评价 → 学习”的闭环。反馈会由当前配置的本地或云端 AI 分析，只有可复用且高置信度的改进才会写入可审计的受管 Skill。
- 发现阶段只加载名称和描述；完整指令与引用资源仅在自动路由、显式 `$skill-name` 激活或会话复用后加载。
- 搜索与回答反馈会先保存为可审计记录，再由 AI 提议安全地更新已有 Skill，或生成一个职责明确、可复用的新 Skill。学习结果不能削弱本地隐私、证据约束、引用校验或 Prompt Injection 防护。
- 可在设置页查看、启用、停用、定位、刷新或删除 Skills。
- 可复用的确定性能力通过受控的应用内工具运行时和对应的 `filenest skill` CLI 执行。内置工具需要显式注册，目前仅处理内存中的只读数据；Skill 不能执行任意 shell 脚本。

### 本地与云端 AI

- 可安装、启动、更新和管理 Ollama，以及本地生成、Embedding、OCR 和 reranker 模型。
- 初始化向导推荐 `qwen3.5:9b`，默认 Embedding 使用 `qwen3-embedding:0.6b`，也可自行调整。
- Docling 和 PaddleOCR 会安装在 FileNest 用户目录下独立的 Python 环境中。
- 可选的音视频处理使用 FFmpeg 解码，并在独立环境中用 OpenAI Whisper 生成带时间码的转写，再复用现有 Embedding 与 RAG 流程。
- 云端模式支持 OpenAI-compatible 与 Anthropic API；Chat、Embedding、OCR 可单独配置凭据或复用凭据。
- 云端模型可手动声明上下文窗口；未知兼容模型默认按 612K tokens 规划。

## 应用形态

- 菜单栏后台运行、状态展示与快捷操作。
- 可收缩的侧边栏、最近会话，以及监听、索引、AI 和完成提醒状态。
- 文件库、统一的右侧预览抽屉、全屏预览、Note、切片查看和移到废纸篓操作。
- 设置页包含通用配置、AI 模型、索引、整理规则、统计、诊断日志与更新。
- 支持英文、简体中文，以及跟随系统、浅色和深色外观模式。

## OpenAI Build Week / Codex 协作

FileNest 在 OpenAI Build Week 期间使用由 GPT-5.6 驱动的 Codex 进行扩展。Codex 协助实现、调试和测试本地索引、检索、聊天、模型管理与跨平台工作流。产品、隐私、架构与发布决策均由项目负责人作出；Codex 作为工程协作者参与开发。

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

Windows 安装包、Explorer/Recycle Bin 集成、DPAPI、托盘行为与自动更新，仍需要在真实 x64/ARM64 Windows 11 环境完成发布验收。

## 数据与隐私

- 文件元数据、结构化切片、向量、Note、会话与统计默认保存在本机。
- 本地模式下，文档内容无需发送到云端。
- 只有用户明确配置云端 Chat、Embedding 或 OCR 时，对应操作的内容才会发送到配置的 API。
- 应用以当前 macOS 用户的文件权限为授权边界，不提供账号、RBAC 或多租户隔离。

## 开源与参与

FileNest 基于 [MIT License](LICENSE) 开源，欢迎参与贡献：

- 提交 Pull Request 前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
- 参与社区时请遵守 [行为准则](CODE_OF_CONDUCT.md)。
- 安全漏洞请按照 [SECURITY.md](SECURITY.md) 私下报告。
- 分发应用或仓库内包含的第三方源码前，请查看
  [第三方声明](THIRD_PARTY_NOTICES.md)。

## 文档

- [产品与工程文档索引](docs/00-index.md)
- [产品概览](docs/01-product-overview.md)
- [功能地图](docs/02-feature-map.md)
- [技术架构](docs/03-technical-architecture.md)
- [验证策略](docs/09-verification.md)
- [Windows 对齐状态](docs/08-windows-parity.md)
- [English README](README.md)

代码和自动化测试是产品行为的最终依据；文档记录当前仓库的产品与工程解释。
