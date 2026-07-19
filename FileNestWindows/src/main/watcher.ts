import chokidar, { type FSWatcher } from 'chokidar'
import { basename, dirname, join, relative } from 'node:path'
import { readdir, stat } from 'node:fs/promises'
import type { AutomaticProcessingItem, FileRecord, Settings, WatchDirectoryStatus } from '../shared/types'
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
  private processingItems = new Map<number, AutomaticProcessingItem>()
  private runGeneration = 0
  private manualOrganizationGeneration = 0
  private manualOrganizationRunning = false
  private manualOrganizationPaused = false
  private manualPauseWaiters: Array<() => void> = []
  private manualQueueItems: AutomaticProcessingItem[] = []
  onChanged?: () => void

  constructor(
    private readonly database: FileNestDatabase,
    private readonly indexer: IndexerService,
    private readonly organizer: OrganizerService,
    private readonly logger: AppLogger
  ) {}

  get isWatching(): boolean { return this.watcher != null }
  get automaticProcessingItems(): AutomaticProcessingItem[] { return [...this.processingItems.values(), ...this.manualQueueItems] }
  get isManualOrganizationRunning(): boolean { return this.manualOrganizationRunning }
  get isManualOrganizationPaused(): boolean { return this.manualOrganizationPaused }

  async statuses(settings: Settings): Promise<WatchDirectoryStatus[]> {
    return Promise.all(settings.watchDirs.map(async (path) => {
      try {
        const info = await stat(path)
        if (!info.isDirectory()) return { path, state: 'unavailable' as const, detail: 'The configured path is not a folder' }
        return {
          path,
          state: this.isWatching ? 'watching' as const : 'stopped' as const,
          detail: this.isWatching ? 'Watching for stable changes' : 'Watching is paused'
        }
      } catch (error) {
        const code = error instanceof Error && 'code' in error ? String(error.code) : ''
        return {
          path,
          state: code === 'ENOENT' ? 'missing' as const : 'unavailable' as const,
          detail: code === 'ENOENT' ? 'The folder is missing or was moved' : 'The folder cannot be accessed'
        }
      }
    }))
  }

  async start(settings: Settings): Promise<void> {
    await this.stop()
    this.currentSettings = settings
    if (!settings.watchDirs.length) return
    const generation = ++this.runGeneration
    this.watcher = chokidar.watch(settings.watchDirs, {
      ignoreInitial: true,
      persistent: true,
      awaitWriteFinish: { stabilityThreshold: 2_000, pollInterval: 250 },
      ignored: (path, info) => shouldIgnore(path, info?.isDirectory() ?? false, settings)
    })
    this.watcher.on('add', (path) => void this.handle(path, false, generation))
    this.watcher.on('change', (path) => void this.handle(path, false, generation))
    this.watcher.on('addDir', (path) => {
      if (!settings.watchDirs.some((root) => dirname(path) === root)) return
      this.directoryCandidates.add(path)
      void this.handle(path, true, generation).finally(() => this.directoryCandidates.delete(path))
    })
    this.watcher.on('unlink', (path) => void this.handleRemoval(path, generation))
    this.watcher.on('unlinkDir', (path) => void this.handleRemoval(path, generation))
    this.watcher.on('error', (error) => void this.logger.log('watcher', 'Watcher error', error))
    this.configureBatchTimer(settings, generation)
    await this.reconcileOrganizedLibrary(settings, generation)
    await this.reconcileManagedItems(settings, generation)
    await this.reconcileWatchRoots(settings, generation)
    await this.logger.log('watcher', `Started watching: ${settings.watchDirs.join(', ')}`)
    this.onChanged?.()
  }

  async stop(): Promise<void> {
    this.runGeneration += 1
    if (this.batchTimer) clearInterval(this.batchTimer)
    this.batchTimer = null
    this.organizeQueue.clear()
    this.processingItems.clear()
    await this.watcher?.close()
    this.watcher = null
    this.directoryCandidates.clear()
    this.onChanged?.()
  }

  async preserveExisting(settings: Settings, directories = settings.watchDirs): Promise<void> {
    for (const root of directories) {
      const entries = await readdir(root, { withFileTypes: true }).catch(() => [])
      await this.database.replaceWatchDirectoryBaseline(root, entries.map((entry) => join(root, entry.name)))
    }
  }

  async scanExisting(settings: Settings, directories = settings.watchDirs): Promise<void> {
    this.currentSettings = settings
    await this.database.clearWatchDirectoryBaselines(directories)
    const generation = this.runGeneration
    for (const root of directories) {
      const entries = await readdir(root, { withFileTypes: true }).catch(() => [])
      for (const entry of entries) {
        if (generation !== this.runGeneration) return
        const path = join(root, entry.name)
        if (!shouldIgnore(path, entry.isDirectory(), settings)) await this.handle(path, entry.isDirectory(), generation)
      }
    }
    if (generation === this.runGeneration) await this.flushOrganizeQueue(generation)
  }

  async organizeDirectoriesOnce(settings: Settings, directories: string[], recursively = false): Promise<void> {
    if (this.manualOrganizationRunning) return
    const roots = [...new Set(directories)].filter((root) => !isInside(settings.organizedRoot, root))
    if (!roots.length) return
    this.manualOrganizationRunning = true
    this.manualOrganizationPaused = false
    const generation = ++this.manualOrganizationGeneration
    this.onChanged?.()
    try {
      const candidates: Array<{ path: string; sourceDir: string; isDirectory: boolean }> = []
      for (const root of roots) candidates.push(...await collectManualCandidates(root, settings, recursively))
      this.updateManualQueue(candidates)
      for (let index = 0; index < candidates.length; index += 1) {
        await this.waitWhileManualOrganizationPaused()
        const candidate = candidates[index]
        if (generation !== this.manualOrganizationGeneration) return
        this.updateManualQueue(candidates.slice(index + 1))
        const info = await stat(candidate.path).catch(() => null)
        if (!info) continue
        const ext = candidate.isDirectory ? '' : normalizedExtension(candidate.path)
        const existing = this.database.getFileByPath(candidate.path)
        const record = await this.database.upsertFile({
          path: candidate.path,
          name: basename(candidate.path),
          ext,
          size: info.size,
          mtime: info.mtime.toISOString(),
          category: candidate.isDirectory ? 'other' : categoryForExtension(ext),
          sourceDir: candidate.sourceDir,
          indexedAt: existing?.indexedAt ?? null,
          contentHash: existing?.contentHash ?? null,
          title: existing?.title ?? null,
          contentText: existing?.contentText ?? null,
          discoveredAt: existing?.discoveredAt ?? new Date().toISOString(),
          organizedAt: existing?.organizedAt ?? null,
          note: existing?.note ?? null,
          organizationSubfolder: existing?.organizationSubfolder ?? null,
          isDirectory: candidate.isDirectory,
          indexSignature: existing?.indexSignature ?? null
        })
        this.setProcessing(record, 'indexing')
        const indexed = await this.indexer.indexFile(record, settings, candidate.path, true, () => generation === this.manualOrganizationGeneration, (stage) => this.setProcessing(record, stage))
        if (!indexed || generation !== this.manualOrganizationGeneration) {
          this.clearProcessing(record.id)
          continue
        }
        const current = this.database.getFile(record.id) ?? record
        if (current.duplicateOfFileId != null) {
          this.clearProcessing(record.id)
          this.onChanged?.()
          continue
        }
        this.setProcessing(current, 'organizing')
        try {
          await this.organizer.organize(current, { ...settings, autoOrganize: true })
        } catch (error) {
          await this.logger.log('organizer', `One-time organization failed: ${candidate.path}`, error)
        } finally {
          this.clearProcessing(record.id)
        }
      }
    } finally {
      if (generation === this.manualOrganizationGeneration) this.manualOrganizationRunning = false
      this.manualOrganizationPaused = false
      this.manualQueueItems = []
      this.onChanged?.()
    }
  }

  pauseManualOrganization(): void {
    if (!this.manualOrganizationRunning) return
    this.manualOrganizationPaused = true
    this.indexer.pause()
    this.onChanged?.()
  }

  resumeManualOrganization(): void {
    this.manualOrganizationPaused = false
    this.indexer.resume()
    for (const resolve of this.manualPauseWaiters.splice(0)) resolve()
    this.onChanged?.()
  }

  cancelManualOrganization(): void {
    if (!this.manualOrganizationRunning) return
    this.manualOrganizationGeneration += 1
    this.manualOrganizationRunning = false
    this.manualOrganizationPaused = false
    this.indexer.cancel()
    for (const resolve of this.manualPauseWaiters.splice(0)) resolve()
    this.processingItems.clear()
    this.manualQueueItems = []
    this.onChanged?.()
  }

  private async waitWhileManualOrganizationPaused(): Promise<void> {
    while (this.manualOrganizationPaused) await new Promise<void>((resolve) => this.manualPauseWaiters.push(resolve))
  }

  private updateManualQueue(candidates: Array<{ path: string }>): void {
    this.manualQueueItems = candidates.slice(0, 10).map((candidate, index) => ({ id: -(index + 1), name: basename(candidate.path), stage: 'waiting' }))
    this.onChanged?.()
  }

  async reconcileOrganizedLibrary(settings: Settings, generation = this.runGeneration): Promise<void> {
    const root = settings.organizedRoot
    const existingManaged = this.database.listFiles().filter((file) => isInside(root, file.path))
    const existingByPath = new Map(existingManaged.map((file) => [canonicalPath(file.path), file]))
    const diskPaths = new Set<string>()
    const visit = async (directory: string): Promise<void> => {
      const entries = await readdir(directory, { withFileTypes: true }).catch(() => [])
      for (const entry of entries) {
        if (generation !== this.runGeneration && this.isWatching) return
        if (settings.excludeHidden && entry.name.startsWith('.')) continue
        const path = join(directory, entry.name)
        const existing = existingByPath.get(canonicalPath(path))
        if (entry.isDirectory()) {
          if (existing?.isDirectory) {
            diskPaths.add(canonicalPath(path))
            continue
          }
          await visit(path)
          continue
        }
        if (!entry.isFile()) continue
        const info = await stat(path).catch(() => null)
        if (!info) continue
        diskPaths.add(canonicalPath(path))
        const ext = normalizedExtension(path)
        const metadataChanged = existing != null && (existing.size !== info.size || Math.abs(new Date(existing.mtime).getTime() - info.mtime.getTime()) >= 1)
        if (existing && !metadataChanged && existing.name === entry.name && existing.organizedAt) continue
        const organizationSubfolder = relative(root, directory).split(/[\\/]/).filter(Boolean).join('/') || null
        if (existing) {
          const patch = {
            name: entry.name,
            size: info.size,
            mtime: info.mtime.toISOString(),
            category: categoryForExtension(ext),
            organizedAt: existing.organizedAt ?? new Date().toISOString(),
            organizationSubfolder,
            ...(metadataChanged ? { indexedAt: null, contentHash: null, indexSignature: null } : {})
          }
          await this.database.updateFile(existing.id, patch)
          if (metadataChanged) {
            const updated = this.database.getFile(existing.id)
            if (updated) await this.indexer.indexFile(updated, settings, path, true, () => generation === this.runGeneration || !this.isWatching)
          }
          continue
        }
        const record = await this.database.upsertFile({
          path,
          name: entry.name,
          ext,
          size: info.size,
          mtime: info.mtime.toISOString(),
          category: categoryForExtension(ext),
          sourceDir: directory,
          indexedAt: null,
          contentHash: null,
          title: null,
          contentText: null,
          discoveredAt: new Date().toISOString(),
          organizedAt: new Date().toISOString(),
          note: null,
          organizationSubfolder,
          isDirectory: false,
          indexSignature: null
        })
        await this.indexer.indexFile(record, settings, path, true, () => generation === this.runGeneration || !this.isWatching)
      }
    }
    await visit(root)
    for (const file of existingManaged) {
      if (!diskPaths.has(canonicalPath(file.path))) await this.database.deleteFile(file.id)
    }
  }

  private async reconcileManagedItems(settings: Settings, generation: number): Promise<void> {
    for (const file of this.database.listFiles().filter((item) => !item.organizedAt)) {
      if (generation !== this.runGeneration) return
      if (!settings.watchDirs.some((root) => isInside(root, file.path))) continue
      try {
        const info = await stat(file.path)
        await this.handle(file.path, info.isDirectory(), generation)
      } catch (error) {
        if (error instanceof Error && 'code' in error && error.code === 'ENOENT') await this.database.deleteFile(file.id)
      }
    }
  }

  private async reconcileWatchRoots(settings: Settings, generation: number): Promise<void> {
    for (const root of settings.watchDirs) {
      const entries = await readdir(root, { withFileTypes: true }).catch(() => [])
      for (const entry of entries) {
        if (generation !== this.runGeneration) return
        const path = join(root, entry.name)
        if (shouldIgnore(path, entry.isDirectory(), settings)) continue
        if (this.database.isWatchDirectoryBaselineEntry(root, path)) continue
        await this.handle(path, entry.isDirectory(), generation)
      }
    }
  }

  private async handle(path: string, isDirectory: boolean, generation: number): Promise<void> {
    const settings = this.currentSettings
    if (!settings || generation !== this.runGeneration || this.isInsideDirectoryCandidate(path)) return
    const sourceDir = settings.watchDirs.find((root) => isInside(root, path)) ?? dirname(path)
    const topLevelPath = topLevelEntry(sourceDir, path)
    if (this.database.isWatchDirectoryBaselineEntry(sourceDir, topLevelPath)) return
    try {
      if (isDirectory && !(await waitForStableDirectory(path, () => generation === this.runGeneration))) return
      const info = await stat(path)
      if (generation !== this.runGeneration) return
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
      this.setProcessing(record, 'indexing')
      const indexed = await this.indexer.indexFile(record, settings, path, false, () => generation === this.runGeneration, (stage) => this.setProcessing(record, stage))
      if (generation !== this.runGeneration) return
      const current = this.database.getFile(record.id) ?? record
      if (current.duplicateOfFileId != null) this.clearProcessing(record.id)
      else if (indexed && settings.autoOrganize) await this.scheduleOrganization(current, settings, generation)
      else this.clearProcessing(record.id)
      this.onChanged?.()
    } catch (error) {
      const record = this.database.getFileByPath(path)
      if (record) this.clearProcessing(record.id)
      await this.logger.log('watcher', `Processing failed: ${path}`, error)
    }
  }

  private isInsideDirectoryCandidate(path: string): boolean {
    return [...this.directoryCandidates].some((directory) => path !== directory && isInside(directory, path))
  }

  private async handleRemoval(path: string, generation: number): Promise<void> {
    if (generation !== this.runGeneration) return
    const file = this.database.getFileByPath(path)
    if (!file) return
    await this.database.deleteFile(file.id)
    this.onChanged?.()
  }

  private async scheduleOrganization(file: FileRecord, settings: Settings, generation: number): Promise<void> {
    if (generation !== this.runGeneration) return
    if (settings.autoOrganizeMode === 'immediate') {
      this.setProcessing(file, 'organizing')
      try { await this.organizer.organize(file, settings) } finally { this.clearProcessing(file.id) }
      return
    }
    this.organizeQueue.add(file.id)
    this.setProcessing(file, 'waiting')
    if (this.organizeQueue.size >= settings.autoOrganizeBatchSize) await this.flushOrganizeQueue(generation)
  }

  private configureBatchTimer(settings: Settings, generation: number): void {
    if (this.batchTimer) clearInterval(this.batchTimer)
    if (settings.autoOrganizeMode === 'batched') {
      this.batchTimer = setInterval(() => void this.flushOrganizeQueue(generation), Math.max(30, settings.autoOrganizeIntervalSeconds) * 1000)
    }
  }

  private async flushOrganizeQueue(generation: number): Promise<void> {
    const settings = this.currentSettings
    if (!settings || generation !== this.runGeneration || !this.organizeQueue.size) return
    const ids = [...this.organizeQueue]
    this.organizeQueue.clear()
    for (const id of ids) {
      if (generation !== this.runGeneration) return
      const file = this.database.getFile(id)
      if (file) {
        this.setProcessing(file, 'organizing')
        try { await this.organizer.organize(file, settings) } catch (error) {
          await this.logger.log('organizer', `Batch organization failed: ${file.path}`, error)
        } finally { this.clearProcessing(id) }
      } else this.clearProcessing(id)
    }
    this.onChanged?.()
  }

  private setProcessing(file: FileRecord, stage: AutomaticProcessingItem['stage']): void {
    this.processingItems.set(file.id, { id: file.id, name: file.name, stage })
    this.onChanged?.()
  }

  private clearProcessing(id: number): void {
    if (this.processingItems.delete(id)) this.onChanged?.()
  }
}

async function collectManualCandidates(root: string, settings: Settings, recursively: boolean): Promise<Array<{ path: string; sourceDir: string; isDirectory: boolean }>> {
  const candidates: Array<{ path: string; sourceDir: string; isDirectory: boolean }> = []
  const visit = async (directory: string): Promise<void> => {
    const entries = await readdir(directory, { withFileTypes: true }).catch(() => [])
    if (entries.some((entry) => ['.git', '.hg', '.svn'].includes(entry.name))) return
    for (const entry of entries) {
      const path = join(directory, entry.name)
      if (entry.isSymbolicLink() || shouldIgnore(path, entry.isDirectory(), settings)) continue
      if (entry.isDirectory() && recursively) await visit(path)
      else candidates.push({ path, sourceDir: directory, isDirectory: entry.isDirectory() })
    }
  }
  await visit(root)
  return candidates
}

function isInside(root: string, path: string): boolean {
  const value = relative(root, path)
  return value === '' || (!value.startsWith('..') && !value.includes(`..${process.platform === 'win32' ? '\\' : '/'}`))
}

function canonicalPath(path: string): string {
  return process.platform === 'win32' ? path.toLocaleLowerCase() : path
}

function topLevelEntry(root: string, path: string): string {
  const first = relative(root, path).split(/[\\/]/).filter(Boolean)[0]
  return first ? join(root, first) : path
}

async function waitForStableDirectory(path: string, isCurrent: () => boolean): Promise<boolean> {
  let previous = await directoryFingerprint(path)
  for (let attempt = 0; attempt < 2; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 1_000))
    if (!isCurrent()) return false
    const current = await directoryFingerprint(path)
    if (!current || current !== previous) {
      previous = current
      attempt = -1
      continue
    }
  }
  return Boolean(previous)
}

async function directoryFingerprint(root: string): Promise<string | null> {
  const entries = await readdir(root, { withFileTypes: true }).catch(() => null)
  if (!entries) return null
  const values: string[] = []
  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    const info = await stat(join(root, entry.name)).catch(() => null)
    if (info) values.push(`${entry.name}|${entry.isDirectory() ? 'd' : 'f'}|${info.size}|${info.mtimeMs}`)
  }
  return values.join('\n')
}
