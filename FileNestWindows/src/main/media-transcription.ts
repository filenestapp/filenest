import { app } from 'electron'
import AdmZip from 'adm-zip'
import { randomUUID } from 'node:crypto'
import { createWriteStream, existsSync } from 'node:fs'
import { copyFile, mkdir, readFile, readdir, rename, rm, writeFile } from 'node:fs/promises'
import { basename, dirname, join } from 'node:path'
import { Readable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { spawn } from 'node:child_process'
import type { DocumentChunk, ManagedMediaServiceStatus } from '../shared/types'
import { estimateCanonicalTokens } from './token-counter'

export const WHISPER_MODELS = [
  { id: 'tiny', detail: 'Fastest; suitable for clear speech' },
  { id: 'base', detail: 'Recommended multilingual default' },
  { id: 'small', detail: 'Higher accuracy on 16 GB or more' },
  { id: 'medium', detail: 'High accuracy; slower locally' },
  { id: 'turbo', detail: 'Fast large-model transcription' }
] as const

const WHISPER_VERSION = '20250625'
const FFMPEG_DOWNLOAD_URL = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'

interface PythonCommand { executable: string; prefix: string[] }
interface WhisperSegment { start: number; end: number; text: string }
interface WhisperPayload { text: string; language?: string; segments: WhisperSegment[] }

export class MediaTranscriptionManager {
  private ffmpegStatus = emptyStatus('FFmpeg is not installed')
  private whisperStatus = emptyStatus('Whisper is not installed')
  private transcriptionChain: Promise<unknown> = Promise.resolve()
  onChanged?: () => void

  private get servicesRoot(): string { return join(app.getPath('userData'), 'services') }
  private get ffmpegRoot(): string { return join(this.servicesRoot, 'ffmpeg') }
  private get managedFfmpeg(): string { return join(this.ffmpegRoot, process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg') }
  private get whisperRoot(): string { return join(this.servicesRoot, 'whisper') }
  private get whisperPython(): string { return join(this.whisperRoot, 'venv', process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python') }
  private get modelRoot(): string { return join(this.whisperRoot, 'models') }

  ffmpeg(): ManagedMediaServiceStatus { return { ...this.ffmpegStatus, installedModels: [] } }
  whisper(): ManagedMediaServiceStatus { return { ...this.whisperStatus, installedModels: [...this.whisperStatus.installedModels] } }

  async refresh(): Promise<void> {
    const ffmpeg = await this.resolveFfmpeg()
    const ffmpegVersion = ffmpeg ? await commandOutput(ffmpeg, ['-version'], 15_000).catch(() => '') : ''
    this.ffmpegStatus = ffmpeg
      ? readyStatus(firstVersionLine(ffmpegVersion, 'ffmpeg version '), `FFmpeg ${firstVersionLine(ffmpegVersion, 'ffmpeg version ') ?? 'ready'}`)
      : emptyStatus('FFmpeg is not installed')

    const installedModels = await this.detectInstalledModels()
    const installedVersion = existsSync(this.whisperPython)
      ? (await readFile(join(this.whisperRoot, 'version.txt'), 'utf8').catch(() => WHISPER_VERSION)).trim()
      : null
    this.whisperStatus = installedVersion
      ? { ...readyStatus(installedVersion, `Whisper ${installedVersion}`), installedModels }
      : { ...emptyStatus('Whisper is not installed'), installedModels }
    this.onChanged?.()
  }

  async installFfmpeg(): Promise<void> {
    if (this.ffmpegStatus.installing) return
    this.setFfmpeg({ state: 'installing', installing: true, progress: 0.05, message: 'Preparing FFmpeg installation…', error: null })
    const staging = join(this.servicesRoot, `ffmpeg.installing-${randomUUID()}`)
    try {
      await mkdir(staging, { recursive: true })
      if (process.platform === 'win32') {
        const archive = join(staging, 'ffmpeg.zip')
        this.setFfmpeg({ progress: 0.15, message: 'Downloading FFmpeg…' })
        await downloadToFile(FFMPEG_DOWNLOAD_URL, archive)
        this.setFfmpeg({ progress: 0.72, message: 'Installing FFmpeg…' })
        const extracted = join(staging, 'extracted')
        await mkdir(extracted, { recursive: true })
        new AdmZip(archive).extractAllTo(extracted, true)
        const executable = await findFile(extracted, 'ffmpeg.exe')
        if (!executable) throw new Error('The FFmpeg archive did not contain ffmpeg.exe')
        await mkdir(this.ffmpegRoot, { recursive: true })
        await copyFile(executable, this.managedFfmpeg)
      } else {
        const existing = await this.resolveFfmpeg()
        if (!existing) throw new Error('Install FFmpeg with Homebrew before enabling media transcription on this development host')
      }
      const resolved = await this.resolveFfmpeg()
      if (!resolved) throw new Error('FFmpeg was not found after installation')
      await commandOutput(resolved, ['-version'], 30_000)
      this.setFfmpeg({ state: 'ready', installing: false, progress: 1, message: 'FFmpeg installation complete', error: null })
      await this.refresh()
    } catch (error) {
      const message = errorMessage(error)
      this.setFfmpeg({ state: 'failed', installing: false, progress: null, message: 'FFmpeg installation failed', error: message })
      throw error
    } finally {
      await rm(staging, { recursive: true, force: true }).catch(() => undefined)
    }
  }

  async installWhisper(): Promise<void> {
    if (this.whisperStatus.installing) return
    const systemPython = await resolvePython()
    if (!systemPython) throw new Error('Python 3.10 or later is required to install Whisper')
    const staging = join(this.servicesRoot, `whisper.installing-${randomUUID()}`)
    const backup = join(this.servicesRoot, `whisper.backup-${randomUUID()}`)
    this.setWhisper({ state: 'installing', installing: true, progress: 0.05, message: 'Creating an isolated Whisper environment…', error: null })
    try {
      await mkdir(staging, { recursive: true })
      const venv = join(staging, 'venv')
      await run(systemPython.executable, [...systemPython.prefix, '-m', 'venv', venv], 180_000)
      const python = join(venv, process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python')
      this.setWhisper({ progress: 0.25, message: 'Downloading and installing OpenAI Whisper…' })
      await run(python, ['-m', 'pip', 'install', '--disable-pip-version-check', `openai-whisper==${WHISPER_VERSION}`], 30 * 60_000)
      this.setWhisper({ progress: 0.88, message: 'Verifying the Whisper installation…' })
      await run(python, ['-c', 'import whisper; print(whisper.__version__)'], 60_000)
      await writeFile(join(staging, 'version.txt'), WHISPER_VERSION, 'utf8')
      await mkdir(join(staging, 'models'), { recursive: true })
      const hadExisting = existsSync(this.whisperRoot)
      if (hadExisting) await rename(this.whisperRoot, backup)
      try {
        await rename(staging, this.whisperRoot)
        if (hadExisting) await rm(backup, { recursive: true, force: true })
      } catch (error) {
        if (hadExisting && !existsSync(this.whisperRoot)) await rename(backup, this.whisperRoot).catch(() => undefined)
        throw error
      }
      this.setWhisper({ state: 'ready', installing: false, progress: 1, message: 'Whisper installation complete', error: null })
      await this.refresh()
    } catch (error) {
      const message = errorMessage(error)
      this.setWhisper({ state: 'failed', installing: false, progress: null, message: 'Whisper installation failed', error: message })
      throw error
    } finally {
      await rm(staging, { recursive: true, force: true }).catch(() => undefined)
    }
  }

  async downloadWhisperModel(requestedModel: string): Promise<void> {
    const model = normalizeWhisperModel(requestedModel)
    if (!existsSync(this.whisperPython)) throw new Error('Install the Whisper runtime first')
    if (this.whisperStatus.installing) return
    this.setWhisper({ state: 'installing', installing: true, installingModel: model, progress: 0.05, message: `Downloading the Whisper ${model} model…`, error: null })
    try {
      await mkdir(this.modelRoot, { recursive: true })
      const ffmpeg = await this.resolveFfmpeg()
      const env = ffmpeg ? withExecutableOnPath(process.env, ffmpeg) : process.env
      await run(this.whisperPython, ['-c', 'import sys, whisper; whisper.load_model(sys.argv[1], download_root=sys.argv[2])', model, this.modelRoot], 60 * 60_000, env)
      this.setWhisper({ state: 'ready', installing: false, installingModel: null, progress: 1, message: 'Whisper model download complete', error: null })
      await this.refresh()
    } catch (error) {
      const message = errorMessage(error)
      this.setWhisper({ state: 'failed', installing: false, installingModel: null, progress: null, message: 'Whisper model download failed', error: message })
      throw error
    }
  }

  async deleteWhisperModel(requestedModel: string): Promise<void> {
    const model = normalizeWhisperModel(requestedModel)
    const candidates = [`${model}.pt`, model === 'turbo' ? 'large-v3-turbo.pt' : '']
    for (const candidate of candidates.filter(Boolean)) await rm(join(this.modelRoot, candidate), { force: true })
    await this.refresh()
  }

  async transcribe(path: string, requestedModel: string): Promise<WhisperPayload> {
    const task = this.transcriptionChain.then(() => this.performTranscription(path, requestedModel))
    this.transcriptionChain = task.catch(() => undefined)
    return task
  }

  private async performTranscription(path: string, requestedModel: string): Promise<WhisperPayload> {
    const model = normalizeWhisperModel(requestedModel)
    const ffmpeg = await this.resolveFfmpeg()
    if (!ffmpeg) throw new Error('FFmpeg is required for media transcription')
    if (!existsSync(this.whisperPython) || !(await this.detectInstalledModels()).includes(model)) {
      throw new Error(`The Whisper ${model} model is not installed`)
    }
    const output = join(app.getPath('temp'), `filenest-whisper-${randomUUID()}.json`)
    try {
      const script = [
        'import json, sys, whisper',
        'model = whisper.load_model(sys.argv[1], download_root=sys.argv[2])',
        'result = model.transcribe(sys.argv[3], verbose=False, fp16=False, task="transcribe")',
        'payload = {"text": result.get("text", ""), "language": result.get("language"), "segments": [{"start": s.get("start", 0), "end": s.get("end", 0), "text": s.get("text", "")} for s in result.get("segments", [])]}',
        'open(sys.argv[4], "w", encoding="utf-8").write(json.dumps(payload, ensure_ascii=False))'
      ].join('; ')
      await run(this.whisperPython, ['-c', script, model, this.modelRoot, path, output], 4 * 60 * 60_000, withExecutableOnPath(process.env, ffmpeg))
      const payload = JSON.parse(await readFile(output, 'utf8')) as WhisperPayload
      return {
        text: String(payload.text ?? '').trim(),
        language: payload.language,
        segments: Array.isArray(payload.segments) ? payload.segments.filter((segment) => String(segment.text ?? '').trim()).map((segment) => ({
          start: Number(segment.start) || 0,
          end: Number(segment.end) || 0,
          text: String(segment.text).trim()
        })) : []
      }
    } finally {
      await rm(output, { force: true }).catch(() => undefined)
    }
  }

  private async resolveFfmpeg(): Promise<string | null> {
    if (existsSync(this.managedFfmpeg)) return this.managedFfmpeg
    for (const candidate of process.platform === 'win32'
      ? ['ffmpeg.exe', join(process.env.LOCALAPPDATA ?? '', 'Microsoft', 'WinGet', 'Links', 'ffmpeg.exe')]
      : ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg', 'ffmpeg']) {
      if (candidate.includes('/') || candidate.includes('\\')) {
        if (existsSync(candidate)) return candidate
      } else if (await commandOutput(candidate, ['-version'], 5_000).then(() => true).catch(() => false)) return candidate
    }
    return null
  }

  private async detectInstalledModels(): Promise<string[]> {
    const files = await readdir(this.modelRoot).catch(() => [])
    const found = new Set(files.filter((file) => file.endsWith('.pt')).map((file) => file.slice(0, -3)))
    if (found.has('large-v3-turbo')) found.add('turbo')
    return [...found].sort()
  }

  private setFfmpeg(patch: Partial<ManagedMediaServiceStatus>): void {
    this.ffmpegStatus = { ...this.ffmpegStatus, ...patch }
    this.onChanged?.()
  }

  private setWhisper(patch: Partial<ManagedMediaServiceStatus>): void {
    this.whisperStatus = { ...this.whisperStatus, ...patch }
    this.onChanged?.()
  }
}

export function buildTranscriptChunks(payload: WhisperPayload, targetTokens: number): DocumentChunk[] {
  const segments = payload.segments.length
    ? payload.segments
    : payload.text ? [{ start: 0, end: 0, text: payload.text }] : []
  const groups: WhisperSegment[][] = []
  let current: WhisperSegment[] = []
  for (const segment of segments) {
    const candidate = [...current, segment].map((item) => item.text).join(' ')
    if (current.length && estimateCanonicalTokens(candidate).count > Math.max(120, targetTokens)) {
      groups.push(current)
      current = []
    }
    current.push(segment)
  }
  if (current.length) groups.push(current)
  return groups.slice(0, 500).map((group, index) => {
    const first = group[0]
    const last = group[group.length - 1]
    const range = `${timestamp(first.start)}–${timestamp(last.end)}`
    const body = `[${range}] ${group.map((segment) => segment.text).join(' ')}`
    const contextualText = `Section: Transcript > ${range}\n${body}`
    const measurement = estimateCanonicalTokens(contextualText)
    return {
      index, text: body, contextualText, sectionPath: ['Transcript', range], pageStart: null, pageEnd: null,
      kind: 'transcript', parentIndex: index, parentText: body, entityTerms: entityTerms(body),
      tokenCount: measurement.count, tokenizerProfile: measurement.tokenizerProfile,
      tokenizerVersion: measurement.tokenizerVersion, tokenCountAccuracy: measurement.accuracy
    }
  })
}

export function normalizeWhisperModel(value: string): string {
  const model = value.trim().toLowerCase()
  return WHISPER_MODELS.some((option) => option.id === model) ? model : 'base'
}

function emptyStatus(message: string): ManagedMediaServiceStatus {
  return { state: 'unavailable', installing: false, installingModel: null, progress: null, message, error: null, version: null, installedModels: [] }
}

function readyStatus(version: string | null, message: string): ManagedMediaServiceStatus {
  return { state: 'ready', installing: false, installingModel: null, progress: null, message, error: null, version, installedModels: [] }
}

async function resolvePython(): Promise<PythonCommand | null> {
  const candidates: PythonCommand[] = process.platform === 'win32'
    ? [{ executable: 'py', prefix: ['-3.11'] }, { executable: 'py', prefix: ['-3.10'] }, { executable: 'python', prefix: [] }, { executable: 'python3', prefix: [] }]
    : [{ executable: 'python3', prefix: [] }, { executable: 'python', prefix: [] }]
  for (const candidate of candidates) {
    const output = await commandOutput(candidate.executable, [...candidate.prefix, '--version'], 10_000).catch(() => '')
    const match = output.match(/Python\s+(\d+)\.(\d+)/i)
    if (match && (Number(match[1]) > 3 || Number(match[1]) === 3 && Number(match[2]) >= 10)) return candidate
  }
  return null
}

function run(executable: string, args: string[], timeoutMs: number, env: NodeJS.ProcessEnv = process.env): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { windowsHide: true, shell: false, stdio: 'ignore', env })
    const timer = setTimeout(() => { child.kill(); reject(new Error(`${basename(executable)} timed out`)) }, timeoutMs)
    child.once('error', (error) => { clearTimeout(timer); reject(error) })
    child.once('close', (code) => {
      clearTimeout(timer)
      if (code === 0) resolve()
      else reject(new Error(`${basename(executable)} exited with code ${code ?? 'unknown'}`))
    })
  })
}

function commandOutput(executable: string, args: string[], timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { windowsHide: true, shell: false })
    let output = ''
    const timer = setTimeout(() => { child.kill(); reject(new Error(`${basename(executable)} timed out`)) }, timeoutMs)
    child.stdout?.on('data', (chunk) => { output += String(chunk) })
    child.stderr?.on('data', (chunk) => { output += String(chunk) })
    child.once('error', (error) => { clearTimeout(timer); reject(error) })
    child.once('close', (code) => { clearTimeout(timer); code === 0 ? resolve(output) : reject(new Error(output.trim() || `${basename(executable)} exited with code ${code ?? 'unknown'}`)) })
  })
}

async function downloadToFile(url: string, path: string): Promise<void> {
  const response = await fetch(url, { signal: AbortSignal.timeout(30 * 60_000) })
  if (!response.ok || !response.body) throw new Error(`FFmpeg download failed with HTTP ${response.status}`)
  await pipeline(Readable.fromWeb(response.body as never), createWriteStream(path))
}

async function findFile(root: string, fileName: string): Promise<string | null> {
  for (const entry of await readdir(root, { withFileTypes: true })) {
    const path = join(root, entry.name)
    if (entry.isFile() && entry.name.toLowerCase() === fileName.toLowerCase()) return path
    if (entry.isDirectory()) {
      const nested = await findFile(path, fileName)
      if (nested) return nested
    }
  }
  return null
}

function withExecutableOnPath(env: NodeJS.ProcessEnv, executable: string): NodeJS.ProcessEnv {
  return { ...env, PATH: [dirname(executable), env.PATH ?? ''].filter(Boolean).join(process.platform === 'win32' ? ';' : ':') }
}

function firstVersionLine(output: string, prefix: string): string | null {
  const line = output.split(/\r?\n/)[0] ?? ''
  const start = line.toLowerCase().indexOf(prefix.toLowerCase())
  return start < 0 ? null : line.slice(start + prefix.length).split(/\s+/)[0] || null
}

function timestamp(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds))
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const remainder = total % 60
  return hours > 0
    ? [hours, minutes, remainder].map((value) => String(value).padStart(2, '0')).join(':')
    : [minutes, remainder].map((value) => String(value).padStart(2, '0')).join(':')
}

function entityTerms(text: string): string[] {
  const matches = new Set<string>()
  for (const pattern of [/\b[A-Z0-9][A-Z0-9._/-]{2,}\d[A-Z0-9._/-]*\b/giu, /\b[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}\b/giu, /\b\d{4}[-/.]\d{1,2}[-/.]\d{1,2}\b/gu]) {
    for (const match of text.matchAll(pattern)) matches.add(match[0].toLocaleLowerCase())
  }
  return [...matches].sort()
}

function errorMessage(error: unknown): string { return error instanceof Error ? error.message : String(error) }

export const mediaTranscriptionManager = new MediaTranscriptionManager()
