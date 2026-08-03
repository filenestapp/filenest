import { contextBridge, ipcRenderer, webUtils } from 'electron'
import type { ChatFeedback, ChatStreamEvent, FileCategory, FileNestApi, LibrarySearchProgressEvent, LibrarySearchRequest, RagFeedbackDraft, ReindexMode, Rule, SendChatRequest, Settings } from '../shared/types'

const api: FileNestApi = {
  getSnapshot: () => ipcRenderer.invoke('app:snapshot'),
  refresh: () => ipcRenderer.invoke('app:refresh'),
  updateSettings: (patch: Partial<Settings>) => ipcRenderer.invoke('settings:update', patch),
  defaultWatchDirectories: () => ipcRenderer.invoke('settings:default-watch-directories'),
  chooseWatchDirectories: () => ipcRenderer.invoke('dialog:watch-directories'),
  chooseOrganizedRoot: () => ipcRenderer.invoke('dialog:organized-root'),
  chooseOrganizationDirectories: () => ipcRenderer.invoke('dialog:organization-directories'),
  chooseChatFile: () => ipcRenderer.invoke('dialog:chat-file'),
  pathForDroppedFile: (file: File) => webUtils.getPathForFile(file),
  startWatching: () => ipcRenderer.invoke('watcher:start'),
  stopWatching: () => ipcRenderer.invoke('watcher:stop'),
  scanExisting: (directories?: string[]) => ipcRenderer.invoke('watcher:scan-existing', directories),
  preserveExisting: (directories?: string[]) => ipcRenderer.invoke('watcher:preserve-existing', directories),
  organizeNow: () => ipcRenderer.invoke('organizer:run'),
  organizeExisting: (directories?: string[]) => ipcRenderer.invoke('organizer:run-existing', directories),
  organizeDirectoriesOnce: (directories: string[], recursively?: boolean) => ipcRenderer.invoke('organizer:run-directories', directories, recursively),
  pauseOrganization: () => ipcRenderer.invoke('organizer:pause'),
  resumeOrganization: () => ipcRenderer.invoke('organizer:resume'),
  cancelOrganization: () => ipcRenderer.invoke('organizer:cancel'),
  reindexAll: (mode?: ReindexMode, categories?: FileCategory[]) => ipcRenderer.invoke('indexer:reindex-all', mode, categories),
  reindexFile: (id: number) => ipcRenderer.invoke('indexer:reindex-file', id),
  retryReindexFiles: (fileIds: number[]) => ipcRenderer.invoke('indexer:retry-files', fileIds),
  pauseIndexing: () => ipcRenderer.invoke('indexer:pause'),
  resumeIndexing: () => ipcRenderer.invoke('indexer:resume'),
  cancelIndexing: () => ipcRenderer.invoke('indexer:cancel'),
  searchFiles: (query: string, category?: FileCategory | null) => ipcRenderer.invoke('files:search', query, category),
  searchLibrary: (request: LibrarySearchRequest) => ipcRenderer.invoke('files:smart-search', request),
  deleteLibrarySearchHistory: (id: number) => ipcRenderer.invoke('library:history-delete', id),
  clearLibrarySearchHistory: () => ipcRenderer.invoke('library:history-clear'),
  submitQuickSearch: (query: string) => ipcRenderer.invoke('quick-search:submit', query),
  consumeLibrarySearch: (id: string) => ipcRenderer.invoke('quick-search:consume', id),
  openFile: (path: string) => ipcRenderer.invoke('files:open', path),
  showInExplorer: (path: string) => ipcRenderer.invoke('files:show-in-explorer', path),
  trashFile: (id: number) => ipcRenderer.invoke('files:trash', id),
  scanDuplicateFiles: () => ipcRenderer.invoke('files:scan-duplicates'),
  trashDuplicateFiles: (paths: string[]) => ipcRenderer.invoke('files:trash-duplicates', paths),
  saveFileNote: (id: number, note: string) => ipcRenderer.invoke('files:note', id, note),
  summarizeFile: (id: number) => ipcRenderer.invoke('files:summarize', id),
  getDocumentChunks: (id: number, offset?: number, limit?: number) => ipcRenderer.invoke('files:chunks', id, offset, limit),
  getDocumentChunkCount: (id: number) => ipcRenderer.invoke('files:chunk-count', id),
  getPreviewUrl: (path: string) => ipcRenderer.invoke('files:preview-url', path),
  createRule: (rule: Omit<Rule, 'id'>) => ipcRenderer.invoke('rules:create', rule),
  updateRule: (rule: Rule) => ipcRenderer.invoke('rules:update', rule),
  deleteRule: (id: number) => ipcRenderer.invoke('rules:delete', id),
  generateRules: (prompt: string) => ipcRenderer.invoke('rules:generate', prompt),
  createChat: (path?: string | null) => ipcRenderer.invoke('chat:create', path),
  beginChat: (path?: string | null) => ipcRenderer.invoke('chat:begin', path),
  selectChat: (id: number) => ipcRenderer.invoke('chat:select', id),
  loadEarlierChatMessages: () => ipcRenderer.invoke('chat:load-earlier'),
  saveChatFeedback: (messageId: number, feedback: ChatFeedback | null, draft?: Partial<RagFeedbackDraft>) => ipcRenderer.invoke('chat:feedback', messageId, feedback, draft),
  saveLibrarySearchFeedback: (query: string, smart: boolean, fileIds: number[], draft: RagFeedbackDraft) => ipcRenderer.invoke('library:feedback', query, smart, fileIds, draft),
  analyzeRagFeedback: (id: number) => ipcRenderer.invoke('feedback:analyze', id),
  markChatSeen: (id: number) => ipcRenderer.invoke('chat:seen', id),
  deleteChat: (id: number) => ipcRenderer.invoke('chat:delete', id),
  clearChats: () => ipcRenderer.invoke('chat:clear'),
  sendChat: (request: SendChatRequest) => ipcRenderer.invoke('chat:send', request),
  cancelChat: (requestId: string) => ipcRenderer.invoke('chat:cancel', requestId),
  onChatStream: (callback: (event: ChatStreamEvent) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, value: ChatStreamEvent): void => callback(value)
    ipcRenderer.on('chat:stream', listener)
    return () => { ipcRenderer.removeListener('chat:stream', listener) }
  },
  onLibrarySearchProgress: (callback: (event: LibrarySearchProgressEvent) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, value: LibrarySearchProgressEvent): void => callback(value)
    ipcRenderer.on('library:search-progress', listener)
    return () => { ipcRenderer.removeListener('library:search-progress', listener) }
  },
  onQuickSearchFocus: (callback: () => void) => {
    ipcRenderer.on('quick-search:focus', callback)
    return () => { ipcRenderer.removeListener('quick-search:focus', callback) }
  },
  refreshOllama: () => ipcRenderer.invoke('ollama:refresh'),
  pullOllamaModel: (model: string) => ipcRenderer.invoke('ollama:pull', model),
  deleteOllamaModel: (model: string) => ipcRenderer.invoke('ollama:delete', model),
  testAiConnections: () => ipcRenderer.invoke('ai:test-connections'),
  installOllama: () => ipcRenderer.invoke('ollama:install'),
  installDocling: () => ipcRenderer.invoke('docling:install'),
  installFfmpeg: () => ipcRenderer.invoke('media:install-ffmpeg'),
  installWhisper: () => ipcRenderer.invoke('media:install-whisper'),
  downloadWhisperModel: (model: string) => ipcRenderer.invoke('media:download-whisper-model', model),
  deleteWhisperModel: (model: string) => ipcRenderer.invoke('media:delete-whisper-model', model),
  refreshReranker: () => ipcRenderer.invoke('reranker:refresh'),
  installReranker: () => ipcRenderer.invoke('reranker:install'),
  startReranker: () => ipcRenderer.invoke('reranker:start'),
  stopReranker: () => ipcRenderer.invoke('reranker:stop'),
  deleteReranker: () => ipcRenderer.invoke('reranker:delete'),
  checkForUpdates: () => ipcRenderer.invoke('updates:check'),
  exportLogs: () => ipcRenderer.invoke('logs:export'),
  clearLogs: () => ipcRenderer.invoke('logs:clear'),
  refreshAgentSkills: () => ipcRenderer.invoke('skills:refresh'),
  setAgentSkillEnabled: (skillPath: string, enabled: boolean) => ipcRenderer.invoke('skills:set-enabled', skillPath, enabled),
  importAgentSkill: () => ipcRenderer.invoke('skills:import'),
  deleteAgentSkill: (skillPath: string) => ipcRenderer.invoke('skills:delete', skillPath),
  openAgentSkillsFolder: () => ipcRenderer.invoke('skills:open-folder'),
  onStateChanged: (callback: () => void) => {
    const listener = (): void => callback()
    ipcRenderer.on('state:changed', listener)
    return () => { ipcRenderer.removeListener('state:changed', listener) }
  }
}

contextBridge.exposeInMainWorld('fileNest', api)
