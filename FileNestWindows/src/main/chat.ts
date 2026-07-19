import { randomUUID } from 'node:crypto'
import type { ChatMessage, ChatRelatedFileMatch, ChatSession, ChatStreamEvent, DocumentChunk, FileRecord, SendChatRequest, Settings } from '../shared/types'
import { FileNestDatabase } from './database'
import { EmbeddingService, type SearchHit } from './embedding'
import { estimateTokens, LlmService, type LlmTurn } from './llm'
import { AppLogger } from './logger'
import { hasStructuredSearchFilters, matchesSmartSearchPlan, resolveSmartSearchPlan, type SmartSearchPlan } from './smart-search-plan'
import { extractEntityTerms } from './indexer'
import { dynamicallyAcceptedSemanticHits, rerankDocuments, rerankerConfiguration, weightedReciprocalRankFusion } from './reranker'
import { prompts } from './prompts'

interface RetrievedFile {
  file: FileRecord
  chunks: DocumentChunk[]
  confidence?: number
}

export class ChatService {
  private controllers = new Map<string, AbortController>()

  constructor(
    private readonly database: FileNestDatabase,
    private readonly embeddings: EmbeddingService,
    private readonly llm: LlmService,
    private readonly logger: AppLogger
  ) {}

  cancel(requestId: string): void { this.controllers.get(requestId)?.abort() }

  send(request: SendChatRequest, settings: Settings, emit: (event: ChatStreamEvent) => void): string {
    const requestId = randomUUID()
    const controller = new AbortController()
    this.controllers.set(requestId, controller)
    void this.run(requestId, request, settings, controller.signal, emit).finally(() => this.controllers.delete(requestId))
    return requestId
  }

  async summarize(file: FileRecord, settings: Settings): Promise<string> {
    const chunks = this.database.listDocumentChunks(file.id)
    const content = (chunks.map((chunk) => chunk.contextualText).join('\n\n') || file.contentText || file.note || file.name).slice(0, 24_000)
    if (settings.llmChoice === 'none') return content.slice(0, 600)
    const parts: string[] = []
    const turns: LlmTurn[] = [
      { role: 'system', content: file.category === 'images' ? prompts.summary.imageSystem : prompts.summary.system },
      { role: 'user', content: `File: ${file.name}\n\n${content}` }
    ]
    const stream = file.category === 'images'
      ? this.llm.streamWithImage(turns, file.path, settings, new AbortController().signal)
      : this.llm.stream(turns, settings, new AbortController().signal)
    for await (const delta of stream) parts.push(delta)
    return parts.join('').trim()
  }

  async generateRules(prompt: string, settings: Settings): Promise<Array<{ name: string; type: 'rule'; pattern: string; targetFolder: string; priority: number; enabled: boolean; action: 'organize' | 'ignore' }>> {
    if (settings.llmChoice === 'none') return heuristicRules(prompt)
    const parts: string[] = []
    for await (const delta of this.llm.stream([
      { role: 'system', content: prompts.rules.system },
      { role: 'user', content: prompt }
    ], settings, new AbortController().signal)) parts.push(delta)
    const match = parts.join('').match(/\[[\s\S]*\]/)
    if (!match) return heuristicRules(prompt)
    const parsed = JSON.parse(match[0]) as Array<Record<string, unknown>>
    return parsed.slice(0, 20).map((item, index) => ({ name: String(item.name ?? `AI Rule ${index + 1}`), type: 'rule', pattern: String(item.pattern ?? ''), targetFolder: sanitizeFolder(String(item.targetFolder ?? 'Other')), priority: Math.max(0, Math.min(1000, Number(item.priority ?? 100 - index))), enabled: true, action: item.action === 'ignore' ? 'ignore' : 'organize' }))
  }

  private async run(requestId: string, request: SendChatRequest, settings: Settings, signal: AbortSignal, emit: (event: ChatStreamEvent) => void): Promise<void> {
    let activeSessionId: number | undefined
    try {
      const startedAt = performance.now()
      const session = await this.ensureSession(request)
      activeSessionId = session.id
      const retryTarget = this.findRetryTarget(session.id, request.retryAssistantMessageId)
      const question = retryTarget?.question ?? request.content.trim()
      if (!question) throw new Error('Enter a question before sending')
      if (!retryTarget) {
        await this.database.addMessage(session.id, 'user', question)
        if (this.database.listMessages(session.id).filter((item) => item.role === 'user').length === 1) {
          await this.database.updateChat(session.id, { title: question.slice(0, 42) || 'New Chat' })
        }
      }
      emit({ requestId, type: 'session', sessionId: session.id })

      let searchPlan: SmartSearchPlan | null = null
      if (!session.attachedFilePath) {
        emit({ requestId, type: 'progress', sessionId: session.id, stage: 'planning' })
        searchPlan = await resolveSmartSearchPlan(question, settings, this.llm, signal, (searchIntent) => {
          emit({ requestId, type: 'progress', sessionId: session.id, stage: 'planning', searchIntent })
        })
        if (signal.aborted) throw new DOMException('Generation stopped', 'AbortError')
      }
      emit({ requestId, type: 'progress', sessionId: session.id, stage: 'searching', searchIntent: searchPlan?.intent })
      const related = await this.retrieve(question, session, settings, searchPlan, () => {
        emit({ requestId, type: 'progress', sessionId: session.id, stage: 'reranking', searchIntent: searchPlan?.intent })
      })
      const relatedFileIds = related.map((item) => item.file.id)
      const relatedFileMatches: ChatRelatedFileMatch[] = related.map((item) => ({ fileId: item.file.id, confidence: item.confidence ?? 0 }))
      emit({ requestId, type: 'progress', sessionId: session.id, stage: 'retrieved', relatedFileIds })
      if (signal.aborted) throw new DOMException('Generation stopped', 'AbortError')

      const history = this.historyForRequest(session.id, retryTarget?.message.id)
      const turns = buildTurns(history, related, settings)
      const provider = this.llm.provider(settings)
      const inputTokens = estimateTokens(turns)
      let content = ''
      let firstResponseAt: number | null = null

      if (settings.llmChoice === 'none') {
        content = retrievalOnlyAnswer(related.map((item) => item.file))
      } else {
        emit({ requestId, type: 'progress', sessionId: session.id, stage: 'generating', relatedFileIds })
        try {
          const image = session.attachedFilePath && related[0]?.file.category === 'images' ? related[0].file : null
          const stream = image ? this.llm.streamWithImage(turns, image.path, settings, signal) : this.llm.stream(turns, settings, signal)
          for await (const delta of stream) {
            if (firstResponseAt == null) firstResponseAt = performance.now()
            content += delta
            emit({ requestId, type: 'delta', sessionId: session.id, delta })
          }
          if (!content.trim()) throw new Error('The model returned no content')
        } catch (error) {
          if (signal.aborted) throw error
          await this.logger.log('chat', 'The language model failed; returning local retrieval results', error)
          content = fallbackAnswer(related.map((item) => item.file), error)
        }
      }

      if (settings.llmChoice !== 'none') {
        emit({ requestId, type: 'progress', sessionId: session.id, stage: 'verifying', relatedFileIds })
        content = validateCitations(content, related)
      }

      const completedAt = performance.now()
      const metrics = {
        inputTokens,
        outputTokens: estimateTokens([{ content }]),
        firstResponseDuration: ((firstResponseAt ?? completedAt) - startedAt) / 1000,
        totalResponseDuration: (completedAt - startedAt) / 1000,
        responseProvider: provider.name,
        responseModel: provider.model
      }
      const message = retryTarget
        ? await this.database.replaceAssistantMessage(retryTarget.message.id, content, relatedFileIds, metrics, relatedFileMatches)
        : await this.database.addMessage(session.id, 'assistant', content, relatedFileIds, metrics, relatedFileMatches)
      await this.database.recordUsage(provider.name, provider.model, inputTokens, metrics.outputTokens, session.id)
      emit({ requestId, type: 'done', sessionId: session.id, message, relatedFileIds })
    } catch (error) {
      if (signal.aborted) {
        emit({ requestId, type: 'error', sessionId: activeSessionId, error: 'Generation stopped' })
      } else {
        await this.logger.log('chat', 'Chat failed', error)
        emit({ requestId, type: 'error', sessionId: activeSessionId, error: error instanceof Error ? error.message : String(error) })
      }
    }
  }

  private findRetryTarget(sessionId: number, messageId?: number | null): { message: ChatMessage; question: string } | null {
    if (messageId == null) return null
    const messages = this.database.listMessages(sessionId)
    const index = messages.findIndex((message) => message.id === messageId && message.role === 'assistant')
    if (index < 0) throw new Error('The response to retry no longer exists')
    const question = messages.slice(0, index).reverse().find((message) => message.role === 'user')?.content
    if (!question) throw new Error('The question for this response no longer exists')
    return { message: messages[index], question }
  }

  private historyForRequest(sessionId: number, retryMessageId?: number): ChatMessage[] {
    const history = this.database.listMessages(sessionId)
    if (retryMessageId == null) return history
    const index = history.findIndex((message) => message.id === retryMessageId)
    return history.slice(0, index)
  }

  private async ensureSession(request: SendChatRequest): Promise<ChatSession> {
    const existing = request.sessionId == null ? null : this.database.listChatSessions().find((item) => item.id === request.sessionId)
    if (existing) {
      if (request.attachedFilePath !== undefined && request.attachedFilePath !== existing.attachedFilePath) {
        await this.database.updateChat(existing.id, { attachedFilePath: request.attachedFilePath })
        return { ...existing, attachedFilePath: request.attachedFilePath ?? null }
      }
      return existing
    }
    return this.database.createChat(request.attachedFilePath ?? null)
  }

  private async retrieve(
    query: string,
    session: ChatSession,
    settings: Settings,
    plan: SmartSearchPlan | null,
    onReranking?: () => void
  ): Promise<RetrievedFile[]> {
    const startedAt = performance.now()
    const limit = Math.max(1, Math.min(30, settings.ragResultLimit))
    if (session.attachedFilePath) {
      const file = this.database.getFileByPath(session.attachedFilePath)
      if (!file) return []
      let hits: SearchHit[] = []
      try { hits = await this.embeddings.search(query, settings, Math.min(limit * 2, 40), file.id) } catch (error) {
        await this.logger.log('chat', 'File semantic search failed; using stored document chunks', error)
      }
      return [{ file, chunks: selectParentChunks(this.database.listDocumentChunks(file.id), hits, limit), confidence: 1 }]
    }

    let semanticHits: SearchHit[] = []
    let semanticThreshold: number | null = null
    try {
      const accepted = dynamicallyAcceptedSemanticHits(await this.embeddings.search(plan?.semanticQuery || query, settings, Math.min(limit * 6, 120)))
      semanticThreshold = accepted.threshold
      semanticHits = accepted.hits
      if (rerankerConfiguration(settings) && semanticHits.length > 1) {
        onReranking?.()
        const candidates = semanticHits.slice(0, 24)
        try {
          const reranked = await rerankDocuments(plan?.semanticQuery || query, candidates.map((hit) => hit.chunkText), settings)
          const scoreByIndex = new Map(reranked.map((item) => [item.index, item.score]))
          const values = candidates.flatMap((hit, index) => scoreByIndex.has(index)
            ? [{ ...hit, score: Math.min(1, Math.max(0, scoreByIndex.get(index)!)) }]
            : [])
          if (values.length) semanticHits = values.sort((left, right) => right.score - left.score)
        } catch (error) {
          await this.logger.log('chat', 'Reranker unavailable; fused retrieval order remains active', error)
        }
      }
    } catch (error) {
      await this.logger.log('chat', 'Semantic search failed; falling back to keyword search', error)
    }
    const candidates = new Map<number, { file: FileRecord; hits: SearchHit[] }>()
    for (const hit of semanticHits) {
      const file = this.database.getFile(hit.fileId)
      if (!file) continue
      if (!matchesPlan(file, plan)) continue
      const existing = candidates.get(file.id) ?? { file, hits: [] }
      existing.hits.push(hit)
      candidates.set(file.id, existing)
    }
    const lexicalIds: number[] = []
    const keywords = [...new Set([...query.split(/[\s，。！？、,.;:]+/), ...(plan?.keywords ?? [])].filter((item) => item.length > 1))]
    for (const keyword of keywords) {
      for (const file of this.database.searchFiles(keyword, null, limit * 2)) {
        if (!matchesPlan(file, plan)) continue
        if (!lexicalIds.includes(file.id)) lexicalIds.push(file.id)
        if (!candidates.has(file.id)) candidates.set(file.id, { file, hits: [] })
      }
    }
    const entityMatches = this.database.entityChunkMatches(extractEntityTerms(query), Math.max(20, Math.min(limit * 2, 60)))
      .filter((match) => {
        const file = this.database.getFile(match.fileId)
        return file != null && matchesPlan(file, plan)
      })
    const entityIds: number[] = []
    for (const match of entityMatches) {
      const file = this.database.getFile(match.fileId)!
      if (!entityIds.includes(file.id)) entityIds.push(file.id)
      const existing = candidates.get(file.id) ?? { file, hits: [] }
      existing.hits.push({ fileId: file.id, chunkIndex: match.chunkIndex, chunkText: match.chunk.contextualText, score: 1 })
      candidates.set(file.id, existing)
    }
    if (hasStructuredSearchFilters(plan)) {
      for (const file of this.database.listFiles()) {
        if (matchesPlan(file, plan) && !candidates.has(file.id)) candidates.set(file.id, { file, hits: [] })
      }
    }
    const semanticIds = [...new Set(semanticHits.map((hit) => hit.fileId))]
    const fused = weightedReciprocalRankFusion([
      { weight: 0.36, ids: lexicalIds },
      { weight: 0.44, ids: semanticIds },
      { weight: 0.20, ids: entityIds }
    ])
    const selected = [...candidates.values()]
      .sort((left, right) => (fused.get(right.file.id) ?? 0) - (fused.get(left.file.id) ?? 0) || left.file.name.localeCompare(right.file.name))
      .slice(0, limit)
      .map(({ file, hits: fileHits }) => ({
        file,
        chunks: selectParentChunks(this.database.listDocumentChunks(file.id), fileHits, 4),
        confidence: entityIds.includes(file.id)
          ? 0.98
          : lexicalIds.includes(file.id)
            ? 0.90
            : semanticConfidence(Math.max(...fileHits.map((hit) => hit.score), -1))
      }))
    const visible = applyRetrievedDisplayConfidencePolicy(selected)
    await this.database.recordRAGSearchTrace({
      query, semanticQuery: plan?.semanticQuery || query, lexicalCandidates: lexicalIds.length,
      semanticCandidates: semanticHits.length, entityCandidates: entityIds.length, fusedCandidates: fused.size,
      returnedResults: visible.length, semanticThreshold, reranker: rerankerConfiguration(settings)?.name ?? null,
      durationMs: performance.now() - startedAt
    })
    return visible
  }
}

function applyRetrievedDisplayConfidencePolicy(results: RetrievedFile[]): RetrievedFile[] {
  const confident = results.filter((result) => (result.confidence ?? 0) >= 0.50)
  const requiredCount = Math.min(3, results.length)
  if (confident.length >= requiredCount) return confident
  return confident.concat(results.filter((result) => (result.confidence ?? 0) < 0.50).slice(0, requiredCount - confident.length))
}

function semanticConfidence(score: number): number {
  return Math.min(1, Math.max(0, (score + 1) / 2))
}

function matchesPlan(file: FileRecord, plan: SmartSearchPlan | null): boolean {
  return matchesSmartSearchPlan(file, plan)
}

function buildTurns(history: ChatMessage[], related: RetrievedFile[], settings: Settings): LlmTurn[] {
  const maxTokens = contextWindowForSettings(settings)
  const contextBudget = Math.max(512, Math.floor(maxTokens * 0.55))
  const perFileBudget = Math.max(160, Math.floor(contextBudget / Math.max(1, related.length)))
  const context = related.map(({ file, chunks }, index) => {
    let remaining = perFileBudget
    const evidence = chunks.slice(0, 4).flatMap((chunk) => {
      if (remaining <= 0) return []
      const text = truncateToTokens(chunk.parentText || chunk.text, remaining)
      remaining -= estimateTokens([{ content: text }])
      const location = [chunk.sectionPath.join(' > '), chunk.pageStart == null ? '' : `p.${chunk.pageStart}${chunk.pageEnd && chunk.pageEnd !== chunk.pageStart ? `-${chunk.pageEnd}` : ''}`].filter(Boolean).join(' · ')
      return [`Relevant evidence${location ? ` (${location})` : ''} [F${index + 1}:P${chunk.parentIndex + 1}]: ${text}`]
    }).join('\n')
    return `FILE START\nSource ID: [F${index + 1}]\nName: ${file.name}\nTitle: ${file.title ?? ''}\nUser note: ${file.note ?? ''}\nMetadata: type=${file.ext || 'none'}; category=${file.category}; size=${file.size} bytes\nLocation: ${file.path}\n${evidence}\nFILE END`
  }).join('\n\n---\n\n')
  const instructions = related.length ? prompts.chat.libraryAnswer : `${prompts.chat.libraryAnswer}\n${prompts.chat.emptyLibrary}`
  const system: LlmTurn = { role: 'system', content: `${instructions}\n\nRETRIEVED FILES START\n${context}\nRETRIEVED FILES END` }
  const responseReserve = Math.max(2_048, Math.floor(maxTokens * 0.15))
  const historyBudget = Math.max(512, maxTokens - estimateTokens([system]) - responseReserve)
  return [
    system,
    ...planChatHistory(history, historyBudget)
  ]
}

export function contextWindowForSettings(settings: Settings): number {
  if (settings.llmChoice === 'ollama') return 32_000
  if (settings.cloudContextWindowTokens > 0) return settings.cloudContextWindowTokens
  const model = settings.cloudModel.toLowerCase()
  if (model.includes('claude')) return 200_000
  if (model.includes('gemini')) return 128_000
  if (model.includes('gpt-4') || model.includes('gpt-5')) return 128_000
  return 30_000
}

export function planChatHistory(history: ChatMessage[], maxTokens: number): LlmTurn[] {
  const turns = history.filter((message) => message.role !== 'system')
  const budget = Math.max(512, maxTokens)
  const recent: ChatMessage[] = []
  let cost = 0
  for (let index = turns.length - 1; index >= 0; index -= 1) {
    const turnCost = estimateTokens([{ content: turns[index].content }]) + 8
    if (recent.length && cost + turnCost > budget * 0.75) break
    recent.unshift(turns[index])
    cost += turnCost
  }
  const omitted = turns.slice(0, Math.max(0, turns.length - recent.length))
  const planned: LlmTurn[] = recent.map((message) => ({ role: message.role as 'user' | 'assistant', content: truncateToTokens(message.content, Math.max(128, Math.floor(budget * 0.45))) }))
  if (omitted.length) {
    const selected = [omitted[0], ...omitted.slice(-7)].filter((value, index, values) => values.findIndex((item) => item.id === value.id) === index)
    const summary = [prompts.chat.compressedHistoryHeader, ...selected.map((message) => `- ${message.role === 'user' ? 'User' : 'Assistant'}: ${truncateToTokens(message.content.replace(/\s+/g, ' '), 180)}`)].join('\n')
    planned.unshift({ role: 'system', content: truncateToTokens(summary, Math.max(256, Math.floor(budget * 0.25))) })
  }
  return planned
}

function selectParentChunks(chunks: DocumentChunk[], hits: SearchHit[], limit: number): DocumentChunk[] {
  if (!chunks.length) return []
  if (!hits.length) return deduplicateParents(chunks).slice(0, limit)
  const selected = new Map<number, DocumentChunk>()
  for (const hit of hits) {
    const chunk = chunks.find((item) => item.index === hit.chunkIndex)
    if (chunk) selected.set(chunk.parentIndex, chunk)
    if (selected.size >= limit) break
  }
  return [...selected.values()]
}

function deduplicateParents(chunks: DocumentChunk[]): DocumentChunk[] {
  return [...new Map(chunks.map((chunk) => [chunk.parentIndex, chunk])).values()]
}

export function validateCitations(content: string, related: RetrievedFile[]): string {
  const valid = new Set<string>()
  related.forEach((item, fileIndex) => {
    valid.add(`F${fileIndex + 1}`)
    for (const chunk of item.chunks) valid.add(`F${fileIndex + 1}:P${chunk.parentIndex + 1}`)
  })
  return content.replace(/\[(F\d+(?::P\d+)?)\]/g, (value, identifier: string) => valid.has(identifier) ? value : '')
}

function truncateToTokens(value: string, maxTokens: number): string {
  if (estimateTokens([{ content: value }]) <= maxTokens) return value
  const maxChars = Math.max(1, Math.floor(maxTokens * 3.2) - 2)
  return `${value.slice(0, maxChars).trim()} …`
}

function retrievalOnlyAnswer(files: FileRecord[]): string {
  if (!files.length) return 'No relevant files were found. Try different keywords, or enable Ollama or a cloud model in Settings for a more complete answer.'
  return `I found ${files.length} related files:\n\n${files.map((file, index) => `${index + 1}. **${file.name}**\n   ${file.path}`).join('\n\n')}`
}

function fallbackAnswer(files: FileRecord[], error: unknown): string {
  const reason = error instanceof Error ? error.message : String(error)
  return `The configured language model was unavailable (${reason}). Local retrieval still completed.\n\n${retrievalOnlyAnswer(files)}`
}

function heuristicRules(prompt: string): Array<{ name: string; type: 'rule'; pattern: string; targetFolder: string; priority: number; enabled: boolean; action: 'organize' | 'ignore' }> {
  const rules: Array<{ name: string; type: 'rule'; pattern: string; targetFolder: string; priority: number; enabled: boolean; action: 'organize' | 'ignore' }> = []
  const extensions = [...prompt.matchAll(/\.?([a-zA-Z0-9]{2,8})/g)].map((match) => match[1].toLowerCase()).filter((ext) => ['pdf', 'docx', 'xlsx', 'pptx', 'jpg', 'png', 'zip', 'md', 'txt'].includes(ext))
  for (const [index, ext] of [...new Set(extensions)].entries()) rules.push({ name: `${ext.toUpperCase()} Files`, type: 'rule', pattern: `*.${ext}`, targetFolder: `Documents/${ext.toUpperCase()}`, priority: 100 - index, enabled: true, action: 'organize' })
  return rules.length ? rules : [{ name: 'Match Description', type: 'rule', pattern: prompt.trim().slice(0, 80), targetFolder: 'Other', priority: 50, enabled: true, action: 'organize' }]
}

function sanitizeFolder(value: string): string {
  const cleaned = value.replace(/[<>:"|?*]/g, '').replace(/^[/\\]+/, '').replace(/\.\./g, '').trim()
  return cleaned || 'Other'
}
