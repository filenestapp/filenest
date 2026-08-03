import type { DocumentChunk, DocumentChunkKind, FileCategory, FileRecord, ReindexMode, Settings } from '../shared/types'
import { FileNestDatabase } from './database'
import { ContentExtractor } from './content-extractor'
import { EmbeddingService } from './embedding'
import { AppLogger } from './logger'
import { estimateCanonicalTokens, tokenUnits } from './token-counter'
import { MEDIA_TRANSCRIPTION_EXTENSIONS } from './defaults'
import { buildTranscriptChunks, mediaTranscriptionManager } from './media-transcription'
import { totalmem } from 'node:os'

interface ActiveIndexTask {
  key: string
  promise: Promise<boolean>
}

export interface ReindexRunResult {
  completed: boolean
  total: number
  failedFileIds: number[]
  pendingFileIds: number[]
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
    checkpoint?: () => boolean,
    onStage?: (stage: 'indexing' | 'transcribing') => void
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
    const promise = this.performIndexFile(file, settings, path, force, generation, checkpoint, onStage)
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
    const parentOffset = note ? 1 : 0
    const chunks = [
      ...(note ? [makeChunk(`User note: ${note}`, 'note', ['User note'], 0, `User note: ${note}`)] : []),
      ...storedChunks.map((chunk) => ({ ...chunk, parentIndex: chunk.parentIndex + parentOffset }))
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
          indexSignature: this.indexConfigurationSignature(settings)
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
    checkpoint?: () => boolean,
    onStage?: (stage: 'indexing' | 'transcribing') => void
  ): Promise<boolean> {
    const isMedia = settings.mediaTranscriptionEnabled && MEDIA_TRANSCRIPTION_EXTENSIONS.includes(file.ext.toLowerCase())
    if (!force && (!settings.autoVectorize || (!file.isDirectory && !settings.vectorizeExtensions.includes(file.ext) && !isMedia))) {
      return true
    }
    try {
      if (!(await this.waitWhilePaused()) || checkpoint?.() === false) return false
      const before = await this.extractor.hash(path, file.isDirectory)
      const indexSignature = this.indexConfigurationSignature(settings)
      if (file.contentHash === before && file.indexSignature === indexSignature && file.indexedAt) return true
      if (!file.isDirectory) {
        const original = this.database.indexedOriginal(before, file.id)
        if (original) {
          await this.database.markFileAsDuplicate(file.id, original.id, before)
          return true
        }
      }

      if (isMedia) onStage?.('transcribing')
      const transcription = isMedia
        ? await mediaTranscriptionManager.transcribe(path, settings.whisperModel)
        : null
      const extracted = transcription
        ? { title: file.name, text: transcription.text }
        : await this.extractor.extract(path, settings, file.isDirectory)
      if (before !== await this.extractor.hash(path, file.isDirectory)) throw new Error('The file changed during content extraction')
      const chunks = transcription
        ? mergeTranscriptMetadata(file.name, file.note, buildTranscriptChunks(transcription, settings.vectorChunkWords))
        : buildDocumentChunks(
            extracted.title,
            file.note,
            extracted.text,
            settings.vectorChunkWords,
            settings.vectorChunkOverlap,
            settings.vectorRetrievalChunkTokens
          )
      onStage?.('indexing')
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
          indexSignature
        }
      )
      return true
    } catch (error) {
      await this.logger.log('indexer', `Indexing failed: ${path}`, error)
      return false
    }
  }

  private indexConfigurationSignature(settings: Settings): string {
    return [
      this.embeddings.signature(settings), settings.doclingEnabled ? 'docling-v3' : 'docling-disabled',
      settings.ocrSource, settings.vectorChunkWords, settings.vectorRetrievalChunkTokens,
      settings.vectorChunkOverlap, settings.mediaTranscriptionEnabled ? `whisper:${settings.whisperModel}` : 'media-disabled'
    ].join('|')
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

  async reindexAll(
    settings: Settings,
    mode: ReindexMode = 'all',
    categories: FileCategory[] = [],
    fileIds?: number[],
    onFileState?: (file: FileRecord, state: 'processing' | 'completed' | 'failed') => Promise<void>
  ): Promise<ReindexRunResult> {
    if (this.running) return { completed: false, total: 0, failedFileIds: [], pendingFileIds: fileIds ?? [] }
    this.running = true
    this.paused = false
    const generation = ++this.batchGeneration
    const requestedIds = fileIds == null ? null : new Set(fileIds)
    const files = this.database.listFiles().filter((file) => {
      if (requestedIds && !requestedIds.has(file.id)) return false
      if (categories.length && !categories.includes(file.category)) return false
      if (mode === 'unindexed') return !file.indexedAt
      if (mode === 'media') return settings.mediaTranscriptionEnabled && MEDIA_TRANSCRIPTION_EXTENSIONS.includes(file.ext.toLowerCase())
      return true
    })
    let failed = 0
    let completed = 0
    const failedFileIds: number[] = []
    const processedFileIds = new Set<number>()
    try {
      let nextIndex = 0
      const concurrency = Math.min(files.length, recommendedFileConcurrency(totalmem(), settings))
      const worker = async (): Promise<void> => {
        while (generation === this.batchGeneration) {
          if (!(await this.waitWhilePaused(generation))) return
          const index = nextIndex++
          if (index >= files.length) return
          const file = files[index]
          this.onProgress?.(completed, files.length, file.name, failed, mode === 'media' ? 'Transcribing audio or video' : 'Checking file')
          await onFileState?.(file, 'processing')
          const succeeded = mode === 'embeddings'
            ? await this.updateNoteIndex(file, settings)
            : await this.indexFile(file, settings, undefined, mode === 'all' || mode === 'media', () => generation === this.batchGeneration)
          if (!succeeded) {
            failed += 1
            failedFileIds.push(file.id)
            await onFileState?.(file, 'failed')
          } else {
            await onFileState?.(file, 'completed')
          }
          completed += 1
          processedFileIds.add(file.id)
        }
      }
      await Promise.all(Array.from({ length: concurrency }, () => worker()))
      const finished = generation === this.batchGeneration
      this.onProgress?.(completed, files.length, '', failed, finished ? 'Completed' : 'Stopped')
      return {
        completed: finished,
        total: files.length,
        failedFileIds,
        pendingFileIds: files.filter((file) => !processedFileIds.has(file.id)).map((file) => file.id)
      }
    } finally {
      if (generation === this.batchGeneration) this.batchGeneration += 1
      this.running = false
      this.resume()
    }
  }
}

export function recommendedFileConcurrency(physicalMemory: number, settings: Pick<Settings, 'embeddingSource' | 'doclingEnabled' | 'ocrSource' | 'mediaTranscriptionEnabled'>): number {
  if (physicalMemory <= 8 * 1024 ** 3) return 1
  if (settings.embeddingSource === 'ollama' || settings.doclingEnabled || settings.ocrSource === 'local' || settings.mediaTranscriptionEnabled) return 2
  return 3
}

function mergeTranscriptMetadata(title: string, note: string | null, transcriptChunks: DocumentChunk[]): DocumentChunk[] {
  const prefix: DocumentChunk[] = []
  if (note?.trim()) prefix.push(makeChunk(`User note: ${note.trim()}`, 'note', ['User note'], prefix.length, `User note: ${note.trim()}`))
  if (title.trim()) prefix.push(makeChunk(title.trim(), 'title', [title.trim()], prefix.length, title.trim()))
  const offset = prefix.length
  return [...prefix, ...transcriptChunks.map((chunk) => ({ ...chunk, parentIndex: chunk.parentIndex + offset }))]
    .map((chunk, index) => ({ ...chunk, index }))
}

export function buildDocumentChunks(
  title: string,
  note: string | null,
  text: string,
  wordsPerChunk: number,
  overlap: number,
  retrievalTokens = Math.min(300, wordsPerChunk)
): DocumentChunk[] {
  const chunks: DocumentChunk[] = []
  let parentIndex = 0
  const normalizedTitle = title.trim()
  if (normalizedTitle) {
    chunks.push(makeChunk(normalizedTitle, 'title', [normalizedTitle], parentIndex, normalizedTitle))
    parentIndex += 1
  }
  const normalizedNote = note?.trim()
  if (normalizedNote) {
    const noteText = `User note: ${normalizedNote}`
    chunks.push(makeChunk(noteText, 'note', ['User note'], parentIndex, noteText))
    parentIndex += 1
  }

  const sections = splitSections(text)
  for (const section of sections) {
    const parents = chunkSemanticText(section.text, wordsPerChunk, 0, section.kind)
    for (const parentText of parents) {
      const children = estimateCanonicalTokens(parentText).count > Math.max(360, retrievalTokens)
        ? chunkSemanticText(parentText, retrievalTokens, overlap, section.kind)
        : [parentText]
      for (const value of children) {
        const context = [section.path.length ? `Section: ${section.path.join(' > ')}` : '', section.page ? `Page: ${section.page}` : '', value]
          .filter(Boolean)
          .join('\n')
        const measurement = estimateCanonicalTokens(context)
        chunks.push({
          ...makeChunk(value, section.kind, section.path, parentIndex, parentText),
          contextualText: context,
          pageStart: section.page,
          pageEnd: section.page,
          entityTerms: extractEntityTerms(value),
          tokenCount: measurement.count,
          tokenizerProfile: measurement.tokenizerProfile,
          tokenizerVersion: measurement.tokenizerVersion,
          tokenCountAccuracy: measurement.accuracy
        })
      }
      parentIndex += 1
    }
  }
  return chunks.slice(0, 500).map((chunk, index) => ({ ...chunk, index }))
}

function makeChunk(text: string, kind: DocumentChunkKind, sectionPath: string[], parentIndex: number, parentText: string): DocumentChunk {
  const measurement = estimateCanonicalTokens(text)
  return {
    index: 0, text, contextualText: text, sectionPath, pageStart: null, pageEnd: null, kind,
    parentIndex, parentText, entityTerms: extractEntityTerms(text),
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
  return chunkSemanticText(text, wordsPerChunk, overlap, inferChunkKind(text))
}

function chunkSemanticText(text: string, targetTokens: number, overlapTokens: number, kind: DocumentChunkKind): string[] {
  const normalized = text.replace(/\r\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim()
  if (!normalized) return []
  if (kind === 'table') return tablePieces(normalized, targetTokens)
  const size = Math.max(50, targetTokens)
  const safeOverlap = Math.min(Math.max(0, overlapTokens), size - 1)
  const units = semanticUnits(normalized, size)
  const chunks: string[] = []
  let start = 0
  while (start < units.length && chunks.length < 500) {
    let end = start
    let cost = 0
    while (end < units.length && (cost === 0 || cost + units[end].tokens <= size)) {
      cost += units[end].tokens
      end += 1
    }
    if (end === start) end += 1
    chunks.push(units.slice(start, end).map((unit) => unit.text).join(units[start]?.separator ?? ' ').trim())
    if (end >= units.length) break
    let nextStart = end
    let retained = 0
    while (nextStart > start && retained + units[nextStart - 1].tokens <= safeOverlap) {
      nextStart -= 1
      retained += units[nextStart].tokens
    }
    start = nextStart > start ? nextStart : end
  }
  return chunks
}

function semanticUnits(text: string, targetTokens: number): Array<{ text: string; tokens: number; separator: string }> {
  const paragraphs = text.split(/\n\s*\n/).map((value) => value.trim()).filter(Boolean)
  const result: Array<{ text: string; tokens: number; separator: string }> = []
  for (const paragraph of paragraphs) {
    const paragraphTokens = estimateCanonicalTokens(paragraph).count
    if (paragraphTokens <= targetTokens) {
      result.push({ text: paragraph, tokens: paragraphTokens, separator: '\n\n' })
      continue
    }
    const sentences = paragraph.match(/[^.!?。！？]+[.!?。！？]+(?:["'”’)]*)|[^.!?。！？]+$/gu)?.map((value) => value.trim()).filter(Boolean) ?? [paragraph]
    if (sentences.length > 1) {
      for (const sentence of sentences) result.push({ text: sentence, tokens: estimateCanonicalTokens(sentence).count, separator: ' ' })
      continue
    }
    if (paragraphTokens <= targetTokens * 4) {
      result.push({ text: paragraph, tokens: paragraphTokens, separator: ' ' })
      continue
    }
    const lexical = tokenUnits(paragraph)
    let current: string[] = []
    let currentTokens = 0
    for (const unit of lexical) {
      if (current.length && currentTokens + unit.weight > targetTokens) {
        const value = current.join(' ').replace(/([\p{Script=Han}])\s+(?=[\p{Script=Han}])/gu, '$1')
        result.push({ text: value, tokens: estimateCanonicalTokens(value).count, separator: ' ' })
        current = []
        currentTokens = 0
      }
      current.push(unit.value)
      currentTokens += unit.weight
    }
    if (current.length) {
      const value = current.join(' ').replace(/([\p{Script=Han}])\s+(?=[\p{Script=Han}])/gu, '$1')
      result.push({ text: value, tokens: estimateCanonicalTokens(value).count, separator: ' ' })
    }
  }
  return result
}

function tablePieces(text: string, targetTokens: number): string[] {
  const rows = text.split('\n').map((row) => row.trim()).filter(Boolean)
  if (rows.length <= 2 || estimateCanonicalTokens(text).count <= targetTokens) return [text]
  const header = rows[0]
  const pieces: string[] = []
  let current = [header]
  let tokens = estimateCanonicalTokens(header).count
  for (const row of rows.slice(1)) {
    const rowTokens = estimateCanonicalTokens(row).count
    if (current.length > 1 && tokens + rowTokens > targetTokens) {
      pieces.push(current.join('\n'))
      current = [header]
      tokens = estimateCanonicalTokens(header).count
    }
    current.push(row)
    tokens += rowTokens
  }
  if (current.length > 1) pieces.push(current.join('\n'))
  return pieces.length ? pieces : [text]
}

export function extractEntityTerms(text: string): string[] {
  const patterns = [
    /\b[A-Z0-9][A-Z0-9._/-]{2,}\d[A-Z0-9._/-]*\b/giu,
    /\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b/giu,
    /\b\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\b/gu,
    /(?:[$€£¥]|SGD|USD|EUR|CNY|RMB)\s*\d[\d,.]*/giu
  ]
  const matches = new Set<string>()
  for (const pattern of patterns) {
    for (const match of text.matchAll(pattern)) {
      const value = match[0].trim().toLocaleLowerCase()
      if (value.length >= 3) matches.add(value)
    }
  }
  return [...matches].sort()
}
