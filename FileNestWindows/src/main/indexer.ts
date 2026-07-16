import type { FileRecord, Settings } from '../shared/types'
import { FileNestDatabase } from './database'
import { ContentExtractor } from './content-extractor'
import { EmbeddingService } from './embedding'
import { AppLogger } from './logger'

export class IndexerService {
  private cancelled = false
  private running = false
  private paused = false
  private pauseWaiters: Array<() => void> = []
  onProgress?: (completed: number, total: number, name: string) => void

  constructor(
    private readonly database: FileNestDatabase,
    private readonly extractor: ContentExtractor,
    private readonly embeddings: EmbeddingService,
    private readonly logger: AppLogger
  ) {}

  get isRunning(): boolean { return this.running }
  get isPaused(): boolean { return this.paused }
  pause(): void { if (this.running) this.paused = true }
  resume(): void {
    this.paused = false
    for (const resolve of this.pauseWaiters.splice(0)) resolve()
  }
  cancel(): void { this.cancelled = true; this.resume() }

  private async waitWhilePaused(): Promise<void> {
    while (this.paused && !this.cancelled) await new Promise<void>((resolve) => this.pauseWaiters.push(resolve))
  }

  async indexFile(file: FileRecord, settings: Settings, overridePath?: string, force = false): Promise<boolean> {
    const path = overridePath ?? file.path
    if (!force && (!settings.autoVectorize || (!file.isDirectory && !settings.vectorizeExtensions.includes(file.ext)))) return true
    try {
      await this.waitWhilePaused()
      if (this.cancelled) return false
      const before = await this.extractor.hash(path, file.isDirectory)
      if (file.contentHash === before && file.indexSignature === this.embeddings.signature(settings) && file.indexedAt) return true
      const extracted = await this.extractor.extract(path, settings, file.isDirectory)
      const after = await this.extractor.hash(path, file.isDirectory)
      if (before !== after) throw new Error('The file changed during indexing')
      const chunks = chunkText([extracted.title, file.note, extracted.text].filter(Boolean).join('\n\n'), settings.vectorChunkWords, settings.vectorChunkOverlap)
      const vectors: Float32Array[] = []
      for (let offset = 0; offset < chunks.length; offset += 16) {
        await this.waitWhilePaused()
        if (this.cancelled) return false
        vectors.push(...await this.embeddings.embedBatch(chunks.slice(offset, offset + 16), settings))
      }
      await this.database.replaceEmbeddings(file.id, chunks.map((text, index) => ({ text, vector: vectors[index] })), this.embeddings.modelName(settings))
      await this.database.updateFile(file.id, { title: extracted.title, contentText: extracted.text, contentHash: after, indexedAt: new Date().toISOString(), indexSignature: this.embeddings.signature(settings) })
      return true
    } catch (error) {
      await this.logger.log('indexer', `Indexing failed: ${path}`, error)
      return false
    }
  }

  async reindexAll(settings: Settings): Promise<void> {
    if (this.running) return
    this.running = true
    this.cancelled = false
    this.paused = false
    const files = this.database.listFiles()
    try {
      for (let index = 0; index < files.length; index += 1) {
        if (this.cancelled) break
        await this.waitWhilePaused()
        if (this.cancelled) break
        this.onProgress?.(index, files.length, files[index].name)
        await this.indexFile({ ...files[index], contentHash: null, indexSignature: null }, settings)
      }
      this.onProgress?.(files.length, files.length, '')
    } finally {
      this.running = false
      this.cancelled = false
      this.resume()
    }
  }
}

export function chunkText(text: string, wordsPerChunk: number, overlap: number): string[] {
  const normalized = text.replace(/\r\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim()
  if (!normalized) return []
  const units = normalized.match(/[\p{Script=Han}]|[\p{L}\p{N}_'-]+|[^\s]/gu) ?? []
  const size = Math.max(50, wordsPerChunk)
  const safeOverlap = Math.min(Math.max(0, overlap), size - 1)
  const chunks: string[] = []
  for (let start = 0; start < units.length; start += size - safeOverlap) {
    chunks.push(units.slice(start, start + size).join(' ').replace(/([\p{Script=Han}])\s+(?=[\p{Script=Han}])/gu, '$1').trim())
    if (start + size >= units.length) break
  }
  return chunks.slice(0, 500)
}
