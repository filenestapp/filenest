import { randomUUID } from 'node:crypto'
import type { ChatMessage, ChatSession, ChatStreamEvent, DocumentChunk, FileRecord, SendChatRequest, Settings } from '../shared/types'
import { FileNestDatabase } from './database'
import { EmbeddingService, type SearchHit } from './embedding'
import { estimateTokens, LlmService, type LlmTurn } from './llm'
import { AppLogger } from './logger'
import { resolveSmartSearchPlan, type SmartSearchPlan } from './smart-search-plan'

interface RetrievedFile {
  file: FileRecord
  chunks: DocumentChunk[]
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
      { role: 'system', content: 'You are a local file summary assistant. Summarize the key points concisely in the current interface language and do not fabricate details.' },
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
      { role: 'system', content: "Convert the user's file-organization request into a JSON array. Each item has name, pattern, targetFolder, priority, and action. Use *.ext or a keyword for pattern; action must be organize or ignore; the target must be a safe relative path. Return JSON only." },
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
      emit({ requestId, type: 'session', sessionId: session.id })
      const retryTarget = this.findRetryTarget(session.id, request.retryAssistantMessageId)
      const question = retryTarget?.question ?? request.content.trim()
      if (!question) throw new Error('Enter a question before sending')
      if (!retryTarget) {
        await this.database.addMessage(session.id, 'user', question)
        if (this.database.listMessages(session.id).filter((item) => item.role === 'user').length === 1) {
          await this.database.updateChat(session.id, { title: question.slice(0, 42) || 'New Chat' })
        }
      }

      let searchPlan: SmartSearchPlan | null = null
      if (!session.attachedFilePath) {
        emit({ requestId, type: 'progress', sessionId: session.id, stage: 'planning' })
        searchPlan = await resolveSmartSearchPlan(question, settings, this.llm, signal, (searchIntent) => {
          emit({ requestId, type: 'progress', sessionId: session.id, stage: 'planning', searchIntent })
        })
        if (signal.aborted) throw new DOMException('Generation stopped', 'AbortError')
      }
      emit({ requestId, type: 'progress', sessionId: session.id, stage: 'searching', searchIntent: searchPlan?.intent })
      const related = await this.retrieve(question, session, settings, searchPlan)
      const relatedFileIds = related.map((item) => item.file.id)
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
        ? await this.database.replaceAssistantMessage(retryTarget.message.id, content, relatedFileIds, metrics)
        : await this.database.addMessage(session.id, 'assistant', content, relatedFileIds, metrics)
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

  private async retrieve(query: string, session: ChatSession, settings: Settings, plan: SmartSearchPlan | null): Promise<RetrievedFile[]> {
    const limit = Math.max(1, Math.min(30, settings.ragResultLimit))
    if (session.attachedFilePath) {
      const file = this.database.getFileByPath(session.attachedFilePath)
      if (!file) return []
      let hits: SearchHit[] = []
      try { hits = await this.embeddings.search(query, settings, Math.min(limit * 2, 40), file.id) } catch (error) {
        await this.logger.log('chat', 'File semantic search failed; using stored document chunks', error)
      }
      return [{ file, chunks: selectNeighborChunks(this.database.listDocumentChunks(file.id), hits, limit) }]
    }

    let hits: SearchHit[] = []
    try {
      hits = await this.embeddings.search(plan?.semanticQuery || query, settings, Math.min(limit * 4, 80))
    } catch (error) {
      await this.logger.log('chat', 'Semantic search failed; falling back to keyword search', error)
    }
    const candidates = new Map<number, { file: FileRecord; hits: SearchHit[] }>()
    for (const hit of hits) {
      const file = this.database.getFile(hit.fileId)
      if (!file) continue
      if (!matchesPlan(file, plan)) continue
      const existing = candidates.get(file.id) ?? { file, hits: [] }
      existing.hits.push(hit)
      candidates.set(file.id, existing)
    }
    for (const keyword of [...query.split(/[\s，。！？、,.;:]+/), ...(plan?.keywords ?? [])].filter((item) => item.length > 1)) {
      for (const file of this.database.searchFiles(keyword, null, limit * 2)) {
        if (matchesPlan(file, plan) && !candidates.has(file.id)) candidates.set(file.id, { file, hits: [] })
      }
    }
    return [...candidates.values()].slice(0, limit).map(({ file, hits: fileHits }) => ({
      file,
      chunks: selectNeighborChunks(this.database.listDocumentChunks(file.id), fileHits, Math.max(3, Math.ceil(limit / 2)))
    }))
  }
}

function matchesPlan(file: FileRecord, plan: SmartSearchPlan | null): boolean {
  if (!plan) return true
  if (plan.categories.length && !plan.categories.includes(file.category)) return false
  const modified = new Date(file.mtime)
  if (plan.dateFrom && modified < plan.dateFrom) return false
  if (plan.dateTo && modified > plan.dateTo) return false
  return true
}

function buildTurns(history: ChatMessage[], related: RetrievedFile[], settings: Settings): LlmTurn[] {
  const maxTokens = contextWindowForSettings(settings)
  const contextBudget = Math.max(512, Math.floor(maxTokens * 0.55))
  const perFileBudget = Math.max(160, Math.floor(contextBudget / Math.max(1, related.length)))
  const context = related.map(({ file, chunks }, index) => {
    const rawText = chunks.length ? chunks.map((chunk) => chunk.contextualText).join('\n\n') : (file.contentText ?? '')
    const text = truncateToTokens(rawText, perFileBudget)
    return `[File ${index + 1} | ID ${file.id}]\nName: ${file.name}\nPath: ${file.path}\nTitle: ${file.title ?? ''}\nNote: ${file.note ?? ''}\nRelevant content:\n${text}`
  }).join('\n\n---\n\n')
  const system: LlmTurn = { role: 'system', content: `You are FileNest, a local file-retrieval assistant. Answer only from the supplied local-file context, state uncertainty clearly, and use exact file names when citing files. Context:\n\n${context || 'No relevant files were retrieved.'}` }
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
    const summary = ['Earlier conversation (automatically compressed; recent messages take precedence):', ...selected.map((message) => `- ${message.role === 'user' ? 'User' : 'Assistant'}: ${truncateToTokens(message.content.replace(/\s+/g, ' '), 180)}`)].join('\n')
    planned.unshift({ role: 'system', content: truncateToTokens(summary, Math.max(256, Math.floor(budget * 0.25))) })
  }
  return planned
}

function selectNeighborChunks(chunks: DocumentChunk[], hits: SearchHit[], limit: number): DocumentChunk[] {
  if (!chunks.length) return []
  if (!hits.length) return chunks.slice(0, limit)
  const selected = new Map<number, DocumentChunk>()
  for (const hit of hits) {
    for (const index of [hit.chunkIndex - 1, hit.chunkIndex, hit.chunkIndex + 1]) {
      const chunk = chunks.find((item) => item.index === index)
      if (chunk) selected.set(chunk.index, chunk)
      if (selected.size >= limit) return [...selected.values()].sort((left, right) => left.index - right.index)
    }
  }
  return [...selected.values()].sort((left, right) => left.index - right.index)
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
