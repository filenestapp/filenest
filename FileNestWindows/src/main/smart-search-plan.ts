import type { FileCategory, Settings } from '../shared/types'
import { LlmService } from './llm'

export interface SmartSearchPlan {
  semanticQuery: string
  keywords: string[]
  categories: FileCategory[]
  dateFrom: Date | null
  dateTo: Date | null
  sortNewestFirst: boolean
  intent: string
  usedAi: boolean
}

interface SmartSearchPayload {
  intent?: string
  semantic_query?: string
  keywords?: string[]
  categories?: string[]
  date_from?: string | null
  date_to?: string | null
  sort?: string
}

export async function resolveSmartSearchPlan(
  query: string,
  settings: Settings,
  llm: LlmService,
  signal: AbortSignal,
  onIntent?: (intent: string) => void
): Promise<SmartSearchPlan> {
  const fallback = fallbackSmartSearchPlan(query)
  if (!query.trim() || settings.llmChoice === 'none') return fallback
  try {
    let response = ''
    let lastIntent = ''
    for await (const delta of llm.stream([
      { role: 'system', content: smartSearchSystemPrompt() },
      { role: 'user', content: query }
    ], settings, signal)) {
      response += delta
      const intent = streamedSearchIntent(response)
      if (intent && intent !== lastIntent) {
        lastIntent = intent
        onIntent?.(intent)
      }
    }
    const payload = decodePayload(response)
    const plan = planFromPayload(payload, query)
    if (plan.intent && plan.intent !== lastIntent) onIntent?.(plan.intent)
    return { ...plan, usedAi: true }
  } catch {
    return fallback
  }
}

export function streamedSearchIntent(response: string): string | null {
  const marker = response.indexOf('"intent"')
  if (marker < 0) return null
  const colon = response.indexOf(':', marker + 8)
  const quote = response.indexOf('"', colon + 1)
  if (colon < 0 || quote < 0) return null
  let value = ''
  let escaped = false
  for (let index = quote + 1; index < response.length; index += 1) {
    const character = response[index]
    if (escaped) {
      value += ['n', 'r', 't'].includes(character) ? ' ' : character
      escaped = false
    } else if (character === '\\') {
      escaped = true
    } else if (character === '"') {
      return value.trim() || null
    } else {
      value += character
    }
  }
  return null
}

function smartSearchSystemPrompt(): string {
  return `Convert the user's file-search request into one strict JSON object. Today is ${new Date().toISOString().slice(0, 10)}.
Return JSON only. Put intent first, followed by semantic_query, keywords, categories, date_from, date_to, and sort.
The intent must be one concise sentence in the user's language. categories may contain documents, images, videos, audio, code, archives, or other.
Resolve relative dates to inclusive YYYY-MM-DD values. Preserve distinctive identifiers in at most 8 keywords. Use null dates and an empty category list when absent. sort is relevance or newest.`
}

function decodePayload(response: string): SmartSearchPayload {
  const start = response.indexOf('{')
  const end = response.lastIndexOf('}')
  if (start < 0 || end < start) throw new Error('The search plan was not valid JSON')
  return JSON.parse(response.slice(start, end + 1)) as SmartSearchPayload
}

function planFromPayload(payload: SmartSearchPayload, fallbackQuery: string): SmartSearchPlan {
  const keywords = [...new Set((payload.keywords ?? []).map((value) => value.trim()).filter(Boolean))].slice(0, 8)
  const categories = (payload.categories ?? []).filter(isFileCategory)
  const dateFrom = parsePlanDate(payload.date_from, false)
  const dateTo = parsePlanDate(payload.date_to, true)
  const semanticQuery = payload.semantic_query?.trim() || (keywords.length || categories.length || dateFrom || dateTo ? '' : fallbackQuery)
  return {
    semanticQuery,
    keywords,
    categories,
    dateFrom,
    dateTo,
    sortNewestFirst: payload.sort?.toLowerCase() === 'newest',
    intent: payload.intent?.trim() || fallbackIntent(fallbackQuery),
    usedAi: false
  }
}

function fallbackSmartSearchPlan(query: string): SmartSearchPlan {
  const date = fallbackDateIntent(query)
  return {
    semanticQuery: query,
    keywords: terms(query).slice(0, 8),
    categories: inferredCategories(query),
    dateFrom: date?.from ?? null,
    dateTo: date?.to ?? null,
    sortNewestFirst: /\b(latest|recent|newest)\b|\u6700\u8fd1|\u6700\u65b0/i.test(query),
    intent: fallbackIntent(query),
    usedAi: false
  }
}

function fallbackDateIntent(query: string): { from: Date; to: Date } | null {
  const normalized = query.normalize('NFKC').toLocaleLowerCase()
  const now = new Date()
  const year = normalized.match(/\b(20\d{2})\b/)?.[1]
  if (year) return { from: new Date(`${year}-01-01T00:00:00`), to: new Date(`${year}-12-31T23:59:59.999`) }
  if (/\btoday\b|\u4eca\u5929/.test(normalized)) return { from: dayBoundary(now, false), to: dayBoundary(now, true) }
  const days = /\b(last|past)\s+30\s+days\b|\u6700\u8fd1\s*30\s*\u5929/.test(normalized) ? 30
    : /\b(last|past)\s+7\s+days\b|\u6700\u8fd1\s*7\s*\u5929/.test(normalized) ? 7 : 0
  if (!days) return null
  const from = dayBoundary(now, false)
  from.setDate(from.getDate() - (days - 1))
  return { from, to: dayBoundary(now, true) }
}

function dayBoundary(value: Date, end: boolean): Date {
  const result = new Date(value)
  result.setHours(end ? 23 : 0, end ? 59 : 0, end ? 59 : 0, end ? 999 : 0)
  return result
}

function fallbackIntent(query: string): string {
  return `Searching the library for: ${query.trim()}`
}

function terms(query: string): string[] {
  return [...new Set(query.normalize('NFKC').toLocaleLowerCase().match(/[\p{L}\p{N}_-]+/gu) ?? [])].filter((term) => term.length > 1)
}

function inferredCategories(query: string): FileCategory[] {
  const normalized = query.toLocaleLowerCase()
  const mappings: Array<[FileCategory, string[]]> = [
    ['documents', ['document', 'pdf', 'word', '\u6587\u6863']],
    ['images', ['image', 'photo', 'screenshot', '\u56fe\u7247', '\u7167\u7247']],
    ['videos', ['video', 'movie', '\u89c6\u9891']],
    ['audio', ['audio', 'recording', '\u97f3\u9891']],
    ['code', ['code', 'source', '\u4ee3\u7801']],
    ['archives', ['archive', 'zip', '\u538b\u7f29\u5305']]
  ]
  return mappings.filter(([, values]) => values.some((value) => normalized.includes(value))).map(([category]) => category)
}

function isFileCategory(value: string): value is FileCategory {
  return ['documents', 'images', 'videos', 'audio', 'code', 'archives', 'other'].includes(value)
}

function parsePlanDate(value: string | null | undefined, endOfDay: boolean): Date | null {
  if (!value) return null
  const date = new Date(`${value}T${endOfDay ? '23:59:59.999' : '00:00:00'}`)
  return Number.isFinite(date.getTime()) ? date : null
}
