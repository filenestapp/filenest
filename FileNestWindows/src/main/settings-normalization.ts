import type { Settings } from '../shared/types'
import { MEDIA_TRANSCRIPTION_EXTENSIONS } from './defaults'

const WHISPER_MODELS = new Set(['tiny', 'base', 'small', 'medium', 'turbo'])

export function normalizeSettingsPatch(patch: Partial<Settings>, current: Settings): Partial<Settings> {
  const result = { ...patch }
  if (result.vectorChunkWords != null) result.vectorChunkWords = Math.min(1000, Math.max(600, Math.round(result.vectorChunkWords)))
  const chunkWords = result.vectorChunkWords ?? current.vectorChunkWords
  if (result.vectorRetrievalChunkTokens != null) result.vectorRetrievalChunkTokens = Math.min(chunkWords, Math.max(120, Math.round(result.vectorRetrievalChunkTokens)))
  if (result.vectorChunkWords != null && current.vectorRetrievalChunkTokens > chunkWords && result.vectorRetrievalChunkTokens == null) result.vectorRetrievalChunkTokens = chunkWords
  const retrievalTokens = result.vectorRetrievalChunkTokens ?? Math.min(current.vectorRetrievalChunkTokens, chunkWords)
  if (result.vectorChunkOverlap != null) result.vectorChunkOverlap = Math.min(retrievalTokens - 1, Math.max(0, Math.round(result.vectorChunkOverlap)))
  else if ((result.vectorChunkWords != null || result.vectorRetrievalChunkTokens != null) && current.vectorChunkOverlap >= retrievalTokens) result.vectorChunkOverlap = Math.floor(retrievalTokens / 5)
  if (result.autoOrganizeIntervalSeconds != null) result.autoOrganizeIntervalSeconds = Math.min(3600, Math.max(30, Math.round(result.autoOrganizeIntervalSeconds)))
  if (result.autoOrganizeBatchSize != null) result.autoOrganizeBatchSize = Math.min(100, Math.max(2, Math.round(result.autoOrganizeBatchSize)))
  if (result.ragResultLimit != null) result.ragResultLimit = Math.min(30, Math.max(1, Math.round(result.ragResultLimit)))
  if (result.cloudContextWindowTokens != null) result.cloudContextWindowTokens = result.cloudContextWindowTokens === 0 ? 0 : Math.min(2_000_000, Math.max(4_096, Math.round(result.cloudContextWindowTokens)))
  if (result.enabledExtensions) result.enabledExtensions = [...new Set(result.enabledExtensions.map((value) => value.replace(/^\./, '').trim().toLowerCase()).filter(Boolean))]
  if (result.vectorizeExtensions) result.vectorizeExtensions = [...new Set(result.vectorizeExtensions.map((value) => value.replace(/^\./, '').trim().toLowerCase()).filter(Boolean))]
  if (result.mediaTranscriptionEnabled) {
    result.enabledExtensions = [...new Set([...(result.enabledExtensions ?? current.enabledExtensions), ...MEDIA_TRANSCRIPTION_EXTENSIONS])]
  }
  if (result.whisperModel != null) {
    const model = result.whisperModel.trim().toLowerCase()
    result.whisperModel = WHISPER_MODELS.has(model) ? model : 'base'
  }
  if (result.watchDirs) result.watchDirs = [...new Set(result.watchDirs)]
  if (result.updateFeedUrl != null) result.updateFeedUrl = result.updateFeedUrl.trim()
  if (result.rerankerBaseUrl != null) result.rerankerBaseUrl = result.rerankerBaseUrl.trim()
  if (result.rerankerModel != null) result.rerankerModel = result.rerankerModel.trim()
  if (result.rerankerSource && !['disabled', 'local', 'cloud'].includes(result.rerankerSource)) result.rerankerSource = 'disabled'
  if (result.cloudApiFormat && result.cloudApiFormat !== current.cloudApiFormat) {
    if (result.cloudApiFormat === 'anthropic') {
      if (current.cloudBaseUrl === 'https://api.openai.com/v1') result.cloudBaseUrl = 'https://api.anthropic.com/v1'
      if (current.cloudModel === 'gpt-4o-mini') result.cloudModel = 'claude-sonnet-5'
    } else {
      if (current.cloudBaseUrl === 'https://api.anthropic.com/v1') result.cloudBaseUrl = 'https://api.openai.com/v1'
      if (current.cloudModel === 'claude-sonnet-5') result.cloudModel = 'gpt-4o-mini'
    }
  }
  return result
}
