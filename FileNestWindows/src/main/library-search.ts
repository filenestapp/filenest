import type { FileRecord, LibrarySearchRequest, LibrarySearchResponse, LibrarySearchResult, Settings } from '../shared/types'
import { FileNestDatabase } from './database'
import { EmbeddingService } from './embedding'
import { AppLogger } from './logger'
import { LlmService } from './llm'
import { resolveSmartSearchPlan, type SmartSearchPlan } from './smart-search-plan'

interface DateIntent {
  from: Date
  to: Date
  label: string
}

export class LibrarySearchService {
  constructor(
    private readonly database: FileNestDatabase,
    private readonly embeddings: EmbeddingService,
    private readonly logger: AppLogger,
    private readonly llm = new LlmService()
  ) {}

  async search(request: LibrarySearchRequest, settings: Settings, onIntent?: (intent: string) => void): Promise<LibrarySearchResponse> {
    const query = request.query.trim()
    const plan = request.smart && query
      ? await resolveSmartSearchPlan(query, settings, this.llm, AbortSignal.timeout(30_000), onIntent)
      : null
    const dateIntent = dateIntentForPlan(plan) ?? explicitDateIntent(request) ?? parseDateIntent(query)
    const candidates = this.database.listFiles().filter((file) => {
      if (request.category && file.category !== request.category) return false
      if (plan?.categories.length && !plan.categories.includes(file.category)) return false
      if (!dateIntent) return true
      const value = new Date(request.dateField === 'created' ? file.discoveredAt : file.mtime)
      return value >= dateIntent.from && value <= dateIntent.to
    })

    const semantic = new Map<number, { score: number; snippet: string; chunkIndex: number }>()
    const semanticQuery = plan?.semanticQuery.trim() || query
    if (semanticQuery && !isDateOnlyQuery(query)) {
      try {
        for (const hit of await this.embeddings.search(semanticQuery, settings, Math.min(300, Math.max(40, candidates.length * 3)))) {
          const previous = semantic.get(hit.fileId)
          if (!previous || hit.score > previous.score) semantic.set(hit.fileId, { score: hit.score, snippet: hit.chunkText, chunkIndex: hit.chunkIndex })
        }
      } catch (error) {
        await this.logger.log('search', 'Semantic library search failed; keyword results remain available', error)
      }
    }

    const terms = [...new Set([...searchTerms(query), ...(plan?.keywords ?? []).flatMap(searchTerms)])]
    const results: LibrarySearchResult[] = []
    for (const file of candidates) {
      const lexical = rankLexical(file, terms)
      const vector = semantic.get(file.id)
      if (query && !dateIntent && !lexical && !vector) continue
      if (query && dateIntent && !isDateOnlyQuery(query) && !lexical && !vector) continue
      const match = lexical ?? (vector ? { score: vector.score * 55, confidence: semanticConfidence(vector.score), kind: 'semantic' as const, snippet: vector.snippet } : { score: 1, confidence: 0.3, kind: 'date' as const, snippet: null })
      results.push({
        file,
        score: match.score + (vector?.score ?? 0) * 15,
        confidence: Math.max(match.confidence, vector ? semanticConfidence(vector.score) : 0),
        matchKind: match.kind,
        snippet: match.snippet,
        chunkIndex: vector?.chunkIndex ?? null
      })
    }

    const sortField = request.sortField ?? (query ? 'relevance' : 'created')
    const sortDirection = plan?.sortNewestFirst && sortField === 'relevance' ? 'descending' : (request.sortDirection ?? 'descending')
    if (plan?.sortNewestFirst && sortField === 'relevance') {
      results.sort((left, right) => right.confidence - left.confidence || new Date(right.file.mtime).getTime() - new Date(left.file.mtime).getTime() || right.score - left.score || left.file.name.localeCompare(right.file.name, undefined, { numeric: true }))
    } else {
      sortResults(results, sortField, sortDirection)
    }
    const total = results.length
    const offset = Math.max(0, Math.floor(request.offset ?? 0))
    const limit = Math.min(200, Math.max(1, Math.floor(request.limit ?? 20)))
    return {
      results: results.slice(offset, offset + limit),
      total,
      interpretedQuery: [query || 'All files', dateIntent?.label].filter(Boolean).join(' · '),
      intent: plan?.intent ?? null,
      usedAi: plan?.usedAi ?? false
    }
  }
}

function rankLexical(file: FileRecord, terms: string[]): { score: number; confidence: number; kind: LibrarySearchResult['matchKind']; snippet: string | null } | null {
  if (!terms.length) return null
  const fields: Array<{ kind: LibrarySearchResult['matchKind']; value: string; weight: number }> = [
    { kind: 'filename', value: file.name, weight: 110 },
    { kind: 'title', value: file.title ?? '', weight: 90 },
    { kind: 'note', value: file.note ?? '', weight: 80 },
    { kind: 'path', value: file.path, weight: 60 },
    { kind: 'content', value: file.contentText ?? '', weight: 40 }
  ]
  let best: { score: number; confidence: number; kind: LibrarySearchResult['matchKind']; snippet: string | null } | null = null
  for (const field of fields) {
    const normalized = field.value.normalize('NFKC').toLocaleLowerCase()
    const matched = terms.filter((term) => normalized.includes(term))
    if (!matched.length) continue
    const coverage = matched.length / terms.length
    const exactBonus = normalized === terms.join(' ') ? 35 : 0
    const score = field.weight * coverage + exactBonus
    const confidence = Math.min(1, 0.35 + coverage * 0.45 + Math.min(0.2, field.weight / 550))
    if (!best || score > best.score) best = { score, confidence, kind: field.kind, snippet: makeSnippet(field.value, matched[0]) }
  }
  return best
}

function makeSnippet(value: string, term: string): string | null {
  const compact = value.replace(/\s+/g, ' ').trim()
  if (!compact) return null
  const index = compact.toLocaleLowerCase().indexOf(term)
  if (index < 0) return compact.slice(0, 220)
  const start = Math.max(0, index - 70)
  const end = Math.min(compact.length, index + term.length + 140)
  return `${start ? '…' : ''}${compact.slice(start, end)}${end < compact.length ? '…' : ''}`
}

function sortResults(results: LibrarySearchResult[], field: NonNullable<LibrarySearchRequest['sortField']>, direction: NonNullable<LibrarySearchRequest['sortDirection']>): void {
  const sign = direction === 'ascending' ? 1 : -1
  results.sort((left, right) => {
    let comparison = 0
    switch (field) {
      case 'name': comparison = left.file.name.localeCompare(right.file.name, undefined, { numeric: true }); break
      case 'size': comparison = left.file.size - right.file.size; break
      case 'modified': comparison = new Date(left.file.mtime).getTime() - new Date(right.file.mtime).getTime(); break
      case 'created': comparison = new Date(left.file.discoveredAt).getTime() - new Date(right.file.discoveredAt).getTime(); break
      case 'relevance': comparison = left.confidence - right.confidence || left.score - right.score; break
    }
    if (comparison) return comparison * sign
    return right.file.name.localeCompare(left.file.name, undefined, { numeric: true })
  })
}

function semanticConfidence(score: number): number {
  return Math.min(1, Math.max(0, (score + 1) / 2))
}

function dateIntentForPlan(plan: SmartSearchPlan | null): DateIntent | null {
  if (!plan?.dateFrom && !plan?.dateTo) return null
  const from = plan.dateFrom ?? new Date(0)
  const to = plan.dateTo ?? endOfDay(new Date())
  return { from, to, label: `${from.toISOString().slice(0, 10)} to ${to.toISOString().slice(0, 10)}` }
}

function searchTerms(query: string): string[] {
  const ignored = new Set(['find', 'show', 'file', 'files', 'from', 'in', 'on', 'last', 'this', 'the', 'recent', 'latest', 'today', 'week', 'month', 'year', '\u6700\u8fd1', '\u67e5\u627e', '\u6587\u4ef6', '\u4eca\u5929', '\u672c\u5468', '\u672c\u6708', '\u4eca\u5e74'])
  return [...new Set((query.normalize('NFKC').toLocaleLowerCase().match(/[\p{L}\p{N}_-]+/gu) ?? []).filter((term) => term.length > 1 && !ignored.has(term) && !/^20\d{2}$/.test(term)))]
}

function explicitDateIntent(request: LibrarySearchRequest): DateIntent | null {
  if (!request.dateFrom && !request.dateTo) return null
  const from = request.dateFrom ? startOfDay(new Date(request.dateFrom)) : new Date(0)
  const to = request.dateTo ? endOfDay(new Date(request.dateTo)) : endOfDay(new Date())
  if (!Number.isFinite(from.getTime()) || !Number.isFinite(to.getTime())) return null
  return { from, to, label: `${from.toISOString().slice(0, 10)} to ${to.toISOString().slice(0, 10)}` }
}

export function parseDateIntent(query: string, now = new Date()): DateIntent | null {
  const normalized = query.normalize('NFKC').toLocaleLowerCase()
  const year = normalized.match(/\b(20\d{2})\b/)?.[1]
  if (year) return { from: new Date(`${year}-01-01T00:00:00`), to: new Date(`${year}-12-31T23:59:59.999`), label: year }
  if (/\b(today)\b|\u4eca\u5929/.test(normalized)) return { from: startOfDay(now), to: endOfDay(now), label: 'Today' }
  if (/\b(last|past)\s+7\s+days\b|\u6700\u8fd1\s*7\s*\u5929/.test(normalized)) return trailingDays(now, 7, 'Last 7 days')
  if (/\b(last|past)\s+30\s+days\b|\u6700\u8fd1\s*30\s*\u5929/.test(normalized)) return trailingDays(now, 30, 'Last 30 days')
  if (/\b(this)\s+week\b|\u672c\u5468/.test(normalized)) {
    const from = startOfDay(now)
    const weekday = (from.getDay() + 6) % 7
    from.setDate(from.getDate() - weekday)
    return { from, to: endOfDay(now), label: 'This week' }
  }
  if (/\b(this)\s+month\b|\u672c\u6708/.test(normalized)) return { from: new Date(now.getFullYear(), now.getMonth(), 1), to: endOfDay(now), label: 'This month' }
  return null
}

function trailingDays(now: Date, days: number, label: string): DateIntent {
  const from = startOfDay(now)
  from.setDate(from.getDate() - (days - 1))
  return { from, to: endOfDay(now), label }
}

function isDateOnlyQuery(query: string): boolean {
  return searchTerms(query).length === 0 && parseDateIntent(query) != null
}

function startOfDay(value: Date): Date {
  const result = new Date(value)
  result.setHours(0, 0, 0, 0)
  return result
}

function endOfDay(value: Date): Date {
  const result = new Date(value)
  result.setHours(23, 59, 59, 999)
  return result
}
