export type FileCategory = 'documents' | 'images' | 'videos' | 'audio' | 'code' | 'archives' | 'other'
export type LlmChoice = 'ollama' | 'cloud' | 'none'
export type EmbeddingSource = 'local' | 'ollama' | 'cloud'
export type OcrSource = 'local' | 'ollama' | 'cloud' | 'disabled'
export type Appearance = 'system' | 'light' | 'dark'
export type AppLanguage = 'system' | 'zh-Hans' | 'en'
export type AutoOrganizeMode = 'immediate' | 'batched'
export type CloudApiFormat = 'openai' | 'anthropic'

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
}

export interface Settings {
  watchDirs: string[]
  organizedRoot: string
  enabledExtensions: string[]
  excludeHidden: boolean
  classifyStrategy: 'rule' | 'hybrid'
  llmChoice: LlmChoice
  ollamaHost: string
  ollamaModel: string
  ollamaEmbeddingModel: string
  ollamaOcrModel: string
  cloudApiFormat: CloudApiFormat
  cloudApiKey: string
  cloudBaseUrl: string
  cloudModel: string
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
  vectorChunkOverlap: number
  doclingEnabled: boolean
  doclingEndpoint: string
  embeddingSource: EmbeddingSource
  ocrSource: OcrSource
  thinkingMode: boolean
  appLanguage: AppLanguage
  appearance: Appearance
  onboardingCompleted: boolean
  launchAtLogin: boolean
  automaticUpdateChecks: boolean
  automaticallyDownloadsUpdates: boolean
  updateFeedUrl: string
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
  dailyActivity: Array<{ day: string; addedFiles: number; indexedFiles: number; tokens: number }>
  categoryStorage: Array<{ category: FileCategory; bytes: number; fileCount: number }>
}

export interface AppSnapshot {
  settings: Settings
  files: FileRecord[]
  rules: Rule[]
  chatSessions: ChatSession[]
  selectedSessionId: number | null
  messages: ChatMessage[]
  statistics: AppStatistics
  watching: boolean
  indexing: boolean
  indexingPaused: boolean
  indexingProgress: { completed: number; total: number; currentName: string } | null
  ollama: { reachable: boolean; models: string[] }
  docling: { installed: boolean; installing: boolean; version: string | null; message: string }
}

export interface SendChatRequest {
  sessionId: number | null
  content: string
  attachedFilePath?: string | null
}

export interface ChatStreamEvent {
  requestId: string
  type: 'session' | 'delta' | 'done' | 'error'
  sessionId?: number
  delta?: string
  message?: ChatMessage
  error?: string
}

export interface FileNestApi {
  getSnapshot(): Promise<AppSnapshot>
  refresh(): Promise<AppSnapshot>
  updateSettings(patch: Partial<Settings>): Promise<Settings>
  chooseWatchDirectories(): Promise<string[]>
  chooseOrganizedRoot(): Promise<string | null>
  chooseChatFile(): Promise<string | null>
  pathForDroppedFile(file: File): string
  startWatching(): Promise<void>
  stopWatching(): Promise<void>
  scanExisting(): Promise<void>
  organizeNow(): Promise<void>
  reindexAll(): Promise<void>
  reindexFile(id: number): Promise<void>
  pauseIndexing(): Promise<void>
  resumeIndexing(): Promise<void>
  cancelIndexing(): Promise<void>
  searchFiles(query: string, category?: FileCategory | null): Promise<FileRecord[]>
  openFile(path: string): Promise<string>
  showInExplorer(path: string): Promise<void>
  trashFile(id: number): Promise<void>
  saveFileNote(id: number, note: string): Promise<void>
  summarizeFile(id: number): Promise<string>
  getPreviewUrl(path: string): Promise<string>
  createRule(rule: Omit<Rule, 'id'>): Promise<Rule>
  updateRule(rule: Rule): Promise<Rule>
  deleteRule(id: number): Promise<void>
  generateRules(prompt: string): Promise<Array<Omit<Rule, 'id'>>>
  createChat(attachedFilePath?: string | null): Promise<ChatSession>
  selectChat(id: number): Promise<ChatMessage[]>
  deleteChat(id: number): Promise<void>
  clearChats(): Promise<void>
  sendChat(request: SendChatRequest): Promise<{ requestId: string }>
  cancelChat(requestId: string): Promise<void>
  onChatStream(callback: (event: ChatStreamEvent) => void): () => void
  refreshOllama(): Promise<{ reachable: boolean; models: string[] }>
  installOllama(): Promise<void>
  installDocling(): Promise<void>
  pullOllamaModel(model: string): Promise<void>
  deleteOllamaModel(model: string): Promise<void>
  checkForUpdates(): Promise<string>
  exportLogs(): Promise<string | null>
  clearLogs(): Promise<number>
  onStateChanged(callback: () => void): () => void
}
