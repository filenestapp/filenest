import { app } from 'electron'
import { appendFile, mkdir, readdir, rm, copyFile } from 'node:fs/promises'
import { join } from 'node:path'

export class AppLogger {
  readonly root = join(app.getPath('userData'), 'logs')

  async log(scope: string, message: string, error?: unknown): Promise<void> {
    await mkdir(this.root, { recursive: true })
    const detail = error instanceof Error ? ` | ${error.stack ?? error.message}` : error ? ` | ${String(error)}` : ''
    await appendFile(join(this.root, `${scope}.log`), `${new Date().toISOString()} ${message}${detail}\n`, 'utf8')
  }

  async clear(): Promise<number> {
    await mkdir(this.root, { recursive: true })
    const files = await readdir(this.root)
    await Promise.all(files.map((file) => rm(join(this.root, file), { force: true })))
    return files.length
  }

  async exportTo(directory: string): Promise<string> {
    await mkdir(this.root, { recursive: true })
    const target = join(directory, `FileNest Logs ${new Date().toISOString().slice(0, 10)}`)
    await mkdir(target, { recursive: true })
    const files = await readdir(this.root)
    await Promise.all(files.map((file) => copyFile(join(this.root, file), join(target, file))))
    return target
  }
}
