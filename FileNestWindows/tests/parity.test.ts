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
import { ChatService, contextWindowForSettings, planChatHistory, validateCitations } from '../src/main/chat'
import { FileNestDatabase } from '../src/main/database'
import { EmbeddingService } from '../src/main/embedding'
import { buildDocumentChunks, extractEntityTerms, IndexerService, recommendedFileConcurrency } from '../src/main/indexer'
import { applyDisplayConfidencePolicy, LibrarySearchService, parseDateIntent } from '../src/main/library-search'
import { AppLogger } from '../src/main/logger'
import { ContentExtractor, walkDirectory } from '../src/main/content-extractor'
import { OrganizerService, OrganizationError } from '../src/main/organizer'
import { LlmService } from '../src/main/llm'
import { estimateCanonicalTokens } from '../src/main/token-counter'
import { FileWatcherService } from '../src/main/watcher'
import { createDefaultSettings, MEDIA_TRANSCRIPTION_EXTENSIONS } from '../src/main/defaults'
import { fallbackSmartSearchPlan, matchesSmartSearchPlan, resolveSmartSearchPlan, streamedSearchIntent } from '../src/main/smart-search-plan'
import { rerankerEndpoint, weightedReciprocalRankFusion } from '../src/main/reranker'
import { isLocalOllamaHost, requiresOllamaService } from '../src/main/ollama'
import { buildTranscriptChunks, normalizeWhisperModel } from '../src/main/media-transcription'
import { duplicateGroups } from '../src/main/duplicate-files'

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
    expect(settings.vectorRetrievalChunkTokens).toBe(300)
    expect(settings.rerankerSource).toBe('disabled')
    expect(settings.mediaTranscriptionEnabled).toBe(false)
    expect(settings.whisperModel).toBe('base')
  })

  it('starts Ollama only when an active provider requires a local service', () => {
    expect(requiresOllamaService({ llmChoice: 'ollama', embeddingSource: 'local' })).toBe(true)
    expect(requiresOllamaService({ llmChoice: 'cloud', embeddingSource: 'ollama' })).toBe(true)
    expect(requiresOllamaService({ llmChoice: 'cloud', embeddingSource: 'cloud' })).toBe(false)
    expect(isLocalOllamaHost('http://127.0.0.1:11434')).toBe(true)
    expect(isLocalOllamaHost('http://[::1]:11434')).toBe(true)
    expect(isLocalOllamaHost('https://ollama.example.com')).toBe(false)
    expect(isLocalOllamaHost('not a URL')).toBe(false)
  })

  it('extracts a complete intent from a streamed smart-search plan', () => {
    expect(streamedSearchIntent('{"intent":"Find recent invoices","semantic_query":"invoice')).toBe('Find recent invoices')
    expect(streamedSearchIntent('{"intent":"incomplete')).toBeNull()
  })

  it('applies the complete macOS structured Smart Search schema', async () => {
    const llm = {
      async *stream(): AsyncGenerator<string> {
        yield '{"intent":"Find the exact indexed invoice","semantic_query":"service invoice","keywords":["INV-77"],"exact_name":"INV-77.pdf","file_extensions":["pdf"],"categories":["documents"],"folder_terms":["Finance"],"item_kind":"file","date_field":"added","date_from":"2026-07-01","date_to":"2026-07-31","size_min_bytes":100,"size_max_bytes":5000,"has_note":true,"is_indexed":true,"sort":"largest"}'
      }
    } as unknown as LlmService
    const plan = await resolveSmartSearchPlan('find the invoice', { ...createDefaultSettings(), llmChoice: 'cloud' }, llm, new AbortController().signal)
    const file = {
      id: 1, path: 'C:\\Finance\\INV-77.pdf', name: 'INV-77.pdf', ext: 'pdf', size: 1_000,
      mtime: '2026-06-01T00:00:00.000Z', category: 'documents', sourceDir: 'C:\\Finance',
      indexedAt: '2026-07-03T00:00:00.000Z', contentHash: 'hash', title: null, contentText: null,
      discoveredAt: '2026-07-02T00:00:00.000Z', organizedAt: null, note: 'Approved',
      organizationSubfolder: 'Finance', isDirectory: false, indexSignature: 'signature'
    } satisfies FileRecord
    expect(plan).toMatchObject({ exactName: 'INV-77.pdf', fileExtensions: ['pdf'], dateField: 'added', sort: 'largest', usedAi: true })
    expect(matchesSmartSearchPlan(file, plan)).toBe(true)
    expect(matchesSmartSearchPlan({ ...file, size: 9_000 }, plan)).toBe(false)
  })
  it('normalizes the same user-controlled limits as macOS', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const current = database.getSettings()
    expect(normalizeSettingsPatch({ ragResultLimit: 99 }, current).ragResultLimit).toBe(30)
    expect(normalizeSettingsPatch({ ragResultLimit: -2 }, current).ragResultLimit).toBe(1)
    expect(normalizeSettingsPatch({ cloudContextWindowTokens: 12 }, current).cloudContextWindowTokens).toBe(4_096)
    expect(normalizeSettingsPatch({ cloudContextWindowTokens: 0 }, current).cloudContextWindowTokens).toBe(0)
    expect(normalizeSettingsPatch({ vectorChunkWords: 12, vectorChunkOverlap: 9_000 }, current)).toMatchObject({ vectorChunkWords: 600, vectorChunkOverlap: 299 })
    expect(normalizeSettingsPatch({ vectorRetrievalChunkTokens: 10, vectorChunkOverlap: 500 }, current)).toMatchObject({ vectorRetrievalChunkTokens: 120, vectorChunkOverlap: 119 })
    expect(normalizeSettingsPatch({ mediaTranscriptionEnabled: true }, current).enabledExtensions).toEqual(expect.arrayContaining(MEDIA_TRANSCRIPTION_EXTENSIONS))
    expect(normalizeSettingsPatch({ whisperModel: 'unknown' }, current).whisperModel).toBe('base')
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
  it('links byte-identical files to the indexed original without duplicate vectors', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const firstPath = join(testRoot, 'Downloads', 'duplicate-original.txt')
    const secondPath = join(testRoot, 'Downloads', 'duplicate-copy.txt')
    await writeFile(firstPath, 'identical duplicate bytes', 'utf8')
    await writeFile(secondPath, 'identical duplicate bytes', 'utf8')
    const first = await addFile(database, firstPath)
    const second = await addFile(database, secondPath)
    const settings = { ...database.getSettings(), embeddingSource: 'local' as const, doclingEnabled: false, ocrSource: 'disabled' as const }
    const indexer = new IndexerService(database, new ContentExtractor(), new EmbeddingService(database), new AppLogger())
    expect(await indexer.indexFile(first, settings)).toBe(true)
    expect(await indexer.indexFile(second, settings)).toBe(true)
    const linked = database.getFile(second.id)!
    expect(linked.duplicateOfFileId).toBe(first.id)
    expect(linked.indexedAt).toBeNull()
    expect(database.listDocumentChunks(second.id)).toHaveLength(0)
    const groups = duplicateGroups(database.listFiles())
    expect(groups[0].retainedFile.id).toBe(first.id)
    expect(groups[0].duplicateFiles.map((file) => file.id)).toContain(second.id)
  })

  it('stops directory inspection when the configured entry budget is exceeded', async () => {
    const root = join(testRoot, 'directory-budget')
    await mkdir(root, { recursive: true })
    await Promise.all(['a.txt', 'b.txt', 'c.txt'].map((name) => writeFile(join(root, name), name, 'utf8')))
    expect(await walkDirectory(root, { maximumEntries: 2, maximumDurationMs: 1_000 })).toBeNull()
    expect(await walkDirectory(root, { maximumEntries: 10, maximumDurationMs: 1_000 })).toHaveLength(3)
  })
  it('creates time-coded Whisper transcript chunks for the shared RAG pipeline', () => {
    const chunks = buildTranscriptChunks({
      text: 'Hello and welcome to the project update.',
      language: 'en',
      segments: [
        { start: 0, end: 12.4, text: 'Hello and welcome.' },
        { start: 12.4, end: 75.2, text: 'This is the project update for INV-2026-18.' }
      ]
    }, 120)
    expect(chunks[0]).toMatchObject({ kind: 'transcript', sectionPath: ['Transcript', '00:00–01:15'] })
    expect(chunks[0].text).toContain('[00:00–01:15]')
    expect(chunks[0].entityTerms).toContain('inv-2026-18')
    expect(normalizeWhisperModel('SMALL')).toBe('small')
    expect(normalizeWhisperModel('unsupported')).toBe('base')
  })

  it('uses conservative adaptive file concurrency for local heavy processing', () => {
    const base = { embeddingSource: 'cloud', doclingEnabled: false, ocrSource: 'disabled', mediaTranscriptionEnabled: false } as const
    expect(recommendedFileConcurrency(8 * 1024 ** 3, base)).toBe(1)
    expect(recommendedFileConcurrency(64 * 1024 ** 3, { ...base, doclingEnabled: true })).toBe(2)
    expect(recommendedFileConcurrency(64 * 1024 ** 3, base)).toBe(3)
  })
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

  it('creates retrieval children that retain complete parents and exact entities', () => {
    const sentence = 'Invoice INV-2026-7788 was issued to billing@example.com on 2026-07-17 for SGD 4,280. '
    const body = Array.from({ length: 70 }, (_, index) => `${sentence}Line ${index + 1} remains complete.`).join(' ')
    const chunks = buildDocumentChunks('Invoice Register', null, body, 600, 40, 120)
    const children = chunks.filter((chunk) => chunk.kind === 'text')
    expect(children.length).toBeGreaterThan(1)
    expect(new Set(children.map((chunk) => chunk.parentIndex)).size).toBeLessThan(children.length)
    expect(children.every((chunk) => chunk.parentText.length >= chunk.text.length)).toBe(true)
    expect(children.some((chunk) => chunk.entityTerms.includes('inv-2026-7788'))).toBe(true)
    expect(extractEntityTerms(sentence)).toEqual(expect.arrayContaining(['billing@example.com', '2026-07-17', 'sgd 4,280.']))
  })

  it('builds compatible reranker endpoints and deterministic weighted fusion', () => {
    expect(rerankerEndpoint('http://127.0.0.1:11435/v1').toString()).toBe('http://127.0.0.1:11435/v1/rerank')
    expect(rerankerEndpoint('https://example.test/custom').toString()).toBe('https://example.test/custom/v1/rerank')
    const scores = weightedReciprocalRankFusion([
      { weight: 0.36, ids: [1, 2] },
      { weight: 0.44, ids: [2, 1] },
      { weight: 0.20, ids: [2] }
    ])
    expect(scores.get(2)).toBeGreaterThan(scores.get(1)!)
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
    expect(database.documentChunkCount(record.id)).toBe(database.listDocumentChunks(record.id).length)
    expect(database.listDocumentChunks(record.id, 1, 1)).toHaveLength(1)
    await database.updateFile(record.id, { note: 'Priority customer document' })
    expect(await indexer.updateNoteIndex(database.getFile(record.id)!, settings)).toBe(true)
    expect(database.listDocumentChunks(record.id)[0]).toMatchObject({ kind: 'note' })
    expect(database.getFile(record.id)?.contentHash).toBe(originalHash)
  })
})

describe('library query behavior', () => {
  it('preserves lexical boundaries in mixed CamelCase and Chinese searches', () => {
    const plan = fallbackSmartSearchPlan('LumensAI视频')
    expect(plan.keywords).toEqual(expect.arrayContaining(['lumens', 'ai', '视频']))
    expect(plan.categories).toContain('videos')
  })
  it('parses relative and explicit year date intent deterministically', () => {
    const now = new Date('2026-07-16T12:00:00')
    const trailing = parseDateIntent('files from last 7 days', now)?.from
    expect(trailing && [trailing.getFullYear(), trailing.getMonth() + 1, trailing.getDate()]).toEqual([2026, 7, 10])
    expect(parseDateIntent('contracts from 2024', now)?.to.toISOString().slice(0, 10)).toBe('2024-12-31')
    const currentMonth = parseDateIntent('\u672c\u6708\u7684\u6587\u4ef6', now)?.from
    expect(currentMonth && [currentMonth.getFullYear(), currentMonth.getMonth() + 1, currentMonth.getDate()]).toEqual([2026, 7, 1])
  })

  it('keeps global Quick Search responsive by skipping semantic retrieval', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const source = join(testRoot, 'Downloads', 'LumensAI-roadmap.txt')
    await writeFile(source, 'A local roadmap for the Lumens AI project.', 'utf8')
    await addFile(database, source)
    const embeddings = new EmbeddingService(database)
    const semanticSearch = vi.spyOn(embeddings, 'search')
    const service = new LibrarySearchService(database, embeddings, new AppLogger())
    const response = await service.search({ query: 'LumensAI', includeSemantic: false }, database.getSettings())
    expect(response.results[0].file.name).toBe('LumensAI-roadmap.txt')
    expect(semanticSearch).not.toHaveBeenCalled()
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
    expect(['content', 'semantic', 'hybrid']).toContain(response.results[0].matchKind)
    expect(response.results[0].confidence).toBeGreaterThanOrEqual(0)
    expect(response.results[0].confidence).toBeLessThanOrEqual(1)
    expect(database.listRAGSearchTraces(1)[0]).toMatchObject({ query: 'September launch milestone', returnedResults: 1 })
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
  it('persists assistant feedback locally', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const session = await database.createChat()
    const message = await database.addMessage(session.id, 'assistant', 'A locally generated answer')
    await database.updateChatMessageFeedback(message.id, 'helpful')
    expect(database.listMessages(session.id)[0].feedback).toBe('helpful')
    await database.updateChatMessageFeedback(message.id, null)
    expect(database.listMessages(session.id)[0].feedback).toBeNull()
  })

  it('pages chat history newest-first internally while returning chronological messages', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const session = await database.createChat()
    for (let index = 0; index < 45; index += 1) await database.addMessage(session.id, 'user', `message-${index}`)
    const latest = database.chatMessagePage(session.id, null, 40)
    expect(latest.messages[0].content).toBe('message-5')
    expect(latest.messages.at(-1)?.content).toBe('message-44')
    expect(latest.hasEarlier).toBe(true)
    const earlier = database.chatMessagePage(session.id, latest.messages[0].id, 40)
    expect(earlier.messages.map((message) => message.content)).toEqual(['message-0', 'message-1', 'message-2', 'message-3', 'message-4'])
    expect(earlier.hasEarlier).toBe(false)
  })

  it('keeps confident search results and uses weak results only to reach three', () => {
    const file = { id: 1, name: 'result.txt', path: 'C:\\result.txt' } as FileRecord
    const result = (id: number, confidence: number) => ({ file: { ...file, id }, score: confidence, confidence, matchKind: 'content' as const, snippet: null, chunkIndex: null })
    expect(applyDisplayConfidencePolicy([result(1, .9), result(2, .8), result(3, .7), result(4, .2)]).map((item) => item.file.id)).toEqual([1, 2, 3])
    expect(applyDisplayConfidencePolicy([result(1, .9), result(2, .4), result(3, .3), result(4, .2)]).map((item) => item.file.id)).toEqual([1, 2, 3])
  })
  it('removes model-invented citations while retaining stable evidence IDs', () => {
    const related = [{
      file: { id: 7 } as FileRecord,
      chunks: [{ parentIndex: 2 } as ReturnType<FileNestDatabase['listDocumentChunks']>[number]]
    }]
    expect(validateCitations('Supported [F1:P3] metadata [F1]. Invalid [F1:P9] [F2].', related)).toBe('Supported [F1:P3] metadata [F1]. Invalid  .')
  })
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

  it('organizes selected folders recursively while skipping source-control repositories', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const root = join(testRoot, 'OneTimeOrganization')
    const nested = join(root, 'Nested')
    const repository = join(root, 'Repository')
    await mkdir(nested, { recursive: true })
    await mkdir(join(repository, '.git'), { recursive: true })
    const selectedFile = join(nested, 'selected-note.txt')
    const repositoryFile = join(repository, 'tracked-note.txt')
    await writeFile(selectedFile, 'Selected folder organization content.', 'utf8')
    await writeFile(repositoryFile, 'Repository content must stay in place.', 'utf8')
    const settings = {
      ...database.getSettings(), organizedRoot: join(testRoot, 'OneTimeOrganized'), llmChoice: 'none' as const,
      embeddingSource: 'local' as const, doclingEnabled: false, ocrSource: 'disabled' as const, autoOrganize: true
    }
    const logger = new AppLogger()
    const watcher = new FileWatcherService(database, new IndexerService(database, new ContentExtractor(), new EmbeddingService(database), logger), new OrganizerService(database, logger), logger)
    await watcher.organizeDirectoriesOnce(settings, [root], true)
    expect(database.listFiles().some((file) => file.name === 'selected-note.txt' && file.organizedAt != null)).toBe(true)
    expect((await stat(repositoryFile)).isFile()).toBe(true)
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
