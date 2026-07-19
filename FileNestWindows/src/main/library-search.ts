import type { FileRecord, LibrarySearchRequest, LibrarySearchResponse, LibrarySearchResult, Settings } from '../shared/types'
import { FileNestDatabase } from './database'
import { EmbeddingService } from './embedding'
import { AppLogger } from './logger'
import { LlmService } from './llm'
import { fallbackSmartSearchPlan, hasStructuredSearchFilters, matchesSmartSearchPlan, resolveSmartSearchPlan, type SmartSearchPlan } from './smart-search-plan'
import { extractEntityTerms } from './indexer'
import { dynamicallyAcceptedSemanticHits, rerankDocuments, rerankerConfiguration, weightedReciprocalRankFusion } from './reranker'

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
    const startedAt = performance.now()
    const query = request.query.trim()
    const plan = request.smart && query
      ? await resolveSmartSearchPlan(query, settings, this.llm, AbortSignal.timeout(30_000), onIntent)
      : fallbackSmartSearchPlan(query)
    const dateIntent = dateIntentForPlan(plan) ?? explicitDateIntent(request) ?? parseDateIntent(query)
    const candidates = this.database.listFiles().filter((file) => {
      if (request.category && file.category !== request.category) return false
      if (!matchesSmartSearchPlan(file, plan)) return false
      if (!dateIntent) return true
      const dateValue = plan ? plan.dateField === 'added' ? file.discoveredAt : plan.dateField === 'organized' ? file.organizedAt : file.mtime : request.dateField === 'created' ? file.discoveredAt : file.mtime
      if (!dateValue) return false
      const value = new Date(dateValue)
      return value >= dateIntent.from && value <= dateIntent.to
    })

    const semantic = new Map<number, { score: number; snippet: string; chunkIndex: number }>()
    const semanticQuery = plan?.semanticQuery.trim() || query
    let semanticCandidates = 0
    let semanticThreshold: number | null = null
    if (request.includeSemantic !== false && semanticQuery && !isDateOnlyQuery(query)) {
      try {
        const rawHits = await this.embeddings.search(semanticQuery, settings, Math.min(300, Math.max(40, candidates.length * 3)))
        const accepted = dynamicallyAcceptedSemanticHits(rawHits)
        semanticThreshold = accepted.threshold
        semanticCandidates = accepted.hits.length
        let hits = accepted.hits
        if (rerankerConfiguration(settings) && hits.length > 1) {
          const rerankCandidates = hits.slice(0, 24)
          try {
            const results = await rerankDocuments(semanticQuery, rerankCandidates.map((hit) => hit.chunkText), settings)
            const scores = new Map(results.map((result) => [result.index, result.score]))
            const reranked = rerankCandidates.flatMap((hit, index) => scores.has(index) ? [{ ...hit, score: Math.min(1, Math.max(0, scores.get(index)!)) }] : [])
            if (reranked.length) hits = reranked.sort((left, right) => right.score - left.score)
          } catch (error) {
            await this.logger.log('search', 'Reranker unavailable; fused retrieval order remains active', error)
          }
        }
        for (const hit of hits) {
          const previous = semantic.get(hit.fileId)
          if (!previous || hit.score > previous.score) semantic.set(hit.fileId, { score: hit.score, snippet: hit.chunkText, chunkIndex: hit.chunkIndex })
        }
      } catch (error) {
        await this.logger.log('search', 'Semantic library search failed; keyword results remain available', error)
      }
    }

    const terms = [...new Set([...searchTerms(query), ...(plan?.keywords ?? []).flatMap(searchTerms)])]
    const entity = new Map<number, { snippet: string; chunkIndex: number }>()
    const candidateIds = new Set(candidates.map((file) => file.id))
    for (const match of this.database.entityChunkMatches(extractEntityTerms(query), Math.max(20, Math.min(60, candidates.length * 2)))) {
      if (candidateIds.has(match.fileId) && !entity.has(match.fileId)) {
        entity.set(match.fileId, { snippet: match.chunk.parentText, chunkIndex: match.chunkIndex })
      }
    }
    const lexicalById = new Map<number, NonNullable<ReturnType<typeof rankLexical>>>()
    for (const file of candidates) {
      const lexical = rankLexical(file, terms)
      if (lexical) lexicalById.set(file.id, lexical)
    }
    const lexicalIds = [...lexicalById].sort((left, right) => right[1].score - left[1].score).map(([id]) => id)
    const semanticIds = [...semantic].sort((left, right) => right[1].score - left[1].score).map(([id]) => id)
    const entityIds = [...entity.keys()]
    const fusedScores = weightedReciprocalRankFusion([
      { weight: 0.36, ids: lexicalIds },
      { weight: 0.44, ids: semanticIds },
      { weight: 0.20, ids: entityIds }
    ])
    const results: LibrarySearchResult[] = []
    for (const file of candidates) {
      const lexical = lexicalById.get(file.id)
      const vector = semantic.get(file.id)
      const entityMatch = entity.get(file.id)
      const structuredOnly = hasStructuredSearchFilters(plan)
      if (query && !dateIntent && !structuredOnly && !lexical && !vector && !entityMatch) continue
      if (query && dateIntent && !structuredOnly && !isDateOnlyQuery(query) && !lexical && !vector && !entityMatch) continue
      const match = lexical ?? (entityMatch
        ? { score: 1, confidence: 0.98, kind: 'entity' as const, snippet: entityMatch.snippet }
        : vector ? { score: vector.score * 55, confidence: semanticConfidence(vector.score), kind: 'semantic' as const, snippet: vector.snippet }
          : { score: 1, confidence: structuredOnly ? 0.85 : 0.3, kind: structuredOnly ? 'filter' as const : 'date' as const, snippet: null })
      const exactName = plan?.exactName != null && file.name.normalize('NFKC').toLocaleLowerCase() === plan.exactName.normalize('NFKC').toLocaleLowerCase()
      const matchKind = entityMatch && (lexical || vector) || lexical && vector ? 'hybrid' as const : match.kind
      results.push({
        file,
        score: (fusedScores.get(file.id) ?? match.score) + (exactName ? 0.1 : 0),
        confidence: Math.max(exactName ? 1 : 0, match.confidence, vector ? semanticConfidence(vector.score) : 0, entityMatch ? 0.98 : 0),
        matchKind: exactName ? 'filename' : matchKind,
        snippet: match.snippet,
        chunkIndex: entityMatch?.chunkIndex ?? vector?.chunkIndex ?? null
      })
    }

    const sortField = request.sortField ?? (query ? 'relevance' : 'created')
    const sortDirection = plan?.sortNewestFirst && sortField === 'relevance' ? 'descending' : (request.sortDirection ?? 'descending')
    if (plan && plan.sort !== 'relevance' && sortField === 'relevance') {
      results.sort((left, right) => comparePlannedSort(left, right, plan.sort) || right.confidence - left.confidence || right.score - left.score || left.file.name.localeCompare(right.file.name, undefined, { numeric: true }))
    } else {
      sortResults(results, sortField, sortDirection)
    }
    const visibleResults = applyDisplayConfidencePolicy(results)
    const total = visibleResults.length
    const offset = Math.max(0, Math.floor(request.offset ?? 0))
    const limit = Math.min(200, Math.max(1, Math.floor(request.limit ?? 20)))
    const response = {
      results: visibleResults.slice(offset, offset + limit),
      total,
      interpretedQuery: [query || 'All files', dateIntent?.label].filter(Boolean).join(' · '),
      intent: plan?.intent ?? null,
      usedAi: plan?.usedAi ?? false
    }
    await this.database.recordRAGSearchTrace({
      query, semanticQuery, lexicalCandidates: lexicalById.size, semanticCandidates,
      entityCandidates: entity.size, fusedCandidates: fusedScores.size, returnedResults: response.results.length,
      semanticThreshold, reranker: rerankerConfiguration(settings)?.name ?? null,
      durationMs: performance.now() - startedAt
    })
    return response
  }
}

export function applyDisplayConfidencePolicy(results: LibrarySearchResult[]): LibrarySearchResult[] {
  const confident = results.filter((result) => result.confidence >= 0.50)
  const requiredCount = Math.min(3, results.length)
  if (confident.length >= requiredCount) return confident
  return confident.concat(results.filter((result) => result.confidence < 0.50).slice(0, requiredCount - confident.length))
}

function comparePlannedSort(left: LibrarySearchResult, right: LibrarySearchResult, sort: SmartSearchPlan['sort']): number {
  switch (sort) {
    case 'newest': return new Date(right.file.mtime).getTime() - new Date(left.file.mtime).getTime()
    case 'oldest': return new Date(left.file.mtime).getTime() - new Date(right.file.mtime).getTime()
    case 'largest': return right.file.size - left.file.size
    case 'smallest': return left.file.size - right.file.size
    case 'relevance': return 0
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
  const bounded = query
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2')
    .replace(/([A-Za-z0-9])(\p{Script=Han})/gu, '$1 $2')
    .replace(/(\p{Script=Han})([A-Za-z0-9])/gu, '$1 $2')
  return [...new Set((bounded.normalize('NFKC').toLocaleLowerCase().match(/[\p{L}\p{N}_-]+/gu) ?? []).filter((term) => term.length > 1 && !ignored.has(term) && !/^20\d{2}$/.test(term)))]
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
