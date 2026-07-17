export type TokenCountAccuracy = 'exact' | 'estimated'

export const CANONICAL_TOKENIZER_PROFILE = 'qwen3-embedding:0.6b'
export const CANONICAL_TOKENIZER_VERSION = 'qwen3-embedding-0.6b-v1'
export const GENERATION_FALLBACK_PROFILE = 'generation-fallback:qwen3-compatible'
export const GENERATION_FALLBACK_VERSION = 'filenest-unicode-v1'

export interface TokenMeasurement {
  count: number
  tokenizerProfile: string
  tokenizerVersion: string
  accuracy: TokenCountAccuracy
}

export function estimateCanonicalTokens(
  text: string,
  tokenizerProfile = CANONICAL_TOKENIZER_PROFILE,
  tokenizerVersion = CANONICAL_TOKENIZER_VERSION
): TokenMeasurement {
  if (!text) return { count: 0, tokenizerProfile, tokenizerVersion, accuracy: 'estimated' }
  return {
    count: Math.max(1, Math.ceil(tokenUnits(text).reduce((sum, unit) => sum + unit.weight, 0))),
    tokenizerProfile,
    tokenizerVersion,
    accuracy: 'estimated'
  }
}

export interface WeightedTokenUnit {
  value: string
  weight: number
}

export function tokenUnits(text: string): WeightedTokenUnit[] {
  const values = text.match(/[\p{Script=Han}]|[A-Za-z0-9_'-]+|[^\s]/gu) ?? []
  return values.map((value) => ({
    value,
    weight: /^\p{Script=Han}$/u.test(value) ? 2 / 3 : /^[A-Za-z0-9_'-]+$/.test(value) ? 4 / 3 : 1
  }))
}
