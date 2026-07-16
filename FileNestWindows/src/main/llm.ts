import type { ChatMessage, Settings } from '../shared/types'

export interface LlmTurn { role: 'system' | 'user' | 'assistant'; content: string }

export class LlmService {
  async complete(turns: LlmTurn[], settings: Settings, timeoutMs = 30_000): Promise<string> {
    const signal = AbortSignal.timeout(timeoutMs)
    let result = ''
    for await (const delta of this.stream(turns, settings, signal)) result += delta
    return result.trim()
  }

  async *stream(turns: LlmTurn[], settings: Settings, signal: AbortSignal): AsyncGenerator<string> {
    if (settings.llmChoice === 'none') return
    if (settings.llmChoice === 'ollama') {
      yield* this.streamOllama(turns, settings, signal)
      return
    }
    if (settings.cloudApiFormat === 'anthropic') {
      yield* this.streamAnthropic(turns, settings, signal)
      return
    }
    yield* this.streamOpenAi(turns, settings, signal)
  }

  provider(settings: Settings): { name: string; model: string } {
    return settings.llmChoice === 'ollama'
      ? { name: 'Ollama', model: settings.ollamaModel }
      : settings.llmChoice === 'cloud'
        ? { name: settings.cloudApiFormat === 'anthropic' ? 'Anthropic' : 'OpenAI Compatible', model: settings.cloudModel }
        : { name: 'Retrieval only', model: 'none' }
  }

  private async *streamOllama(turns: LlmTurn[], settings: Settings, signal: AbortSignal): AsyncGenerator<string> {
    const response = await fetch(new URL('/api/chat', settings.ollamaHost.replace(/\/+$/, '') + '/'), {
      method: 'POST', signal, headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: settings.ollamaModel, messages: turns, stream: true, think: settings.thinkingMode, options: { temperature: 0.2 } })
    })
    if (!response.ok || !response.body) throw new Error(`Ollama ${response.status}: ${await response.text()}`)
    for await (const line of readLines(response.body, signal)) {
      const payload = JSON.parse(line) as { message?: { content?: string } }
      if (payload.message?.content) yield payload.message.content
    }
  }

  private async *streamOpenAi(turns: LlmTurn[], settings: Settings, signal: AbortSignal): AsyncGenerator<string> {
    const response = await fetch(new URL('chat/completions', settings.cloudBaseUrl.replace(/\/+$/, '') + '/'), {
      method: 'POST', signal,
      headers: { 'content-type': 'application/json', authorization: `Bearer ${settings.cloudApiKey}` },
      body: JSON.stringify({ model: settings.cloudModel, messages: turns, stream: true, temperature: 0.2 })
    })
    if (!response.ok || !response.body) throw new Error(`Cloud LLM ${response.status}: ${await response.text()}`)
    for await (const line of readSseData(response.body, signal)) {
      if (line === '[DONE]') break
      const payload = JSON.parse(line) as { choices?: Array<{ delta?: { content?: string } }> }
      const delta = payload.choices?.[0]?.delta?.content
      if (delta) yield delta
    }
  }

  private async *streamAnthropic(turns: LlmTurn[], settings: Settings, signal: AbortSignal): AsyncGenerator<string> {
    const system = turns.filter((turn) => turn.role === 'system').map((turn) => turn.content).join('\n\n')
    const messages = turns.filter((turn) => turn.role !== 'system')
    const response = await fetch(new URL('messages', settings.cloudBaseUrl.replace(/\/+$/, '') + '/'), {
      method: 'POST', signal,
      headers: { 'content-type': 'application/json', 'x-api-key': settings.cloudApiKey, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: settings.cloudModel, system, messages, stream: true, max_tokens: 4096, temperature: 0.2 })
    })
    if (!response.ok || !response.body) throw new Error(`Anthropic ${response.status}: ${await response.text()}`)
    for await (const line of readSseData(response.body, signal)) {
      const payload = JSON.parse(line) as { type?: string; delta?: { text?: string } }
      if (payload.type === 'content_block_delta' && payload.delta?.text) yield payload.delta.text
    }
  }
}

async function* readLines(stream: ReadableStream<Uint8Array>, signal: AbortSignal): AsyncGenerator<string> {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let buffer = ''
  while (!signal.aborted) {
    const { done, value } = await reader.read()
    if (done) break
    buffer += decoder.decode(value, { stream: true })
    const lines = buffer.split('\n')
    buffer = lines.pop() ?? ''
    for (const line of lines) if (line.trim()) yield line.trim()
  }
}

async function* readSseData(stream: ReadableStream<Uint8Array>, signal: AbortSignal): AsyncGenerator<string> {
  for await (const line of readLines(stream, signal)) {
    if (line.startsWith('data:')) yield line.slice(5).trim()
  }
}

export function estimateTokens(messages: Array<Pick<ChatMessage, 'content'>> | LlmTurn[]): number {
  return Math.max(1, Math.ceil(messages.reduce((sum, message) => sum + message.content.length, 0) / 3.2))
}
