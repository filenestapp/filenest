import { app, safeStorage } from 'electron'
import initSqlJs, { type Database as SqlDatabase, type SqlJsStatic } from 'sql.js'
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import type { AppStatistics, ChatMessage, ChatSession, FileCategory, FileRecord, Rule, Settings } from '../shared/types'
import { CATEGORY_FOLDERS, createDefaultSettings } from './defaults'

type SqlValue = string | number | Uint8Array | null
const SECRET_SETTING_KEYS = new Set<keyof Settings>(['cloudApiKey', 'cloudEmbeddingApiKey', 'cloudOcrApiKey'])
const SECRET_PREFIX = 'filenest-secure:v1:'

export interface EmbeddingRow {
  fileId: number
  chunkIndex: number
  vector: Float32Array
  model: string
  chunkText: string
}

export class FileNestDatabase {
  private db!: SqlDatabase
  private SQL!: SqlJsStatic
  private flushChain: Promise<void> = Promise.resolve()
  readonly path = join(app.getPath('userData'), 'filenest-windows.sqlite')

  async initialize(): Promise<void> {
    const wasmPath = app.isPackaged
      ? join(process.resourcesPath, 'sql-wasm.wasm')
      : join(process.cwd(), 'node_modules', 'sql.js', 'dist', 'sql-wasm.wasm')
    this.SQL = await initSqlJs({ locateFile: () => wasmPath })
    await mkdir(dirname(this.path), { recursive: true })
    this.db = existsSync(this.path) ? new this.SQL.Database(await readFile(this.path)) : new this.SQL.Database()
    this.migrate()
    this.seedRules()
    await this.flush()
  }

  private migrate(): void {
    this.db.run(`
      PRAGMA foreign_keys = ON;
      CREATE TABLE IF NOT EXISTS files (
        id INTEGER PRIMARY KEY AUTOINCREMENT, path TEXT NOT NULL UNIQUE, name TEXT NOT NULL,
        ext TEXT NOT NULL, size INTEGER NOT NULL, mtime TEXT NOT NULL, category TEXT NOT NULL,
        source_dir TEXT NOT NULL, indexed_at TEXT, content_hash TEXT, title TEXT, content_text TEXT,
        discovered_at TEXT NOT NULL, organized_at TEXT, note TEXT, organization_subfolder TEXT,
        is_directory INTEGER NOT NULL DEFAULT 0, index_signature TEXT
      );
      CREATE TABLE IF NOT EXISTS embeddings (
        id INTEGER PRIMARY KEY AUTOINCREMENT, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        chunk_index INTEGER NOT NULL, vector BLOB NOT NULL, vector_text TEXT, dim INTEGER NOT NULL, model TEXT NOT NULL,
        chunk_text TEXT NOT NULL, UNIQUE(file_id, chunk_index)
      );
      CREATE TABLE IF NOT EXISTS rules (
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, type TEXT NOT NULL, pattern TEXT NOT NULL,
        target_folder TEXT NOT NULL, priority INTEGER NOT NULL, enabled INTEGER NOT NULL, action TEXT NOT NULL DEFAULT 'organize'
      );
      CREATE TABLE IF NOT EXISTS chat_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL, attached_file_path TEXT
      );
      CREATE TABLE IF NOT EXISTS chat_messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
        role TEXT NOT NULL, content TEXT NOT NULL, ts TEXT NOT NULL, related_file_ids TEXT NOT NULL DEFAULT '[]'
      );
      CREATE TABLE IF NOT EXISTS token_usage (
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
        input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, session_id INTEGER
      );
      CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS idx_files_added ON files(discovered_at DESC);
      CREATE INDEX IF NOT EXISTS idx_embeddings_file ON embeddings(file_id);
      CREATE INDEX IF NOT EXISTS idx_chat_messages_session ON chat_messages(session_id, ts);
    `)
    const embeddingColumns = this.rows('PRAGMA table_info(embeddings)').map((row) => String(row.name))
    if (!embeddingColumns.includes('vector_text')) this.db.run('ALTER TABLE embeddings ADD COLUMN vector_text TEXT')
    this.db.run("UPDATE rules SET target_folder='Documents' WHERE name='PDF Documents' AND pattern='*.pdf' AND target_folder='Documents/PDF'")
    this.db.run("UPDATE rules SET target_folder='Documents' WHERE name='Office Documents' AND pattern='*.doc;*.docx;*.docm;*.xls;*.xlsx;*.ppt;*.pptx' AND target_folder='Documents/Office'")
  }

  private seedRules(): void {
    const count = Number(this.scalar('SELECT COUNT(*) FROM rules') ?? 0)
    if (count > 0) return
    const seeds = [
      ['PDF Documents', '*.pdf', 'Documents', 90],
      ['Office Documents', '*.doc;*.docx;*.docm;*.xls;*.xlsx;*.ppt;*.pptx', 'Documents', 80],
      ['Images', '*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp', 'Images', 70],
      ['Code', '*.swift;*.py;*.js;*.ts;*.tsx;*.jsx;*.java;*.go;*.rs;*.cs', 'Code', 60],
      ['Archives', '*.zip;*.rar;*.7z;*.tar;*.gz', 'Archives', 50]
    ]
    for (const [name, pattern, target, priority] of seeds) {
      this.db.run('INSERT INTO rules(name,type,pattern,target_folder,priority,enabled,action) VALUES(?,?,?,?,?,1,\'organize\')', [name, 'rule', pattern, target, priority] as SqlValue[])
    }
  }

  private rows(sql: string, params: SqlValue[] = []): Record<string, unknown>[] {
    const statement = this.db.prepare(sql, params)
    const result: Record<string, unknown>[] = []
    try {
      while (statement.step()) result.push(statement.getAsObject())
    } finally {
      statement.free()
    }
    return result
  }

  private scalar(sql: string, params: SqlValue[] = []): unknown {
    return Object.values(this.rows(sql, params)[0] ?? {})[0]
  }

  async flush(): Promise<void> {
    const snapshot = this.db.export()
    this.flushChain = this.flushChain.catch(() => undefined).then(() => writeFile(this.path, snapshot))
    await this.flushChain
  }

  getSettings(): Settings {
    const defaults = createDefaultSettings()
    const stored = Object.fromEntries(this.rows('SELECT key,value FROM settings').map((row) => {
      const key = String(row.key) as keyof Settings
      const value = JSON.parse(String(row.value)) as unknown
      return [key, SECRET_SETTING_KEYS.has(key) ? decryptSecret(value) : value]
    }))
    return { ...defaults, ...stored }
  }

  async updateSettings(patch: Partial<Settings>): Promise<Settings> {
    this.db.run('BEGIN')
    try {
      for (const [key, value] of Object.entries(patch)) {
        const storedValue = SECRET_SETTING_KEYS.has(key as keyof Settings) ? encryptSecret(value) : value
        this.db.run('INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', [key, JSON.stringify(storedValue)])
      }
      this.db.run('COMMIT')
    } catch (error) {
      this.db.run('ROLLBACK')
      throw error
    }
    await this.flush()
    return this.getSettings()
  }

  listFiles(): FileRecord[] {
    return this.rows('SELECT * FROM files ORDER BY discovered_at DESC').map(mapFile)
  }

  getFile(id: number): FileRecord | null {
    const row = this.rows('SELECT * FROM files WHERE id=?', [id])[0]
    return row ? mapFile(row) : null
  }

  getFileByPath(path: string): FileRecord | null {
    const row = this.rows('SELECT * FROM files WHERE path=? COLLATE NOCASE', [path])[0]
    return row ? mapFile(row) : null
  }

  searchFiles(query: string, category?: FileCategory | null, limit = 200): FileRecord[] {
    const needle = `%${query.replace(/[\\%_]/g, '\\$&')}%`
    const categoryClause = category ? ' AND category=?' : ''
    const params: SqlValue[] = [needle, needle, needle]
    if (category) params.push(category)
    params.push(limit)
    return this.rows(`SELECT * FROM files WHERE (name LIKE ? ESCAPE '\\' OR COALESCE(title,'') LIKE ? ESCAPE '\\' OR COALESCE(content_text,'') LIKE ? ESCAPE '\\')${categoryClause} ORDER BY discovered_at DESC LIMIT ?`, params).map(mapFile)
  }

  async upsertFile(input: Omit<FileRecord, 'id'>): Promise<FileRecord> {
    const existing = this.getFileByPath(input.path)
    const values: SqlValue[] = [input.path, input.name, input.ext, input.size, input.mtime, input.category, input.sourceDir, input.indexedAt, input.contentHash, input.title, input.contentText, input.discoveredAt, input.organizedAt, input.note, input.organizationSubfolder, input.isDirectory ? 1 : 0, input.indexSignature]
    if (existing) {
      this.db.run(`UPDATE files SET path=?,name=?,ext=?,size=?,mtime=?,category=?,source_dir=?,indexed_at=?,content_hash=?,title=?,content_text=?,discovered_at=?,organized_at=?,note=?,organization_subfolder=?,is_directory=?,index_signature=? WHERE id=?`, [...values, existing.id])
      await this.flush()
      return this.getFile(existing.id)!
    }
    this.db.run(`INSERT INTO files(path,name,ext,size,mtime,category,source_dir,indexed_at,content_hash,title,content_text,discovered_at,organized_at,note,organization_subfolder,is_directory,index_signature) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, values)
    const id = Number(this.scalar('SELECT last_insert_rowid()'))
    await this.flush()
    return this.getFile(id)!
  }

  async updateFile(id: number, patch: Partial<FileRecord>): Promise<void> {
    const allowed: Record<string, string> = { path: 'path', name: 'name', size: 'size', mtime: 'mtime', category: 'category', sourceDir: 'source_dir', indexedAt: 'indexed_at', contentHash: 'content_hash', title: 'title', contentText: 'content_text', organizedAt: 'organized_at', note: 'note', organizationSubfolder: 'organization_subfolder', indexSignature: 'index_signature' }
    const entries = Object.entries(patch).filter(([key]) => key in allowed)
    if (!entries.length) return
    this.db.run(`UPDATE files SET ${entries.map(([key]) => `${allowed[key]}=?`).join(',')} WHERE id=?`, [...entries.map(([, value]) => value as SqlValue), id])
    await this.flush()
  }

  async deleteFile(id: number): Promise<void> {
    this.db.run('DELETE FROM files WHERE id=?', [id])
    await this.flush()
  }

  async replaceEmbeddings(fileId: number, chunks: Array<{ vector: Float32Array; text: string }>, model: string): Promise<void> {
    this.db.run('BEGIN')
    try {
      this.db.run('DELETE FROM embeddings WHERE file_id=?', [fileId])
      chunks.forEach((chunk, index) => {
        const bytes = new Uint8Array(chunk.vector.buffer.slice(chunk.vector.byteOffset, chunk.vector.byteOffset + chunk.vector.byteLength))
        const encoded = Buffer.from(bytes).toString('base64')
        this.db.run('INSERT INTO embeddings(file_id,chunk_index,vector,vector_text,dim,model,chunk_text) VALUES(?,?,?,?,?,?,?)', [fileId, index, new Uint8Array([0]), encoded, chunk.vector.length, model, chunk.text])
      })
      this.db.run('COMMIT')
    } catch (error) {
      this.db.run('ROLLBACK')
      throw error
    }
    await this.flush()
  }

  listEmbeddings(fileId?: number): EmbeddingRow[] {
    const rows = fileId == null
      ? this.rows('SELECT file_id,chunk_index,vector,vector_text,dim,model,chunk_text FROM embeddings ORDER BY file_id,chunk_index')
      : this.rows('SELECT file_id,chunk_index,vector,vector_text,dim,model,chunk_text FROM embeddings WHERE file_id=? ORDER BY chunk_index', [fileId])
    return rows.map((row) => {
      const bytes = row.vector_text ? Uint8Array.from(Buffer.from(String(row.vector_text), 'base64')) : typeof row.vector === 'string' ? Uint8Array.from(Buffer.from(row.vector, 'base64')) : row.vector as Uint8Array
      const aligned = bytes.byteOffset % 4 === 0 ? bytes : Uint8Array.from(bytes)
      return { fileId: Number(row.file_id), chunkIndex: Number(row.chunk_index), vector: new Float32Array(aligned.buffer, aligned.byteOffset, aligned.byteLength / 4), model: String(row.model), chunkText: String(row.chunk_text) }
    })
  }

  listRules(): Rule[] {
    return this.rows('SELECT * FROM rules ORDER BY priority DESC,id ASC').map(mapRule)
  }

  async createRule(rule: Omit<Rule, 'id'>): Promise<Rule> {
    this.db.run('INSERT INTO rules(name,type,pattern,target_folder,priority,enabled,action) VALUES(?,?,?,?,?,?,?)', [rule.name, rule.type, rule.pattern, rule.targetFolder, rule.priority, rule.enabled ? 1 : 0, rule.action])
    const id = Number(this.scalar('SELECT last_insert_rowid()'))
    await this.flush()
    return this.listRules().find((item) => item.id === id)!
  }

  async updateRule(rule: Rule): Promise<Rule> {
    this.db.run('UPDATE rules SET name=?,type=?,pattern=?,target_folder=?,priority=?,enabled=?,action=? WHERE id=?', [rule.name, rule.type, rule.pattern, rule.targetFolder, rule.priority, rule.enabled ? 1 : 0, rule.action, rule.id])
    await this.flush()
    return this.listRules().find((item) => item.id === rule.id)!
  }

  async deleteRule(id: number): Promise<void> {
    this.db.run('DELETE FROM rules WHERE id=?', [id])
    await this.flush()
  }

  listChatSessions(): ChatSession[] {
    return this.rows('SELECT * FROM chat_sessions ORDER BY updated_at DESC').map(mapSession)
  }

  async createChat(attachedFilePath: string | null = null): Promise<ChatSession> {
    const now = new Date().toISOString()
    this.db.run('INSERT INTO chat_sessions(title,created_at,updated_at,attached_file_path) VALUES(?,?,?,?)', ['New Chat', now, now, attachedFilePath])
    const id = Number(this.scalar('SELECT last_insert_rowid()'))
    await this.flush()
    return this.listChatSessions().find((item) => item.id === id)!
  }

  async updateChat(id: number, patch: Partial<Pick<ChatSession, 'title' | 'updatedAt' | 'attachedFilePath'>>): Promise<void> {
    const entries = Object.entries(patch)
    if (!entries.length) return
    const names: Record<string, string> = { title: 'title', updatedAt: 'updated_at', attachedFilePath: 'attached_file_path' }
    this.db.run(`UPDATE chat_sessions SET ${entries.map(([key]) => `${names[key]}=?`).join(',')} WHERE id=?`, [...entries.map(([, value]) => value), id] as SqlValue[])
    await this.flush()
  }

  listMessages(sessionId: number): ChatMessage[] {
    return this.rows('SELECT * FROM chat_messages WHERE session_id=? ORDER BY ts,id', [sessionId]).map(mapMessage)
  }

  async addMessage(sessionId: number, role: ChatMessage['role'], content: string, relatedFileIds: number[] = []): Promise<ChatMessage> {
    const now = new Date().toISOString()
    this.db.run('INSERT INTO chat_messages(session_id,role,content,ts,related_file_ids) VALUES(?,?,?,?,?)', [sessionId, role, content, now, JSON.stringify(relatedFileIds)])
    const id = Number(this.scalar('SELECT last_insert_rowid()'))
    await this.updateChat(sessionId, { updatedAt: now })
    return this.listMessages(sessionId).find((item) => item.id === id)!
  }

  async deleteChat(id: number): Promise<void> {
    this.db.run('DELETE FROM chat_sessions WHERE id=?', [id])
    await this.flush()
  }

  async clearChats(): Promise<void> {
    this.db.run('DELETE FROM chat_sessions')
    await this.flush()
  }

  async recordUsage(provider: string, model: string, inputTokens: number, outputTokens: number, sessionId: number): Promise<void> {
    this.db.run('INSERT INTO token_usage(ts,provider,model,input_tokens,output_tokens,session_id) VALUES(?,?,?,?,?,?)', [new Date().toISOString(), provider, model, inputTokens, outputTokens, sessionId])
    await this.flush()
  }

  async statistics(days = 14): Promise<AppStatistics> {
    const files = this.listFiles()
    const usage = this.rows('SELECT * FROM token_usage')
    const today = new Date().toISOString().slice(0, 10)
    const dailyActivity = Array.from({ length: days }, (_, offset) => {
      const date = new Date()
      date.setDate(date.getDate() - (days - offset - 1))
      const day = date.toISOString().slice(0, 10)
      return {
        day,
        addedFiles: files.filter((file) => file.discoveredAt.startsWith(day)).length,
        indexedFiles: files.filter((file) => file.indexedAt?.startsWith(day)).length,
        tokens: usage.filter((row) => String(row.ts).startsWith(day)).reduce((sum, row) => sum + Number(row.input_tokens) + Number(row.output_tokens), 0)
      }
    })
    const categoryStorage = (Object.keys(CATEGORY_FOLDERS) as FileCategory[]).map((category) => {
      const items = files.filter((file) => file.category === category)
      return { category, bytes: items.reduce((sum, file) => sum + file.size, 0), fileCount: items.length }
    })
    const dbBytes = await stat(this.path).then((value) => value.size).catch(() => 0)
    return {
      totalFiles: files.length,
      indexedFiles: files.filter((file) => file.indexedAt).length,
      todayAddedFiles: files.filter((file) => file.discoveredAt.startsWith(today)).length,
      totalTokens: usage.reduce((sum, row) => sum + Number(row.input_tokens) + Number(row.output_tokens), 0),
      todayTokens: usage.filter((row) => String(row.ts).startsWith(today)).reduce((sum, row) => sum + Number(row.input_tokens) + Number(row.output_tokens), 0),
      managedFileBytes: files.reduce((sum, file) => sum + file.size, 0),
      databaseBytes: dbBytes,
      vectorBytes: this.listEmbeddings().reduce((sum, item) => sum + item.vector.byteLength, 0),
      extractedTextBytes: files.reduce((sum, file) => sum + Buffer.byteLength(file.contentText ?? '', 'utf8'), 0),
      dailyActivity,
      categoryStorage
    }
  }
}

function encryptSecret(value: unknown): unknown {
  if (typeof value !== 'string' || !value || value.startsWith(SECRET_PREFIX) || !safeStorage?.isEncryptionAvailable()) return value
  return SECRET_PREFIX + safeStorage.encryptString(value).toString('base64')
}

function decryptSecret(value: unknown): unknown {
  if (typeof value !== 'string' || !value.startsWith(SECRET_PREFIX) || !safeStorage?.isEncryptionAvailable()) return value
  try { return safeStorage.decryptString(Buffer.from(value.slice(SECRET_PREFIX.length), 'base64')) } catch { return '' }
}

function mapFile(row: Record<string, unknown>): FileRecord {
  return { id: Number(row.id), path: String(row.path), name: String(row.name), ext: String(row.ext), size: Number(row.size), mtime: String(row.mtime), category: String(row.category) as FileCategory, sourceDir: String(row.source_dir), indexedAt: row.indexed_at == null ? null : String(row.indexed_at), contentHash: row.content_hash == null ? null : String(row.content_hash), title: row.title == null ? null : String(row.title), contentText: row.content_text == null ? null : String(row.content_text), discoveredAt: String(row.discovered_at), organizedAt: row.organized_at == null ? null : String(row.organized_at), note: row.note == null ? null : String(row.note), organizationSubfolder: row.organization_subfolder == null ? null : String(row.organization_subfolder), isDirectory: Boolean(row.is_directory), indexSignature: row.index_signature == null ? null : String(row.index_signature) }
}

function mapRule(row: Record<string, unknown>): Rule {
  return { id: Number(row.id), name: String(row.name), type: String(row.type) as Rule['type'], pattern: String(row.pattern), targetFolder: String(row.target_folder), priority: Number(row.priority), enabled: Boolean(row.enabled), action: String(row.action) as Rule['action'] }
}

function mapSession(row: Record<string, unknown>): ChatSession {
  return { id: Number(row.id), title: String(row.title), createdAt: String(row.created_at), updatedAt: String(row.updated_at), attachedFilePath: row.attached_file_path == null ? null : String(row.attached_file_path) }
}

function mapMessage(row: Record<string, unknown>): ChatMessage {
  return { id: Number(row.id), sessionId: Number(row.session_id), role: String(row.role) as ChatMessage['role'], content: String(row.content), timestamp: String(row.ts), relatedFileIds: JSON.parse(String(row.related_file_ids || '[]')) as number[] }
}
