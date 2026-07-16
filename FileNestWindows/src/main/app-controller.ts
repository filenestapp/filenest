import { app, BrowserWindow, dialog, shell } from 'electron'
import { basename, dirname } from 'node:path'
import { stat } from 'node:fs/promises'
import type { AppSnapshot, ChatStreamEvent, FileCategory, FileRecord, Rule, SendChatRequest, Settings } from '../shared/types'
import { FileNestDatabase } from './database'
import { AppLogger } from './logger'
import { ContentExtractor } from './content-extractor'
import { EmbeddingService } from './embedding'
import { IndexerService } from './indexer'
import { OrganizerService } from './organizer'
import { FileWatcherService } from './watcher'
import { LlmService } from './llm'
import { ChatService } from './chat'
import { OllamaManager } from './ollama'
import updater from 'electron-updater'
import { doclingManager } from './docling'
import { categoryForExtension, normalizedExtension } from './file-policy'

const { autoUpdater } = updater

export class AppController {
  readonly database = new FileNestDatabase()
  private readonly logger = new AppLogger()
  private readonly extractor = new ContentExtractor()
  private readonly embeddings = new EmbeddingService(this.database)
  private readonly indexer = new IndexerService(this.database, this.extractor, this.embeddings, this.logger)
  private readonly organizer = new OrganizerService(this.database, this.logger)
  private readonly watcher = new FileWatcherService(this.database, this.indexer, this.organizer, this.logger)
  private readonly chat = new ChatService(this.database, this.embeddings, new LlmService(), this.logger)
  private readonly ollamaManager = new OllamaManager()
  private selectedSessionId: number | null = null
  private ollama = { reachable: false, models: [] as string[] }
  private indexingProgress: AppSnapshot['indexingProgress'] = null
  onChanged?: () => void

  async initialize(): Promise<void> {
    await this.database.initialize()
    const settings = this.database.getSettings()
    this.selectedSessionId = this.database.listChatSessions()[0]?.id ?? null
    this.indexer.onProgress = (completed, total, currentName) => {
      this.indexingProgress = total ? { completed, total, currentName } : null
      this.notifyChanged()
    }
    this.watcher.onChanged = () => this.notifyChanged()
    this.ollama = await this.ollamaManager.refresh(settings)
    if (process.platform === 'win32') app.setLoginItemSettings({ openAtLogin: settings.launchAtLogin, path: process.execPath })
    if (settings.onboardingCompleted) await this.watcher.start(settings)
    if (settings.automaticUpdateChecks && app.isPackaged) setTimeout(() => void this.checkForUpdates(), 10_000)
  }

  async snapshot(): Promise<AppSnapshot> {
    const sessions = this.database.listChatSessions()
    if (this.selectedSessionId != null && !sessions.some((session) => session.id === this.selectedSessionId)) this.selectedSessionId = sessions[0]?.id ?? null
    return {
      settings: this.database.getSettings(),
      files: this.database.listFiles(),
      rules: this.database.listRules(),
      chatSessions: sessions,
      selectedSessionId: this.selectedSessionId,
      messages: this.selectedSessionId == null ? [] : this.database.listMessages(this.selectedSessionId),
      statistics: await this.database.statistics(),
      watching: this.watcher.isWatching,
      indexing: this.indexer.isRunning,
      indexingPaused: this.indexer.isPaused,
      indexingProgress: this.indexingProgress,
      ollama: this.ollama,
      docling: await doclingManager.status()
    }
  }

  async updateSettings(patch: Partial<Settings>): Promise<Settings> {
    const previous = this.database.getSettings()
    const next = await this.database.updateSettings(normalizeSettingsPatch(patch))
    if ('launchAtLogin' in patch && process.platform === 'win32') app.setLoginItemSettings({ openAtLogin: next.launchAtLogin, path: process.execPath })
    const watcherKeys: Array<keyof Settings> = ['watchDirs', 'enabledExtensions', 'excludeHidden', 'autoOrganize', 'autoOrganizeMode', 'autoOrganizeIntervalSeconds', 'autoOrganizeBatchSize']
    if (watcherKeys.some((key) => JSON.stringify(previous[key]) !== JSON.stringify(next[key])) && this.watcher.isWatching) await this.watcher.start(next)
    this.notifyChanged()
    return next
  }

  async chooseWatchDirectories(): Promise<string[]> {
    const result = await dialog.showOpenDialog({ title: 'Choose Folders to Watch', properties: ['openDirectory', 'multiSelections', 'createDirectory'] })
    return result.canceled ? [] : result.filePaths
  }

  async chooseOrganizedRoot(): Promise<string | null> {
    const result = await dialog.showOpenDialog({ title: 'Choose where to store organized files', defaultPath: this.database.getSettings().organizedRoot, properties: ['openDirectory', 'createDirectory'] })
    return result.canceled ? null : result.filePaths[0] ?? null
  }

  async chooseChatFile(): Promise<string | null> {
    const result = await dialog.showOpenDialog({ title: 'Choose a file to chat with', properties: ['openFile'] })
    const path = result.canceled ? null : result.filePaths[0] ?? null
    if (path) await this.ensureAttachedFile(path)
    return path
  }

  async startWatching(): Promise<void> { await this.watcher.start(this.database.getSettings()); this.notifyChanged() }
  async stopWatching(): Promise<void> { await this.watcher.stop(); this.notifyChanged() }
  async scanExisting(): Promise<void> { await this.watcher.scanExisting(this.database.getSettings()); this.notifyChanged() }
  async organizeNow(): Promise<void> { await this.organizer.organizeAll(this.database.getSettings()); this.notifyChanged() }
  async reindexAll(): Promise<void> { await this.indexer.reindexAll(this.database.getSettings()); this.indexingProgress = null; this.notifyChanged() }
  async reindexFile(id: number): Promise<void> {
    const file = this.database.getFile(id)
    if (!file) return
    await this.indexer.indexFile({ ...file, contentHash: null, indexSignature: null }, this.database.getSettings(), undefined, true)
    this.notifyChanged()
  }
  pauseIndexing(): void { this.indexer.pause(); this.notifyChanged() }
  resumeIndexing(): void { this.indexer.resume(); this.notifyChanged() }
  cancelIndexing(): void { this.indexer.cancel(); this.notifyChanged() }

  searchFiles(query: string, category?: FileCategory | null): FileRecord[] {
    if (!query.trim() && !category) return this.database.listFiles()
    if (!query.trim()) return this.database.listFiles().filter((file) => file.category === category)
    return this.database.searchFiles(query.trim(), category)
  }

  async openFile(path: string): Promise<string> { return shell.openPath(path) }
  showInExplorer(path: string): void { shell.showItemInFolder(path) }

  async trashFile(id: number): Promise<void> {
    const file = this.database.getFile(id)
    if (!file) return
    await shell.trashItem(file.path)
    await this.database.deleteFile(id)
    this.notifyChanged()
  }

  async saveFileNote(id: number, note: string): Promise<void> {
    await this.database.updateFile(id, { note })
    const file = this.database.getFile(id)
    if (file) await this.indexer.indexFile({ ...file, contentHash: null }, this.database.getSettings(), undefined, true)
    this.notifyChanged()
  }

  async summarizeFile(id: number): Promise<string> {
    const file = this.database.getFile(id)
    if (!file) throw new Error('The file does not exist')
    return this.chat.summarize(file, this.database.getSettings())
  }

  previewUrl(path: string): string {
    const allowed = this.database.getFileByPath(path)
    if (!allowed) throw new Error('The file is not in the FileNest library')
    return `filenest-file://local/${Buffer.from(path, 'utf8').toString('base64url')}`
  }

  isPreviewPathAllowed(path: string): boolean { return this.database.getFileByPath(path) != null }

  async createRule(rule: Omit<Rule, 'id'>): Promise<Rule> { const value = await this.database.createRule(rule); this.notifyChanged(); return value }
  async updateRule(rule: Rule): Promise<Rule> { const value = await this.database.updateRule(rule); this.notifyChanged(); return value }
  async deleteRule(id: number): Promise<void> { await this.database.deleteRule(id); this.notifyChanged() }
  generateRules(prompt: string): ReturnType<ChatService['generateRules']> { return this.chat.generateRules(prompt, this.database.getSettings()) }

  async createChat(attachedFilePath: string | null = null) {
    const session = await this.database.createChat(attachedFilePath)
    this.selectedSessionId = session.id
    this.notifyChanged()
    return session
  }

  selectChat(id: number) { this.selectedSessionId = id; this.notifyChanged(); return this.database.listMessages(id) }
  async deleteChat(id: number): Promise<void> { await this.database.deleteChat(id); if (this.selectedSessionId === id) this.selectedSessionId = this.database.listChatSessions()[0]?.id ?? null; this.notifyChanged() }
  async clearChats(): Promise<void> { await this.database.clearChats(); this.selectedSessionId = null; this.notifyChanged() }

  async sendChat(request: SendChatRequest, sender: Electron.WebContents): Promise<{ requestId: string }> {
    if (request.attachedFilePath) await this.ensureAttachedFile(request.attachedFilePath)
    const requestId = this.chat.send(request, this.database.getSettings(), (event) => {
      if (event.sessionId != null) this.selectedSessionId = event.sessionId
      if (!sender.isDestroyed()) sender.send('chat:stream', event)
      if (event.type === 'done') this.notifyChanged()
    })
    return { requestId }
  }

  cancelChat(requestId: string): void { this.chat.cancel(requestId) }

  async refreshOllama() { this.ollama = await this.ollamaManager.refresh(this.database.getSettings()); this.notifyChanged(); return this.ollama }
  async pullOllamaModel(model: string): Promise<void> { await this.ollamaManager.pull(model, this.database.getSettings()); await this.refreshOllama() }
  async deleteOllamaModel(model: string): Promise<void> { await this.ollamaManager.delete(model, this.database.getSettings()); await this.refreshOllama() }
  async installOllama(): Promise<void> {
    await this.ollamaManager.install()
    await new Promise((resolve) => setTimeout(resolve, 1_500))
    await this.refreshOllama()
  }
  async installDocling(): Promise<void> {
    const task = doclingManager.install()
    this.notifyChanged()
    try { await task } finally { this.notifyChanged() }
  }

  async checkForUpdates(): Promise<string> {
    if (!app.isPackaged) return 'Development builds do not check for updates'
    const feed = this.database.getSettings().updateFeedUrl.trim()
    if (!/^https:\/\//i.test(feed)) return 'Configure a valid HTTPS update URL first'
    try {
      autoUpdater.autoDownload = this.database.getSettings().automaticallyDownloadsUpdates
      autoUpdater.setFeedURL({ provider: 'generic', url: feed })
      const result = await autoUpdater.checkForUpdates()
      return result?.updateInfo?.version ? `Found version ${result.updateInfo.version}` : "You're up to date"
    } catch (error) {
      await this.logger.log('updates', 'Update check failed', error)
      return error instanceof Error ? error.message : String(error)
    }
  }

  async exportLogs(): Promise<string | null> {
    const result = await dialog.showOpenDialog({ title: 'Choose where to export logs', properties: ['openDirectory', 'createDirectory'] })
    return result.canceled ? null : this.logger.exportTo(result.filePaths[0])
  }

  clearLogs(): Promise<number> { return this.logger.clear() }

  async shutdown(): Promise<void> {
    this.indexer.cancel()
    await this.watcher.stop()
    await this.database.flush()
  }

  private async ensureAttachedFile(path: string): Promise<FileRecord> {
    const existing = this.database.getFileByPath(path)
    if (existing?.indexedAt) return existing
    const info = await stat(path)
    if (!info.isFile()) throw new Error('Only files can be attached')
    const ext = normalizedExtension(path)
    const record = await this.database.upsertFile({
      path,
      name: basename(path),
      ext,
      size: info.size,
      mtime: info.mtime.toISOString(),
      category: categoryForExtension(ext),
      sourceDir: dirname(path),
      indexedAt: existing?.indexedAt ?? null,
      contentHash: existing?.contentHash ?? null,
      title: existing?.title ?? null,
      contentText: existing?.contentText ?? null,
      discoveredAt: existing?.discoveredAt ?? new Date().toISOString(),
      organizedAt: existing?.organizedAt ?? null,
      note: existing?.note ?? null,
      organizationSubfolder: existing?.organizationSubfolder ?? null,
      isDirectory: false,
      indexSignature: existing?.indexSignature ?? null
    })
    await this.indexer.indexFile(record, this.database.getSettings(), path, true)
    this.notifyChanged()
    return this.database.getFile(record.id) ?? record
  }

  notifyChanged(): void {
    for (const window of BrowserWindow.getAllWindows()) if (!window.isDestroyed()) window.webContents.send('state:changed')
    this.onChanged?.()
  }
}

function normalizeSettingsPatch(patch: Partial<Settings>): Partial<Settings> {
  const result = { ...patch }
  if (result.vectorChunkWords != null) result.vectorChunkWords = Math.min(4000, Math.max(50, Math.round(result.vectorChunkWords)))
  if (result.vectorChunkOverlap != null) result.vectorChunkOverlap = Math.max(0, Math.round(result.vectorChunkOverlap))
  if (result.autoOrganizeIntervalSeconds != null) result.autoOrganizeIntervalSeconds = Math.min(3600, Math.max(5, Math.round(result.autoOrganizeIntervalSeconds)))
  if (result.autoOrganizeBatchSize != null) result.autoOrganizeBatchSize = Math.min(500, Math.max(1, Math.round(result.autoOrganizeBatchSize)))
  if (result.enabledExtensions) result.enabledExtensions = [...new Set(result.enabledExtensions.map((value) => value.replace(/^\./, '').trim().toLowerCase()).filter(Boolean))]
  if (result.vectorizeExtensions) result.vectorizeExtensions = [...new Set(result.vectorizeExtensions.map((value) => value.replace(/^\./, '').trim().toLowerCase()).filter(Boolean))]
  if (result.watchDirs) result.watchDirs = [...new Set(result.watchDirs)]
  if (result.updateFeedUrl != null) result.updateFeedUrl = result.updateFeedUrl.trim()
  return result
}
