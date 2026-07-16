import { basename, extname, resolve, sep } from 'node:path'
import type { FileCategory, Settings } from '../shared/types'

const categories: Record<FileCategory, Set<string>> = {
  documents: new Set(['pdf', 'doc', 'docx', 'docm', 'txt', 'md', 'markdown', 'rtf', 'rtfd', 'pages', 'xls', 'xlsx', 'xlsm', 'ppt', 'pptx', 'ppsx', 'csv', 'key', 'keynote', 'numbers', 'epub', 'odt', 'ods', 'odp']),
  images: new Set(['png', 'jpg', 'jpeg', 'gif', 'heic', 'tiff', 'tif', 'bmp', 'svg', 'webp', 'psd', 'sketch']),
  videos: new Set(['mp4', 'mov', 'avi', 'mkv', 'm4v', 'wmv', 'flv', 'webm']),
  audio: new Set(['mp3', 'wav', 'aac', 'flac', 'm4a', 'ogg', 'aiff']),
  code: new Set(['swift', 'py', 'js', 'ts', 'tsx', 'jsx', 'java', 'kt', 'go', 'rs', 'c', 'cpp', 'h', 'hpp', 'cs', 'rb', 'php', 'sh', 'sql', 'json', 'yaml', 'yml', 'html', 'css', 'vue', 'lua', 'r']),
  archives: new Set(['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'dmg', 'iso']),
  other: new Set()
}

const ignoredNames = new Set(['thumbs.db', 'desktop.ini', '.ds_store'])
const ignoredExtensions = new Set(['crdownload', 'download', 'part', 'partial', 'tmp', 'temp', 'swp', 'swo', 'lock', 'lck', 'icloud'])

export function normalizedExtension(path: string): string {
  return extname(path).replace(/^\./, '').toLowerCase()
}

export function categoryForExtension(ext: string): FileCategory {
  const normalized = ext.toLowerCase()
  for (const [category, extensions] of Object.entries(categories) as Array<[FileCategory, Set<string>]>) {
    if (extensions.has(normalized)) return category
  }
  return 'other'
}

export function shouldIgnore(path: string, isDirectory: boolean, settings: Settings): boolean {
  if (settings.organizedRoot) {
    const candidate = resolve(path).toLocaleLowerCase()
    const organizedRoot = resolve(settings.organizedRoot).toLocaleLowerCase()
    if (candidate === organizedRoot || candidate.startsWith(organizedRoot + sep)) return true
  }
  const name = basename(path).toLowerCase()
  if (ignoredNames.has(name) || name.startsWith('~$') || name.startsWith('._') || name.endsWith('~')) return true
  if (settings.excludeHidden && basename(path).startsWith('.')) return true
  if (isDirectory) return false
  const ext = normalizedExtension(path)
  return ignoredExtensions.has(ext) || !settings.enabledExtensions.includes(ext)
}

export function matchesPattern(fileName: string, extension: string, pattern: string): boolean {
  const raw = pattern.trim().toLowerCase()
  if (!raw) return false
  const candidates = raw.split(/[;,\n]+/).map((item) => item.trim()).filter(Boolean)
  return candidates.some((candidate) => {
    if (candidate.startsWith('*.')) return extension === candidate.slice(2)
    if (candidate.startsWith('.')) return extension === candidate.slice(1)
    if (!candidate.includes('*') && !candidate.includes('?')) {
      return extension === candidate || fileName.toLowerCase().includes(candidate)
    }
    const escaped = candidate.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.')
    return new RegExp(`^${escaped}$`, 'i').test(fileName)
  })
}
