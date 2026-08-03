import { app } from 'electron'
import { copyFile, mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, join, relative, resolve } from 'node:path'
import type { AgentSkill, AgentSkillCapability, AgentSkillDiagnostic, AgentSkillExecutionRoute } from '../shared/types'
import { FileNestDatabase } from './database'

interface ParsedSkill {
  name: string
  description: string
  metadata: Record<string, string>
  allowedTools: string | null
  body: string
}

export interface AgentSkillActivation {
  names: string[]
  context: string
  executionRoute: AgentSkillExecutionRoute | null
}

const DISABLED_NAMES_KEY = 'agent_skills.disabled_names.v1'
const ENABLED_NAMES_KEY = 'agent_skills.enabled_names.v1'
const MAX_SKILL_BYTES = 512_000
const MAX_ACTIVATION_CHARS = 20_000
const SKILL_NAME = /^[a-z0-9]+(?:-[a-z0-9]+)*$/

export class AgentSkillService {
  private skills: AgentSkill[] = []
  private diagnostics: AgentSkillDiagnostic[] = []
  readonly managedDirectory = join(app.getPath('userData'), 'Skills')
  readonly sharedDirectory = join(homedir(), '.agents', 'skills')
  readonly bundledDirectory = app.isPackaged
    ? join(process.resourcesPath, 'Skills')
    : join(process.cwd(), 'resources', 'Skills')

  constructor(private readonly database: FileNestDatabase) {}

  async refresh(): Promise<AgentSkill[]> {
    const disabled = this.namesFor(DISABLED_NAMES_KEY)
    const enabledShared = this.namesFor(ENABLED_NAMES_KEY)
    const candidates = new Map<string, AgentSkill[]>()
    const diagnostics: AgentSkillDiagnostic[] = []
    for (const [directory, origin] of [
      [this.bundledDirectory, 'bundled'],
      [this.sharedDirectory, 'sharedUser'],
      [this.managedDirectory, 'managed']
    ] as const) {
      const found = await this.discover(directory, origin, disabled, enabledShared)
      diagnostics.push(...found.diagnostics)
      for (const skill of found.skills) candidates.set(skill.name, [...(candidates.get(skill.name) ?? []), skill])
    }
    const precedence: Record<AgentSkill['origin'], number> = { bundled: 0, sharedUser: 1, managed: 2 }
    this.skills = [...candidates.values()].map((items) => {
      const ordered = [...items].sort((left, right) => precedence[right.origin] - precedence[left.origin])
      const selected = ordered.find((skill) => skill.enabled) ?? ordered[0]
      for (const candidate of ordered) {
        if (candidate.skillFilePath === selected.skillFilePath) continue
        diagnostics.push({
          path: candidate.skillFilePath,
          severity: 'warning',
          message: candidate.enabled
            ? `A higher-precedence skill named ${candidate.name} shadows this package.`
            : `This disabled package does not shadow the active ${selected.origin} skill named ${candidate.name}.`
        })
      }
      return selected
    }).sort((left, right) => left.name.localeCompare(right.name))
    this.diagnostics = diagnostics
    return this.skills
  }

  all(): AgentSkill[] { return this.skills }
  allDiagnostics(): AgentSkillDiagnostic[] { return this.diagnostics }

  async setEnabled(skillPath: string, enabled: boolean): Promise<void> {
    const skill = this.skills.find((item) => item.skillFilePath === skillPath)
    if (!skill || skill.origin === 'bundled') return
    const disabled = this.namesFor(DISABLED_NAMES_KEY)
    const enabledShared = this.namesFor(ENABLED_NAMES_KEY)
    if (enabled) {
      disabled.delete(skill.name)
      if (skill.origin === 'sharedUser') enabledShared.add(skill.name)
    } else {
      disabled.add(skill.name)
      enabledShared.delete(skill.name)
    }
    await this.saveNames(DISABLED_NAMES_KEY, disabled)
    await this.saveNames(ENABLED_NAMES_KEY, enabledShared)
    await this.refresh()
  }

  async importPackage(skillFilePath: string): Promise<AgentSkill> {
    const source = resolve(skillFilePath)
    if (basename(source) !== 'SKILL.md') throw new Error('Select a SKILL.md file to add')
    const parsed = await parseSkill(source)
    if (!parsed || !SKILL_NAME.test(parsed.name)) throw new Error('The selected SKILL.md package is invalid')
    const destination = join(this.managedDirectory, parsed.name)
    if (existsSync(destination)) throw new Error('A FileNest-managed skill with this name already exists')
    await mkdir(this.managedDirectory, { recursive: true })
    await copyDirectory(resolve(source, '..'), destination)
    const disabled = this.namesFor(DISABLED_NAMES_KEY)
    disabled.delete(parsed.name)
    await this.saveNames(DISABLED_NAMES_KEY, disabled)
    await this.refresh()
    const imported = this.skills.find((skill) => skill.name === parsed.name && skill.origin === 'managed')
    if (!imported) throw new Error('The added skill could not be loaded')
    return imported
  }

  async deleteManagedPackage(skillPath: string): Promise<void> {
    const skill = this.skills.find((item) => item.skillFilePath === skillPath)
    if (!skill || skill.origin !== 'managed') throw new Error('Only FileNest-managed skills can be removed')
    const packageDirectory = resolve(skill.skillFilePath, '..')
    const expectedDirectory = resolve(this.managedDirectory, skill.name)
    if (packageDirectory !== expectedDirectory) throw new Error('The selected skill package is outside the managed skills folder')
    await rm(packageDirectory, { recursive: true, force: true })
    const disabled = this.namesFor(DISABLED_NAMES_KEY)
    const enabledShared = this.namesFor(ENABLED_NAMES_KEY)
    disabled.delete(skill.name)
    enabledShared.delete(skill.name)
    await this.saveNames(DISABLED_NAMES_KEY, disabled)
    await this.saveNames(ENABLED_NAMES_KEY, enabledShared)
    await this.refresh()
  }

  async instructionBody(name: string): Promise<string | null> {
    const skill = this.skills.find((item) => item.name === name)
    if (!skill) return null
    return (await parseSkill(skill.skillFilePath))?.body ?? null
  }

  async evolveSkill(name: string, description: string | null, instruction: string, rationale: string | null): Promise<AgentSkill | null> {
    const target = this.skills.find((item) => item.name === name)
    const parsed = target ? await parseSkill(target.skillFilePath) : null
    if (!target || !parsed) return null
    const normalizedInstruction = collapseWhitespace(instruction)
    if (!normalizedInstruction) return target
    const learnedSection = parsed.body.includes('## Learned Adjustments') ? '' : '\n\n## Learned Adjustments'
    const adjustment = parsed.body.toLowerCase().includes(normalizedInstruction.toLowerCase()) ? '' : `\n\n- ${normalizedInstruction}${rationale ? `\n  Rationale: ${collapseWhitespace(rationale)}` : ''}`
    return this.writeManagedSkill({
      name: target.name,
      description: clampText(description || parsed.description, 1_024),
      title: titleForSkill(target.name),
      metadata: { ...parsed.metadata, 'filenest-origin': 'feedback-learning', 'filenest-parent-origin': target.origin, 'filenest-version': String(Math.max(1, Number(parsed.metadata['filenest-version'] ?? 0) + 1)) },
      body: `${parsed.body}${adjustment ? learnedSection + adjustment : ''}`
    })
  }

  async upsertLearnedSkill(name: string, description: string, title: string, scope: 'search' | 'answer' | 'both', instructions: string, rationale: string | null): Promise<AgentSkill | null> {
    if (!SKILL_NAME.test(name)) throw new Error('The learned skill name is invalid')
    const body = `# ${clampText(title, 100)}\n\n${collapseWhitespace(instructions)}${rationale ? `\n\n## Rationale\n\n${collapseWhitespace(rationale)}` : ''}`
    return this.writeManagedSkill({
      name,
      description: clampText(description, 1_024),
      title: clampText(title, 100),
      metadata: { 'filenest-origin': 'feedback-learning', 'filenest-scope': scope, 'filenest-version': '1' },
      body
    })
  }

  async activate(capability: AgentSkillCapability, task: string): Promise<AgentSkillActivation> {
    const explicitNames = extractExplicitNames(task)
    const capabilityValue = capability
    const selected = this.skills.filter((skill) => skill.enabled && (
      explicitNames.includes(skill.name)
      || skill.metadata['filenest-auto-activate'] === capabilityValue
      || scopeMatchesCapability(skill.metadata['filenest-scope'], capabilityValue)
      || matchesSkillIntent(skill.metadata['filenest-intent'], task)
    ))
    const unique = [...new Map(selected.map((skill) => [skill.name, skill])).values()]
    const loaded = await Promise.all(unique.map(async (skill) => ({ skill, parsed: await parseSkill(skill.skillFilePath) })))
    const context = loaded.flatMap(({ skill, parsed }) => parsed ? [
      `<skill_content name="${skill.name}">`,
      parsed.body.slice(0, MAX_ACTIVATION_CHARS),
      '</skill_content>'
    ] : []).join('\n\n')
    const preferences = loaded.flatMap(({ skill }) => {
      const value = skill.metadata['filenest-execution-route'] as AgentSkillExecutionRoute | undefined
      return value === 'retrieval' || value === 'complete-document' || value === 'map-reduce'
        ? [{ value, priority: Number(skill.metadata['filenest-route-priority'] ?? 0) || 0 }]
        : []
    }).sort((left, right) => right.priority - left.priority)
    return { names: unique.map((skill) => skill.name), context, executionRoute: preferences[0]?.value ?? null }
  }

  private async discover(directory: string, origin: AgentSkill['origin'], disabled: Set<string>, enabledShared: Set<string>): Promise<{ skills: AgentSkill[]; diagnostics: AgentSkillDiagnostic[] }> {
    const diagnostics: AgentSkillDiagnostic[] = []
    const skills: AgentSkill[] = []
    const entries = await readdir(directory, { withFileTypes: true }).catch(() => [])
    for (const entry of entries) {
      if (!entry.isDirectory()) continue
      const skillFilePath = join(directory, entry.name, 'SKILL.md')
      const parsed = await parseSkill(skillFilePath)
      if (!parsed) continue
      if (!SKILL_NAME.test(parsed.name)) {
        diagnostics.push({ path: skillFilePath, severity: 'error', message: 'The skill name does not follow Agent Skills naming rules.' })
        continue
      }
      const resources = await listResources(join(directory, entry.name))
      const enabled = origin === 'bundled' || (!disabled.has(parsed.name) && (origin !== 'sharedUser' || enabledShared.has(parsed.name)))
      skills.push({ name: parsed.name, description: parsed.description, metadata: parsed.metadata, allowedTools: parsed.allowedTools, skillFilePath, origin, resources, diagnostics: [], enabled })
    }
    return { skills, diagnostics }
  }

  private namesFor(key: string): Set<string> {
    try { return new Set(JSON.parse(this.database.getInternalSetting(key) ?? '[]') as string[]) } catch { return new Set() }
  }

  private async saveNames(key: string, names: Set<string>): Promise<void> {
    await this.database.setInternalSetting(key, JSON.stringify([...names].sort()))
  }

  private async writeManagedSkill(input: { name: string; description: string; title: string; metadata: Record<string, string>; body: string }): Promise<AgentSkill | null> {
    const directory = resolve(this.managedDirectory, input.name)
    const root = resolve(this.managedDirectory)
    if (!directory.startsWith(`${root}/`)) throw new Error('The learned skill destination is invalid')
    await mkdir(directory, { recursive: true })
    const metadata = Object.entries(input.metadata).map(([key, value]) => `  ${key}: "${yamlValue(value)}"`).join('\n')
    const source = `---\nname: ${input.name}\ndescription: "${yamlValue(input.description)}"\nmetadata:\n${metadata}\n---\n\n${input.body.trim()}\n`
    await writeFile(join(directory, 'SKILL.md'), source, 'utf8')
    const disabled = this.namesFor(DISABLED_NAMES_KEY)
    disabled.delete(input.name)
    await this.saveNames(DISABLED_NAMES_KEY, disabled)
    await this.refresh()
    return this.skills.find((skill) => skill.name === input.name && skill.origin === 'managed') ?? null
  }
}

async function parseSkill(path: string): Promise<ParsedSkill | null> {
  const info = await stat(path).catch(() => null)
  if (!info || !info.isFile() || info.size > MAX_SKILL_BYTES) return null
  const source = await readFile(path, 'utf8').catch(() => '')
  const match = source.match(/^---\s*\n([\s\S]*?)\n---\s*\n?([\s\S]*)$/)
  if (!match) return null
  const metadata: Record<string, string> = {}
  let inMetadata = false
  for (const line of match[1].split(/\r?\n/)) {
    if (/^metadata:\s*$/.test(line)) { inMetadata = true; continue }
    const value = line.match(/^(\s+)?([A-Za-z0-9_-]+):\s*["']?(.*?)["']?\s*$/)
    if (!value) continue
    const [, indent, key, raw] = value
    if (indent && !inMetadata) continue
    if (indent) metadata[key] = raw
    else {
      inMetadata = false
      if (key === 'name') metadata.__name = raw
      if (key === 'description') metadata.__description = raw
      if (key === 'allowed-tools') metadata.__allowedTools = raw
    }
  }
  const name = metadata.__name ?? ''
  const description = metadata.__description ?? ''
  delete metadata.__name
  delete metadata.__description
  const allowedTools = metadata.__allowedTools ?? null
  delete metadata.__allowedTools
  return name && description ? { name, description, metadata, allowedTools, body: match[2].trim() } : null
}

async function listResources(directory: string): Promise<Array<{ relativePath: string; kind: string }>> {
  const output: Array<{ relativePath: string; kind: string }> = []
  const visit = async (current: string): Promise<void> => {
    const entries = await readdir(current, { withFileTypes: true }).catch(() => [])
    for (const entry of entries) {
      if (output.length >= 100) return
      const path = join(current, entry.name)
      if (entry.isDirectory()) await visit(path)
      else if (entry.name !== 'SKILL.md') output.push({ relativePath: relative(directory, path), kind: entry.name.endsWith('.md') ? 'reference' : 'resource' })
    }
  }
  await visit(directory)
  return output
}

async function copyDirectory(source: string, destination: string): Promise<void> {
  await mkdir(destination, { recursive: false })
  const entries = await readdir(source, { withFileTypes: true })
  for (const entry of entries) {
    const sourcePath = join(source, entry.name)
    const destinationPath = join(destination, entry.name)
    if (entry.isDirectory()) await copyDirectory(sourcePath, destinationPath)
    else if (entry.isFile()) await copyFile(sourcePath, destinationPath)
  }
}

function extractExplicitNames(task: string): string[] {
  return [...task.matchAll(/\$([a-z0-9]+(?:-[a-z0-9]+)*)/gi)].map((match) => match[1].toLowerCase())
}

function matchesSkillIntent(intent: string | undefined, task: string): boolean {
  if (intent !== 'long-document') return false
  const normalized = task.toLowerCase()
  const requestsDocumentWork = /translate|translation|summari[sz]e|summary|\u5168\u6587|\u6574\u4efd|\u6574\u4e2a\u6587\u6863|\u7ffb\u8bd1|\u603b\u7ed3/.test(normalized)
  const requestsFullCoverage = /entire|whole|full document|complete document|\u5168\u6587|\u6574\u4efd|\u6574\u4e2a\u6587\u6863/.test(normalized)
  const requestsNarrowScope = /page\s*\d|chapter|section|paragraph|\u7b2c\s*\d+\s*\u9875|\u7ae0\u8282|\u6bb5\u843d/.test(normalized)
  return requestsDocumentWork && requestsFullCoverage && !requestsNarrowScope
}

function scopeMatchesCapability(scope: string | undefined, capability: AgentSkillCapability): boolean {
  if (capability === 'search') return scope === 'search' || scope === 'both'
  if (capability === 'library-answer' || capability === 'attached-file-answer') return scope === 'answer' || scope === 'both'
  return false
}

function collapseWhitespace(value: string): string { return value.trim().replace(/\s+/g, ' ') }
function clampText(value: string, maximum: number): string { return collapseWhitespace(value).slice(0, maximum) }
function yamlValue(value: string): string { return value.replace(/[\r\n]+/g, ' ').replace(/"/g, "'") }
function titleForSkill(name: string): string { return name.split('-').map((part) => part[0]?.toUpperCase() + part.slice(1)).join(' ') }
