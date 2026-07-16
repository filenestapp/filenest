import { app } from 'electron'
import { randomUUID } from 'node:crypto'
import { existsSync } from 'node:fs'
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { basename, join, parse } from 'node:path'
import { spawn } from 'node:child_process'

const PINNED_VERSION = '2.102.1'

export interface DoclingStatus {
  installed: boolean
  installing: boolean
  version: string | null
  message: string
}

export class DoclingManager {
  private installing = false
  private message = ''

  private get root(): string { return join(app.getPath('userData'), 'services', 'docling') }
  private get executable(): string {
    return process.platform === 'win32'
      ? join(this.root, 'venv', 'Scripts', 'docling.exe')
      : join(this.root, 'venv', 'bin', 'docling')
  }

  async status(): Promise<DoclingStatus> {
    const installed = existsSync(this.executable)
    const version = installed
      ? (await readFile(join(this.root, 'version.txt'), 'utf8').catch(() => PINNED_VERSION)).trim()
      : null
    return { installed, installing: this.installing, version, message: this.message || (installed ? `Docling ${version}` : 'Not installed') }
  }

  async install(): Promise<void> {
    if (this.installing) return
    this.installing = true
    const parent = join(app.getPath('userData'), 'services')
    const staging = join(parent, `docling.installing-${randomUUID()}`)
    const backup = join(parent, `docling.backup-${randomUUID()}`)
    try {
      await mkdir(parent, { recursive: true })
      const python = await resolvePython()
      if (!python) throw new Error('Python 3.10 or later is required. Install Python from the Microsoft Store or python.org first.')
      this.message = 'Creating an isolated Docling environment…'
      const venv = join(staging, 'venv')
      await run(python.command, [...python.prefix, '-m', 'venv', venv], 120_000)
      const pip = process.platform === 'win32' ? join(venv, 'Scripts', 'pip.exe') : join(venv, 'bin', 'pip')
      const executable = process.platform === 'win32' ? join(venv, 'Scripts', 'docling.exe') : join(venv, 'bin', 'docling')
      this.message = 'Downloading and installing Docling dependencies…'
      await run(pip, ['install', '--disable-pip-version-check', `docling==${PINNED_VERSION}`], 30 * 60_000)
      this.message = 'Verifying the Docling installation…'
      await run(executable, ['--version'], 60_000)
      await writeFile(join(staging, 'version.txt'), PINNED_VERSION, 'utf8')
      const hadExisting = existsSync(this.root)
      if (hadExisting) await rename(this.root, backup)
      try {
        await rename(staging, this.root)
        if (hadExisting) await rm(backup, { recursive: true, force: true })
      } catch (error) {
        if (hadExisting && !existsSync(this.root)) await rename(backup, this.root).catch(() => undefined)
        throw error
      }
      this.message = 'Docling installation complete'
    } catch (error) {
      this.message = error instanceof Error ? error.message : String(error)
      throw error
    } finally {
      this.installing = false
      await rm(staging, { recursive: true, force: true }).catch(() => undefined)
    }
  }

  async convert(path: string): Promise<{ title: string; text: string } | null> {
    if (!existsSync(this.executable)) return null
    const output = join(app.getPath('temp'), `filenest-docling-${randomUUID()}`)
    try {
      await mkdir(output, { recursive: true })
      await run(this.executable, [path, '--to', 'md', '--output', output], 10 * 60_000)
      const markdown = join(output, `${parse(path).name}.md`)
      const text = await readFile(markdown, 'utf8').catch(() => '')
      return text.trim() ? { title: basename(path), text: text.slice(0, 1_000_000) } : null
    } finally {
      await rm(output, { recursive: true, force: true }).catch(() => undefined)
    }
  }
}

async function resolvePython(): Promise<{ command: string; prefix: string[] } | null> {
  const candidates = process.platform === 'win32'
    ? [{ command: 'py', prefix: ['-3'] }, { command: 'python', prefix: [] }, { command: 'python3', prefix: [] }]
    : [{ command: 'python3', prefix: [] }, { command: 'python', prefix: [] }]
  for (const candidate of candidates) {
    const output = await run(candidate.command, [...candidate.prefix, '--version'], 10_000).catch(() => '')
    const match = output.match(/Python\s+(\d+)\.(\d+)/i)
    if (match && (Number(match[1]) > 3 || Number(match[1]) === 3 && Number(match[2]) >= 10)) return candidate
  }
  return null
}

function run(command: string, args: string[], timeoutMs: number): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { windowsHide: true, shell: false })
    let output = ''
    let errorOutput = ''
    const timer = setTimeout(() => { child.kill(); reject(new Error(`${basename(command)} timed out`)) }, timeoutMs)
    child.stdout.on('data', (chunk) => { output += String(chunk) })
    child.stderr.on('data', (chunk) => { errorOutput += String(chunk) })
    child.once('error', (error) => { clearTimeout(timer); reject(error) })
    child.once('close', (code) => {
      clearTimeout(timer)
      if (code === 0) resolve(`${output}\n${errorOutput}`.trim())
      else reject(new Error(errorOutput.trim() || `${basename(command)} exited with code ${code}`))
    })
  })
}

export const doclingManager = new DoclingManager()
