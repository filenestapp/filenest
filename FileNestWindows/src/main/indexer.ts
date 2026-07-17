import type { DocumentChunk, DocumentChunkKind, FileRecord, ReindexMode, Settings } from '../shared/types'
import { FileNestDatabase } from './database'
import { ContentExtractor } from './content-extractor'
import { EmbeddingService } from './embedding'
import { AppLogger } from './logger'
import { estimateCanonicalTokens, tokenUnits } from './token-counter'

interface ActiveIndexTask {
  key: string
  promise: Promise<boolean>
}

export class IndexerService {
  private running = false
  private paused = false
  private batchGeneration = 0
  private pauseWaiters: Array<() => void> = []
  private activeTasks = new Map<number, ActiveIndexTask>()
  private fileGenerations = new Map<number, number>()
  onProgress?: (completed: number, total: number, name: string, failed: number, stage: string) => void

  constructor(
    private readonly database: FileNestDatabase,
    private readonly extractor: ContentExtractor,
    private readonly embeddings: EmbeddingService,
    private readonly logger: AppLogger
  ) {}

  get isRunning(): boolean { return this.running }
  get isPaused(): boolean { return this.paused }

  pause(): void {
    if (this.running) this.paused = true
  }

  resume(): void {
    this.paused = false
    for (const resolve of this.pauseWaiters.splice(0)) resolve()
  }

  cancel(): void {
    this.batchGeneration += 1
    this.resume()
  }

  private async waitWhilePaused(batchGeneration?: number): Promise<boolean> {
    while (this.paused && (batchGeneration == null || batchGeneration === this.batchGeneration)) {
      await new Promise<void>((resolve) => this.pauseWaiters.push(resolve))
    }
    return batchGeneration == null || batchGeneration === this.batchGeneration
  }

  async indexFile(
    file: FileRecord,
    settings: Settings,
    overridePath?: string,
    force = false,
    checkpoint?: () => boolean
  ): Promise<boolean> {
    const path = overridePath ?? file.path
    const key = [path, force ? 'force' : 'incremental', this.embeddings.signature(settings)].join('|')
    while (true) {
      const active = this.activeTasks.get(file.id)
      if (!active) break
      if (active.key === key) return active.promise
      await active.promise
    }

    const generation = (this.fileGenerations.get(file.id) ?? 0) + 1
    this.fileGenerations.set(file.id, generation)
    const promise = this.performIndexFile(file, settings, path, force, generation, checkpoint)
    this.activeTasks.set(file.id, { key, promise })
    try {
      return await promise
    } finally {
      if (this.activeTasks.get(file.id)?.promise === promise) this.activeTasks.delete(file.id)
    }
  }

  async updateNoteIndex(file: FileRecord, settings: Settings): Promise<boolean> {
    const storedChunks = this.database.listDocumentChunks(file.id).filter((chunk) => chunk.kind !== 'note')
    const note = file.note?.trim()
    const chunks = [
      ...(note ? [{
        index: 0,
        text: `User note: ${note}`,
        contextualText: `User note: ${note}`,
        sectionPath: ['User note'],
        pageStart: null,
        pageEnd: null,
        kind: 'note' as const
      }] : []),
      ...storedChunks
    ].map((chunk, index) => ({ ...chunk, index }))
    const generation = (this.fileGenerations.get(file.id) ?? 0) + 1
    this.fileGenerations.set(file.id, generation)
    try {
      const vectors = await this.embedChunks(chunks, settings)
      if (this.fileGenerations.get(file.id) !== generation) return false
      await this.database.commitFileIndex(
        file.id,
        chunks.map((chunk, index) => ({ chunk, vector: vectors[index] })),
        this.embeddings.modelName(settings),
        {
          title: file.title,
          contentText: file.contentText,
          contentHash: file.contentHash,
          indexedAt: file.indexedAt ?? new Date().toISOString(),
          indexSignature: this.embeddings.signature(settings)
        }
      )
      return true
    } catch (error) {
      await this.logger.log('indexer', `Note indexing failed: ${file.path}`, error)
      return false
    }
  }

  private async performIndexFile(
    file: FileRecord,
    settings: Settings,
    path: string,
    force: boolean,
    generation: number,
    checkpoint?: () => boolean
  ): Promise<boolean> {
    if (!force && (!settings.autoVectorize || (!file.isDirectory && !settings.vectorizeExtensions.includes(file.ext)))) {
      return true
    }
    try {
      if (!(await this.waitWhilePaused()) || checkpoint?.() === false) return false
      const before = await this.extractor.hash(path, file.isDirectory)
      if (file.contentHash === before && file.indexSignature === this.embeddings.signature(settings) && file.indexedAt) return true

      const extracted = await this.extractor.extract(path, settings, file.isDirectory)
      if (before !== await this.extractor.hash(path, file.isDirectory)) throw new Error('The file changed during content extraction')
      const chunks = buildDocumentChunks(extracted.title, file.note, extracted.text, settings.vectorChunkWords, settings.vectorChunkOverlap)
      const vectors = await this.embedChunks(chunks, settings, checkpoint)

      if (checkpoint?.() === false || this.fileGenerations.get(file.id) !== generation) return false
      if (before !== await this.extractor.hash(path, file.isDirectory)) throw new Error('The file changed during embedding')
      await this.database.commitFileIndex(
        file.id,
        chunks.map((chunk, index) => ({ chunk, vector: vectors[index] })),
        this.embeddings.modelName(settings),
        {
          title: extracted.title,
          contentText: extracted.text,
          contentHash: before,
          indexedAt: new Date().toISOString(),
          indexSignature: this.embeddings.signature(settings)
        }
      )
      return true
    } catch (error) {
      await this.logger.log('indexer', `Indexing failed: ${path}`, error)
      return false
    }
  }

  private async embedChunks(chunks: DocumentChunk[], settings: Settings, checkpoint?: () => boolean): Promise<Float32Array[]> {
    const vectors: Float32Array[] = []
    for (let offset = 0; offset < chunks.length; offset += 16) {
      if (!(await this.waitWhilePaused()) || checkpoint?.() === false) throw new Error('Indexing stopped')
      const texts = chunks.slice(offset, offset + 16).map((chunk) => chunk.contextualText)
      vectors.push(...await this.embedWithRecovery(texts, settings))
    }
    return vectors
  }

  private async embedWithRecovery(texts: string[], settings: Settings, retriedSingle = false): Promise<Float32Array[]> {
    try {
      const vectors = await this.embeddings.embedBatch(texts, settings)
      if (vectors.length !== texts.length || vectors.some((vector) => !vector.length || [...vector].some((value) => !Number.isFinite(value)))) {
        throw new Error('The embedding provider returned invalid vectors')
      }
      return vectors
    } catch (error) {
      if (texts.length > 1) {
        const midpoint = Math.ceil(texts.length / 2)
        return [
          ...await this.embedWithRecovery(texts.slice(0, midpoint), settings),
          ...await this.embedWithRecovery(texts.slice(midpoint), settings)
        ]
      }
      if (!retriedSingle) return this.embedWithRecovery(texts, settings, true)
      throw error
    }
  }

  async reindexAll(settings: Settings, mode: ReindexMode = 'all'): Promise<void> {
    if (this.running) return
    this.running = true
    this.paused = false
    const generation = ++this.batchGeneration
    const files = this.database.listFiles().filter((file) => mode !== 'unindexed' || !file.indexedAt)
    let failed = 0
    let completed = 0
    try {
      for (let index = 0; index < files.length; index += 1) {
        if (generation !== this.batchGeneration || !(await this.waitWhilePaused(generation))) break
        this.onProgress?.(index, files.length, files[index].name, failed, 'Checking file')
        const succeeded = mode === 'embeddings'
          ? await this.updateNoteIndex(files[index], settings)
          : await this.indexFile(files[index], settings, undefined, mode === 'all', () => generation === this.batchGeneration)
        if (!succeeded) failed += 1
        completed += 1
      }
      this.onProgress?.(completed, files.length, '', failed, generation === this.batchGeneration ? 'Completed' : 'Stopped')
    } finally {
      if (generation === this.batchGeneration) this.batchGeneration += 1
      this.running = false
      this.resume()
    }
  }
}

export function buildDocumentChunks(
  title: string,
  note: string | null,
  text: string,
  wordsPerChunk: number,
  overlap: number
): DocumentChunk[] {
  const chunks: DocumentChunk[] = []
  const normalizedTitle = title.trim()
  if (normalizedTitle) chunks.push(makeChunk(normalizedTitle, 'title', [normalizedTitle]))
  const normalizedNote = note?.trim()
  if (normalizedNote) chunks.push(makeChunk(`User note: ${normalizedNote}`, 'note', ['User note']))

  const sections = splitSections(text)
  for (const section of sections) {
    for (const value of chunkText(section.text, wordsPerChunk, overlap)) {
      const context = [section.path.length ? `Section: ${section.path.join(' > ')}` : '', section.page ? `Page: ${section.page}` : '', value]
        .filter(Boolean)
        .join('\n')
      const measurement = estimateCanonicalTokens(context)
      chunks.push({
        ...makeChunk(value, section.kind, section.path),
        contextualText: context,
        pageStart: section.page,
        pageEnd: section.page,
        tokenCount: measurement.count,
        tokenizerProfile: measurement.tokenizerProfile,
        tokenizerVersion: measurement.tokenizerVersion,
        tokenCountAccuracy: measurement.accuracy
      })
    }
  }
  return chunks.slice(0, 500).map((chunk, index) => ({ ...chunk, index }))
}

function makeChunk(text: string, kind: DocumentChunkKind, sectionPath: string[]): DocumentChunk {
  const measurement = estimateCanonicalTokens(text)
  return {
    index: 0, text, contextualText: text, sectionPath, pageStart: null, pageEnd: null, kind,
    tokenCount: measurement.count,
    tokenizerProfile: measurement.tokenizerProfile,
    tokenizerVersion: measurement.tokenizerVersion,
    tokenCountAccuracy: measurement.accuracy
  }
}

function splitSections(text: string): Array<{ text: string; path: string[]; page: number | null; kind: DocumentChunkKind }> {
  const lines = text.replace(/\r\n/g, '\n').split('\n')
  const result: Array<{ text: string; path: string[]; page: number | null; kind: DocumentChunkKind }> = []
  const headings: string[] = []
  let page: number | null = null
  let buffer: string[] = []

  const flush = (): void => {
    const value = buffer.join('\n').trim()
    if (value) result.push({ text: value, path: [...headings], page, kind: inferChunkKind(value) })
    buffer = []
  }

  for (const line of lines) {
    const pageMatch = line.match(/^\[Page\s+(\d+)\]$/i)
    if (pageMatch) {
      flush()
      page = Number(pageMatch[1])
      continue
    }
    const heading = line.match(/^(#{1,6})\s+(.+)$/)
    if (heading) {
      flush()
      const level = heading[1].length
      headings.splice(level - 1)
      headings[level - 1] = heading[2].trim()
      continue
    }
    if (!line.trim()) {
      flush()
      continue
    }
    buffer.push(line)
  }
  flush()
  return result.length ? result : [{ text: text.trim(), path: [], page: null, kind: 'text' }]
}

function inferChunkKind(text: string): DocumentChunkKind {
  const lines = text.split('\n').filter(Boolean)
  if (lines.length > 1 && lines.filter((line) => /\t|\|/.test(line)).length >= Math.ceil(lines.length / 2)) return 'table'
  if (lines.length > 1 && lines.filter((line) => /^\s*(?:[-*•]|\d+[.)])\s+/.test(line)).length >= Math.ceil(lines.length / 2)) return 'list'
  return 'text'
}

export function chunkText(text: string, wordsPerChunk: number, overlap: number): string[] {
  const normalized = text.replace(/\r\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim()
  if (!normalized) return []
  const units = tokenUnits(normalized)
  const size = Math.max(50, wordsPerChunk)
  const safeOverlap = Math.min(Math.max(0, overlap), size - 1)
  const chunks: string[] = []
  let start = 0
  while (start < units.length && chunks.length < 500) {
    let end = start
    let cost = 0
    while (end < units.length && cost + units[end].weight <= size + Number.EPSILON) {
      cost += units[end].weight
      end += 1
    }
    if (end === start) end += 1
    chunks.push(joinUnits(units.slice(start, end).map((unit) => unit.value)))
    if (end >= units.length) break
    let nextStart = end
    let retained = 0
    while (nextStart > start && retained + units[nextStart - 1].weight <= safeOverlap + Number.EPSILON) {
      nextStart -= 1
      retained += units[nextStart].weight
    }
    start = nextStart > start ? nextStart : end
  }
  return chunks
}

function joinUnits(units: string[]): string {
  return units.join(' ').replace(/([\p{Script=Han}])\s+(?=[\p{Script=Han}])/gu, '$1').trim()
}
