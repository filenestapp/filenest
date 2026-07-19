import { app } from 'electron'
import { spawn, type ChildProcess } from 'node:child_process'
import { existsSync } from 'node:fs'
import { mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

export interface ManagedRerankerStatus {
  state: 'unavailable' | 'installed' | 'starting' | 'running' | 'failed'
  installing: boolean
  progress: number | null
  message: string
  error: string | null
  modelDiskBytes: number
}

interface PythonCommand {
  executable: string
  prefix: string[]
}

const MODEL = 'Qwen/Qwen3-Reranker-0.6B'
const PORT = 11_435

export class RerankerServiceManager {
  private process: ChildProcess | null = null
  private statusValue: ManagedRerankerStatus = {
    state: 'unavailable', installing: false, progress: null, message: 'Not downloaded', error: null, modelDiskBytes: 0
  }
  onChanged?: () => void

  private get root(): string { return join(app.getPath('userData'), 'Reranker') }
  private get venvRoot(): string { return join(this.root, 'venv') }
  private get python(): string { return join(this.venvRoot, process.platform === 'win32' ? 'Scripts/python.exe' : 'bin/python') }
  private get modelRoot(): string { return join(this.root, 'models', 'qwen3-reranker-0.6b') }
  private get scriptPath(): string { return join(this.root, 'reranker_server.py') }
  private get pidPath(): string { return join(this.root, 'reranker.pid') }

  status(): ManagedRerankerStatus { return { ...this.statusValue } }

  async refresh(): Promise<ManagedRerankerStatus> {
    const installed = existsSync(join(this.modelRoot, 'config.json')) && existsSync(this.python)
    const modelDiskBytes = await directorySize(this.modelRoot)
    if (await this.healthCheck()) {
      this.setStatus({ state: 'running', message: 'Ready', error: null, modelDiskBytes })
    } else if (!this.statusValue.installing && this.statusValue.state !== 'starting') {
      this.setStatus({ state: installed ? 'installed' : 'unavailable', message: installed ? 'Installed · service stopped' : 'Not downloaded', modelDiskBytes })
    }
    return this.status()
  }

  async install(): Promise<void> {
    if (this.statusValue.installing) return
    const systemPython = await resolveSystemPython()
    if (!systemPython) throw new Error('Python 3.10 or later is required to install the local reranker')
    this.setStatus({ installing: true, progress: 0.03, message: 'Preparing the isolated reranker environment…', error: null })
    try {
      await mkdir(this.root, { recursive: true })
      if (!existsSync(this.python)) await run(systemPython.executable, [...systemPython.prefix, '-m', 'venv', this.venvRoot])
      this.setStatus({ progress: 0.18, message: 'Installing the local reranker runtime…' })
      await run(this.python, ['-m', 'pip', 'install', '--disable-pip-version-check', 'sentence-transformers>=5.4,<6', 'fastapi>=0.115,<1', 'uvicorn>=0.34,<1'])
      this.setStatus({ progress: 0.38, message: 'Downloading Qwen3-Reranker-0.6B…' })
      await mkdir(join(this.root, 'models'), { recursive: true })
      await run(this.python, ['-c', `from huggingface_hub import snapshot_download; snapshot_download(repo_id=${JSON.stringify(MODEL)}, local_dir=${JSON.stringify(this.modelRoot)})`])
      await this.writeServerScript()
      this.setStatus({ progress: 0.94, message: 'Verifying the reranker model…' })
      await run(this.python, ['-c', `from sentence_transformers import CrossEncoder; model=CrossEncoder(${JSON.stringify(this.modelRoot)}, device='cpu'); assert len(model.predict([('File search','A local document')])) == 1`])
      this.setStatus({ installing: false, progress: 1, state: 'installed', message: 'Reranker installation complete' })
      await this.refresh()
      await this.start()
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      this.setStatus({ installing: false, progress: null, state: 'failed', message: 'Installation failed', error: message })
      throw error
    }
  }

  async start(): Promise<void> {
    await this.refresh()
    if (this.statusValue.state === 'running') return
    if (!existsSync(join(this.modelRoot, 'config.json')) || !existsSync(this.python)) return
    await this.writeServerScript()
    if (await this.healthCheck()) throw new Error(`Port ${PORT} is already used by a reranker not managed by FileNest`)
    this.setStatus({ state: 'starting', message: 'Starting local service…', error: null })
    const child = spawn(this.python, [this.scriptPath, '--model', this.modelRoot, '--port', String(PORT)], {
      windowsHide: true,
      stdio: 'ignore',
      env: { ...process.env, HF_HUB_DISABLE_TELEMETRY: '1', TOKENIZERS_PARALLELISM: 'false' }
    })
    this.process = child
    child.unref()
    await writeFile(this.pidPath, String(child.pid ?? ''), 'utf8')
    child.once('exit', () => {
      if (this.process !== child) return
      this.process = null
      if (this.statusValue.state === 'running' || this.statusValue.state === 'starting') {
        this.setStatus({ state: 'failed', message: 'Service unavailable', error: 'The local reranker service stopped unexpectedly' })
      }
    })
    for (let attempt = 0; attempt < 120; attempt += 1) {
      if (await this.healthCheck()) {
        this.setStatus({ state: 'running', message: 'Ready', error: null })
        return
      }
      if (child.exitCode != null) break
      await delay(500)
    }
    await this.stop()
    throw new Error('The local reranker did not become ready in time')
  }

  async stop(): Promise<void> {
    const storedPid = Number(await readFile(this.pidPath, 'utf8').catch(() => ''))
    const pid = this.process?.pid ?? (Number.isInteger(storedPid) ? storedPid : null)
    this.process = null
    if (pid) {
      if (process.platform === 'win32') await run('taskkill', ['/pid', String(pid), '/T', '/F']).catch(() => undefined)
      else { try { process.kill(pid, 'SIGTERM') } catch { /* The process already stopped. */ } }
    }
    await rm(this.pidPath, { force: true })
    this.setStatus({ state: existsSync(join(this.modelRoot, 'config.json')) ? 'installed' : 'unavailable', message: existsSync(join(this.modelRoot, 'config.json')) ? 'Installed · service stopped' : 'Not downloaded' })
  }

  async deleteModel(): Promise<void> {
    await this.stop()
    await rm(this.modelRoot, { recursive: true, force: true })
    await this.refresh()
  }

  async shutdown(): Promise<void> { await this.stop() }

  private async healthCheck(): Promise<boolean> {
    try {
      const response = await fetch(`http://127.0.0.1:${PORT}/health`, { signal: AbortSignal.timeout(1_000) })
      return response.ok
    } catch { return false }
  }

  private async writeServerScript(): Promise<void> {
    await mkdir(this.root, { recursive: true })
    await writeFile(this.scriptPath, SERVER_SCRIPT, 'utf8')
  }

  private setStatus(patch: Partial<ManagedRerankerStatus>): void {
    this.statusValue = { ...this.statusValue, ...patch }
    this.onChanged?.()
  }
}

async function resolveSystemPython(): Promise<PythonCommand | null> {
  const candidates: PythonCommand[] = process.platform === 'win32'
    ? [{ executable: 'py', prefix: ['-3.11'] }, { executable: 'py', prefix: ['-3.10'] }, { executable: 'python', prefix: [] }, { executable: 'python3', prefix: [] }]
    : [{ executable: 'python3', prefix: [] }, { executable: 'python', prefix: [] }]
  for (const candidate of candidates) {
    try {
      const output = await commandOutput(candidate.executable, [...candidate.prefix, '--version'])
      const match = output.match(/Python\s+(\d+)\.(\d+)/i)
      if (match && (Number(match[1]) > 3 || Number(match[2]) >= 10)) return candidate
    } catch { /* Try the next interpreter. */ }
  }
  return null
}

function run(executable: string, args: string[]): Promise<void> {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { windowsHide: true, stdio: 'ignore' })
    child.once('error', reject)
    child.once('exit', (code) => code === 0 ? resolve() : reject(new Error(`Reranker command failed with exit code ${code ?? 'unknown'}`)))
  })
}

function commandOutput(executable: string, args: string[]): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { windowsHide: true })
    let output = ''
    child.stdout?.on('data', (value) => { output += String(value) })
    child.stderr?.on('data', (value) => { output += String(value) })
    child.once('error', reject)
    child.once('exit', (code) => code === 0 ? resolve(output) : reject(new Error(`Python probe failed with exit code ${code ?? 'unknown'}`)))
  })
}

async function directorySize(root: string): Promise<number> {
  const info = await stat(root).catch(() => null)
  if (!info) return 0
  if (info.isFile()) return info.size
  const { readdir } = await import('node:fs/promises')
  const entries = await readdir(root, { withFileTypes: true })
  let total = 0
  for (const entry of entries) total += await directorySize(join(root, entry.name))
  return total
}

function delay(milliseconds: number): Promise<void> { return new Promise((resolve) => setTimeout(resolve, milliseconds)) }

const SERVER_SCRIPT = `import argparse
import torch
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sentence_transformers import CrossEncoder

parser = argparse.ArgumentParser()
parser.add_argument("--model", required=True)
parser.add_argument("--port", required=True, type=int)
args = parser.parse_args()
device = "cuda" if torch.cuda.is_available() else "cpu"
model = CrossEncoder(args.model, device=device)
app = FastAPI(docs_url=None, redoc_url=None)

class RerankRequest(BaseModel):
    model: str | None = None
    query: str
    documents: list[str]
    top_n: int | None = None

@app.get("/health")
def health():
    return {"status": "ok"}

@app.post("/v1/rerank")
def rerank(request: RerankRequest):
    if not request.documents:
        return {"results": []}
    try:
        scores = model.predict([(request.query, document) for document in request.documents], activation_fn=torch.nn.Sigmoid(), show_progress_bar=False)
        results = [{"index": index, "relevance_score": float(score)} for index, score in enumerate(scores)]
        results.sort(key=lambda item: item["relevance_score"], reverse=True)
        return {"results": results[:request.top_n] if request.top_n else results}
    except Exception as error:
        raise HTTPException(status_code=500, detail=str(error)) from error

uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")
`
