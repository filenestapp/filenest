import { shell } from 'electron'
import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import type { Settings } from '../shared/types'

export class OllamaManager {
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
    if (!response.ok) throw new Error(`ModelDownload Failed：${response.status} ${await response.text()}`)
  }

  async delete(model: string, settings: Settings): Promise<void> {
    const response = await fetch(new URL('/api/delete', settings.ollamaHost.replace(/\/+$/, '') + '/'), { method: 'DELETE', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ model }) })
    if (!response.ok) throw new Error(`Failed to delete model: ${response.status} ${await response.text()}`)
  }

  async install(): Promise<void> {
    if (process.platform !== 'win32') {
      await shell.openExternal('https://ollama.com/download/windows')
      return
    }
    try {
      await run('winget.exe', ['install', '--id', 'Ollama.Ollama', '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements'], 15 * 60_000)
      const local = process.env.LOCALAPPDATA
      const executable = local ? join(local, 'Programs', 'Ollama', 'ollama.exe') : ''
      if (executable && existsSync(executable)) {
        const service = spawn(executable, ['serve'], { detached: true, stdio: 'ignore', windowsHide: true })
        service.unref()
      }
    } catch {
      await shell.openExternal('https://ollama.com/download/windows')
    }
  }
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
