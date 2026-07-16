import { contextBridge, ipcRenderer, webUtils } from 'electron'
import type { ChatStreamEvent, FileCategory, FileNestApi, Rule, SendChatRequest, Settings } from '../shared/types'

const api: FileNestApi = {
  getSnapshot: () => ipcRenderer.invoke('app:snapshot'),
  refresh: () => ipcRenderer.invoke('app:refresh'),
  updateSettings: (patch: Partial<Settings>) => ipcRenderer.invoke('settings:update', patch),
  chooseWatchDirectories: () => ipcRenderer.invoke('dialog:watch-directories'),
  chooseOrganizedRoot: () => ipcRenderer.invoke('dialog:organized-root'),
  chooseChatFile: () => ipcRenderer.invoke('dialog:chat-file'),
  pathForDroppedFile: (file: File) => webUtils.getPathForFile(file),
  startWatching: () => ipcRenderer.invoke('watcher:start'),
  stopWatching: () => ipcRenderer.invoke('watcher:stop'),
  scanExisting: () => ipcRenderer.invoke('watcher:scan-existing'),
  organizeNow: () => ipcRenderer.invoke('organizer:run'),
  reindexAll: () => ipcRenderer.invoke('indexer:reindex-all'),
  reindexFile: (id: number) => ipcRenderer.invoke('indexer:reindex-file', id),
  pauseIndexing: () => ipcRenderer.invoke('indexer:pause'),
  resumeIndexing: () => ipcRenderer.invoke('indexer:resume'),
  cancelIndexing: () => ipcRenderer.invoke('indexer:cancel'),
  searchFiles: (query: string, category?: FileCategory | null) => ipcRenderer.invoke('files:search', query, category),
  openFile: (path: string) => ipcRenderer.invoke('files:open', path),
  showInExplorer: (path: string) => ipcRenderer.invoke('files:show-in-explorer', path),
  trashFile: (id: number) => ipcRenderer.invoke('files:trash', id),
  saveFileNote: (id: number, note: string) => ipcRenderer.invoke('files:note', id, note),
  summarizeFile: (id: number) => ipcRenderer.invoke('files:summarize', id),
  getPreviewUrl: (path: string) => ipcRenderer.invoke('files:preview-url', path),
  createRule: (rule: Omit<Rule, 'id'>) => ipcRenderer.invoke('rules:create', rule),
  updateRule: (rule: Rule) => ipcRenderer.invoke('rules:update', rule),
  deleteRule: (id: number) => ipcRenderer.invoke('rules:delete', id),
  generateRules: (prompt: string) => ipcRenderer.invoke('rules:generate', prompt),
  createChat: (path?: string | null) => ipcRenderer.invoke('chat:create', path),
  selectChat: (id: number) => ipcRenderer.invoke('chat:select', id),
  deleteChat: (id: number) => ipcRenderer.invoke('chat:delete', id),
  clearChats: () => ipcRenderer.invoke('chat:clear'),
  sendChat: (request: SendChatRequest) => ipcRenderer.invoke('chat:send', request),
  cancelChat: (requestId: string) => ipcRenderer.invoke('chat:cancel', requestId),
  onChatStream: (callback: (event: ChatStreamEvent) => void) => {
    const listener = (_event: Electron.IpcRendererEvent, value: ChatStreamEvent): void => callback(value)
    ipcRenderer.on('chat:stream', listener)
    return () => ipcRenderer.removeListener('chat:stream', listener)
  },
  refreshOllama: () => ipcRenderer.invoke('ollama:refresh'),
  pullOllamaModel: (model: string) => ipcRenderer.invoke('ollama:pull', model),
  deleteOllamaModel: (model: string) => ipcRenderer.invoke('ollama:delete', model),
  installOllama: () => ipcRenderer.invoke('ollama:install'),
  installDocling: () => ipcRenderer.invoke('docling:install'),
  checkForUpdates: () => ipcRenderer.invoke('updates:check'),
  exportLogs: () => ipcRenderer.invoke('logs:export'),
  clearLogs: () => ipcRenderer.invoke('logs:clear'),
  onStateChanged: (callback: () => void) => {
    const listener = (): void => callback()
    ipcRenderer.on('state:changed', listener)
    return () => ipcRenderer.removeListener('state:changed', listener)
  }
}

contextBridge.exposeInMainWorld('fileNest', api)
