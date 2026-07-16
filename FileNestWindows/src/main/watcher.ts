import chokidar, { type FSWatcher } from 'chokidar'
import { basename, dirname, relative } from 'node:path'
import { readdir, stat } from 'node:fs/promises'
import type { FileRecord, Settings } from '../shared/types'
import { FileNestDatabase } from './database'
import { categoryForExtension, normalizedExtension, shouldIgnore } from './file-policy'
import { IndexerService } from './indexer'
import { OrganizerService } from './organizer'
import { AppLogger } from './logger'

export class FileWatcherService {
  private watcher: FSWatcher | null = null
  private directoryCandidates = new Set<string>()
  private organizeQueue = new Set<number>()
  private batchTimer: ReturnType<typeof setInterval> | null = null
  private currentSettings: Settings | null = null
  onChanged?: () => void

  constructor(
    private readonly database: FileNestDatabase,
    private readonly indexer: IndexerService,
    private readonly organizer: OrganizerService,
    private readonly logger: AppLogger
  ) {}

  get isWatching(): boolean { return this.watcher != null }

  async start(settings: Settings): Promise<void> {
    await this.stop()
    this.currentSettings = settings
    if (!settings.watchDirs.length) return
    this.watcher = chokidar.watch(settings.watchDirs, {
      ignoreInitial: true,
      persistent: true,
      awaitWriteFinish: { stabilityThreshold: 2_000, pollInterval: 250 },
      ignored: (path, stats) => shouldIgnore(path, stats?.isDirectory() ?? false, settings)
    })
    this.watcher.on('add', (path) => void this.handle(path, false))
    this.watcher.on('change', (path) => void this.handle(path, false))
    this.watcher.on('addDir', (path) => {
      if (settings.watchDirs.some((root) => dirname(path) === root)) {
        this.directoryCandidates.add(path)
        void this.handle(path, true).finally(() => this.directoryCandidates.delete(path))
      }
    })
    this.watcher.on('unlink', (path) => void this.handleRemoval(path))
    this.watcher.on('unlinkDir', (path) => void this.handleRemoval(path))
    this.watcher.on('error', (error) => void this.logger.log('watcher', 'Watcher error', error))
    this.configureBatchTimer(settings)
    await this.logger.log('watcher', `Start Watching：${settings.watchDirs.join(', ')}`)
    this.onChanged?.()
  }

  async stop(): Promise<void> {
    if (this.batchTimer) clearInterval(this.batchTimer)
    this.batchTimer = null
    await this.flushOrganizeQueue()
    await this.watcher?.close()
    this.watcher = null
    this.directoryCandidates.clear()
    this.onChanged?.()
  }

  async scanExisting(settings: Settings): Promise<void> {
    this.currentSettings = settings
    for (const root of settings.watchDirs) {
      const entries = await readdir(root, { withFileTypes: true }).catch(() => [])
      for (const entry of entries) {
        const path = `${root}/${entry.name}`
        if (!shouldIgnore(path, entry.isDirectory(), settings)) await this.handle(path, entry.isDirectory())
      }
    }
    await this.flushOrganizeQueue()
  }

  private async handle(path: string, isDirectory: boolean): Promise<void> {
    const settings = this.currentSettings
    if (!settings || this.isInsideDirectoryCandidate(path)) return
    try {
      const info = await stat(path)
      const sourceDir = settings.watchDirs.find((root) => path === root || path.startsWith(`${root}/`) || path.startsWith(`${root}\\`)) ?? dirname(path)
      const ext = isDirectory ? '' : normalizedExtension(path)
      const existing = this.database.getFileByPath(path)
      const input: Omit<FileRecord, 'id'> = {
        path,
        name: basename(path),
        ext,
        size: info.size,
        mtime: info.mtime.toISOString(),
        category: isDirectory ? 'other' : categoryForExtension(ext),
        sourceDir,
        indexedAt: existing?.indexedAt ?? null,
        contentHash: existing?.contentHash ?? null,
        title: existing?.title ?? null,
        contentText: existing?.contentText ?? null,
        discoveredAt: existing?.discoveredAt ?? new Date().toISOString(),
        organizedAt: existing?.organizedAt ?? null,
        note: existing?.note ?? null,
        organizationSubfolder: existing?.organizationSubfolder ?? null,
        isDirectory,
        indexSignature: existing?.indexSignature ?? null
      }
      const record = await this.database.upsertFile(input)
      const indexed = await this.indexer.indexFile(record, settings, path)
      const current = this.database.getFile(record.id) ?? record
      if (indexed && settings.autoOrganize) await this.scheduleOrganization(current, settings)
      this.onChanged?.()
    } catch (error) {
      await this.logger.log('watcher', `Processing failed: ${path}`, error)
    }
  }

  private isInsideDirectoryCandidate(path: string): boolean {
    return [...this.directoryCandidates].some((directory) => path !== directory && relative(directory, path) && !relative(directory, path).startsWith('..'))
  }

  private async handleRemoval(path: string): Promise<void> {
    const file = this.database.getFileByPath(path)
    if (!file) return
    await this.database.deleteFile(file.id)
    this.onChanged?.()
  }

  private async scheduleOrganization(file: FileRecord, settings: Settings): Promise<void> {
    if (settings.autoOrganizeMode === 'immediate') {
      await this.organizer.organize(file, settings)
      return
    }
    this.organizeQueue.add(file.id)
    if (this.organizeQueue.size >= settings.autoOrganizeBatchSize) await this.flushOrganizeQueue()
  }

  private configureBatchTimer(settings: Settings): void {
    if (this.batchTimer) clearInterval(this.batchTimer)
    if (settings.autoOrganizeMode === 'batched') {
      this.batchTimer = setInterval(() => void this.flushOrganizeQueue(), Math.max(5, settings.autoOrganizeIntervalSeconds) * 1000)
    }
  }

  private async flushOrganizeQueue(): Promise<void> {
    const settings = this.currentSettings
    if (!settings || !this.organizeQueue.size) return
    const ids = [...this.organizeQueue]
    this.organizeQueue.clear()
    for (const id of ids) {
      const file = this.database.getFile(id)
      if (file) await this.organizer.organize(file, settings).catch((error) => this.logger.log('organizer', `Batch organization failed: ${file.path}`, error))
    }
    this.onChanged?.()
  }
}
