import { shell } from 'electron'
import { spawn, spawnSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import type { Settings } from '../shared/types'

export class OllamaManager {
  private launchedProcess: ReturnType<typeof spawn> | null = null
  private startTask: Promise<{ reachable: boolean; models: string[] }> | null = null

  async refresh(settings: Settings): Promise<{ reachable: boolean; models: string[] }> {
    try {
      const response = await fetch(new URL('/api/tags', settings.ollamaHost.replace(/\/+$/, '') + '/'), { signal: AbortSignal.timeout(3_000) })
      if (!response.ok) return { reachable: false, models: [] }
      const payload = await response.json() as { models?: Array<{ name?: string; model?: string }> }
      return { reachable: true, models: (payload.models ?? []).map((item) => item.name ?? item.model ?? '').filter(Boolean) }
    } catch {
      return { reachable: false, models: [] }
    }
  }

  async pull(model: string, settings: Settings): Promise<void> {
    const response = await fetch(new URL('/api/pull', settings.ollamaHost.replace(/\/+$/, '') + '/'), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ model, stream: false }) })
    if (!response.ok) throw new Error(`Model download failed: ${response.status} ${await response.text()}`)
  }

  async delete(model: string, settings: Settings): Promise<void> {
    const response = await fetch(new URL('/api/delete', settings.ollamaHost.replace(/\/+$/, '') + '/'), { method: 'DELETE', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ model }) })
    if (!response.ok) throw new Error(`Failed to delete model: ${response.status} ${await response.text()}`)
  }

  async install(settings?: Settings): Promise<void> {
    if (process.platform !== 'win32') {
      await shell.openExternal('https://ollama.com/download/windows')
      return
    }
    try {
      await run('winget.exe', ['install', '--id', 'Ollama.Ollama', '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements'], 15 * 60_000)
      const local = process.env.LOCALAPPDATA
      const executable = local ? join(local, 'Programs', 'Ollama', 'ollama.exe') : ''
      if (executable && existsSync(executable)) {
        await this.start(settings ?? ({} as Settings))
      }
    } catch {
      await shell.openExternal('https://ollama.com/download/windows')
    }
  }

  start(settings: Settings): Promise<{ reachable: boolean; models: string[] }> {
    if (this.startTask) return this.startTask
    this.startTask = this.performStart(settings).finally(() => { this.startTask = null })
    return this.startTask
  }

  async stop(): Promise<void> {
    const process = this.launchedProcess
    this.launchedProcess = null
    if (!process?.pid) return
    if (globalThis.process.platform === 'win32') await run('taskkill', ['/pid', String(process.pid), '/T', '/F'], 15_000).catch(() => undefined)
    else { try { process.kill('SIGTERM') } catch { /* The process already stopped. */ } }
  }

  private async performStart(settings: Settings): Promise<{ reachable: boolean; models: string[] }> {
    const current = await this.refresh(settings)
    if (current.reachable || !requiresOllamaService(settings) || !isLocalOllamaHost(settings.ollamaHost)) return current
    if (this.launchedProcess && this.launchedProcess.exitCode == null) return this.waitUntilReady(settings, this.launchedProcess)
    const executable = resolveOllamaExecutable()
    if (!executable) return current
    const process = spawn(executable, ['serve'], {
      stdio: 'ignore',
      windowsHide: true,
      env: { ...globalThis.process.env, OLLAMA_FLASH_ATTENTION: settings.ollamaFlashAttentionEnabled === false ? '0' : '1' }
    })
    this.launchedProcess = process
    process.once('exit', () => { if (this.launchedProcess === process) this.launchedProcess = null })
    return this.waitUntilReady(settings, process)
  }

  private async waitUntilReady(settings: Settings, process: ReturnType<typeof spawn>): Promise<{ reachable: boolean; models: string[] }> {
    for (let attempt = 0; attempt < 60; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 250))
      const current = await this.refresh(settings)
      if (current.reachable) return current
      if (process.exitCode != null) break
    }
    return { reachable: false, models: [] }
  }
}

export function requiresOllamaService(settings: Pick<Settings, 'llmChoice' | 'embeddingSource'>): boolean {
  return settings.llmChoice === 'ollama' || settings.embeddingSource === 'ollama'
}

export function isLocalOllamaHost(host: string): boolean {
  try {
    const hostname = new URL(host).hostname.replace(/^\[|\]$/g, '').toLocaleLowerCase()
    return ['localhost', '127.0.0.1', '::1', '0.0.0.0'].includes(hostname)
  } catch { return false }
}

function resolveOllamaExecutable(): string | null {
  const local = globalThis.process.env.LOCALAPPDATA
  const installed = local ? join(local, 'Programs', 'Ollama', 'ollama.exe') : ''
  if (installed && existsSync(installed)) return installed
  const probe = spawnSync(globalThis.process.platform === 'win32' ? 'where.exe' : 'which', ['ollama'], { encoding: 'utf8', windowsHide: true })
  return probe.status === 0 ? probe.stdout.split(/\r?\n/).map((value) => value.trim()).find(Boolean) ?? null : null
}

function run(command: string, args: string[], timeoutMs: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { windowsHide: true, shell: false, stdio: 'ignore' })
    const timer = setTimeout(() => { child.kill(); reject(new Error('Ollama installation timed out')) }, timeoutMs)
    child.once('error', (error) => { clearTimeout(timer); reject(error) })
    child.once('close', (code) => {
      clearTimeout(timer)
      if (code === 0) resolve()
      else reject(new Error(`winget exited with code ${code}`))
    })
  })
}
