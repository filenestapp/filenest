# FileNest — macOS 智能文件管家

监听下载/桌面目录 → 自动归类整理 → 向量索引 → 用自然语言聊天找文件。

## 核心功能

1. **自动归类** — 监听指定目录（默认 `~/Downloads`），新文件按扩展名自动分到 `~/FileNestOrganized/{文档,图片,视频,音频,代码,压缩包}` 子文件夹。规则可自定义、可调优先级，支持「仅规则 / 仅AI / 混合」三种策略。
2. **向量化索引** — 文件内容抽取（PDF/文本/代码）后用 Apple 内置 NLEmbedding 生成向量，存入本地 SQLite，用 Accelerate (vDSP) 做 cosine 相似度检索。完全离线、零隐私泄露。
3. **聊天找文件 (RAG)** — 用自然语言描述需求（如「上周的合同」），系统向量检索相关文件，拼接上下文交给 LLM（默认本地 Ollama，可切云端 API）回答并引用文件，点击即在 Finder 定位。

## 应用形态

- **菜单栏常驻**（`MenuBarExtra`）：状态显示 + 快速操作 + 最近文件
- **完整主窗口**（`WindowGroup`）：文件库（搜索/分类/列表）、聊天、规则管理
- **设置**（`Settings`）：监听目录、文件类型、分类策略、AI Provider 配置

## 技术栈

| 领域 | 选型 | 说明 |
|---|---|---|
| UI | SwiftUI + MenuBarExtra (macOS 13+) | 菜单栏+窗口，最低 macOS 13 |
| 存储 | GRDB.swift (系统 SQLite) | 元数据 + 向量 BLOB，App Store 友好 |
| 向量检索 | Accelerate (vDSP) 内存暴力检索 | 沙盒安全、零依赖；几十万向量内够快 |
| 文本向量 | NLEmbedding (Apple 内置) | 离线、隐私、512 维 |
| 聊天 LLM | Ollama (默认) / OpenAI 兼容 API | 可切换，未配置则优雅降级 |
| PDF 抽取 | PDFKit (系统) | 零依赖 |
| 文件监听 | DispatchSource + 定时轮询 | 原生 |

## 构建

```bash
# 1. 生成 Xcode 工程（已生成，仅源文件变动时需要）
xcodegen generate

# 2. 命令行构建
xcodebuild -project FileNest.xcodeproj -scheme FileNest -configuration Debug \
  -destination 'platform=macOS' build

# 3. 运行（构建产物）
open ~/Library/Developer/Xcode/DerivedData/FileNest-*/Build/Products/Debug/FileNest.app

# 4. 运行单元测试
xcodebuild -project FileNest.xcodeproj -scheme FileNest \
  -configuration Debug -destination 'platform=macOS' test
```

或直接用 Xcode 打开 `FileNest.xcodeproj` 运行。

## 启用聊天功能（可选）

聊天需要 LLM。默认用本地 Ollama：

```bash
brew install ollama
ollama serve                # 后台运行
ollama pull qwen2.5:7b      # 拉取模型（也可选 llama3.1:8b 等）
```

不装 Ollama 也能用：在设置里切换到「云端 API」，填入 OpenAI/DeepSeek/智谱等兼容接口的 Key。两者都没配置时，聊天会优雅降级为提示信息，向量检索仍正常工作。

## 架构

```
UI 层 (SwiftUI)
  MenuBarView · MainView · LibraryView · ChatView · RulesView · SettingsView
        │
服务层
  FileWatcherService  → 监听目录，发现新文件
  OrganizerService    → 规则分类，移动文件
  IndexerService      → 内容抽取 + 分块 + 向量化
  ChatService         → RAG 检索 + LLM 对话
        │
领域层 (可插拔协议)
  EmbeddingProvider   → NLEmbeddingProvider / OllamaEmbeddingProvider
  LLMProvider         → OllamaLLMProvider / OpenAICompatibleLLMProvider / NoopLLMProvider
  VectorStore         → AccelerateVectorStore (vDSP)
  Classifier          → RuleClassifier
        │
基础设施层
  SQLiteStore (GRDB)  → files / embeddings / rules / chat_messages / settings
```

**可插拔设计**：所有外部能力抽象为协议，Provider 可在设置中切换，贯彻「合理默认 + 可配置」。

## 关键设计决策

### 为什么不用 sqlite-vec / vec1？
App Sandbox（上架 App Store 必需）禁止运行时加载 SQLite 扩展，系统的 SQLite 也禁用了扩展加载。sqlite-vec/vec1 必须自带整套 SQLite 源码并静态编译，构建/分发复杂度高。而在本应用规模（几万向量）下，Swift + Accelerate 暴力检索反而更快（省掉 SQL/虚拟表开销），且零依赖、完全沙盒安全。`VectorStore` 协议化保留了未来切换到 vec1 的可能。

### 为什么 Embedding 用 NLEmbedding？
零配置、离线、隐私。无需下载模型、无需联网、无 API 费用，开箱即用。代价是对中文文本的语义区分度弱于专门的多语言模型（如 nomic-embed-text）—— 想要更好效果可在设置切到 Ollama embedding。

## 调试日志

运行时日志写入 `~/FileNestLogs/{watcher,indexer}.log`（文件日志，绕过统一日志系统的隐私过滤）。
数据库位于 `~/Library/Application Support/filenest.sqlite`。
