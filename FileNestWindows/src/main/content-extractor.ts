import { createWorker } from 'tesseract.js'
import mammoth from 'mammoth'
import JSZip from 'jszip'
import { createHash } from 'node:crypto'
import { basename, extname, relative } from 'node:path'
import { readFile, readdir, stat } from 'node:fs/promises'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import type { Settings } from '../shared/types'
import { doclingManager } from './docling'

export interface ExtractedContent {
  title: string
  text: string
}

const textExtensions = new Set(['txt', 'md', 'markdown', 'json', 'yaml', 'yml', 'csv', 'log', 'xml', 'html', 'swift', 'py', 'js', 'ts', 'tsx', 'jsx', 'java', 'kt', 'go', 'rs', 'c', 'cpp', 'h', 'hpp', 'cs', 'rb', 'php', 'sh', 'sql', 'css', 'vue', 'lua', 'r'])
const imageExtensions = new Set(['png', 'jpg', 'jpeg', 'gif', 'heic', 'webp', 'bmp', 'tiff', 'tif'])
const zipDocumentExtensions = new Set(['pptx', 'ppsx', 'epub', 'odt', 'ods', 'odp', 'pages', 'numbers', 'key', 'keynote'])
const legacyOfficeExtensions = new Set(['doc', 'xls', 'ppt'])
const execFileAsync = promisify(execFile)

export class ContentExtractor {
  private ocrWorkerPromise: ReturnType<typeof createWorker> | null = null

  async extract(path: string, settings: Settings, isDirectory = false): Promise<ExtractedContent> {
    if (isDirectory) return this.extractDirectory(path)
    const ext = extname(path).slice(1).toLowerCase()
    if (settings.doclingEnabled && ['pdf', 'doc', 'docx', 'docm', 'xls', 'xlsx', 'xlsm', 'ppt', 'pptx', 'ppsx', 'epub', 'odt', 'ods', 'odp'].includes(ext)) {
      const docling = await this.tryDocling(path, settings).catch(() => null)
      if (docling?.text.trim()) return docling
    }
    if (ext === 'pdf') return this.extractPdf(path)
    if (ext === 'docx' || ext === 'docm') return this.extractDocx(path)
    if (ext === 'xlsx' || ext === 'xlsm') return this.extractSpreadsheet(path)
    if (ext === 'rtf') return this.extractRtf(path)
    if (ext === 'csv') return this.extractText(path)
    if (zipDocumentExtensions.has(ext)) return this.extractZipDocument(path)
    if (legacyOfficeExtensions.has(ext)) return this.extractLegacyOffice(path, ext)
    if (textExtensions.has(ext)) return this.extractText(path)
    if (imageExtensions.has(ext)) return this.extractImage(path, settings)
    return { title: basename(path), text: basename(path) }
  }

  async hash(path: string, isDirectory = false): Promise<string> {
    const hash = createHash('sha256')
    if (!isDirectory) {
      hash.update(await readFile(path))
      return hash.digest('hex')
    }
    const entries = await walkDirectory(path, 1000)
    for (const entry of entries) hash.update(`${entry.path}|${entry.size}|${entry.mtimeMs}\n`)
    return hash.digest('hex')
  }

  private async extractText(path: string): Promise<ExtractedContent> {
    const text = (await readFile(path, 'utf8')).slice(0, 500_000)
    const firstMeaningful = text.split(/\r?\n/).find((line) => line.trim())?.trim()
    return { title: firstMeaningful?.slice(0, 160) || basename(path), text }
  }

  private async extractRtf(path: string): Promise<ExtractedContent> {
    const raw = (await readFile(path)).toString('latin1').slice(0, 1_500_000)
    const text = raw
      .replace(/\\'([0-9a-fA-F]{2})/g, (_match, hex: string) => String.fromCharCode(Number.parseInt(hex, 16)))
      .replace(/\\u(-?\d+)\??/g, (_match, value: string) => String.fromCharCode(Number(value) & 0xffff))
      .replace(/\\(?:par|line)\b/g, '\n')
      .replace(/\\[a-zA-Z]+-?\d* ?/g, '')
      .replace(/[{}]/g, '')
      .replace(/\n{3,}/g, '\n\n')
      .trim()
      .slice(0, 1_000_000)
    return { title: basename(path), text: text || basename(path) }
  }

  private async extractPdf(path: string): Promise<ExtractedContent> {
    const pdfjs = await import('pdfjs-dist/legacy/build/pdf.mjs')
    const document = await pdfjs.getDocument({ data: new Uint8Array(await readFile(path)), useSystemFonts: true }).promise
    const pages: string[] = []
    for (let index = 1; index <= Math.min(document.numPages, 300); index += 1) {
      const page = await document.getPage(index)
      const content = await page.getTextContent()
      const text = content.items.map((item) => 'str' in item ? item.str : '').join(' ').trim()
      if (text) pages.push(`[Page ${index}]\n${text}`)
    }
    const metadata = await document.getMetadata().catch(() => null)
    const title = metadata && 'info' in metadata && typeof metadata.info === 'object' && metadata.info && 'Title' in metadata.info
      ? String(metadata.info.Title || basename(path))
      : basename(path)
    return { title, text: pages.join('\n\n').slice(0, 1_000_000) || basename(path) }
  }

  private async extractDocx(path: string): Promise<ExtractedContent> {
    const result = await mammoth.extractRawText({ path })
    const text = result.value.slice(0, 1_000_000)
    return { title: text.split(/\r?\n/).find((line) => line.trim())?.slice(0, 160) || basename(path), text }
  }

  private async extractSpreadsheet(path: string): Promise<ExtractedContent> {
    const zip = await JSZip.loadAsync(await readFile(path))
    const sharedEntry = zip.file('xl/sharedStrings.xml')
    const shared = sharedEntry ? parseSharedStrings(await sharedEntry.async('string')) : []
    const workbookEntry = zip.file('xl/workbook.xml')
    const workbookXml = workbookEntry ? await workbookEntry.async('string') : ''
    const sheetNames = [...workbookXml.matchAll(/<sheet\b[^>]*name="([^"]+)"/g)].map((match) => decodeEntities(match[1]))
    const sheetEntries = Object.values(zip.files)
      .filter((entry) => !entry.dir && /^xl\/worksheets\/sheet\d+\.xml$/i.test(entry.name))
      .sort((left, right) => left.name.localeCompare(right.name, undefined, { numeric: true }))
    const sections: string[] = []
    for (let index = 0; index < sheetEntries.length; index += 1) {
      sections.push(`# ${sheetNames[index] ?? `Sheet ${index + 1}`}\n${parseWorksheet(await sheetEntries[index].async('string'), shared)}`)
    }
    return { title: basename(path), text: sections.join('\n\n').slice(0, 1_000_000) || basename(path) }
  }

  private async extractZipDocument(path: string): Promise<ExtractedContent> {
    const zip = await JSZip.loadAsync(await readFile(path))
    const candidates = Object.values(zip.files).filter((entry) => !entry.dir && /\.(xml|xhtml|html|txt)$/i.test(entry.name)).slice(0, 300)
    const pieces: string[] = []
    for (const entry of candidates) {
      const raw = await entry.async('string')
      const clean = decodeEntities(raw.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ')).trim()
      if (clean) pieces.push(`[${entry.name}]\n${clean}`)
    }
    return { title: basename(path), text: pieces.join('\n\n').slice(0, 1_000_000) || basename(path) }
  }

  private async extractImage(path: string, settings: Settings): Promise<ExtractedContent> {
    if (settings.ocrSource === 'disabled') return { title: basename(path), text: basename(path) }
    if (settings.ocrSource === 'ollama' || settings.ocrSource === 'cloud') {
      const text = await this.remoteOcr(path, settings).catch(() => '')
      return { title: basename(path), text: text || basename(path) }
    }
    try {
      this.ocrWorkerPromise ??= createWorker(['eng', 'chi_sim'])
      const worker = await this.ocrWorkerPromise
      const result = await worker.recognize(path)
      const text = result.data.text.trim() || await this.ollamaOcr(path, settings).catch(() => '')
      return { title: basename(path), text: text || basename(path) }
    } catch {
      const fallback = await this.ollamaOcr(path, settings).catch(() => '')
      return { title: basename(path), text: fallback || basename(path) }
    }
  }

  private async ollamaOcr(path: string, settings: Settings): Promise<string> {
    const image = (await readFile(path)).toString('base64')
    const response = await fetch(new URL('/api/chat', settings.ollamaHost.replace(/\/+$/, '') + '/'), {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: settings.ollamaOcrModel, stream: false, messages: [{ role: 'user', content: 'Recognize all text in the image, preserve reading order, and return only the recognized text.', images: [image] }] }),
      signal: AbortSignal.timeout(20_000)
    })
    if (!response.ok) throw new Error(`Ollama OCR ${response.status}`)
    const payload = await response.json() as { message?: { content?: string } }
    return payload.message?.content?.trim() ?? ''
  }

  private async remoteOcr(path: string, settings: Settings): Promise<string> {
    const mime = mimeFor(path)
    const image = (await readFile(path)).toString('base64')
    if (settings.ocrSource === 'ollama') {
      const response = await fetch(new URL('/api/chat', settings.ollamaHost.replace(/\/+$/, '') + '/'), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ model: settings.ollamaOcrModel, stream: false, messages: [{ role: 'user', content: 'Recognize all text in the image, preserve reading order, and return only the recognized text.', images: [image] }] }) })
      if (!response.ok) throw new Error(`Ollama OCR ${response.status}`)
      const payload = await response.json() as { message?: { content?: string } }
      return payload.message?.content?.trim() ?? ''
    }
    const key = settings.cloudOcrReuseChatCredentials ? settings.cloudApiKey : settings.cloudOcrApiKey
    const base = settings.cloudOcrReuseChatCredentials ? settings.cloudBaseUrl : settings.cloudOcrBaseUrl
    const model = settings.cloudOcrModel
    const format = settings.cloudOcrReuseChatCredentials ? settings.cloudApiFormat : settings.cloudOcrFormat
    if (format === 'anthropic') {
      const response = await fetch(new URL('messages', base.replace(/\/+$/, '') + '/'), {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' },
        body: JSON.stringify({ model, max_tokens: 4096, messages: [{ role: 'user', content: [{ type: 'image', source: { type: 'base64', media_type: mime, data: image } }, { type: 'text', text: 'Recognize all text in the image, preserve reading order, and return only the recognized text.' }] }] })
      })
      if (!response.ok) throw new Error(`Anthropic OCR ${response.status}`)
      const payload = await response.json() as { content?: Array<{ type?: string; text?: string }> }
      return payload.content?.filter((item) => item.type === 'text').map((item) => item.text ?? '').join('').trim() ?? ''
    }
    const response = await fetch(new URL('chat/completions', base.replace(/\/+$/, '') + '/'), { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` }, body: JSON.stringify({ model, messages: [{ role: 'user', content: [{ type: 'text', text: 'Recognize all text in the image, preserve reading order, and return only the recognized text.' }, { type: 'image_url', image_url: { url: `data:${mime};base64,${image}` } }] }] }) })
    if (!response.ok) throw new Error(`Cloud OCR ${response.status}`)
    const payload = await response.json() as { choices?: Array<{ message?: { content?: string } }> }
    return payload.choices?.[0]?.message?.content?.trim() ?? ''
  }

  private async extractDirectory(path: string): Promise<ExtractedContent> {
    const entries = await walkDirectory(path, 2000)
    const text = entries.map((entry) => `${entry.isDirectory ? '[Folder]' : '[File]'} ${relative(path, entry.path)} (${entry.size} bytes)`).join('\n')
    return { title: basename(path), text: `Folder: ${basename(path)}\n\n${text}` }
  }

  private async extractLegacyOffice(path: string, extension: string): Promise<ExtractedContent> {
    if (process.platform !== 'win32') return { title: basename(path), text: basename(path) }
    const script = legacyOfficePowerShell(extension)
    try {
      const { stdout } = await execFileAsync('powershell.exe', ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script, path], {
        windowsHide: true,
        timeout: 30_000,
        maxBuffer: 2_000_000,
        encoding: 'utf8'
      })
      const text = stdout.trim().slice(0, 1_000_000)
      return { title: basename(path), text: text || basename(path) }
    } catch {
      return { title: basename(path), text: basename(path) }
    }
  }

  private async tryDocling(path: string, settings: Settings): Promise<ExtractedContent | null> {
    const managed = await doclingManager.convert(path)
    if (managed?.text.trim()) return managed
    if (!settings.doclingEndpoint.trim()) return null
    const data = new FormData()
    data.set('file', new Blob([await readFile(path)]), basename(path))
    const response = await fetch(new URL('/v1/convert/file', settings.doclingEndpoint.replace(/\/+$/, '') + '/'), { method: 'POST', body: data, signal: AbortSignal.timeout(4_000) })
    if (!response.ok) return null
    const payload = await response.json() as { document?: { markdown?: string; text?: string }; markdown?: string; text?: string; title?: string }
    const text = payload.document?.markdown ?? payload.document?.text ?? payload.markdown ?? payload.text ?? ''
    return text ? { title: payload.title ?? basename(path), text: text.slice(0, 1_000_000) } : null
  }
}

async function walkDirectory(root: string, limit: number): Promise<Array<{ path: string; size: number; mtimeMs: number; isDirectory: boolean }>> {
  const result: Array<{ path: string; size: number; mtimeMs: number; isDirectory: boolean }> = []
  const queue = [root]
  while (queue.length && result.length < limit) {
    const current = queue.shift()!
    const entries = await readdir(current, { withFileTypes: true }).catch(() => [])
    for (const entry of entries) {
      if (entry.name.startsWith('.')) continue
      const path = `${current}/${entry.name}`
      const info = await stat(path).catch(() => null)
      if (!info) continue
      result.push({ path, size: info.size, mtimeMs: info.mtimeMs, isDirectory: entry.isDirectory() })
      if (entry.isDirectory()) queue.push(path)
      if (result.length >= limit) break
    }
  }
  return result
}

function decodeEntities(value: string): string {
  return value.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'")
}

function parseSharedStrings(xml: string): string[] {
  return [...xml.matchAll(/<si\b[^>]*>([\s\S]*?)<\/si>/g)].map((match) => decodeEntities(match[1].replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim()))
}

function parseWorksheet(xml: string, shared: string[]): string {
  return [...xml.matchAll(/<row\b[^>]*>([\s\S]*?)<\/row>/g)].map((rowMatch) => {
    const cells: string[] = []
    for (const cell of rowMatch[1].matchAll(/<c\b([^>]*)>([\s\S]*?)<\/c>/g)) {
      const attributes = cell[1]
      const body = cell[2]
      const raw = body.match(/<v>([\s\S]*?)<\/v>/)?.[1] ?? body.match(/<t[^>]*>([\s\S]*?)<\/t>/)?.[1] ?? ''
      const value = /\bt="s"/.test(attributes) ? shared[Number(raw)] ?? raw : decodeEntities(raw)
      cells.push(value.trim())
    }
    return cells.join('\t')
  }).filter(Boolean).join('\n')
}

function mimeFor(path: string): string {
  const ext = extname(path).slice(1).toLowerCase()
  return ext === 'png' ? 'image/png' : ext === 'webp' ? 'image/webp' : ext === 'gif' ? 'image/gif' : ext === 'heic' ? 'image/heic' : ext === 'tif' || ext === 'tiff' ? 'image/tiff' : 'image/jpeg'
}

function legacyOfficePowerShell(extension: string): string {
  const prelude = "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new(); $path=$args[0];"
  if (extension === 'doc') {
    return `${prelude} $app=$null; $document=$null; try { $app=New-Object -ComObject Word.Application; $app.Visible=$false; $document=$app.Documents.Open($path,$false,$true); [Console]::Write($document.Content.Text) } finally { if($document){$document.Close($false)}; if($app){$app.Quit()} }`
  }
  if (extension === 'xls') {
    return `${prelude} $app=$null; $book=$null; try { $app=New-Object -ComObject Excel.Application; $app.Visible=$false; $app.DisplayAlerts=$false; $book=$app.Workbooks.Open($path,0,$true); foreach($sheet in $book.Worksheets){ Write-Output ('# '+$sheet.Name); $range=$sheet.UsedRange; $rows=[Math]::Min($range.Rows.Count,2000); $cols=[Math]::Min($range.Columns.Count,100); for($r=1;$r -le $rows;$r++){ $line=@(); for($c=1;$c -le $cols;$c++){ $line += [string]$range.Cells.Item($r,$c).Text }; Write-Output ($line -join [char]9) } } } finally { if($book){$book.Close($false)}; if($app){$app.Quit()} }`
  }
  return `${prelude} $app=$null; $deck=$null; try { $app=New-Object -ComObject PowerPoint.Application; $deck=$app.Presentations.Open($path,$true,$true,$false); foreach($slide in $deck.Slides){ Write-Output ('# Slide '+$slide.SlideIndex); foreach($shape in $slide.Shapes){ if($shape.HasTextFrame -and $shape.TextFrame.HasText){ Write-Output $shape.TextFrame.TextRange.Text } } } } finally { if($deck){$deck.Close()}; if($app){$app.Quit()} }`
}
