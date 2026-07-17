import type { AppLanguage } from '../../shared/types'
import simplifiedChinese from './zh-Hans.json'

const chinese = simplifiedChinese as Record<string, string>

export function resolveLanguage(language: AppLanguage): 'zh-Hans' | 'en' {
  if (language === 'system') return navigator.language.toLowerCase().startsWith('zh') ? 'zh-Hans' : 'en'
  return language
}

export function translate(value: string, language: AppLanguage): string {
  return resolveLanguage(language) === 'zh-Hans' ? chinese[value] ?? value : value
}

export function translateForDocument(value: string): string {
  return translate(value, document.documentElement.lang.toLowerCase().startsWith('zh') ? 'zh-Hans' : 'en')
}
