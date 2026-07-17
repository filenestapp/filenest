import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import { mkdir, mkdtemp, rm, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

const testRoot = await mkdtemp(join(tmpdir(), 'filenest-windows-parity-'))

vi.mock('electron', () => ({
  app: {
    isPackaged: false,
    getPath: (name: string) => name === 'userData' ? join(testRoot, 'user-data') : name === 'downloads' ? join(testRoot, 'Downloads') : join(testRoot, 'Documents')
  },
  safeStorage: {
    isEncryptionAvailable: () => false,
    encryptString: (value: string) => Buffer.from(value),
    decryptString: (value: Buffer) => value.toString('utf8')
  }
}))

import type { ChatStreamEvent, FileRecord, Settings } from '../src/shared/types'
import { normalizeSettingsPatch } from '../src/main/settings-normalization'
import { ChatService, contextWindowForSettings, planChatHistory } from '../src/main/chat'
import { FileNestDatabase } from '../src/main/database'
import { EmbeddingService } from '../src/main/embedding'
import { buildDocumentChunks, IndexerService } from '../src/main/indexer'
import { LibrarySearchService, parseDateIntent } from '../src/main/library-search'
import { AppLogger } from '../src/main/logger'
import { ContentExtractor } from '../src/main/content-extractor'
import { OrganizerService, OrganizationError } from '../src/main/organizer'
import { LlmService } from '../src/main/llm'
import { estimateCanonicalTokens } from '../src/main/token-counter'
import { FileWatcherService } from '../src/main/watcher'
import { createDefaultSettings } from '../src/main/defaults'
import { streamedSearchIntent } from '../src/main/smart-search-plan'

beforeAll(async () => {
  await mkdir(join(testRoot, 'Downloads'), { recursive: true })
  await mkdir(join(testRoot, 'Documents'), { recursive: true })
})

afterAll(async () => rm(testRoot, { recursive: true, force: true }))

describe('settings and bounded chat context', () => {
  it('uses the shared multilingual token accounting profile', () => {
    expect(estimateCanonicalTokens('hello world').count).toBe(3)
    expect(estimateCanonicalTokens('中文测试').count).toBe(3)
    expect(estimateCanonicalTokens('one two three').count).toBe(4)
    expect(estimateCanonicalTokens('').count).toBe(0)
  })

  it('uses the same fixed Ollama defaults and model families as macOS', () => {
    const settings = createDefaultSettings()
    expect(settings.ollamaModel).toBe('qwen3.5:9b')
    expect(settings.ollamaEmbeddingModel).toBe('qwen3-embedding:0.6b')
    expect(settings.quickSearchShortcut).toBe('CommandOrControl+Alt+Space')
  })

  it('extracts a complete intent from a streamed smart-search plan', () => {
    expect(streamedSearchIntent('{"intent":"Find recent invoices","semantic_query":"invoice')).toBe('Find recent invoices')
    expect(streamedSearchIntent('{"intent":"incomplete')).toBeNull()
  })
  it('normalizes the same user-controlled limits as macOS', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const current = database.getSettings()
    expect(normalizeSettingsPatch({ ragResultLimit: 99 }, current).ragResultLimit).toBe(30)
    expect(normalizeSettingsPatch({ ragResultLimit: -2 }, current).ragResultLimit).toBe(1)
    expect(normalizeSettingsPatch({ cloudContextWindowTokens: 12 }, current).cloudContextWindowTokens).toBe(4_096)
    expect(normalizeSettingsPatch({ cloudContextWindowTokens: 0 }, current).cloudContextWindowTokens).toBe(0)
    expect(normalizeSettingsPatch({ vectorChunkWords: 12, vectorChunkOverlap: 9_000 }, current)).toMatchObject({ vectorChunkWords: 600, vectorChunkOverlap: 599 })
  })

  it('uses manual cloud context windows and retains the newest conversation turns', () => {
    const settings = { llmChoice: 'cloud', cloudContextWindowTokens: 65_536, cloudModel: 'custom-model' } as Settings
    expect(contextWindowForSettings(settings)).toBe(65_536)
    const messages = Array.from({ length: 20 }, (_, index) => ({
      id: index + 1,
      sessionId: 1,
      role: index % 2 ? 'assistant' as const : 'user' as const,
      content: `message-${index} ${'context '.repeat(200)}`,
      timestamp: new Date().toISOString(),
      relatedFileIds: []
    }))
    const planned = planChatHistory(messages, 1_000)
    expect(planned[0].role).toBe('system')
    expect(planned.at(-1)?.content).toContain('message-19')
  })
})

describe('structured indexing and atomic persistence', () => {
  it('builds title, note, list, table, and contextual text chunks', () => {
    const chunks = buildDocumentChunks(
      'Quarterly Report',
      'Reviewed by Finance',
      '# Revenue\n- North region grew\n- South region held\n\n| Region | Value |\n| North | 42 |',
      600,
      80
    )
    expect(chunks[0]).toMatchObject({ index: 0, kind: 'title', text: 'Quarterly Report' })
    expect(chunks.some((chunk) => chunk.kind === 'note')).toBe(true)
    expect(chunks.some((chunk) => chunk.kind === 'list')).toBe(true)
    expect(chunks.some((chunk) => chunk.kind === 'table')).toBe(true)
    expect(chunks.every((chunk, index) => chunk.index === index && chunk.contextualText.length > 0)).toBe(true)
  })

  it('persists structured chunks and updates a note without reparsing the source', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const source = join(testRoot, 'Downloads', 'structured-note.txt')
    await writeFile(source, 'Project Atlas\n\n# Milestones\n- Design\n- Delivery', 'utf8')
    const record = await addFile(database, source)
    const settings = { ...database.getSettings(), embeddingSource: 'local' as const, doclingEnabled: false, ocrSource: 'disabled' as const }
    const indexer = new IndexerService(database, new ContentExtractor(), new EmbeddingService(database), new AppLogger())
    expect(await indexer.indexFile(record, settings)).toBe(true)
    const indexed = database.getFile(record.id)!
    const originalHash = indexed.contentHash
    expect(database.listDocumentChunks(record.id).length).toBeGreaterThan(1)
    await database.updateFile(record.id, { note: 'Priority customer document' })
    expect(await indexer.updateNoteIndex(database.getFile(record.id)!, settings)).toBe(true)
    expect(database.listDocumentChunks(record.id)[0]).toMatchObject({ kind: 'note' })
    expect(database.getFile(record.id)?.contentHash).toBe(originalHash)
  })
})

describe('library query behavior', () => {
  it('parses relative and explicit year date intent deterministically', () => {
    const now = new Date('2026-07-16T12:00:00')
    const trailing = parseDateIntent('files from last 7 days', now)?.from
    expect(trailing && [trailing.getFullYear(), trailing.getMonth() + 1, trailing.getDate()]).toEqual([2026, 7, 10])
    expect(parseDateIntent('contracts from 2024', now)?.to.toISOString().slice(0, 10)).toBe('2024-12-31')
    const currentMonth = parseDateIntent('\u672c\u6708\u7684\u6587\u4ef6', now)?.from
    expect(currentMonth && [currentMonth.getFullYear(), currentMonth.getMonth() + 1, currentMonth.getDate()]).toEqual([2026, 7, 1])
  })

  it('merges lexical and semantic matches, filters categories, sorts, and pages', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const source = join(testRoot, 'Downloads', 'searchable-roadmap.txt')
    await writeFile(source, 'Product roadmap\nThe launch milestone is scheduled for September.', 'utf8')
    const record = await addFile(database, source)
    const settings = { ...database.getSettings(), embeddingSource: 'local' as const, doclingEnabled: false, ocrSource: 'disabled' as const }
    const embeddings = new EmbeddingService(database)
    const indexer = new IndexerService(database, new ContentExtractor(), embeddings, new AppLogger())
    await indexer.indexFile(record, settings)
    const service = new LibrarySearchService(database, embeddings, new AppLogger())
    const response = await service.search({ query: 'September launch milestone', category: 'documents', sortField: 'relevance', offset: 0, limit: 1 }, settings)
    expect(response.total).toBeGreaterThan(0)
    expect(response.results).toHaveLength(1)
    expect(response.results[0].file.id).toBe(record.id)
    expect(['content', 'semantic']).toContain(response.results[0].matchKind)
    expect(response.results[0].confidence).toBeGreaterThanOrEqual(0)
    expect(response.results[0].confidence).toBeLessThanOrEqual(1)
  })

  it('runs explicit Smart Search with a deterministic fallback when generation is disabled', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const source = join(testRoot, 'Downloads', 'smart-search-invoice.txt')
    await writeFile(source, 'Invoice INV-2026-77 for the July service period.', 'utf8')
    await addFile(database, source)
    const service = new LibrarySearchService(database, new EmbeddingService(database), new AppLogger())
    const response = await service.search({ query: 'recent invoice INV-2026-77', smart: true }, { ...database.getSettings(), llmChoice: 'none' })
    expect(response.usedAi).toBe(false)
    expect(response.intent).toContain('INV-2026-77')
    expect(response.results[0].confidence).toBeGreaterThan(0)
  })
})

describe('safe organization and chat persistence', () => {
  it('refuses to move a file that changed after indexing', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const source = join(testRoot, 'Downloads', 'mutation-guard.md')
    await writeFile(source, 'Original indexed content', 'utf8')
    const record = await addFile(database, source, 'md')
    const settings = { ...database.getSettings(), organizedRoot: join(testRoot, 'Organized'), embeddingSource: 'local' as const, doclingEnabled: false, ocrSource: 'disabled' as const }
    const indexer = new IndexerService(database, new ContentExtractor(), new EmbeddingService(database), new AppLogger())
    await indexer.indexFile(record, settings)
    await database.createRule({ name: 'Mutation guard', type: 'rule', pattern: 'mutation-guard', targetFolder: 'Documents/Checks', priority: 1_000, enabled: true, action: 'organize' })
    await writeFile(source, 'Changed after indexing', 'utf8')
    const organizer = new OrganizerService(database, new AppLogger())
    await expect(organizer.organize(database.getFile(record.id)!, settings)).rejects.toMatchObject({ code: 'source-changed' } satisfies Partial<OrganizationError>)
    expect((await stat(source)).isFile()).toBe(true)
  })

  it('retries by replacing the assistant response and records response metrics', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const source = join(testRoot, 'Downloads', 'retry-source.txt')
    await writeFile(source, 'The retry source contains a local answer.', 'utf8')
    const file = await addFile(database, source)
    const settings = { ...database.getSettings(), llmChoice: 'none' as const, ragResultLimit: 4 }
    const service = new ChatService(database, new EmbeddingService(database), new LlmService(), new AppLogger())
    const first = await sendAndWait(service, { sessionId: null, content: 'Find the local answer', attachedFilePath: file.path }, settings)
    expect(first.type).toBe('done')
    const sessionId = first.sessionId!
    const assistant = first.message!
    expect(database.listMessages(sessionId)).toHaveLength(2)
    expect(assistant.totalResponseDuration).not.toBeNull()
    const retried = await sendAndWait(service, { sessionId, content: 'Find the local answer', attachedFilePath: file.path, retryAssistantMessageId: assistant.id }, settings)
    expect(retried.message?.id).toBe(assistant.id)
    expect(database.listMessages(sessionId)).toHaveLength(2)
    expect((await database.statistics()).totalTokens).toBeGreaterThan(0)
  })

  it('publishes planning intent before chat retrieval', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const source = join(testRoot, 'Downloads', 'planning-source.txt')
    await writeFile(source, 'Quarterly planning notes for the product launch.', 'utf8')
    await addFile(database, source)
    const service = new ChatService(database, new EmbeddingService(database), new LlmService(), new AppLogger())
    const events: ChatStreamEvent[] = []
    await new Promise<void>((resolve) => {
      service.send({ sessionId: null, content: 'find quarterly planning notes' }, { ...database.getSettings(), llmChoice: 'none' }, (event) => {
        events.push(event)
        if (event.type === 'done' || event.type === 'error') resolve()
      })
    })
    expect(events.some((event) => event.stage === 'planning')).toBe(true)
    expect(events.find((event) => event.stage === 'searching')?.searchIntent).toContain('quarterly planning notes')
  })

  it('persists watched-directory baselines across database reloads', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const root = join(testRoot, 'Downloads')
    const existing = join(root, 'pre-existing.pdf')
    await database.replaceWatchDirectoryBaseline(root, [existing])
    expect(database.isWatchDirectoryBaselineEntry(root, existing)).toBe(true)
    const reopened = new FileNestDatabase()
    await reopened.initialize()
    expect(reopened.isWatchDirectoryBaselineEntry(root, existing)).toBe(true)
    await reopened.clearWatchDirectoryBaselines([root])
    expect(reopened.isWatchDirectoryBaselineEntry(root, existing)).toBe(false)
  })

  it('reconciles a new file that arrived while watching was stopped', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const root = join(testRoot, 'OfflineArrival')
    await mkdir(root, { recursive: true })
    const path = join(root, 'arrived-while-offline.txt')
    await writeFile(path, 'This file arrived while FileNest was not running.', 'utf8')
    const settings = {
      ...database.getSettings(),
      watchDirs: [root],
      autoOrganize: false,
      embeddingSource: 'local' as const,
      doclingEnabled: false,
      ocrSource: 'disabled' as const
    }
    const logger = new AppLogger()
    const indexer = new IndexerService(database, new ContentExtractor(), new EmbeddingService(database), logger)
    const watcher = new FileWatcherService(database, indexer, new OrganizerService(database, logger), logger)
    await watcher.start(settings)
    expect(database.getFileByPath(path)?.indexedAt).not.toBeNull()
    await watcher.stop()
  })

  it('reconciles the organized library without rewriting stable rows', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const root = join(testRoot, 'ManagedLibrary')
    await mkdir(join(root, 'Documents', 'Stable'), { recursive: true })
    const path = join(root, 'Documents', 'Stable', 'unchanged.txt')
    await writeFile(path, 'stable managed content', 'utf8')
    const record = await addFile(database, path)
    await database.updateFile(record.id, { organizedAt: new Date().toISOString(), organizationSubfolder: 'Documents/Stable' })
    const settings = { ...database.getSettings(), organizedRoot: root, embeddingSource: 'local' as const, doclingEnabled: false, ocrSource: 'disabled' as const }
    const logger = new AppLogger()
    const indexer = new IndexerService(database, new ContentExtractor(), new EmbeddingService(database), logger)
    await indexer.indexFile(database.getFile(record.id)!, settings)
    const watcher = new FileWatcherService(database, indexer, new OrganizerService(database, logger), logger)
    const update = vi.spyOn(database, 'updateFile')

    await watcher.reconcileOrganizedLibrary(settings)

    expect(update).not.toHaveBeenCalled()
    await writeFile(path, 'changed managed content with a different size', 'utf8')
    await watcher.reconcileOrganizedLibrary(settings)
    expect(update).toHaveBeenCalledTimes(1)
    expect(database.getFile(record.id)?.contentText).toContain('changed managed content')
  })
})

async function addFile(database: FileNestDatabase, path: string, extension = 'txt'): Promise<FileRecord> {
  const info = await stat(path)
  return database.upsertFile({
    path,
    name: path.split('/').at(-1)!,
    ext: extension,
    size: info.size,
    mtime: info.mtime.toISOString(),
    category: 'documents',
    sourceDir: join(testRoot, 'Downloads'),
    indexedAt: null,
    contentHash: null,
    title: null,
    contentText: null,
    discoveredAt: new Date().toISOString(),
    organizedAt: null,
    note: null,
    organizationSubfolder: null,
    isDirectory: false,
    indexSignature: null
  })
}

function sendAndWait(service: ChatService, request: Parameters<ChatService['send']>[0], settings: Settings): Promise<ChatStreamEvent> {
  return new Promise((resolve, reject) => {
    service.send(request, settings, (event) => {
      if (event.type === 'done') resolve(event)
      if (event.type === 'error') reject(new Error(event.error))
    })
  })
}
