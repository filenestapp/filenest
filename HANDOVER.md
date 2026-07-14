# FileNest 项目交接文档

> 给接手开发者的完整交接说明。读完这份文档，你应该能：理解项目目标与现状、在本地跑起来、知道代码在哪里、清楚已知的坑和下一步该做什么。

---

## 1. 一句话项目概述

**FileNest** 是一个 macOS 原生应用，解决"下载/桌面文件越堆越乱、想找时找不到"的痛点。它做三件事：

1. **自动归类** — 监听 `~/Downloads`，新文件按规则自动分到 `~/FileNestOrganized/{文档,图片,视频,音频,代码,压缩包}`
2. **向量化索引** — 抽取文件内容，用 Apple 内置 NLEmbedding 生成向量存入本地 SQLite，用 Accelerate(vDSP) 做语义检索
3. **聊天找文件(RAG)** — 用自然语言描述需求，向量检索相关文件，拼上下文交给 LLM 回答并引用文件

形态：**菜单栏常驻 + 可展开的主窗口**。

---

## 2. 当前状态

### 已完成 ✅
- 完整的垂直切片 MVP，**可以编译、可以运行、核心闭环已验证通过**
- 20 个 Swift 源文件，约 2387 行
- `xcodebuild` clean build 成功（macOS 26.6 / Xcode 26.6 / Swift 6.3，arm64）
- 已用真实下载目录验证：68 个文件被扫描，按类型正确归类，文本文件成功抽取+向量化（512维一致）

### 端到端验证结果（2026-07-14）

| 环节 | 结果 |
|---|---|
| 文件监听 | ✅ 扫描下载目录，正确跳过不在白名单的文件 |
| 自动归类 | ✅ txt/md→文档，py→代码，zip→压缩包，文件物理移动到目标目录 |
| 内容抽取 | ✅ PDF(PDFKit)/文本/代码，提取标题+正文入 DB |
| 向量化 | ✅ NLEmbedding 512维，所有向量维度一致 |
| 语义检索 | ✅ "产品需求文档"→正确匹配笔记.md（相似度0.94） |
| 聊天 RAG | ⚠️ 架构完整，但**当前机器未装 Ollama**，所以 LLM 部分未实测；装上即可用 |
| 稳定性 | ✅ 进程长期运行无崩溃 |

### 未做（明确的后续工作，见第 8 节）
- 没有写单元测试
- AI 语义分类是占位实现（hybrid 策略实际降级为规则分类）
- 没有图片多模态识别
- 没有上架打包/签名配置（当前是 ad-hoc 签名 `-`）
- 不是 git 仓库（**建议接手后第一件事 `git init`**）

---

## 3. 环境与构建

### 开发环境
- **macOS 26.6**，**Apple Silicon (M2 Max, 32GB)**
- **Xcode 26.6**，**Swift 6.3.3**
- 最低部署目标：**macOS 13.0**（用了 MenuBarExtra / NavigationSplitView，需 13+）

### 工具依赖
- **xcodegen**（已装，`brew install xcodegen`）— 从 `project.yml` 生成 `.xcodeproj`
- **GRDB.swift 6.29+** — 唯一的第三方依赖，通过 Swift Package Manager 自动拉取

### 构建步骤

```bash
# 1. （仅源文件变动时）重新生成 Xcode 工程
xcodegen generate

# 2. 命令行构建
xcodebuild -project FileNest.xcodeproj -scheme FileNest \
  -configuration Debug -destination 'platform=macOS' build

# 3. 运行
open ~/Library/Developer/Xcode/DerivedData/FileNest-*/Build/Products/Debug/FileNest.app
```

或者直接用 Xcode 打开 `FileNest.xcodeproj`，选 FileNest scheme → Run。

### 启用聊天功能（可选，不影响其他功能）
```bash
brew install ollama
ollama serve                # 后台运行
ollama pull qwen2.5:7b      # 拉模型（首次几 GB）
```
不装 Ollama 也能用：设置→AI 里切到「云端 API」填 Key。两者都没配时聊天优雅降级，向量检索照常工作。

### 运行时数据位置
- 数据库：`~/Library/Application Support/filenest.sqlite`
- 调试日志：`~/FileNestLogs/{watcher,indexer}.log`
- 归类目标：`~/FileNestOrganized/{文档,图片,...}/`

---

## 4. 架构总览

```
┌─────────────────────────────────────────────┐
│  UI 层 (SwiftUI)                             │
│  MenuBarView · MainView · LibraryView ·       │
│  ChatView · RulesView · SettingsView          │
├─────────────────────────────────────────────┤
│  服务层                                       │
│  FileWatcherService  监听目录 → 发现新文件      │
│  OrganizerService    规则分类 → 移动文件        │
│  IndexerService      内容抽取 → 分块 → 向量化   │
│  ChatService         RAG 检索 → LLM 对话       │
├─────────────────────────────────────────────┤
│  领域层 (可插拔协议)                           │
│  EmbeddingProvider   NLEmbedding / Ollama      │
│  LLMProvider         Ollama / OpenAI / Noop    │
│  VectorStore         AccelerateVectorStore     │
│  Classifier          RuleClassifier            │
├─────────────────────────────────────────────┤
│  基础设施层                                   │
│  SQLiteStore (GRDB)  files/embeddings/rules/   │
│                       chat_messages/settings   │
└─────────────────────────────────────────────┘
```

**核心设计哲学：可插拔协议 + 合理默认。** 所有外部能力（向量化、LLM、向量库、分类器）都是协议，有默认实现，可在设置里切换。

---

## 5. 文件清单与职责

按依赖顺序（从底层到 UI）阅读最容易理解。

### App/（应用入口与全局状态）
| 文件 | 行 | 职责 |
|---|---|---|
| `FileNestApp.swift` | 39 | `@main` 入口，三个 Scene：MenuBarExtra + WindowGroup + Settings |
| `AppState.swift` | 71 | **全局状态中枢**，`@MainActor` ObservableObject，持有所有服务实例。UI 通过 `@EnvironmentObject` 访问 |
| `AppSettings.swift` | 118 | 所有可配置项，持久化到 SQLite `settings` 表。**注意：`@Published` 属性不能用 didSet，持久化逻辑在独立的 `setXxx()` 方法里**，UI 用自定义 Binding 调这些 setter |

### Domain/（模型与协议）
| 文件 | 行 | 职责 |
|---|---|---|
| `Models.swift` | 126 | `FileRecord` / `Rule` / `ChatMessage` 三个 GRDB 模型 + `FileCategory` 枚举（含扩展名→大类映射） |
| `Protocols.swift` | 36 | 四个可插拔协议：`EmbeddingProvider` / `LLMProvider` / `VectorStore` / `Classifier` |

### Storage/（数据层）
| 文件 | 行 | 职责 |
|---|---|---|
| `SQLiteStore.swift` | 233 | **数据基础**。DatabasePool，建库建表迁移，files/embeddings/rules/chat/settings 的 CRUD，默认规则注入 |
| `AccelerateVectorStore.swift` | 191 | 向量检索。向量以 BLOB 存 SQLite，启动时载入内存，用 vDSP 做 cosine 暴力检索。**核心方法：`loadAll` / `upsert` / `remove` / `search`** |

### Providers/（可插拔实现）
| 文件 | 行 | 职责 |
|---|---|---|
| `EmbeddingProviders.swift` | 61 | `NLEmbeddingProvider`（默认，Apple内置512维）/ `OllamaEmbeddingProvider`（可选768维） |
| `LLMProviders.swift` | 88 | `OllamaLLMProvider`（默认本地）/ `OpenAICompatibleLLMProvider`（云端）/ `NoopLLMProvider`（降级） |

### Services/（业务逻辑）
| 文件 | 行 | 职责 |
|---|---|---|
| `FileWatcherService.swift` | 193 | 监听目录（DispatchSource + 10秒轮询兜底），发现新文件→入DB→触发索引+归类 |
| `OrganizerService.swift` | 138 | 规则分类器 + 文件移动（含同名冲突处理）。`organize(fileId:)` 单个，`runOnce()` 批量 |
| `IndexerService.swift` | 117 | 内容抽取→分块→向量化→入库。`indexFile(id:overridePath:)` 是核心方法 |
| `ChatService.swift` | 115 | RAG：问题向量化→检索top5→拼context→调LLM→保存带引用的回复 |

### Extraction/
| 文件 | 行 | 职责 |
|---|---|---|
| `ContentExtractor.swift` | 66 | 从文件抽文本：PDF(PDFKit)/txt/md/json/代码(直读)/其他(用文件名)。限制单文件2万字符 |

### UI/（SwiftUI 视图）
| 文件 | 行 | 职责 |
|---|---|---|
| `MenuBarView.swift` | 123 | 菜单栏弹窗：状态 + 监听开关 + 快速操作 + 最近8个文件 |
| `MainView.swift` | 60 | 主窗口三栏导航：文件库/聊天/规则 |
| `LibraryView.swift` | 138 | 文件库：搜索 + 分类筛选 + Table 列表 + 右键在Finder显示 |
| `ChatView.swift` | 174 | 聊天：消息流（含引用文件卡片）+ 输入框。乐观插入用户消息，异步等LLM回复 |
| `RulesView.swift` | 137 | 规则管理：Table + 新增/编辑(sheet) + 策略切换 |
| `SettingsView.swift` | 163 | 设置：监听目录/文件类型/自动整理 + AI Provider配置(Ollama/云端) + 连接测试 |

---

## 6. 数据模型（SQLite 表）

```
files          id, path(唯一), name, ext, size, mtime, category,
               source_dir, indexed_at, content_hash, title, content_text
embeddings     id, file_id(FK→files, cascade删除), vector(BLOB), dim,
               model, chunk_idx, chunk_text
rules          id, name, type(rule/ai), pattern, target_folder, priority, enabled
chat_messages  id, role, content, ts, related_file_ids(JSON字符串)
settings       key(主键), value   -- 所有配置项的 k/v 存储
```

向量编码：`[Float]` → little-endian `Data`（见 `AccelerateVectorStore.encode/decode`）。

---

## 7. ⚠️ 关键已知坑与设计约束（必读）

开发过程中踩过的坑，**接手前务必了解，避免重蹈覆辙**：

### 7.1 NLEmbedding 不是线程安全的（已修复）
NLEmbedding 底层的 CoreNLP/BNNS 神经网络推理引擎**并发调用会直接崩溃**（SIGABRT）。
- **现状**：`NLEmbeddingProvider` 用一个串行 `DispatchQueue` 序列化了所有 `vector(for:)` 调用。
- **注意**：如果未来引入并行向量化提速，**不要**并发调 NLEmbedding，要么继续串行，要么换 Ollama embedding（线程安全）。

### 7.2 向量维度必须一致
- NLEmbedding **中文模型=640维，英文模型=512维**，混用会导致 `AccelerateVectorStore` 的 dim 锁定冲突、后续向量被丢弃。
- **现状**：统一用英文模型（512维）。代价是对纯中文文本语义区分度较弱。
- **改进方向**：想提升中文效果，切到 Ollama 的 `nomic-embed-text`（768维），但需要**清空旧向量重新索引**（维度变了）。

### 7.3 索引必须在文件移动之前（已修复）
`OrganizerService.organize()` 会移动文件物理位置。如果先移动再索引，indexer 在原路径找不到文件。
- **现状**：`FileWatcherService.handleNewFile` 里顺序是 **先 `indexFile(overridePath:)` 再 `organize()`**。indexer 用传入的原始 url 读文件，organizer 移动后更新 DB 里的 path。
- **注意**：`OrganizerService.runOnce()` 里也是同样顺序，改的时候别搞反。

### 7.4 GRDB 6.29+ 的 async 重载歧义（已修复）
GRDB 的 `DatabasePool.write` / `writeWithoutTransaction` 在 6.29 引入了 `async` 重载（带 `@Sendable @escaping`）。在 `async` 函数里调用时，编译器会优先匹配 async 版本，导致 "expression is async but not marked with await" 报错。
- **现状**：所有 DB 写入都提取到**非 async 的私有辅助函数**里（如 `insertToDB` / `removeFromDB`），绕过重载歧义。
- **注意**：新增 async 函数里的 DB 操作时，沿用这个模式。

### 7.5 @Published 属性不能用 didSet
SwiftUI 的 `@Published` property wrapper 与 `didSet` 冲突。
- **现状**：`AppSettings` 的持久化逻辑放在显式的 `setXxx()` 方法里，UI 用自定义 `Binding(get:set:)` 调这些 setter。
- **注意**：新增可配置项时，照这个模式：声明 `@Published var` + 写一个 `setXxx()` 方法 + UI 里用 Binding 包裹。

### 7.6 macOS 13 兼容性
部署目标设为 macOS 13。**不要用 macOS 14+ 的 API**，踩过的坑：
- `onChange(of:perform:)` —— macOS 13 是单参数闭包 `{ _ in }`，不是 macOS 14 的双参数 `{ oldValue, newValue in }`
- `ContentUnavailableView` —— macOS 14+，已替换为自定义 VStack

### 7.7 FileWatcherService 的并发安全
watcher 有两个并发来源：每个目录一个 DispatchSource + 一个全局轮询 Timer。共享状态 `seen: Set<String>`（去重表）曾因并发损坏崩溃。
- **现状**：`seen` 用 `NSLock` 保护；DispatchSource 和 Timer 都挂在同一个串行 `queue` 上。
- **注意**：watcher 的 `queue` 必须保持串行。

### 7.8 为什么不用 sqlite-vec / vec1
深入调研过。**App Sandbox 禁止运行时加载 SQLite 扩展**，系统 SQLite 也禁用了 `load_extension`。要用 sqlite-vec/vec1 必须自带整套 SQLite 源码静态编译，构建/分发复杂度高。而当前规模（几万向量）下 Accelerate 暴力检索反而更快。`VectorStore` 协议已抽象，未来若超几十万向量需要 ANN 索引，可平滑迁移到 vec1。详见 README「关键设计决策」。

---

## 8. 建议的后续工作（按优先级）

### P0（建议先做）
1. **`git init` + 提交首个 commit** — 当前不是版本控制，代码丢了就没了
2. **实测聊天功能** — 装上 Ollama + 拉模型，跑通 RAG 端到端，验证引用文件是否正确
3. **写核心单元测试** — 至少覆盖：`RuleClassifier`、`ContentExtractor`、`AccelerateVectorStore`(encode/decode/search)、`IndexerService.chunk`

### P1（体验提升）
4. **AI 真正语义分类** — 当前 `classifyStrategy="ai"` 是占位（降级为扩展名分类）。可让 LLM 读文件名/内容前N字返回分类
5. **更强的中文 embedding** — 接 Ollama nomic-embed-text 或云端 embedding，提升中文语义区分度（需重新索引）
6. **增量索引优化** — 当前 `seen` 去重表在重启后丢失，每次启动重扫全部目录。可改用 DB 里的 `content_hash` 判断文件是否变更
7. **文件监听改用 FSEvents 全树** — 当前 DispatchSource 只监听目录描述符 + 10秒轮询，不够实时

### P2（功能扩展）
8. **图片多模态** — 用视觉模型给图片打标签后向量化
9. **打包上架** — 配置正式签名、App图标、沙盒 entitlements 审计、公证
10. **撤销/历史** — OrganizerService 移动文件后记录 undo，支持还原
11. **多目录监听** — 设置里已支持添加目录，但 UI 交互和实际监听需验证

---

## 9. 快速上手清单

接手后建议按这个顺序操作：

```
□ 1. git init && git add . && git commit -m "init: FileNest MVP"
□ 2. xcodegen generate  （确认工程能生成）
□ 3. xcodebuild ... build （确认能编译）
□ 4. open ...FileNest.app （确认能运行，菜单栏出现图标）
□ 5. 往 ~/Downloads 放个 .txt，等10秒，查 ~/FileNestLogs/watcher.log 确认被扫到
□ 6. 查 DB：sqlite3 ~/Library/Application\ Support/filenest.sqlite "SELECT name,category FROM files"
□ 7. 装 Ollama，打开主窗口聊天标签，问个问题，确认 RAG 工作
□ 8. 读 HANDOVER.md 第 7 节（已知坑），再读感兴趣模块的源码
□ 9. 读 README.md 了解设计决策
□ 10. 开始你的改动
```

---

## 10. 联系上下文

- 本项目由 AI 辅助开发（GLM-5.2），从空目录开始，方案经过用户确认（混合AI方案 / 全文件类型可配置 / 菜单栏+主窗口 / SQLite+向量可配置 / 垂直切片MVP）
- 开发过程中的所有技术调研（含 sqlite-vec vs vec1 vs Accelerate 的深度对比）记录在会话历史中
- 如有疑问，优先看 `README.md` 的「关键设计决策」和本文档第 7 节
