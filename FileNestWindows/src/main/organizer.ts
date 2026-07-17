import { basename, dirname, extname, join, normalize, parse, resolve, sep } from 'node:path'
import { copyFile, cp, mkdir, rename, rm, stat } from 'node:fs/promises'
import type { FileRecord, Settings } from '../shared/types'
import { FileNestDatabase } from './database'
import { CATEGORY_FOLDERS } from './defaults'
import { matchesPattern } from './file-policy'
import { AppLogger } from './logger'
import { LlmService } from './llm'
import { ContentExtractor } from './content-extractor'

export class OrganizationError extends Error {
  constructor(readonly code: 'source-changed' | 'move-failed' | 'database-failed-rolled-back' | 'database-failed-rollback-failed', message: string, options?: ErrorOptions) {
    super(message, options)
    this.name = 'OrganizationError'
  }
}

export class OrganizerService {
  constructor(
    private readonly database: FileNestDatabase,
    private readonly logger: AppLogger,
    private readonly llm = new LlmService(),
    private readonly extractor = new ContentExtractor()
  ) {}

  async organize(file: FileRecord, settings: Settings): Promise<FileRecord> {
    if (!settings.autoOrganize) return file
    const decision = await this.destination(file, settings)
    if (!decision) return file
    const root = resolve(settings.organizedRoot)
    const folder = resolve(root, decision)
    if (folder !== root && !folder.startsWith(root + sep)) throw new Error('The rule target is outside the organization root')
    await mkdir(folder, { recursive: true })
    const target = await uniqueDestination(join(folder, basename(file.path)))
    if (normalize(target) === normalize(file.path)) return file
    if (file.contentHash) {
      const currentHash = await this.extractor.hash(file.path, file.isDirectory).catch(() => null)
      if (currentHash !== file.contentHash) {
        throw new OrganizationError('source-changed', 'The item changed after indexing and must be indexed again before it can be moved')
      }
    }
    try {
      await movePath(file.path, target, file.isDirectory)
    } catch (error) {
      throw new OrganizationError('move-failed', `Unable to move ${file.name}`, { cause: error })
    }
    try {
      await this.database.updateFile(file.id, { path: target, name: basename(target), organizedAt: new Date().toISOString(), organizationSubfolder: decision })
      return this.database.getFile(file.id)!
    } catch (error) {
      try {
        await movePath(target, file.path, file.isDirectory)
      } catch (rollbackError) {
        await this.logger.log('organizer', `Database update and physical rollback both failed: ${target}`, rollbackError)
        throw new OrganizationError('database-failed-rollback-failed', `The database update and rollback both failed for ${file.name}`, { cause: error })
      }
      throw new OrganizationError('database-failed-rolled-back', `The database update failed and the move was rolled back for ${file.name}`, { cause: error })
    }
  }

  async organizeAll(settings: Settings): Promise<void> {
    for (const file of this.database.listFiles().filter((item) => !item.organizedAt)) {
      await this.organize(file, settings).catch((error) => this.logger.log('organizer', `Organization failed: ${file.path}`, error))
    }
  }

  private async destination(file: FileRecord, settings: Settings): Promise<string | null> {
    for (const rule of this.database.listRules().filter((item) => item.enabled && item.type === 'rule').sort((a, b) => b.priority - a.priority)) {
      if (!matchesPattern(file.name, file.ext, rule.pattern)) continue
      if (rule.action === 'ignore') return null
      const target = safeRelative(rule.targetFolder)
      if (!(settings.classifyStrategy === 'hybrid' && target === CATEGORY_FOLDERS[file.category])) return target
    }
    if (settings.classifyStrategy === 'rule') return null
    const category = CATEGORY_FOLDERS[file.category]
    const topic = await this.classifySubfolder(file, settings).catch((error) => {
      void this.logger.log('organizer', `AI secondary-folder classification failed: ${file.path}`, error)
      return null
    })
    return topic ? `${category}/${topic}` : file.organizationSubfolder || category
  }

  private async classifySubfolder(file: FileRecord, settings: Settings): Promise<string | null> {
    if (settings.llmChoice === 'none') return null
    const context = [
      `File name: ${file.name}`,
      `Title: ${file.title ?? ''}`,
      `User note: ${file.note ?? ''}`,
      `Content: ${(file.contentText ?? '').slice(0, 2_000)}`
    ].join('\n')
    if (!file.title && !file.note && !file.contentText) return null
    const response = await this.llm.complete([
      { role: 'system', content: 'You are a local file topic classifier. The file is already in a primary folder based on its extension. Choose a short, stable, reusable topic subfolder based on its title, user note, and content. Return JSON only: {"folder":"subfolder name"}. Use 2 to 20 characters. Do not include /, \\, :, a file type, or an extension. Do not explain. Prefer reusable topics such as Contracts, Invoices, Project Materials, Meeting Notes, Learning Materials, Product Design, Travel, or Finance. Do not copy the complete file name.' },
      { role: 'user', content: context }
    ], settings, 20_000)
    const match = response.match(/\{[\s\S]*\}/)
    if (!match) return null
    const payload = JSON.parse(match[0]) as { folder?: unknown }
    if (typeof payload.folder !== 'string') return null
    const folder = safeTopic(payload.folder)
    return folder.length >= 2 && folder.length <= 40 ? folder : null
  }
}

function safeRelative(input: string): string {
  const rawParts = input.replace(/^[/\\]+/, '').split(/[/\\]/)
  if (!rawParts.length || rawParts.some((part) => part === '..')) throw new Error('Invalid destination folder')
  const parts = rawParts.map(safeTopic)
  if (parts.some((part) => !part)) throw new Error('Invalid destination folder')
  return parts.join(sep)
}

function safeTopic(input: string): string {
  const cleaned = input.replace(/[<>:"/\\|?*\u0000-\u001F]/g, '').trim().replace(/[. ]+$/g, '')
  return /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$/i.test(cleaned) ? '' : cleaned
}

async function uniqueDestination(path: string): Promise<string> {
  try {
    await stat(path)
  } catch {
    return path
  }
  const info = parse(path)
  for (let index = 2; index < 10_000; index += 1) {
    const candidate = join(info.dir, `${info.name} (${index})${info.ext}`)
    try {
      await stat(candidate)
    } catch {
      return candidate
    }
  }
  throw new Error('Unable to generate a conflict-free file name')
}

async function movePath(source: string, target: string, isDirectory: boolean): Promise<void> {
  await mkdir(dirname(target), { recursive: true })
  try {
    await rename(source, target)
  } catch (error) {
    if (!(error instanceof Error && 'code' in error && error.code === 'EXDEV')) throw error
    if (isDirectory) await cp(source, target, { recursive: true, errorOnExist: true })
    else await copyFile(source, target)
    await rm(source, { recursive: isDirectory, force: false })
  }
}
