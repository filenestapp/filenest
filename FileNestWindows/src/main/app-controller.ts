import { app, BrowserWindow, dialog, shell } from 'electron'
import { basename, dirname, join } from 'node:path'
import { readFile, rm, stat, writeFile } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import type { AiConnectivityCheck, AppSnapshot, ChatFeedback, ChatStreamEvent, DuplicateFileGroup, DuplicateScanProgress, DuplicateTrashResult, FileCategory, FileRecord, LibrarySearchRequest, LibrarySearchResponse, ReindexMode, Rule, SendChatRequest, Settings } from '../shared/types'
import { FileNestDatabase } from './database'
import { AppLogger } from './logger'
import { ContentExtractor } from './content-extractor'
import { EmbeddingService } from './embedding'
import { IndexerService } from './indexer'
import { OrganizerService } from './organizer'
import { FileWatcherService } from './watcher'
import { LlmService } from './llm'
import { ChatService } from './chat'
import { OllamaManager, requiresOllamaService } from './ollama'
import updater from 'electron-updater'
import { doclingManager } from './docling'
import { categoryForExtension, normalizedExtension } from './file-policy'
import { LibrarySearchService } from './library-search'
import { normalizeSettingsPatch } from './settings-normalization'
import { prompts } from './prompts'
import { RerankerServiceManager } from './reranker-manager'
import { mediaTranscriptionManager } from './media-transcription'
import { DuplicateFileService, sha256File } from './duplicate-files'

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
  private readonly librarySearch = new LibrarySearchService(this.database, this.embeddings, this.logger)
  private readonly duplicateFiles = new DuplicateFileService(this.database)
  private readonly ollamaManager = new OllamaManager()
  private readonly rerankerManager = new RerankerServiceManager()
  private selectedSessionId: number | null = null
  private readonly runningChatSessionIds = new Set<number>()
  private readonly completedChatSessionIds = new Set<number>()
  private pendingLibrarySearch: { id: string; query: string; includeSemantic?: boolean } | null = null
  private quickSearchShortcutError: string | null = null
  private pendingChatAttachmentPath: string | null = null
  private ollama = { reachable: false, models: [] as string[] }
  private indexingProgress: AppSnapshot['indexingProgress'] = null
  private loadedChatMessageLimit = 40
  private duplicateFileGroups: DuplicateFileGroup[] = []
  private duplicateScanProgress: DuplicateScanProgress | null = null
  private duplicateTrashProgress: AppSnapshot['duplicateTrashProgress'] = null
  private duplicateScanError: string | null = null
  onChanged?: () => void
  onQuickSearchRequested?: () => void
  onQuickSearchShortcutChanged?: (shortcut: string) => string | null

  async initialize(): Promise<void> {
    await this.database.initialize()
    this.duplicateFileGroups = this.duplicateFiles.knownGroups()
    const settings = this.database.getSettings()
    this.selectedSessionId = null
    this.indexer.onProgress = (completed, total, currentName, failed, stage) => {
      this.indexingProgress = total ? { completed, total, currentName, failed, stage } : null
      this.notifyChanged()
    }
    this.watcher.onChanged = () => this.notifyChanged()
    this.rerankerManager.onChanged = () => this.notifyChanged()
    mediaTranscriptionManager.onChanged = () => this.notifyChanged()
    this.ollama = requiresOllamaService(settings)
      ? await this.ollamaManager.start(settings)
      : await this.ollamaManager.refresh(settings)
    await this.rerankerManager.refresh()
    await mediaTranscriptionManager.refresh()
    if (settings.rerankerSource === 'local') void this.rerankerManager.start().catch((error) => this.logger.log('reranker', 'Unable to start the local reranker', error))
    if (process.platform === 'win32') app.setLoginItemSettings({ openAtLogin: settings.launchAtLogin, path: process.execPath })
    if (settings.onboardingCompleted) await this.watcher.start(settings)
    if (settings.onboardingCompleted) void this.resumePendingOrganization()
    void this.backfillFileCreationDates()
    if (settings.onboardingCompleted) void this.auditManagedContent()
    if (settings.automaticUpdateChecks && app.isPackaged) setTimeout(() => void this.checkForUpdates(), 10_000)
  }

  async snapshot(): Promise<AppSnapshot> {
    if (!this.duplicateScanProgress && !this.duplicateTrashProgress) this.duplicateFileGroups = this.duplicateFiles.knownGroups()
    const sessions = this.database.listChatSessions()
    if (this.selectedSessionId != null && !sessions.some((session) => session.id === this.selectedSessionId)) this.selectedSessionId = sessions[0]?.id ?? null
    const messagePage = this.selectedSessionId == null
      ? { messages: [], hasEarlier: false }
      : this.database.chatMessagePage(this.selectedSessionId, null, this.loadedChatMessageLimit)
    return {
      settings: this.database.getSettings(),
      files: this.database.listFiles(),
      rules: this.database.listRules(),
      chatSessions: sessions,
      selectedSessionId: this.selectedSessionId,
      pendingChatAttachmentPath: this.pendingChatAttachmentPath,
      messages: messagePage.messages,
      hasEarlierChatMessages: messagePage.hasEarlier,
      runningChatSessionIds: [...this.runningChatSessionIds],
      completedChatSessionIds: [...this.completedChatSessionIds],
      pendingLibrarySearch: this.pendingLibrarySearch,
      quickSearchShortcutError: this.quickSearchShortcutError,
      statistics: await this.database.statistics(),
      watching: this.watcher.isWatching,
      indexing: this.indexer.isRunning,
      indexingPaused: this.indexer.isPaused,
      indexingProgress: this.indexingProgress,
      organizing: this.watcher.isManualOrganizationRunning,
      organizationPaused: this.watcher.isManualOrganizationPaused,
      automaticProcessingItems: this.watcher.automaticProcessingItems,
      duplicateFileGroups: this.duplicateFileGroups,
      duplicateScanProgress: this.duplicateScanProgress,
      duplicateTrashProgress: this.duplicateTrashProgress,
      duplicateScanError: this.duplicateScanError,
      watchDirectoryStatuses: await this.watcher.statuses(this.database.getSettings()),
      ollama: this.ollama,
      docling: await doclingManager.status(),
      ffmpeg: mediaTranscriptionManager.ffmpeg(),
      whisper: mediaTranscriptionManager.whisper(),
      reranker: this.rerankerManager.status()
    }
  }

  private async backfillFileCreationDates(): Promise<void> {
    const candidates = this.database.filesMissingCreationDate(256)
    const values = (await Promise.all(candidates.map(async (file) => {
      const metadata = await stat(file.path).catch(() => null)
      return metadata ? { id: file.id, creationDate: metadata.birthtime.toISOString() } : null
    }))).filter((value): value is { id: number; creationDate: string } => value != null)
    await this.database.updateCreationDates(values).catch((error) => this.logger.log('database', 'Unable to backfill file creation dates', error))
    if (candidates.length === 256) setTimeout(() => void this.backfillFileCreationDates(), 250)
  }

  private async auditManagedContent(force = false): Promise<number> {
    const timestampKey = 'managed_content_audit.last_completed_at.v1'
    const cursorKey = 'managed_content_audit.last_file_id.v1'
    const now = Date.now()
    const lastCompleted = Number(this.database.getInternalSetting(timestampKey) ?? 0)
    if (!force && now - lastCompleted < 24 * 60 * 60 * 1000) return 0
    const settings = this.database.getSettings()
    const cursor = Number(this.database.getInternalSetting(cursorKey) ?? 0)
    const fetched = this.database.managedContentAuditCandidates(settings.organizedRoot, settings.vectorizeExtensions, cursor, 256)
    const maximumBytes = 256 * 1024 * 1024
    const selected: FileRecord[] = []
    let selectedBytes = 0
    for (const file of fetched) {
      if (selected.length && selectedBytes + Math.max(0, file.size) > maximumBytes) break
      selected.push(file)
      selectedBytes += Math.max(0, file.size)
    }
    const changedIds: number[] = []
    for (const file of selected) {
      try {
        const currentHash = file.isDirectory ? await this.extractor.hash(file.path, true) : await sha256File(file.path)
        if (file.contentHash && currentHash !== file.contentHash) changedIds.push(file.id)
      } catch {
        // Missing or unreadable files are reconciled by the watcher instead.
      }
    }
    await this.database.invalidateFileIndexes(changedIds)
    if (selected.at(-1)) await this.database.setInternalSetting(cursorKey, String(selected.at(-1)!.id))
    else if (cursor > 0) await this.database.setInternalSetting(cursorKey, '0')
    await this.database.setInternalSetting(timestampKey, String(now))
    if (changedIds.length) this.notifyChanged()
    return changedIds.length
  }

  async updateSettings(patch: Partial<Settings>): Promise<Settings> {
    const previous = this.database.getSettings()
    const next = await this.database.updateSettings(normalizeSettingsPatch(patch, previous))
    if ('quickSearchShortcut' in patch) this.quickSearchShortcutError = this.onQuickSearchShortcutChanged?.(next.quickSearchShortcut) ?? null
    if ('launchAtLogin' in patch && process.platform === 'win32') app.setLoginItemSettings({ openAtLogin: next.launchAtLogin, path: process.execPath })
    if ('rerankerSource' in patch) {
      if (next.rerankerSource === 'local') void this.rerankerManager.start().catch((error) => this.logger.log('reranker', 'Unable to start the local reranker', error))
      else await this.rerankerManager.stop()
    }
    const watcherKeys: Array<keyof Settings> = ['watchDirs', 'enabledExtensions', 'excludeHidden', 'autoOrganize', 'autoOrganizeMode', 'autoOrganizeIntervalSeconds', 'autoOrganizeBatchSize']
    if (watcherKeys.some((key) => JSON.stringify(previous[key]) !== JSON.stringify(next[key])) && this.watcher.isWatching) await this.watcher.start(next)
    const ollamaKeys: Array<keyof Settings> = ['llmChoice', 'embeddingSource', 'ollamaHost', 'ollamaFlashAttentionEnabled']
    if (ollamaKeys.some((key) => previous[key] !== next[key])) {
      this.ollama = requiresOllamaService(next) ? await this.ollamaManager.start(next) : await this.ollamaManager.refresh(next)
    }
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

  async chooseOrganizationDirectories(): Promise<string[]> {
    const result = await dialog.showOpenDialog({
      title: 'Choose Folders to Organize',
      message: 'Selected folders are processed once and are not added to monitoring.',
      buttonLabel: 'Choose',
      properties: ['openDirectory', 'multiSelections']
    })
    return result.canceled ? [] : result.filePaths
  }

  async chooseChatFile(): Promise<string | null> {
    const result = await dialog.showOpenDialog({ title: 'Choose a file to chat with', properties: ['openFile'] })
    const path = result.canceled ? null : result.filePaths[0] ?? null
    if (path) await this.ensureAttachedFile(path)
    return path
  }

  async startWatching(): Promise<void> { await this.watcher.start(this.database.getSettings()); this.notifyChanged() }
  async stopWatching(): Promise<void> { await this.watcher.stop(); this.notifyChanged() }
  async scanExisting(directories?: string[]): Promise<void> { await this.watcher.scanExisting(this.database.getSettings(), directories); this.notifyChanged() }
  async preserveExisting(directories?: string[]): Promise<void> { await this.watcher.preserveExisting(this.database.getSettings(), directories); this.notifyChanged() }
  async organizeNow(): Promise<void> { await this.watcher.organizePending(this.database.getSettings()); this.notifyChanged() }
  async organizeExisting(directories?: string[]): Promise<void> { await this.watcher.organizeExisting(this.database.getSettings(), directories); this.notifyChanged() }
  async organizeDirectoriesOnce(directories: string[], recursively = false): Promise<void> {
    const normalized = [...new Set(directories.map((path) => path.trim()).filter(Boolean))]
    if (!normalized.length || this.watcher.isManualOrganizationRunning) return
    await writeFile(this.pendingOrganizationPath, JSON.stringify({ directories: normalized, recursively }), 'utf8')
    try {
      await this.watcher.organizeDirectoriesOnce(this.database.getSettings(), normalized, recursively)
    } finally {
      if (!this.watcher.isManualOrganizationRunning) await rm(this.pendingOrganizationPath, { force: true })
      this.notifyChanged()
    }
  }
  pauseOrganization(): void { this.watcher.pauseManualOrganization(); this.notifyChanged() }
  resumeOrganization(): void { this.watcher.resumeManualOrganization(); this.notifyChanged() }
  async cancelOrganization(): Promise<void> {
    this.watcher.cancelManualOrganization()
    await rm(this.pendingOrganizationPath, { force: true })
    this.notifyChanged()
  }
  async reindexAll(mode: ReindexMode = 'all', categories: FileCategory[] = []): Promise<void> { await this.indexer.reindexAll(this.database.getSettings(), mode, categories); this.indexingProgress = null; this.notifyChanged() }
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

  searchLibrary(request: LibrarySearchRequest, sender?: Electron.WebContents): Promise<LibrarySearchResponse> {
    return this.librarySearch.search(request, this.database.getSettings(), (intent) => {
      if (request.requestId && sender && !sender.isDestroyed()) {
        sender.send('library:search-progress', { requestId: request.requestId, intent })
      }
    })
  }

  requestLibrarySearch(rawQuery: string): void {
    const query = rawQuery.trim()
    if (!query) return
    this.pendingLibrarySearch = { id: randomUUID(), query, includeSemantic: false }
    this.onQuickSearchRequested?.()
    this.notifyChanged()
  }

  consumeLibrarySearch(id: string): void {
    if (this.pendingLibrarySearch?.id !== id) return
    this.pendingLibrarySearch = null
    this.notifyChanged()
  }

  setQuickSearchShortcutError(error: string | null): void {
    this.quickSearchShortcutError = error
    this.notifyChanged()
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

  async scanDuplicateFiles(): Promise<DuplicateFileGroup[]> {
    if (this.duplicateScanProgress || this.duplicateTrashProgress) return this.duplicateFileGroups
    this.duplicateScanError = null
    try {
      this.duplicateFileGroups = await this.duplicateFiles.scan((progress) => {
        this.duplicateScanProgress = progress
        this.notifyChanged()
      })
      return this.duplicateFileGroups
    } catch (error) {
      this.duplicateScanError = error instanceof Error ? error.message : String(error)
      return []
    } finally {
      this.duplicateScanProgress = null
      this.notifyChanged()
    }
  }

  async trashDuplicateFiles(paths: string[]): Promise<DuplicateTrashResult> {
    if (this.duplicateTrashProgress || this.duplicateScanProgress) return { movedCount: 0, failedFileNames: [] }
    const result = await this.duplicateFiles.moveToTrash(paths, (path) => shell.trashItem(path), (completedCount, totalCount, currentFileName) => {
      this.duplicateTrashProgress = { completedCount, totalCount, currentFileName }
      this.notifyChanged()
    })
    this.duplicateTrashProgress = null
    this.duplicateFileGroups = this.duplicateFiles.knownGroups()
    this.notifyChanged()
    return result
  }

  async saveFileNote(id: number, note: string): Promise<void> {
    await this.database.updateFile(id, { note })
    const file = this.database.getFile(id)
    if (file) await this.indexer.updateNoteIndex(file, this.database.getSettings())
    this.notifyChanged()
  }

  async summarizeFile(id: number): Promise<string> {
    const file = this.database.getFile(id)
    if (!file) throw new Error('The file does not exist')
    return this.chat.summarize(file, this.database.getSettings())
  }

  getDocumentChunks(id: number, offset = 0, limit?: number) { return this.database.listDocumentChunks(id, offset, limit) }
  getDocumentChunkCount(id: number): number { return this.database.documentChunkCount(id) }

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

  beginChat(attachedFilePath: string | null = null): void {
    this.selectedSessionId = null
    this.pendingChatAttachmentPath = attachedFilePath
    this.notifyChanged()
  }

  selectChat(id: number) { this.selectedSessionId = id; this.loadedChatMessageLimit = 40; this.pendingChatAttachmentPath = null; this.completedChatSessionIds.delete(id); this.notifyChanged(); return this.database.chatMessagePage(id, null, this.loadedChatMessageLimit).messages }
  loadEarlierChatMessages(): void { if (this.selectedSessionId != null) this.loadedChatMessageLimit += 40; this.notifyChanged() }
  async saveChatFeedback(messageId: number, feedback: ChatFeedback | null): Promise<void> { await this.database.updateChatMessageFeedback(messageId, feedback); this.notifyChanged() }
  markChatSeen(id: number): void { this.completedChatSessionIds.delete(id); this.notifyChanged() }
  async deleteChat(id: number): Promise<void> { await this.database.deleteChat(id); this.runningChatSessionIds.delete(id); this.completedChatSessionIds.delete(id); if (this.selectedSessionId === id) this.selectedSessionId = this.database.listChatSessions()[0]?.id ?? null; this.notifyChanged() }
  async clearChats(): Promise<void> { await this.database.clearChats(); this.selectedSessionId = null; this.runningChatSessionIds.clear(); this.completedChatSessionIds.clear(); this.notifyChanged() }

  async sendChat(request: SendChatRequest, sender: Electron.WebContents): Promise<{ requestId: string }> {
    if (request.attachedFilePath) await this.ensureAttachedFile(request.attachedFilePath)
    const requestId = this.chat.send(request, this.database.getSettings(), (event) => {
      if (event.sessionId != null) {
        this.selectedSessionId = event.sessionId
        this.pendingChatAttachmentPath = null
        if (event.type === 'session') {
          this.runningChatSessionIds.add(event.sessionId)
          this.completedChatSessionIds.delete(event.sessionId)
        } else if (event.type === 'done') {
          this.runningChatSessionIds.delete(event.sessionId)
          this.completedChatSessionIds.add(event.sessionId)
        } else if (event.type === 'error') {
          this.runningChatSessionIds.delete(event.sessionId)
        }
      }
      if (!sender.isDestroyed()) sender.send('chat:stream', event)
      if (event.type === 'session' || event.type === 'done' || event.type === 'error') this.notifyChanged()
    })
    return { requestId }
  }

  cancelChat(requestId: string): void { this.chat.cancel(requestId) }

  async refreshOllama() { this.ollama = await this.ollamaManager.refresh(this.database.getSettings()); this.notifyChanged(); return this.ollama }
  async pullOllamaModel(model: string): Promise<void> { await this.ollamaManager.pull(model, this.database.getSettings()); await this.refreshOllama() }
  async deleteOllamaModel(model: string): Promise<void> { await this.ollamaManager.delete(model, this.database.getSettings()); await this.refreshOllama() }
  async installOllama(): Promise<void> {
    await this.ollamaManager.install(this.database.getSettings())
    await new Promise((resolve) => setTimeout(resolve, 1_500))
    await this.refreshOllama()
  }
  async installDocling(): Promise<void> {
    const task = doclingManager.install()
    this.notifyChanged()
    try { await task } finally { this.notifyChanged() }
  }
  async installFfmpeg(): Promise<void> { await mediaTranscriptionManager.installFfmpeg(); this.notifyChanged() }
  async installWhisper(): Promise<void> { await mediaTranscriptionManager.installWhisper(); this.notifyChanged() }
  async downloadWhisperModel(model: string): Promise<void> { await mediaTranscriptionManager.downloadWhisperModel(model); this.notifyChanged() }
  async deleteWhisperModel(model: string): Promise<void> { await mediaTranscriptionManager.deleteWhisperModel(model); this.notifyChanged() }
  async refreshReranker(): Promise<void> { await this.rerankerManager.refresh(); this.notifyChanged() }
  async installReranker(): Promise<void> { await this.rerankerManager.install(); this.notifyChanged() }
  async startReranker(): Promise<void> { await this.rerankerManager.start(); this.notifyChanged() }
  async stopReranker(): Promise<void> { await this.rerankerManager.stop(); this.notifyChanged() }
  async deleteReranker(): Promise<void> { await this.rerankerManager.deleteModel(); this.notifyChanged() }

  async testAiConnections(): Promise<AiConnectivityCheck[]> {
    const settings = this.database.getSettings()
    const results: AiConnectivityCheck[] = []
    if (settings.llmChoice === 'none') {
      results.push({ capability: 'chat', provider: 'Retrieval only', success: true, detail: 'Generative chat is disabled' })
    } else {
      const provider = new LlmService().provider(settings)
      try {
        await new LlmService().complete([
          { role: 'system', content: prompts.connectivity.system },
          { role: 'user', content: prompts.connectivity.user }
        ], settings, 15_000)
        results.push({ capability: 'chat', provider: provider.name, success: true, detail: provider.model })
      } catch (error) {
        results.push({ capability: 'chat', provider: provider.name, success: false, detail: error instanceof Error ? error.message : String(error) })
      }
    }
    try {
      const vector = await this.embeddings.embed(prompts.connectivity.embedding, settings)
      results.push({ capability: 'embedding', provider: this.embeddings.modelName(settings), success: vector.length > 0, detail: `${vector.length} dimensions` })
    } catch (error) {
      results.push({ capability: 'embedding', provider: this.embeddings.modelName(settings), success: false, detail: error instanceof Error ? error.message : String(error) })
    }
    const ocrProvider = settings.ocrSource === 'disabled' ? 'Disabled' : settings.ocrSource === 'local' ? 'Local Tesseract with Ollama fallback' : settings.ocrSource === 'ollama' ? `Ollama ${settings.ollamaOcrModel}` : `Cloud ${settings.cloudOcrModel}`
    try {
      const detail = await testOcrConnection(settings)
      results.push({ capability: 'ocr', provider: ocrProvider, success: true, detail })
    } catch (error) {
      results.push({ capability: 'ocr', provider: ocrProvider, success: false, detail: error instanceof Error ? error.message : String(error) })
    }
    return results
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
    await this.ollamaManager.stop()
    await this.rerankerManager.shutdown()
    await this.database.flush()
  }

  private get pendingOrganizationPath(): string { return join(app.getPath('userData'), 'pending-organization-job.json') }

  private async resumePendingOrganization(): Promise<void> {
    const job = await readFile(this.pendingOrganizationPath, 'utf8')
      .then((value) => JSON.parse(value) as { directories?: unknown; recursively?: unknown })
      .catch(() => null)
    if (!job || !Array.isArray(job.directories) || !job.directories.every((path) => typeof path === 'string')) return
    await this.organizeDirectoriesOnce(job.directories, job.recursively === true)
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

const CONNECTIVITY_TEST_PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='

async function testOcrConnection(settings: Settings): Promise<string> {
  if (settings.ocrSource === 'disabled') return 'OCR is disabled'
  if (settings.ocrSource === 'local') return 'The bundled local OCR runtime is available; Ollama remains the fallback'
  if (settings.ocrSource === 'ollama') {
    const response = await fetch(new URL('/api/chat', settings.ollamaHost.replace(/\/+$/, '') + '/'), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: settings.ollamaOcrModel, stream: false, messages: [{ role: 'user', content: 'Return OK after inspecting this connectivity test image.', images: [CONNECTIVITY_TEST_PNG] }] }),
      signal: AbortSignal.timeout(15_000)
    })
    if (!response.ok) throw new Error(`Ollama OCR ${response.status}: ${await response.text()}`)
    return settings.ollamaOcrModel
  }
  const reuse = settings.cloudOcrReuseChatCredentials
  const key = reuse ? settings.cloudApiKey : settings.cloudOcrApiKey
  const base = reuse ? settings.cloudBaseUrl : settings.cloudOcrBaseUrl
  const format = reuse ? settings.cloudApiFormat : settings.cloudOcrFormat
  if (!key) throw new Error('The OCR API key is empty')
  const url = new URL(format === 'anthropic' ? 'messages' : 'chat/completions', base.replace(/\/+$/, '') + '/')
  const headers: Record<string, string> = format === 'anthropic'
    ? { 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' }
    : { 'content-type': 'application/json', authorization: `Bearer ${key}` }
  const body = format === 'anthropic'
    ? { model: settings.cloudOcrModel, max_tokens: 8, messages: [{ role: 'user', content: [{ type: 'image', source: { type: 'base64', media_type: 'image/png', data: CONNECTIVITY_TEST_PNG } }, { type: 'text', text: 'Return OK.' }] }] }
    : { model: settings.cloudOcrModel, max_tokens: 8, messages: [{ role: 'user', content: [{ type: 'text', text: 'Return OK.' }, { type: 'image_url', image_url: { url: `data:image/png;base64,${CONNECTIVITY_TEST_PNG}` } }] }] }
  const response = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(15_000) })
  if (!response.ok) throw new Error(`Cloud OCR ${response.status}: ${await response.text()}`)
  return settings.cloudOcrModel
}
