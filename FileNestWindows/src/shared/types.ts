export type FileCategory = 'documents' | 'images' | 'videos' | 'audio' | 'code' | 'archives' | 'other'
export type LlmChoice = 'ollama' | 'cloud' | 'none'
export type EmbeddingSource = 'local' | 'ollama' | 'cloud'
export type OcrSource = 'local' | 'ollama' | 'cloud' | 'disabled'
export type RerankerSource = 'disabled' | 'local' | 'cloud'
export type Appearance = 'system' | 'light' | 'dark'
export type AppLanguage = 'system' | 'zh-Hans' | 'en'
export type AutoOrganizeMode = 'immediate' | 'batched'
export type ReindexMode = 'all' | 'unindexed' | 'embeddings' | 'media'
export type CloudApiFormat = 'openai' | 'anthropic'
export type AgentSkillOrigin = 'bundled' | 'sharedUser' | 'managed'
export type AgentSkillCapability = 'search' | 'library-answer' | 'attached-file-answer' | 'feedback-learning'
export type AgentSkillExecutionRoute = 'retrieval' | 'complete-document' | 'map-reduce'

export interface FileRecord {
  id: number
  path: string
  name: string
  ext: string
  size: number
  mtime: string
  category: FileCategory
  sourceDir: string
  indexedAt: string | null
  contentHash: string | null
  title: string | null
  contentText: string | null
  discoveredAt: string
  organizedAt: string | null
  note: string | null
  organizationSubfolder: string | null
  isDirectory: boolean
  indexSignature: string | null
  creationDate?: string | null
  duplicateOfFileId?: number | null
  duplicateDetectedAt?: string | null
}

export interface DuplicateFileGroup {
  contentHash: string
  files: FileRecord[]
  retainedFile: FileRecord
  duplicateFiles: FileRecord[]
  reclaimableBytes: number
}

export interface DuplicateScanProgress {
  scannedCount: number
  totalCount: number
}

export interface DuplicateTrashResult {
  movedCount: number
  failedFileNames: string[]
}

export interface ChatRelatedFileMatch {
  fileId: number
  confidence: number
}

export type ChatFeedback = 'helpful' | 'notHelpful'

export type DocumentChunkKind = 'title' | 'text' | 'table' | 'list' | 'picture' | 'transcript' | 'note' | 'metadata'

export interface DocumentChunk {
  index: number
  text: string
  contextualText: string
  sectionPath: string[]
  pageStart: number | null
  pageEnd: number | null
  kind: DocumentChunkKind
  parentIndex: number
  parentText: string
  entityTerms: string[]
  tokenCount?: number
  tokenizerProfile?: string
  tokenizerVersion?: string
  tokenCountAccuracy?: 'exact' | 'estimated'
}

export interface Rule {
  id: number
  name: string
  type: 'rule' | 'ai'
  pattern: string
  targetFolder: string
  priority: number
  enabled: boolean
  action: 'organize' | 'ignore'
}

export interface ChatSession {
  id: number
  title: string
  createdAt: string
  updatedAt: string
  attachedFilePath: string | null
}

export interface ChatMessage {
  id: number
  sessionId: number
  role: 'system' | 'user' | 'assistant'
  content: string
  timestamp: string
  relatedFileIds: number[]
  relatedFileMatches?: ChatRelatedFileMatch[]
  inputTokens?: number | null
  outputTokens?: number | null
  firstResponseDuration?: number | null
  totalResponseDuration?: number | null
  responseProvider?: string | null
  responseModel?: string | null
  feedback?: ChatFeedback | null
}

export interface Settings {
  watchDirs: string[]
  organizedRoot: string
  enabledExtensions: string[]
  customFileExtensions: string[]
  excludeHidden: boolean
  classifyStrategy: 'rule' | 'hybrid'
  llmChoice: LlmChoice
  ollamaHost: string
  ollamaModel: string
  ollamaFlashAttentionEnabled: boolean
  ollamaEmbeddingModel: string
  ollamaOcrModel: string
  cloudApiFormat: CloudApiFormat
  cloudApiKey: string
  cloudBaseUrl: string
  cloudModel: string
  cloudContextWindowTokens: number
  cloudContextWindowOverrides: Record<string, number>
  cloudEmbeddingBaseUrl: string
  cloudEmbeddingApiKey: string
  cloudEmbeddingModel: string
  cloudEmbeddingReuseChatCredentials: boolean
  cloudOcrFormat: CloudApiFormat
  cloudOcrBaseUrl: string
  cloudOcrApiKey: string
  cloudOcrModel: string
  cloudOcrReuseChatCredentials: boolean
  autoOrganize: boolean
  autoOrganizeMode: AutoOrganizeMode
  autoOrganizeIntervalSeconds: number
  autoOrganizeBatchSize: number
  autoVectorize: boolean
  vectorizeExtensions: string[]
  vectorChunkWords: number
  vectorRetrievalChunkTokens: number
  vectorChunkOverlap: number
  ragResultLimit: number
  rerankerSource: RerankerSource
  rerankerBaseUrl: string
  rerankerApiKey: string
  rerankerModel: string
  rerankerReuseChatCredentials: boolean
  doclingEnabled: boolean
  doclingEndpoint: string
  mediaTranscriptionEnabled: boolean
  whisperModel: string
  embeddingSource: EmbeddingSource
  ocrSource: OcrSource
  thinkingMode: boolean
  appLanguage: AppLanguage
  appearance: Appearance
  quickSearchShortcut: string
  onboardingCompleted: boolean
  launchAtLogin: boolean
  automaticUpdateChecks: boolean
  automaticallyDownloadsUpdates: boolean
  updateFeedUrl: string
}

export interface AgentSkillDiagnostic {
  path: string
  message: string
  severity: 'warning' | 'error'
}

export interface AgentSkill {
  name: string
  description: string
  metadata: Record<string, string>
  allowedTools: string | null
  skillFilePath: string
  origin: AgentSkillOrigin
  resources: Array<{ relativePath: string; kind: string }>
  diagnostics: AgentSkillDiagnostic[]
  enabled: boolean
}

export interface AppStatistics {
  totalFiles: number
  indexedFiles: number
  todayAddedFiles: number
  totalTokens: number
  todayTokens: number
  managedFileBytes: number
  databaseBytes: number
  vectorBytes: number
  extractedTextBytes: number
  localModelBytes: number
  dailyActivity: Array<{ day: string; addedFiles: number; indexedFiles: number; tokens: number }>
  categoryStorage: Array<{ category: FileCategory; bytes: number; fileCount: number }>
}

export interface WatchDirectoryStatus {
  path: string
  state: 'watching' | 'missing' | 'unavailable' | 'stopped'
  detail: string
}

export interface AutomaticProcessingItem {
  id: number
  name: string
  stage: 'indexing' | 'transcribing' | 'waiting' | 'organizing'
}

export interface ManagedMediaServiceStatus {
  state: 'unavailable' | 'ready' | 'installing' | 'failed'
  installing: boolean
  installingModel: string | null
  progress: number | null
  message: string
  error: string | null
  version: string | null
  installedModels: string[]
}

export type LibrarySortField = 'relevance' | 'name' | 'size' | 'modified' | 'created'
export type SortDirection = 'ascending' | 'descending'
export type LibraryDateField = 'created' | 'modified'

export interface LibrarySearchRequest {
  query: string
  smart?: boolean
  includeSemantic?: boolean
  requestId?: string
  category?: FileCategory | null
  dateField?: LibraryDateField
  dateFrom?: string | null
  dateTo?: string | null
  sortField?: LibrarySortField
  sortDirection?: SortDirection
  offset?: number
  limit?: number
}

export interface LibrarySearchResult {
  file: FileRecord
  score: number
  confidence: number
  matchKind: 'filename' | 'title' | 'note' | 'path' | 'content' | 'semantic' | 'entity' | 'hybrid' | 'date' | 'filter' | 'all'
  snippet: string | null
  chunkIndex: number | null
}

export interface LibrarySearchResponse {
  results: LibrarySearchResult[]
  total: number
  interpretedQuery: string
  intent: string | null
  usedAi: boolean
}

export interface LibrarySearchProgressEvent {
  requestId: string
  intent: string
}

export interface AppSnapshot {
  settings: Settings
  files: FileRecord[]
  rules: Rule[]
  chatSessions: ChatSession[]
  selectedSessionId: number | null
  pendingChatAttachmentPath: string | null
  messages: ChatMessage[]
  hasEarlierChatMessages: boolean
  runningChatSessionIds: number[]
  completedChatSessionIds: number[]
  pendingLibrarySearch: { id: string; query: string; includeSemantic?: boolean } | null
  quickSearchShortcutError: string | null
  statistics: AppStatistics
  watching: boolean
  indexing: boolean
  indexingPaused: boolean
  indexingProgress: { completed: number; total: number; currentName: string; failed: number; stage: string } | null
  organizing: boolean
  organizationPaused: boolean
  automaticProcessingItems: AutomaticProcessingItem[]
  duplicateFileGroups: DuplicateFileGroup[]
  duplicateScanProgress: DuplicateScanProgress | null
  duplicateTrashProgress: { completedCount: number; totalCount: number; currentFileName: string | null } | null
  duplicateScanError: string | null
  watchDirectoryStatuses: WatchDirectoryStatus[]
  ollama: { reachable: boolean; models: string[] }
  docling: { installed: boolean; installing: boolean; version: string | null; message: string }
  ffmpeg: ManagedMediaServiceStatus
  whisper: ManagedMediaServiceStatus
  reranker: { state: 'unavailable' | 'installed' | 'starting' | 'running' | 'failed'; installing: boolean; progress: number | null; message: string; error: string | null; modelDiskBytes: number }
  agentSkills: AgentSkill[]
  agentSkillDiagnostics: AgentSkillDiagnostic[]
}

export interface SendChatRequest {
  sessionId: number | null
  content: string
  attachedFilePath?: string | null
  retryAssistantMessageId?: number | null
}

export interface ChatStreamEvent {
  requestId: string
  type: 'session' | 'progress' | 'delta' | 'done' | 'error'
  sessionId?: number
  delta?: string
  message?: ChatMessage
  error?: string
  stage?: 'planning' | 'searching' | 'reranking' | 'retrieved' | 'preparing-document' | 'processing-document' | 'reducing-document' | 'generating' | 'verifying'
  documentProgress?: { completed: number; total: number }
  searchIntent?: string
  relatedFileIds?: number[]
}

export interface AiConnectivityCheck {
  capability: 'chat' | 'embedding' | 'ocr'
  provider: string
  success: boolean
  detail: string
}

export interface FileNestApi {
  getSnapshot(): Promise<AppSnapshot>
  refresh(): Promise<AppSnapshot>
  updateSettings(patch: Partial<Settings>): Promise<Settings>
  chooseWatchDirectories(): Promise<string[]>
  chooseOrganizedRoot(): Promise<string | null>
  chooseOrganizationDirectories(): Promise<string[]>
  chooseChatFile(): Promise<string | null>
  pathForDroppedFile(file: File): string
  startWatching(): Promise<void>
  stopWatching(): Promise<void>
  scanExisting(directories?: string[]): Promise<void>
  preserveExisting(directories?: string[]): Promise<void>
  organizeNow(): Promise<void>
  organizeExisting(directories?: string[]): Promise<void>
  organizeDirectoriesOnce(directories: string[], recursively?: boolean): Promise<void>
  pauseOrganization(): Promise<void>
  resumeOrganization(): Promise<void>
  cancelOrganization(): Promise<void>
  reindexAll(mode?: ReindexMode, categories?: FileCategory[]): Promise<void>
  reindexFile(id: number): Promise<void>
  pauseIndexing(): Promise<void>
  resumeIndexing(): Promise<void>
  cancelIndexing(): Promise<void>
  searchFiles(query: string, category?: FileCategory | null): Promise<FileRecord[]>
  searchLibrary(request: LibrarySearchRequest): Promise<LibrarySearchResponse>
  submitQuickSearch(query: string): Promise<void>
  consumeLibrarySearch(id: string): Promise<void>
  openFile(path: string): Promise<string>
  showInExplorer(path: string): Promise<void>
  trashFile(id: number): Promise<void>
  scanDuplicateFiles(): Promise<DuplicateFileGroup[]>
  trashDuplicateFiles(paths: string[]): Promise<DuplicateTrashResult>
  saveFileNote(id: number, note: string): Promise<void>
  summarizeFile(id: number): Promise<string>
  getDocumentChunks(id: number, offset?: number, limit?: number): Promise<DocumentChunk[]>
  getDocumentChunkCount(id: number): Promise<number>
  getPreviewUrl(path: string): Promise<string>
  createRule(rule: Omit<Rule, 'id'>): Promise<Rule>
  updateRule(rule: Rule): Promise<Rule>
  deleteRule(id: number): Promise<void>
  generateRules(prompt: string): Promise<Array<Omit<Rule, 'id'>>>
  createChat(attachedFilePath?: string | null): Promise<ChatSession>
  beginChat(attachedFilePath?: string | null): Promise<void>
  selectChat(id: number): Promise<ChatMessage[]>
  loadEarlierChatMessages(): Promise<void>
  saveChatFeedback(messageId: number, feedback: ChatFeedback | null): Promise<void>
  markChatSeen(id: number): Promise<void>
  deleteChat(id: number): Promise<void>
  clearChats(): Promise<void>
  sendChat(request: SendChatRequest): Promise<{ requestId: string }>
  cancelChat(requestId: string): Promise<void>
  onChatStream(callback: (event: ChatStreamEvent) => void): () => void
  onLibrarySearchProgress(callback: (event: LibrarySearchProgressEvent) => void): () => void
  onQuickSearchFocus(callback: () => void): () => void
  refreshOllama(): Promise<{ reachable: boolean; models: string[] }>
  installOllama(): Promise<void>
  installDocling(): Promise<void>
  installFfmpeg(): Promise<void>
  installWhisper(): Promise<void>
  downloadWhisperModel(model: string): Promise<void>
  deleteWhisperModel(model: string): Promise<void>
  refreshReranker(): Promise<void>
  installReranker(): Promise<void>
  startReranker(): Promise<void>
  stopReranker(): Promise<void>
  deleteReranker(): Promise<void>
  pullOllamaModel(model: string): Promise<void>
  deleteOllamaModel(model: string): Promise<void>
  testAiConnections(): Promise<AiConnectivityCheck[]>
  checkForUpdates(): Promise<string>
  exportLogs(): Promise<string | null>
  clearLogs(): Promise<number>
  refreshAgentSkills(): Promise<void>
  setAgentSkillEnabled(skillPath: string, enabled: boolean): Promise<void>
  importAgentSkill(): Promise<void>
  deleteAgentSkill(skillPath: string): Promise<void>
  openAgentSkillsFolder(): Promise<string>
  onStateChanged(callback: () => void): () => void
}
