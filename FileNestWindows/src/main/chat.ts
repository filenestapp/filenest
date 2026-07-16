import { randomUUID } from 'node:crypto'
import type { ChatMessage, ChatSession, ChatStreamEvent, FileRecord, SendChatRequest, Settings } from '../shared/types'
import { FileNestDatabase } from './database'
import { EmbeddingService } from './embedding'
import { estimateTokens, LlmService, type LlmTurn } from './llm'
import { AppLogger } from './logger'

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
    const content = (file.contentText ?? file.note ?? file.name).slice(0, 14_000)
    if (settings.llmChoice === 'none') return content.slice(0, 600)
    const parts: string[] = []
    const signal = new AbortController().signal
    for await (const delta of this.llm.stream([
      { role: 'system', content: 'You are a local file summary assistant. Summarize the key points concisely in the current interface language and do not fabricate details.' },
      { role: 'user', content: `File: ${file.name}\n\n${content}` }
    ], settings, signal)) parts.push(delta)
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
    try {
      const session = await this.ensureSession(request)
      emit({ requestId, type: 'session', sessionId: session.id })
      const user = await this.database.addMessage(session.id, 'user', request.content)
      if (this.database.listMessages(session.id).filter((item) => item.role === 'user').length === 1) {
        await this.database.updateChat(session.id, { title: request.content.trim().slice(0, 42) || 'New Chat' })
      }
      const related = await this.retrieve(request.content, session, settings)
      if (settings.llmChoice === 'none') {
        const content = retrievalOnlyAnswer(related)
        const message = await this.database.addMessage(session.id, 'assistant', content, related.map((file) => file.id))
        emit({ requestId, type: 'done', sessionId: session.id, message })
        return
      }
      const history = this.database.listMessages(session.id)
      const turns = buildTurns(history, related, settings)
      let content = ''
      for await (const delta of this.llm.stream(turns, settings, signal)) {
        content += delta
        emit({ requestId, type: 'delta', sessionId: session.id, delta })
      }
      if (!content.trim()) throw new Error('The model returned no content')
      const message = await this.database.addMessage(session.id, 'assistant', content, related.map((file) => file.id))
      const provider = this.llm.provider(settings)
      await this.database.recordUsage(provider.name, provider.model, estimateTokens(turns), estimateTokens([{ content }]), session.id)
      emit({ requestId, type: 'done', sessionId: session.id, message })
    } catch (error) {
      if (signal.aborted) {
        emit({ requestId, type: 'error', error: 'Generation stopped' })
      } else {
        await this.logger.log('chat', 'Chat failed', error)
        emit({ requestId, type: 'error', error: error instanceof Error ? error.message : String(error) })
      }
    }
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

  private async retrieve(query: string, session: ChatSession, settings: Settings): Promise<FileRecord[]> {
    if (session.attachedFilePath) {
      const file = this.database.getFileByPath(session.attachedFilePath)
      return file ? [file] : []
    }
    try {
      const hits = await this.embeddings.search(query, settings, 16)
      const seen = new Set<number>()
      const files: FileRecord[] = []
      for (const hit of hits) {
        if (seen.has(hit.fileId)) continue
        const file = this.database.getFile(hit.fileId)
        if (file) { seen.add(file.id); files.push(file) }
        if (files.length === 5) break
      }
      if (files.length) return files
    } catch (error) {
      await this.logger.log('chat', 'Semantic search failed; falling back to keyword search', error)
    }
    const keywords = query.split(/[\s，。！？、,.;:]+/).filter((item) => item.length > 1)
    const found = new Map<number, FileRecord>()
    for (const keyword of keywords) this.database.searchFiles(keyword, null, 8).forEach((file) => found.set(file.id, file))
    return [...found.values()].slice(0, 5)
  }
}

function buildTurns(history: ChatMessage[], related: FileRecord[], settings: Settings): LlmTurn[] {
  const context = related.map((file, index) => `[File ${index + 1} | ID ${file.id}]\nName: ${file.name}\nPath: ${file.path}\nTitle: ${file.title ?? ''}\nNote: ${file.note ?? ''}\nContent: \n${(file.contentText ?? '').slice(0, 10_000)}`).join('\n\n---\n\n')
  return [
    { role: 'system', content: `You are FileNest, a local file-retrieval assistant. Answer only from the supplied local-file context, state uncertainty clearly, and use exact file names when citing files. Context:\n\n${context || 'No relevant files were retrieved.'}` },
    ...planChatHistory(history, settings.llmChoice === 'ollama' ? 8_000 : 30_000)
  ]
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

function truncateToTokens(value: string, maxTokens: number): string {
  if (estimateTokens([{ content: value }]) <= maxTokens) return value
  const maxChars = Math.max(1, Math.floor(maxTokens * 3.2) - 2)
  return `${value.slice(0, maxChars).trim()} …`
}

function retrievalOnlyAnswer(files: FileRecord[]): string {
  if (!files.length) return 'No relevant files were found. Try different keywords, or enable Ollama or a cloud model in Settings for a more complete answer.'
  return `I found ${files.length} related files:\n\n${files.map((file, index) => `${index + 1}. **${file.name}**\n   ${file.path}`).join('\n\n')}`
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
