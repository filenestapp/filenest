import type { Settings } from '../shared/types'

export interface RerankItem {
  index: number
  score: number
}

export interface RerankerConfiguration {
  name: string
  baseUrl: string
  apiKey: string
  model: string
}

export function rerankerConfiguration(settings: Settings): RerankerConfiguration | null {
  if (settings.rerankerSource === 'disabled') return null
  if (settings.rerankerSource === 'cloud' && settings.rerankerReuseChatCredentials) {
    return { name: 'cloud-reranker', baseUrl: settings.cloudBaseUrl, apiKey: settings.cloudApiKey, model: settings.rerankerModel }
  }
  return {
    name: settings.rerankerSource === 'local' ? 'local-reranker' : 'cloud-reranker',
    baseUrl: settings.rerankerBaseUrl,
    apiKey: settings.rerankerApiKey,
    model: settings.rerankerModel
  }
}

export async function rerankDocuments(
  query: string,
  documents: string[],
  settings: Settings,
  signal?: AbortSignal
): Promise<RerankItem[]> {
  const configuration = rerankerConfiguration(settings)
  if (!configuration || !query.trim() || !documents.length) return []
  const response = await fetch(rerankerEndpoint(configuration.baseUrl), {
    method: 'POST',
    signal: signal ?? AbortSignal.timeout(45_000),
    headers: {
      'content-type': 'application/json',
      ...(configuration.apiKey ? { authorization: `Bearer ${configuration.apiKey}` } : {})
    },
    body: JSON.stringify({
      model: configuration.model,
      query,
      documents,
      top_n: documents.length
    })
  })
  if (!response.ok) throw new Error(`Reranker ${response.status}: ${(await response.text()).slice(0, 240)}`)
  const payload = await response.json() as { results?: Array<Record<string, unknown>>; data?: Array<Record<string, unknown>> }
  const values = payload.results ?? payload.data
  if (!Array.isArray(values)) throw new Error('The reranker returned an invalid response')
  return values.flatMap((value) => {
    const index = Number(value.index)
    const score = Number(value.relevance_score ?? value.score)
    return Number.isInteger(index) && index >= 0 && index < documents.length && Number.isFinite(score)
      ? [{ index, score }]
      : []
  }).sort((left, right) => right.score - left.score)
}

export function rerankerEndpoint(baseUrl: string): URL {
  const url = new URL(baseUrl.trim())
  const path = url.pathname.replace(/^\/+|\/+$/g, '')
  url.pathname = `/${path.endsWith('rerank') ? path : path.endsWith('v1') ? `${path}/rerank` : `${path ? `${path}/` : ''}v1/rerank`}`
  return url
}

export function dynamicallyAcceptedSemanticHits<T extends { score: number }>(hits: T[]): { hits: T[]; threshold: number | null } {
  const finite = hits.filter((hit) => Number.isFinite(hit.score)).sort((left, right) => right.score - left.score)
  const top = finite[0]?.score
  if (top == null || top < 0.38) return { hits: [], threshold: null }
  const threshold = Math.max(0.38, top - 0.18)
  return { hits: finite.filter((hit) => hit.score >= threshold), threshold }
}

export function weightedReciprocalRankFusion(
  lanes: Array<{ weight: number; ids: number[] }>,
  constant = 60
): Map<number, number> {
  const scores = new Map<number, number>()
  for (const lane of lanes) {
    lane.ids.forEach((id, index) => scores.set(id, (scores.get(id) ?? 0) + lane.weight / (constant + index + 1)))
  }
  return scores
}
