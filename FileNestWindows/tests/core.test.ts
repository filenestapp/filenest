import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest'
import { mkdtemp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'

const testRoot = await mkdtemp(join(tmpdir(), 'filenest-windows-tests-'))

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

import { categoryForExtension, matchesPattern, shouldIgnore } from '../src/main/file-policy'
import { localEmbedding } from '../src/main/embedding'
import { chunkText, IndexerService } from '../src/main/indexer'
import { FileNestDatabase } from '../src/main/database'
import { ContentExtractor } from '../src/main/content-extractor'
import { EmbeddingService } from '../src/main/embedding'
import { OrganizerService } from '../src/main/organizer'
import { AppLogger } from '../src/main/logger'
import { LlmService } from '../src/main/llm'
import { planChatHistory } from '../src/main/chat'

beforeAll(async () => {
  await mkdir(join(testRoot, 'Downloads'), { recursive: true })
  await mkdir(join(testRoot, 'Documents'), { recursive: true })
})

afterAll(async () => rm(testRoot, { recursive: true, force: true }))

describe('file policy', () => {
  it('matches the macOS category and rule semantics', () => {
    expect(categoryForExtension('DOCX')).toBe('documents')
    expect(categoryForExtension('tsx')).toBe('code')
    expect(categoryForExtension('7z')).toBe('archives')
    expect(matchesPattern('Invoice July.PDF', 'pdf', '*.pdf')).toBe(true)
    expect(matchesPattern('Invoice July.PDF', 'pdf', 'invoice')).toBe(true)
    expect(matchesPattern('photo.png', 'png', '*.pdf;*.docx')).toBe(false)
  })

  it('ignores hidden and partial downloads', () => {
    const settings = { excludeHidden: true, enabledExtensions: ['pdf'] } as never
    expect(shouldIgnore('/tmp/.secret.pdf', false, settings)).toBe(true)
    expect(shouldIgnore('/tmp/file.crdownload', false, settings)).toBe(true)
    expect(shouldIgnore('/tmp/file.pdf', false, settings)).toBe(false)
  })
})

describe('local vector index', () => {
  it('is deterministic, finite and normalized', () => {
    const first = localEmbedding('the final contract downloaded last week')
    const second = localEmbedding('the final contract downloaded last week')
    expect([...first]).toEqual([...second])
    expect(first).toHaveLength(384)
    expect([...first].every(Number.isFinite)).toBe(true)
    const magnitude = Math.sqrt([...first].reduce((sum, value) => sum + value * value, 0))
    expect(magnitude).toBeCloseTo(1, 5)
  })

  it('chunks Chinese and English text with overlap', () => {
    const chunks = chunkText('product requirements document contract '.repeat(120), 80, 12)
    expect(chunks.length).toBeGreaterThan(2)
    expect(chunks.every((chunk) => chunk.length > 0)).toBe(true)
  })

  it('compresses old chat turns while preserving recent context', () => {
    const messages = Array.from({ length: 30 }, (_, index) => ({
      id: index + 1,
      sessionId: 1,
      role: index % 2 === 0 ? 'user' as const : 'assistant' as const,
      content: `turn-${index} ${'context '.repeat(120)}`,
      timestamp: new Date().toISOString(),
      relatedFileIds: []
    }))
    const planned = planChatHistory(messages, 1_200)
    expect(planned[0].role).toBe('system')
    expect(planned[0].content).toContain('automatically compressed')
    expect(planned.at(-1)?.content).toContain('turn-29')
  })
})

describe('database, indexing and organization integration', () => {
  it('persists metadata, vectors, chat and moves only after indexing', async () => {
    const database = new FileNestDatabase()
    await database.initialize()
    const source = join(testRoot, 'Downloads', 'contract.txt')
    await writeFile(source, 'Contract Final\nThis is the signed product contract for July.', 'utf8')
    const info = await stat(source)
    const settings = { ...database.getSettings(), organizedRoot: join(testRoot, 'Organized'), watchDirs: [join(testRoot, 'Downloads')], embeddingSource: 'local' as const, doclingEnabled: false, ocrSource: 'disabled' as const }
    const record = await database.upsertFile({ path: source, name: 'contract.txt', ext: 'txt', size: info.size, mtime: info.mtime.toISOString(), category: 'documents', sourceDir: join(testRoot, 'Downloads'), indexedAt: null, contentHash: null, title: null, contentText: null, discoveredAt: new Date().toISOString(), organizedAt: null, note: null, organizationSubfolder: null, isDirectory: false, indexSignature: null })
    const logger = new AppLogger()
    const embedding = new EmbeddingService(database)
    const indexer = new IndexerService(database, new ContentExtractor(), embedding, logger)
    expect(await indexer.indexFile(record, settings)).toBe(true)
    const indexed = database.getFile(record.id)!
    expect(indexed.indexedAt).not.toBeNull()
    expect(indexed.contentText).toContain('signed product contract')
    expect(database.listEmbeddings(record.id).length).toBeGreaterThan(0)
    expect(database.listEmbeddings(record.id)[0].vector.length).toBe(384)
    const hits = await embedding.search('product contract', settings, 5)
    expect(hits[0]?.fileId).toBe(record.id)
    const fakeLlm = { complete: async () => '{"folder":"Contracts"}' } as unknown as LlmService
    const organizer = new OrganizerService(database, logger, fakeLlm)
    const moved = await organizer.organize(indexed, settings)
    expect(moved.path).toContain(join('Organized', 'Documents', 'Contracts'))
    expect(moved.organizationSubfolder).toBe('Documents/Contracts')
    expect(await readFile(moved.path, 'utf8')).toContain('Contract Final')
    const session = await database.createChat(moved.path)
    await database.addMessage(session.id, 'user', 'Summarize the contract')
    const assistant = await database.addMessage(session.id, 'assistant', 'This is a contract summary', [record.id])
    expect(database.listMessages(session.id)).toHaveLength(2)
    expect(assistant.relatedFileIds).toEqual([record.id])
    expect((await database.statistics()).totalFiles).toBeGreaterThan(0)
  })
})
