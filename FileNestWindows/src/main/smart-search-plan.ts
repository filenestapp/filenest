import type { FileCategory, FileRecord, Settings } from '../shared/types'
import { LlmService } from './llm'
import { smartSearchPlannerPrompt } from './prompts'

export interface SmartSearchPlan {
  semanticQuery: string
  keywords: string[]
  exactName: string | null
  fileExtensions: string[]
  categories: FileCategory[]
  folderTerms: string[]
  itemKind: 'any' | 'file' | 'directory'
  dateField: 'modified' | 'added' | 'organized'
  dateFrom: Date | null
  dateTo: Date | null
  sizeMinBytes: number | null
  sizeMaxBytes: number | null
  hasNote: boolean | null
  isIndexed: boolean | null
  sort: 'relevance' | 'newest' | 'oldest' | 'largest' | 'smallest'
  sortNewestFirst: boolean
  intent: string
  usedAi: boolean
}

interface SmartSearchPayload {
  intent?: string
  semantic_query?: string
  keywords?: string[]
  exact_name?: string | null
  file_extensions?: string[]
  categories?: string[]
  folder_terms?: string[]
  item_kind?: string
  date_field?: string
  date_from?: string | null
  date_to?: string | null
  size_min_bytes?: number | null
  size_max_bytes?: number | null
  has_note?: boolean | null
  is_indexed?: boolean | null
  sort?: string
}

export async function resolveSmartSearchPlan(
  query: string,
  settings: Settings,
  llm: LlmService,
  signal: AbortSignal,
  onIntent?: (intent: string) => void,
  skillContext = ''
): Promise<SmartSearchPlan> {
  const fallback = fallbackSmartSearchPlan(query)
  if (!query.trim() || settings.llmChoice === 'none') return fallback
  try {
    let response = ''
    let lastIntent = ''
    for await (const delta of llm.stream([
      { role: 'system', content: `${smartSearchPlannerPrompt(new Date().toISOString().slice(0, 10))}${skillContext ? `\n\n${skillContext}` : ''}` },
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

export function matchesSmartSearchPlan(file: FileRecord, plan: SmartSearchPlan | null): boolean {
  if (!plan) return true
  if (plan.exactName && file.name.normalize('NFKC').toLocaleLowerCase() !== plan.exactName.normalize('NFKC').toLocaleLowerCase()) return false
  if (plan.fileExtensions.length && !plan.fileExtensions.includes(file.ext.toLocaleLowerCase())) return false
  if (plan.categories.length && !plan.categories.includes(file.category)) return false
  if (plan.folderTerms.length) {
    const haystack = [file.path, file.sourceDir, file.organizationSubfolder ?? ''].join('\n').normalize('NFKC').toLocaleLowerCase()
    if (!plan.folderTerms.every((term) => haystack.includes(term.normalize('NFKC').toLocaleLowerCase()))) return false
  }
  if (plan.itemKind === 'file' && file.isDirectory || plan.itemKind === 'directory' && !file.isDirectory) return false
  if (plan.sizeMinBytes != null && file.size < plan.sizeMinBytes) return false
  if (plan.sizeMaxBytes != null && file.size > plan.sizeMaxBytes) return false
  if (plan.hasNote != null && Boolean(file.note?.trim()) !== plan.hasNote) return false
  if (plan.isIndexed != null && Boolean(file.indexedAt) !== plan.isIndexed) return false
  const date = dateForPlan(file, plan.dateField)
  if (plan.dateFrom && (!date || date < plan.dateFrom)) return false
  if (plan.dateTo && (!date || date > plan.dateTo)) return false
  return true
}

export function hasStructuredSearchFilters(plan: SmartSearchPlan | null): boolean {
  return plan != null && Boolean(plan.exactName || plan.fileExtensions.length || plan.categories.length || plan.folderTerms.length || plan.itemKind !== 'any' || plan.dateFrom || plan.dateTo || plan.sizeMinBytes != null || plan.sizeMaxBytes != null || plan.hasNote != null || plan.isIndexed != null)
}

function dateForPlan(file: FileRecord, field: SmartSearchPlan['dateField']): Date | null {
  const value = field === 'added' ? file.discoveredAt : field === 'organized' ? file.organizedAt : file.mtime
  if (!value) return null
  const date = new Date(value)
  return Number.isFinite(date.getTime()) ? date : null
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
  const fileExtensions = [...new Set((payload.file_extensions ?? []).map((value) => value.replace(/^\./, '').trim().toLocaleLowerCase()).filter(Boolean))].slice(0, 12)
  const folderTerms = [...new Set((payload.folder_terms ?? []).map((value) => value.trim()).filter(Boolean))].slice(0, 4)
  const dateFrom = parsePlanDate(payload.date_from, false)
  const dateTo = parsePlanDate(payload.date_to, true)
  const exactName = payload.exact_name?.trim() || null
  const itemKind = payload.item_kind === 'file' || payload.item_kind === 'directory' ? payload.item_kind : 'any'
  const dateField = payload.date_field === 'added' || payload.date_field === 'organized' ? payload.date_field : 'modified'
  const sort = isSort(payload.sort) ? payload.sort : 'relevance'
  const hasStructuredFilters = keywords.length || exactName || fileExtensions.length || categories.length || folderTerms.length || itemKind !== 'any' || dateFrom || dateTo || payload.size_min_bytes != null || payload.size_max_bytes != null || payload.has_note != null || payload.is_indexed != null
  const semanticQuery = payload.semantic_query?.trim() || (hasStructuredFilters ? '' : fallbackQuery)
  return {
    semanticQuery,
    keywords,
    exactName,
    fileExtensions,
    categories,
    folderTerms,
    itemKind,
    dateField,
    dateFrom,
    dateTo,
    sizeMinBytes: finiteNonnegative(payload.size_min_bytes),
    sizeMaxBytes: finiteNonnegative(payload.size_max_bytes),
    hasNote: typeof payload.has_note === 'boolean' ? payload.has_note : null,
    isIndexed: typeof payload.is_indexed === 'boolean' ? payload.is_indexed : null,
    sort,
    sortNewestFirst: sort === 'newest',
    intent: payload.intent?.trim() || fallbackIntent(fallbackQuery),
    usedAi: false
  }
}

export function fallbackSmartSearchPlan(query: string): SmartSearchPlan {
  const date = fallbackDateIntent(query)
  return {
    semanticQuery: query,
    keywords: terms(query).slice(0, 8),
    exactName: null,
    fileExtensions: inferredExtensions(query),
    categories: inferredCategories(query),
    folderTerms: [],
    itemKind: 'any',
    dateField: 'modified',
    dateFrom: date?.from ?? null,
    dateTo: date?.to ?? null,
    sizeMinBytes: null,
    sizeMaxBytes: null,
    hasNote: null,
    isIndexed: null,
    sort: /\b(latest|recent|newest)\b|\u6700\u8fd1|\u6700\u65b0/i.test(query) ? 'newest' : 'relevance',
    sortNewestFirst: /\b(latest|recent|newest)\b|\u6700\u8fd1|\u6700\u65b0/i.test(query),
    intent: fallbackIntent(query),
    usedAi: false
  }
}

function inferredExtensions(query: string): string[] {
  const known = new Set(['pdf', 'doc', 'docx', 'xlsx', 'pptx', 'txt', 'md', 'jpg', 'jpeg', 'png', 'gif', 'mp4', 'mov', 'mp3', 'wav', 'zip', 'rar', '7z', 'swift', 'py', 'js', 'ts', 'tsx', 'json', 'csv'])
  return [...new Set((query.toLocaleLowerCase().match(/(?:\.|\b)([a-z0-9]{2,8})\b/g) ?? [])
    .map((value) => value.replace(/^\./, ''))
    .filter((value) => known.has(value)))]
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
  return [...new Set(insertSearchBoundaries(query).normalize('NFKC').toLocaleLowerCase().match(/[\p{L}\p{N}_-]+/gu) ?? [])].filter((term) => term.length > 1)
}

function insertSearchBoundaries(value: string): string {
  return value
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
    .replace(/([A-Za-z0-9])(\p{Script=Han})/gu, '$1 $2')
    .replace(/(\p{Script=Han})([A-Za-z0-9])/gu, '$1 $2')
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

function isSort(value: string | undefined): value is SmartSearchPlan['sort'] {
  return value != null && ['relevance', 'newest', 'oldest', 'largest', 'smallest'].includes(value)
}

function finiteNonnegative(value: number | null | undefined): number | null {
  return value != null && Number.isFinite(value) ? Math.max(0, Math.round(value)) : null
}
