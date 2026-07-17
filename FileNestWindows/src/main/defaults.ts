import { app } from 'electron'
import { join } from 'node:path'
import { totalmem } from 'node:os'
import type { FileCategory, Settings } from '../shared/types'

export const DEFAULT_EXTENSIONS = [
  'pdf', 'doc', 'docx', 'docm', 'txt', 'md', 'rtf', 'xls', 'xlsx', 'xlsm', 'ppt', 'pptx',
  'ppsx', 'csv', 'epub', 'odt', 'ods', 'odp', 'pages', 'numbers', 'key', 'keynote',
  'png', 'jpg', 'jpeg', 'gif', 'heic', 'tiff', 'tif', 'webp', 'bmp', 'svg', 'psd', 'sketch',
  'mp4', 'mov', 'avi', 'mkv', 'm4v', 'mp3', 'wav', 'aac', 'flac', 'm4a', 'swift', 'py',
  'js', 'ts', 'tsx', 'jsx', 'java', 'kt', 'go', 'rs', 'c', 'cpp', 'h', 'hpp', 'cs', 'rb',
  'php', 'sh', 'sql', 'json', 'yaml', 'yml', 'html', 'css', 'vue', 'lua', 'r', 'zip',
  'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'dmg'
]

export const DEFAULT_VECTOR_EXTENSIONS = [
  'pdf', 'doc', 'docx', 'docm', 'txt', 'md', 'markdown', 'rtf', 'xls', 'xlsx', 'xlsm',
  'ppt', 'pptx', 'ppsx', 'csv', 'epub', 'odt', 'ods', 'odp', 'pages', 'numbers', 'key',
  'keynote', 'png', 'jpg', 'jpeg', 'gif', 'heic', 'tiff', 'tif', 'webp', 'bmp', 'swift', 'py',
  'js', 'ts', 'tsx', 'jsx', 'java', 'kt', 'go', 'rs', 'c', 'cpp', 'h', 'hpp', 'cs',
  'rb', 'php', 'sh', 'sql', 'json', 'yaml', 'yml', 'html', 'css', 'vue', 'lua', 'r'
]

export const CATEGORY_FOLDERS: Record<FileCategory, string> = {
  documents: 'Documents',
  images: 'Images',
  videos: 'Videos',
  audio: 'Audio',
  code: 'Code',
  archives: 'Archives',
  other: 'Other'
}

export function createDefaultSettings(): Settings {
  const documents = app.getPath('documents')
  const memoryGb = Math.max(1, Math.round(totalmem() / 1024 ** 3))
  const chatModel = memoryGb >= 24 ? 'qwen3.5:9b' : memoryGb >= 16 ? 'qwen3.5:4b' : 'qwen3.5:2b'
  const embeddingModel = memoryGb >= 64 ? 'qwen3-embedding:8b' : memoryGb >= 32 ? 'qwen3-embedding:4b' : 'qwen3-embedding:0.6b'
  return {
    watchDirs: [...new Set([app.getPath('desktop'), app.getPath('downloads')])],
    organizedRoot: join(documents, 'FileNest Organized'),
    enabledExtensions: DEFAULT_EXTENSIONS,
    excludeHidden: true,
    classifyStrategy: 'hybrid',
    llmChoice: 'ollama',
    ollamaHost: 'http://127.0.0.1:11434',
    ollamaModel: chatModel,
    ollamaFlashAttentionEnabled: true,
    ollamaEmbeddingModel: embeddingModel,
    ollamaOcrModel: 'glm-ocr',
    cloudApiFormat: 'openai',
    cloudApiKey: '',
    cloudBaseUrl: 'https://api.openai.com/v1',
    cloudModel: 'gpt-4o-mini',
    cloudContextWindowTokens: 0,
    cloudEmbeddingBaseUrl: 'https://api.openai.com/v1',
    cloudEmbeddingApiKey: '',
    cloudEmbeddingModel: 'text-embedding-3-small',
    cloudEmbeddingReuseChatCredentials: false,
    cloudOcrFormat: 'openai',
    cloudOcrBaseUrl: 'https://api.openai.com/v1',
    cloudOcrApiKey: '',
    cloudOcrModel: 'gpt-4.1-mini',
    cloudOcrReuseChatCredentials: false,
    autoOrganize: true,
    autoOrganizeMode: 'batched',
    autoOrganizeIntervalSeconds: 30,
    autoOrganizeBatchSize: 5,
    autoVectorize: true,
    vectorizeExtensions: DEFAULT_VECTOR_EXTENSIONS,
    vectorChunkWords: 600,
    vectorChunkOverlap: 80,
    ragResultLimit: 10,
    doclingEnabled: true,
    doclingEndpoint: '',
    embeddingSource: 'local',
    ocrSource: 'local',
    thinkingMode: false,
    appLanguage: 'system',
    appearance: 'system',
    onboardingCompleted: false,
    launchAtLogin: false,
    automaticUpdateChecks: true,
    automaticallyDownloadsUpdates: false,
    updateFeedUrl: ''
  }
}
