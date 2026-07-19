import { createHash } from 'node:crypto'
import type { Settings } from '../shared/types'
import { FileNestDatabase } from './database'

export const OLLAMA_EMBEDDING_CONTEXT_LENGTH = 32_000

export interface SearchHit {
  fileId: number
  score: number
  chunkText: string
  chunkIndex: number
}

export class EmbeddingService {
  constructor(private readonly database: FileNestDatabase) {}

  signature(settings: Settings): string {
    const source = settings.embeddingSource
    const model = source === 'local' ? 'filenest-local-384-v1' : source === 'ollama' ? settings.ollamaEmbeddingModel : settings.cloudEmbeddingModel
    return createHash('sha256').update([source, model].join('|')).digest('hex')
  }

  modelName(settings: Settings): string {
    if (settings.embeddingSource === 'ollama') return `ollama:${settings.ollamaEmbeddingModel}`
    if (settings.embeddingSource === 'cloud') return `cloud:${settings.cloudEmbeddingModel}`
    return 'local:filenest-multilingual-hash-384-v1'
  }

  async embed(text: string, settings: Settings): Promise<Float32Array> {
    if (settings.embeddingSource === 'ollama') return this.ollamaEmbed(text, settings)
    if (settings.embeddingSource === 'cloud') return this.cloudEmbed(text, settings)
    return localEmbedding(text)
  }

  async embedBatch(texts: string[], settings: Settings): Promise<Float32Array[]> {
    if (settings.embeddingSource === 'ollama') {
      const url = new URL('/api/embed', normalizeBase(settings.ollamaHost))
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ model: settings.ollamaEmbeddingModel, input: texts, truncate: true, options: { num_ctx: OLLAMA_EMBEDDING_CONTEXT_LENGTH } })
      })
      if (response.ok) {
        const payload = await response.json() as { embeddings?: number[][] }
        if (payload.embeddings?.length === texts.length) return payload.embeddings.map(normalizeVector)
      }
    }
    if (settings.embeddingSource === 'cloud') {
      const key = settings.cloudEmbeddingReuseChatCredentials ? settings.cloudApiKey : settings.cloudEmbeddingApiKey
      const base = settings.cloudEmbeddingReuseChatCredentials ? settings.cloudBaseUrl : settings.cloudEmbeddingBaseUrl
      const response = await fetch(new URL('embeddings', normalizeApiBase(base)), {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` },
        body: JSON.stringify({ model: settings.cloudEmbeddingModel, input: texts })
      })
      if (!response.ok) throw new Error(`Embedding API ${response.status}: ${await response.text()}`)
      const payload = await response.json() as { data?: Array<{ embedding: number[]; index: number }> }
      if (!payload.data) throw new Error('The embedding API returned no vector')
      return payload.data.sort((a, b) => a.index - b.index).map((item) => normalizeVector(item.embedding))
    }
    return texts.map((text) => localEmbedding(text))
  }

  async search(query: string, settings: Settings, k = 8, fileId?: number): Promise<SearchHit[]> {
    const queryVector = await this.embed(query, settings)
    return this.database.listEmbeddings(fileId)
      .filter((row) => row.vector.length === queryVector.length)
      .map((row) => ({ fileId: row.fileId, score: cosine(queryVector, row.vector), chunkText: row.chunkText, chunkIndex: row.chunkIndex }))
      .sort((a, b) => b.score - a.score)
      .slice(0, k)
  }

  private async ollamaEmbed(text: string, settings: Settings): Promise<Float32Array> {
    const response = await fetch(new URL('/api/embed', normalizeBase(settings.ollamaHost)), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: settings.ollamaEmbeddingModel, input: text, truncate: true, options: { num_ctx: OLLAMA_EMBEDDING_CONTEXT_LENGTH } })
    })
    if (!response.ok) throw new Error(`Ollama Embedding ${response.status}: ${await response.text()}`)
    const payload = await response.json() as { embeddings?: number[][] }
    const vector = payload.embeddings?.[0]
    if (!vector?.length) throw new Error('Ollama returned no embedding')
    return normalizeVector(vector)
  }

  private async cloudEmbed(text: string, settings: Settings): Promise<Float32Array> {
    const [result] = await this.embedBatch([text], settings)
    return result
  }
}

export function localEmbedding(text: string, dimension = 384): Float32Array {
  const vector = new Float32Array(dimension)
  const normalized = text.normalize('NFKC').toLowerCase().replace(/\s+/g, ' ').trim()
  const words = normalized.match(/[\p{L}\p{N}_-]+/gu) ?? []
  const chinese = [...normalized.replace(/[^\p{Script=Han}]/gu, '')]
  const tokens = [...words]
  for (let i = 0; i < chinese.length; i += 1) {
    tokens.push(chinese[i])
    if (i + 1 < chinese.length) tokens.push(chinese[i] + chinese[i + 1])
    if (i + 2 < chinese.length) tokens.push(chinese[i] + chinese[i + 1] + chinese[i + 2])
  }
  for (const token of tokens) {
    const hash = fnv1a(token)
    const index = hash % dimension
    vector[index] += (hash & 1) === 0 ? 1 : -1
    if (token.length > 3) vector[(hash >>> 9) % dimension] += 0.5
  }
  return normalizeVector(vector)
}

function fnv1a(value: string): number {
  let hash = 0x811c9dc5
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index)
    hash = Math.imul(hash, 0x01000193)
  }
  return hash >>> 0
}

function normalizeVector(values: ArrayLike<number>): Float32Array {
  const vector = Float32Array.from(values)
  let magnitude = 0
  for (const value of vector) magnitude += value * value
  magnitude = Math.sqrt(magnitude)
  if (!Number.isFinite(magnitude) || magnitude === 0) return vector
  for (let index = 0; index < vector.length; index += 1) vector[index] /= magnitude
  return vector
}

function cosine(left: Float32Array, right: Float32Array): number {
  let sum = 0
  for (let index = 0; index < left.length; index += 1) sum += left[index] * right[index]
  return sum
}

function normalizeBase(value: string): string {
  const normalized = value.trim().replace(/\/+$/, '')
  if (!/^https?:\/\//i.test(normalized)) throw new Error('The service endpoint must be an HTTP or HTTPS URL')
  return `${normalized}/`
}

function normalizeApiBase(value: string): string {
  return normalizeBase(value).replace(/\/+$/, '') + '/'
}
