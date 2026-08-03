import { app, safeStorage } from 'electron'
import initSqlJs, { type Database as SqlDatabase, type SqlJsStatic } from 'sql.js'
import { mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { homedir } from 'node:os'
import type { AppStatistics, ChatFeedback, ChatMessage, ChatRelatedFileMatch, ChatSession, DocumentChunk, FileCategory, FileRecord, LibrarySearchHistoryEntry, RagFeedbackDraft, RagFeedbackRecord, ReindexJobFileItem, ReindexJobSummary, ReindexMode, Rule, Settings } from '../shared/types'
import { CANONICAL_TOKENIZER_PROFILE, CANONICAL_TOKENIZER_VERSION, estimateCanonicalTokens, GENERATION_FALLBACK_PROFILE } from './token-counter'
import { CATEGORY_FOLDERS, createDefaultSettings } from './defaults'

type SqlValue = string | number | Uint8Array | null
const SECRET_SETTING_KEYS = new Set<keyof Settings>(['cloudApiKey', 'cloudEmbeddingApiKey', 'cloudOcrApiKey', 'rerankerApiKey'])
const SECRET_PREFIX = 'filenest-secure:v1:'

export interface EmbeddingRow {
  fileId: number
  chunkIndex: number
  vector: Float32Array
  model: string
  chunkText: string
}

export interface RAGSearchTrace {
  query: string
  semanticQuery: string
  lexicalCandidates: number
  semanticCandidates: number
  entityCandidates: number
  fusedCandidates: number
  returnedResults: number
  semanticThreshold: number | null
  reranker: string | null
  durationMs: number
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
        is_directory INTEGER NOT NULL DEFAULT 0, index_signature TEXT, creation_date TEXT,
        duplicate_of_file_id INTEGER REFERENCES files(id) ON DELETE SET NULL, duplicate_detected_at TEXT
      );
      CREATE TABLE IF NOT EXISTS embeddings (
        id INTEGER PRIMARY KEY AUTOINCREMENT, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        chunk_index INTEGER NOT NULL, vector BLOB NOT NULL, vector_text TEXT, dim INTEGER NOT NULL, model TEXT NOT NULL,
        chunk_text TEXT NOT NULL, UNIQUE(file_id, chunk_index)
      );
      CREATE TABLE IF NOT EXISTS document_chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        chunk_index INTEGER NOT NULL, text TEXT NOT NULL, contextual_text TEXT NOT NULL,
        section_path TEXT NOT NULL DEFAULT '[]', page_start INTEGER, page_end INTEGER,
        kind TEXT NOT NULL DEFAULT 'text', parent_index INTEGER, entity_terms TEXT NOT NULL DEFAULT '[]',
        token_count INTEGER NOT NULL DEFAULT 0,
        tokenizer_profile TEXT NOT NULL DEFAULT '${CANONICAL_TOKENIZER_PROFILE}',
        tokenizer_version TEXT NOT NULL DEFAULT '${CANONICAL_TOKENIZER_VERSION}',
        token_count_accuracy TEXT NOT NULL DEFAULT 'estimated', UNIQUE(file_id, chunk_index)
      );
      CREATE TABLE IF NOT EXISTS document_parents (
        id INTEGER PRIMARY KEY AUTOINCREMENT, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        parent_index INTEGER NOT NULL, text TEXT NOT NULL, contextual_text TEXT NOT NULL,
        section_path TEXT NOT NULL DEFAULT '[]', page_start INTEGER, page_end INTEGER,
        kind TEXT NOT NULL DEFAULT 'text', token_count INTEGER NOT NULL DEFAULT 0,
        tokenizer_profile TEXT NOT NULL DEFAULT '${CANONICAL_TOKENIZER_PROFILE}',
        tokenizer_version TEXT NOT NULL DEFAULT '${CANONICAL_TOKENIZER_VERSION}',
        token_count_accuracy TEXT NOT NULL DEFAULT 'estimated', UNIQUE(file_id, parent_index)
      );
      CREATE TABLE IF NOT EXISTS rag_search_traces (
        id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL, query TEXT NOT NULL,
        semantic_query TEXT NOT NULL, lexical_candidates INTEGER NOT NULL,
        semantic_candidates INTEGER NOT NULL, entity_candidates INTEGER NOT NULL,
        fused_candidates INTEGER NOT NULL, returned_results INTEGER NOT NULL,
        semantic_threshold REAL, reranker TEXT, duration_ms REAL NOT NULL
      );
      CREATE TABLE IF NOT EXISTS library_search_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT, normalized_query TEXT NOT NULL, query TEXT NOT NULL,
        smart INTEGER NOT NULL DEFAULT 0, result_count INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL, UNIQUE(normalized_query,smart)
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
        role TEXT NOT NULL, content TEXT NOT NULL, ts TEXT NOT NULL, related_file_ids TEXT NOT NULL DEFAULT '[]',
        input_tokens INTEGER, output_tokens INTEGER, first_response_duration REAL, total_response_duration REAL,
        response_provider TEXT, response_model TEXT, related_file_matches TEXT NOT NULL DEFAULT '[]', feedback TEXT
      );
      CREATE TABLE IF NOT EXISTS rag_feedback (
        id INTEGER PRIMARY KEY AUTOINCREMENT, source_key TEXT NOT NULL UNIQUE, source_kind TEXT NOT NULL,
        message_id INTEGER REFERENCES chat_messages(id) ON DELETE CASCADE, session_id INTEGER REFERENCES chat_sessions(id) ON DELETE CASCADE,
        search_query TEXT, result_file_ids TEXT NOT NULL DEFAULT '[]', rating TEXT NOT NULL,
        reason TEXT, best_file_id INTEGER REFERENCES files(id) ON DELETE SET NULL, best_file_reason TEXT,
        analysis_status TEXT NOT NULL DEFAULT 'pending', analysis_summary TEXT, analysis_error TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL, analyzed_at TEXT
      );
      CREATE TABLE IF NOT EXISTS reindex_jobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT, status TEXT NOT NULL, mode TEXT NOT NULL, categories TEXT NOT NULL DEFAULT '[]',
        total INTEGER NOT NULL, completed INTEGER NOT NULL DEFAULT 0, failed INTEGER NOT NULL DEFAULT 0, current_file_name TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS reindex_job_files (
        job_id INTEGER NOT NULL REFERENCES reindex_jobs(id) ON DELETE CASCADE, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        state TEXT NOT NULL DEFAULT 'queued', error TEXT, updated_at TEXT NOT NULL, PRIMARY KEY(job_id,file_id)
      );
      CREATE TABLE IF NOT EXISTS token_usage (
        id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
        input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL, session_id INTEGER,
        tokenizer_profile TEXT NOT NULL DEFAULT '${GENERATION_FALLBACK_PROFILE}',
        token_count_accuracy TEXT NOT NULL DEFAULT 'estimated'
      );
      CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS watch_directory_baseline_entries (
        directory_path TEXT NOT NULL, entry_path TEXT NOT NULL,
        PRIMARY KEY(directory_path, entry_path)
      );
      CREATE INDEX IF NOT EXISTS idx_files_added ON files(discovered_at DESC);
      CREATE INDEX IF NOT EXISTS idx_embeddings_file ON embeddings(file_id);
      CREATE INDEX IF NOT EXISTS idx_chunks_file ON document_chunks(file_id, chunk_index);
      CREATE INDEX IF NOT EXISTS idx_parents_file ON document_parents(file_id, parent_index);
      CREATE INDEX IF NOT EXISTS idx_chat_messages_session ON chat_messages(session_id, ts);
      CREATE INDEX IF NOT EXISTS idx_rag_feedback_updated ON rag_feedback(updated_at DESC);
      CREATE INDEX IF NOT EXISTS idx_library_search_history_updated ON library_search_history(updated_at DESC);
      CREATE INDEX IF NOT EXISTS idx_reindex_job_files_state ON reindex_job_files(job_id,state);
    `)
    const embeddingColumns = this.rows('PRAGMA table_info(embeddings)').map((row) => String(row.name))
    if (!embeddingColumns.includes('vector_text')) this.db.run('ALTER TABLE embeddings ADD COLUMN vector_text TEXT')
    const chunkColumns = this.rows('PRAGMA table_info(document_chunks)').map((row) => String(row.name))
    if (!chunkColumns.includes('token_count')) this.db.run('ALTER TABLE document_chunks ADD COLUMN token_count INTEGER NOT NULL DEFAULT 0')
    if (!chunkColumns.includes('tokenizer_profile')) this.db.run(`ALTER TABLE document_chunks ADD COLUMN tokenizer_profile TEXT NOT NULL DEFAULT '${CANONICAL_TOKENIZER_PROFILE}'`)
    if (!chunkColumns.includes('tokenizer_version')) this.db.run(`ALTER TABLE document_chunks ADD COLUMN tokenizer_version TEXT NOT NULL DEFAULT '${CANONICAL_TOKENIZER_VERSION}'`)
    if (!chunkColumns.includes('token_count_accuracy')) this.db.run("ALTER TABLE document_chunks ADD COLUMN token_count_accuracy TEXT NOT NULL DEFAULT 'estimated'")
    if (!chunkColumns.includes('parent_index')) this.db.run('ALTER TABLE document_chunks ADD COLUMN parent_index INTEGER')
    if (!chunkColumns.includes('entity_terms')) this.db.run("ALTER TABLE document_chunks ADD COLUMN entity_terms TEXT NOT NULL DEFAULT '[]'")
    this.db.run('CREATE INDEX IF NOT EXISTS idx_chunks_parent ON document_chunks(file_id, parent_index)')
    const usageColumns = this.rows('PRAGMA table_info(token_usage)').map((row) => String(row.name))
    if (!usageColumns.includes('tokenizer_profile')) this.db.run(`ALTER TABLE token_usage ADD COLUMN tokenizer_profile TEXT NOT NULL DEFAULT '${GENERATION_FALLBACK_PROFILE}'`)
    if (!usageColumns.includes('token_count_accuracy')) this.db.run("ALTER TABLE token_usage ADD COLUMN token_count_accuracy TEXT NOT NULL DEFAULT 'estimated'")

    const messageColumns = this.rows('PRAGMA table_info(chat_messages)').map((row) => String(row.name))
    const messageMigrations: Array<[string, string]> = [
      ['input_tokens', 'INTEGER'], ['output_tokens', 'INTEGER'],
      ['first_response_duration', 'REAL'], ['total_response_duration', 'REAL'],
      ['response_provider', 'TEXT'], ['response_model', 'TEXT'],
      ['related_file_matches', "TEXT NOT NULL DEFAULT '[]'"], ['feedback', 'TEXT']
    ]
    for (const [name, type] of messageMigrations) {
      if (!messageColumns.includes(name)) this.db.run(`ALTER TABLE chat_messages ADD COLUMN ${name} ${type}`)
    }
    const fileColumns = this.rows('PRAGMA table_info(files)').map((row) => String(row.name))
    const fileMigrations: Array<[string, string]> = [
      ['creation_date', 'TEXT'], ['duplicate_of_file_id', 'INTEGER'], ['duplicate_detected_at', 'TEXT']
    ]
    for (const [name, type] of fileMigrations) {
      if (!fileColumns.includes(name)) this.db.run(`ALTER TABLE files ADD COLUMN ${name} ${type}`)
    }
    this.db.run('CREATE INDEX IF NOT EXISTS idx_files_content_hash ON files(content_hash)')
    this.db.run('CREATE INDEX IF NOT EXISTS idx_files_duplicate_original ON files(duplicate_of_file_id)')
    this.runMigrationOnce('structured_chunk_backfill_v1', () => {
      for (const row of this.rows(
        "SELECT id,contextual_text FROM document_chunks WHERE token_count=0 OR (token_count_accuracy='estimated' AND tokenizer_version!=?)",
        [CANONICAL_TOKENIZER_VERSION]
      )) {
        const measurement = estimateCanonicalTokens(String(row.contextual_text ?? ''))
        this.db.run(
          'UPDATE document_chunks SET token_count=?,tokenizer_profile=?,tokenizer_version=?,token_count_accuracy=? WHERE id=?',
          [measurement.count, measurement.tokenizerProfile, measurement.tokenizerVersion, measurement.accuracy, Number(row.id)]
        )
      }
      this.db.run(`INSERT OR IGNORE INTO document_chunks(file_id,chunk_index,text,contextual_text,section_path,kind)
        SELECT file_id,chunk_index,chunk_text,chunk_text,'[]','text' FROM embeddings WHERE COALESCE(chunk_text,'') <> ''`)
      this.db.run('UPDATE document_chunks SET parent_index=chunk_index WHERE parent_index IS NULL')
      this.db.run(`INSERT OR IGNORE INTO document_parents(file_id,parent_index,text,contextual_text,section_path,page_start,page_end,kind,token_count,tokenizer_profile,tokenizer_version,token_count_accuracy)
        SELECT file_id,chunk_index,text,contextual_text,section_path,page_start,page_end,kind,token_count,tokenizer_profile,tokenizer_version,token_count_accuracy FROM document_chunks`)
      this.db.run(`DELETE FROM document_parents WHERE NOT EXISTS (SELECT 1 FROM document_chunks
        WHERE document_chunks.file_id=document_parents.file_id AND document_chunks.parent_index=document_parents.parent_index)`)
    })
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

  private runMigrationOnce(name: string, action: () => void): void {
    if (this.scalar('SELECT 1 FROM schema_migrations WHERE name=?', [name])) return
    this.db.run('BEGIN')
    try {
      action()
      this.db.run('INSERT INTO schema_migrations(name,applied_at) VALUES(?,?)', [name, new Date().toISOString()])
      this.db.run('COMMIT')
    } catch (error) {
      this.db.run('ROLLBACK')
      throw error
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

  getInternalSetting(key: string): string | null {
    const row = this.rows('SELECT value FROM settings WHERE key=?', [key])[0]
    if (!row) return null
    try {
      const value = JSON.parse(String(row.value)) as unknown
      return typeof value === 'string' ? value : String(value)
    } catch {
      return String(row.value)
    }
  }

  async setInternalSetting(key: string, value: string): Promise<void> {
    this.db.run('INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value', [key, JSON.stringify(value)])
    await this.flush()
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
    const params: SqlValue[] = [needle, needle, needle, needle, needle]
    if (category) params.push(category)
    params.push(limit)
    return this.rows(`SELECT * FROM files WHERE (name LIKE ? ESCAPE '\\' OR path LIKE ? ESCAPE '\\' OR COALESCE(title,'') LIKE ? ESCAPE '\\' OR COALESCE(note,'') LIKE ? ESCAPE '\\' OR COALESCE(content_text,'') LIKE ? ESCAPE '\\')${categoryClause} ORDER BY discovered_at DESC LIMIT ?`, params).map(mapFile)
  }

  async upsertFile(input: Omit<FileRecord, 'id'>): Promise<FileRecord> {
    const existing = this.getFileByPath(input.path)
    const values: SqlValue[] = [input.path, input.name, input.ext, input.size, input.mtime, input.category, input.sourceDir, input.indexedAt, input.contentHash, input.title, input.contentText, input.discoveredAt, input.organizedAt, input.note, input.organizationSubfolder, input.isDirectory ? 1 : 0, input.indexSignature, input.creationDate ?? existing?.creationDate ?? null, input.duplicateOfFileId ?? existing?.duplicateOfFileId ?? null, input.duplicateDetectedAt ?? existing?.duplicateDetectedAt ?? null]
    if (existing) {
      this.db.run(`UPDATE files SET path=?,name=?,ext=?,size=?,mtime=?,category=?,source_dir=?,indexed_at=?,content_hash=?,title=?,content_text=?,discovered_at=?,organized_at=?,note=?,organization_subfolder=?,is_directory=?,index_signature=?,creation_date=?,duplicate_of_file_id=?,duplicate_detected_at=? WHERE id=?`, [...values, existing.id])
      await this.flush()
      return this.getFile(existing.id)!
    }
    this.db.run(`INSERT INTO files(path,name,ext,size,mtime,category,source_dir,indexed_at,content_hash,title,content_text,discovered_at,organized_at,note,organization_subfolder,is_directory,index_signature,creation_date,duplicate_of_file_id,duplicate_detected_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`, values)
    const id = Number(this.scalar('SELECT last_insert_rowid()'))
    await this.flush()
    return this.getFile(id)!
  }

  async updateFile(id: number, patch: Partial<FileRecord>): Promise<void> {
    const allowed: Record<string, string> = { path: 'path', name: 'name', size: 'size', mtime: 'mtime', category: 'category', sourceDir: 'source_dir', indexedAt: 'indexed_at', contentHash: 'content_hash', title: 'title', contentText: 'content_text', organizedAt: 'organized_at', note: 'note', organizationSubfolder: 'organization_subfolder', indexSignature: 'index_signature', creationDate: 'creation_date', duplicateOfFileId: 'duplicate_of_file_id', duplicateDetectedAt: 'duplicate_detected_at' }
    const entries = Object.entries(patch).filter(([key]) => key in allowed)
    if (!entries.length) return
    this.db.run(`UPDATE files SET ${entries.map(([key]) => `${allowed[key]}=?`).join(',')} WHERE id=?`, [...entries.map(([, value]) => value as SqlValue), id])
    await this.flush()
  }

  async deleteFile(id: number): Promise<void> {
    this.db.run('DELETE FROM files WHERE id=?', [id])
    await this.flush()
  }

  filesMissingCreationDate(limit = 256): FileRecord[] {
    return this.rows('SELECT * FROM files WHERE creation_date IS NULL ORDER BY id LIMIT ?', [Math.max(1, Math.min(2_000, Math.floor(limit)))]).map(mapFile)
  }

  async updateCreationDates(values: Array<{ id: number; creationDate: string }>): Promise<void> {
    if (!values.length) return
    this.db.run('BEGIN')
    try {
      for (const value of values) this.db.run('UPDATE files SET creation_date=? WHERE id=?', [value.creationDate, value.id])
      this.db.run('COMMIT')
    } catch (error) {
      this.db.run('ROLLBACK')
      throw error
    }
    await this.flush()
  }

  async updateFileInventories(values: Array<{ id: number; contentHash: string; creationDate: string }>): Promise<void> {
    if (!values.length) return
    this.db.run('BEGIN')
    try {
      for (const value of values) this.db.run('UPDATE files SET content_hash=?,creation_date=? WHERE id=?', [value.contentHash, value.creationDate, value.id])
      this.db.run('COMMIT')
    } catch (error) {
      this.db.run('ROLLBACK')
      throw error
    }
    await this.flush()
  }

  managedContentAuditCandidates(rootPath: string, extensions: string[], afterId: number, limit = 256): FileRecord[] {
    const normalizedRoot = rootPath.replace(/[\\/]+$/, '')
    const pathPattern = `${normalizedRoot.replace(/[\\%_]/g, '\\$&')}%`
    const normalizedExtensions = [...new Set(extensions.map((value) => value.replace(/^\./, '').toLocaleLowerCase()))]
    if (!normalizedExtensions.length) return []
    const placeholders = normalizedExtensions.map(() => '?').join(',')
    return this.rows(`SELECT * FROM files WHERE id>? AND path LIKE ? ESCAPE '\\' AND indexed_at IS NOT NULL
      AND content_hash IS NOT NULL AND (is_directory=1 OR LOWER(ext) IN (${placeholders})) ORDER BY id LIMIT ?`,
    [afterId, pathPattern, ...normalizedExtensions, Math.max(1, Math.min(2_000, Math.floor(limit)))]).map(mapFile)
  }

  async invalidateFileIndexes(ids: number[]): Promise<void> {
    const unique = [...new Set(ids)]
    if (!unique.length) return
    this.db.run('BEGIN')
    try {
      for (const id of unique) {
        this.db.run('DELETE FROM embeddings WHERE file_id=?', [id])
        this.db.run('DELETE FROM document_chunks WHERE file_id=?', [id])
        this.db.run('DELETE FROM document_parents WHERE file_id=?', [id])
        this.db.run('UPDATE files SET indexed_at=NULL,index_signature=NULL,content_hash=NULL,duplicate_of_file_id=NULL,duplicate_detected_at=NULL WHERE id=?', [id])
      }
      this.db.run('COMMIT')
    } catch (error) {
      this.db.run('ROLLBACK')
      throw error
    }
    await this.flush()
  }

  filesMissingContentHash(): FileRecord[] {
    return this.rows('SELECT * FROM files WHERE is_directory=0 AND content_hash IS NULL ORDER BY id').map(mapFile)
  }

  indexedOriginal(contentHash: string, excludingFileId: number): FileRecord | null {
    const row = this.rows(`SELECT * FROM files WHERE content_hash=? AND id<>? AND indexed_at IS NOT NULL
      AND duplicate_of_file_id IS NULL ORDER BY COALESCE(discovered_at,organized_at,indexed_at,mtime),id LIMIT 1`, [contentHash, excludingFileId])[0]
    return row ? mapFile(row) : null
  }

  async markFileAsDuplicate(id: number, originalFileId: number, contentHash: string): Promise<void> {
    this.db.run('BEGIN')
    try {
      this.db.run('DELETE FROM embeddings WHERE file_id=?', [id])
      this.db.run('DELETE FROM document_chunks WHERE file_id=?', [id])
      this.db.run('DELETE FROM document_parents WHERE file_id=?', [id])
      this.db.run(`UPDATE files SET content_hash=?,duplicate_of_file_id=?,duplicate_detected_at=?,
        indexed_at=NULL,index_signature=NULL WHERE id=?`, [contentHash, originalFileId, new Date().toISOString(), id])
      this.db.run('COMMIT')
    } catch (error) {
      this.db.run('ROLLBACK')
      throw error
    }
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

  async commitFileIndex(
    fileId: number,
    chunks: Array<{ chunk: DocumentChunk; vector: Float32Array }>,
    model: string,
    patch: Pick<FileRecord, 'title' | 'contentText' | 'contentHash' | 'indexedAt' | 'indexSignature'>
  ): Promise<void> {
    this.db.run('BEGIN')
    try {
      this.db.run('DELETE FROM embeddings WHERE file_id=?', [fileId])
      this.db.run('DELETE FROM document_chunks WHERE file_id=?', [fileId])
      this.db.run('DELETE FROM document_parents WHERE file_id=?', [fileId])
      const parents = new Map<number, DocumentChunk>()
      for (const { chunk } of chunks) if (!parents.has(chunk.parentIndex)) parents.set(chunk.parentIndex, chunk)
      for (const [parentIndex, chunk] of parents) {
        const measurement = estimateCanonicalTokens(chunk.parentText)
        this.db.run(
          'INSERT INTO document_parents(file_id,parent_index,text,contextual_text,section_path,page_start,page_end,kind,token_count,tokenizer_profile,tokenizer_version,token_count_accuracy) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
          [fileId, parentIndex, chunk.parentText, chunk.parentText, JSON.stringify(chunk.sectionPath), chunk.pageStart, chunk.pageEnd,
            chunk.kind, measurement.count, measurement.tokenizerProfile, measurement.tokenizerVersion, measurement.accuracy]
        )
      }
      for (const { chunk, vector } of chunks) {
        const bytes = new Uint8Array(vector.buffer.slice(vector.byteOffset, vector.byteOffset + vector.byteLength))
        const encoded = Buffer.from(bytes).toString('base64')
        this.db.run(
          'INSERT INTO embeddings(file_id,chunk_index,vector,vector_text,dim,model,chunk_text) VALUES(?,?,?,?,?,?,?)',
          [fileId, chunk.index, new Uint8Array([0]), encoded, vector.length, model, chunk.contextualText]
        )
        this.db.run(
          'INSERT INTO document_chunks(file_id,chunk_index,text,contextual_text,section_path,page_start,page_end,kind,parent_index,entity_terms,token_count,tokenizer_profile,tokenizer_version,token_count_accuracy) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
          [fileId, chunk.index, chunk.text, chunk.contextualText, JSON.stringify(chunk.sectionPath), chunk.pageStart, chunk.pageEnd, chunk.kind,
            chunk.parentIndex, JSON.stringify(chunk.entityTerms),
            chunk.tokenCount ?? estimateCanonicalTokens(chunk.contextualText).count,
            chunk.tokenizerProfile ?? CANONICAL_TOKENIZER_PROFILE,
            chunk.tokenizerVersion ?? CANONICAL_TOKENIZER_VERSION,
            chunk.tokenCountAccuracy ?? 'estimated']
        )
      }
      this.db.run(
        'UPDATE files SET title=?,content_text=?,content_hash=?,indexed_at=?,index_signature=?,duplicate_of_file_id=NULL,duplicate_detected_at=NULL WHERE id=?',
        [patch.title, patch.contentText, patch.contentHash, patch.indexedAt, patch.indexSignature, fileId]
      )
      this.db.run('COMMIT')
    } catch (error) {
      this.db.run('ROLLBACK')
      throw error
    }
    await this.flush()
  }

  listDocumentChunks(fileId: number, offset = 0, limit?: number): DocumentChunk[] {
    const pagination = limit == null ? '' : ' LIMIT ? OFFSET ?'
    const parameters: SqlValue[] = limit == null
      ? [fileId]
      : [fileId, Math.max(0, Math.floor(limit)), Math.max(0, Math.floor(offset))]
    return this.rows(`SELECT c.*,p.text AS parent_text FROM document_chunks c
      LEFT JOIN document_parents p ON p.file_id=c.file_id AND p.parent_index=c.parent_index
      WHERE c.file_id=? ORDER BY c.chunk_index${pagination}`, parameters).map((row) => ({
      index: Number(row.chunk_index),
      text: String(row.text),
      contextualText: String(row.contextual_text),
      sectionPath: JSON.parse(String(row.section_path || '[]')) as string[],
      pageStart: row.page_start == null ? null : Number(row.page_start),
      pageEnd: row.page_end == null ? null : Number(row.page_end),
      kind: String(row.kind) as DocumentChunk['kind'],
      parentIndex: Number(row.parent_index ?? row.chunk_index),
      parentText: String(row.parent_text ?? row.text),
      entityTerms: JSON.parse(String(row.entity_terms || '[]')) as string[],
      tokenCount: Number(row.token_count ?? 0),
      tokenizerProfile: String(row.tokenizer_profile ?? CANONICAL_TOKENIZER_PROFILE),
      tokenizerVersion: String(row.tokenizer_version ?? CANONICAL_TOKENIZER_VERSION),
      tokenCountAccuracy: String(row.token_count_accuracy ?? 'estimated') as 'exact' | 'estimated'
    }))
  }

  documentChunkCount(fileId: number): number {
    return Number(this.scalar('SELECT COUNT(*) FROM document_chunks WHERE file_id=?', [fileId]) ?? 0)
  }

  entityChunkMatches(terms: string[], limit: number): Array<{ fileId: number; chunkIndex: number; chunk: DocumentChunk }> {
    if (!terms.length || limit <= 0) return []
    const normalized = new Set(terms.map((term) => term.normalize('NFKC').toLocaleLowerCase()))
    const matches: Array<{ fileId: number; chunkIndex: number; chunk: DocumentChunk }> = []
    for (const row of this.rows(`SELECT c.file_id,c.chunk_index,c.text,c.contextual_text,c.section_path,c.page_start,c.page_end,
      c.kind,c.parent_index,c.entity_terms,c.token_count,c.tokenizer_profile,c.tokenizer_version,c.token_count_accuracy,
      p.text AS parent_text FROM document_chunks c
      LEFT JOIN document_parents p ON p.file_id=c.file_id AND p.parent_index=c.parent_index`)) {
      const entityTerms = JSON.parse(String(row.entity_terms || '[]')) as string[]
      if (!entityTerms.some((term) => normalized.has(term.normalize('NFKC').toLocaleLowerCase()))) continue
      matches.push({ fileId: Number(row.file_id), chunkIndex: Number(row.chunk_index), chunk: {
        index: Number(row.chunk_index), text: String(row.text), contextualText: String(row.contextual_text),
        sectionPath: JSON.parse(String(row.section_path || '[]')) as string[],
        pageStart: row.page_start == null ? null : Number(row.page_start), pageEnd: row.page_end == null ? null : Number(row.page_end),
        kind: String(row.kind) as DocumentChunk['kind'], parentIndex: Number(row.parent_index ?? row.chunk_index),
        parentText: String(row.parent_text ?? row.text), entityTerms,
        tokenCount: Number(row.token_count ?? 0), tokenizerProfile: String(row.tokenizer_profile ?? CANONICAL_TOKENIZER_PROFILE),
        tokenizerVersion: String(row.tokenizer_version ?? CANONICAL_TOKENIZER_VERSION),
        tokenCountAccuracy: String(row.token_count_accuracy ?? 'estimated') as 'exact' | 'estimated'
      } })
      if (matches.length >= limit) break
    }
    return matches
  }

  async recordRAGSearchTrace(trace: RAGSearchTrace): Promise<void> {
    this.db.run(`INSERT INTO rag_search_traces(created_at,query,semantic_query,lexical_candidates,semantic_candidates,
      entity_candidates,fused_candidates,returned_results,semantic_threshold,reranker,duration_ms)
      VALUES(?,?,?,?,?,?,?,?,?,?,?)`, [new Date().toISOString(), trace.query, trace.semanticQuery, trace.lexicalCandidates,
      trace.semanticCandidates, trace.entityCandidates, trace.fusedCandidates, trace.returnedResults,
      trace.semanticThreshold, trace.reranker, trace.durationMs])
    this.db.run('DELETE FROM rag_search_traces WHERE id NOT IN (SELECT id FROM rag_search_traces ORDER BY id DESC LIMIT 500)')
    await this.flush()
  }

  listRAGSearchTraces(limit = 100): RAGSearchTrace[] {
    return this.rows('SELECT * FROM rag_search_traces ORDER BY id DESC LIMIT ?', [Math.max(1, Math.min(500, Math.floor(limit)))]).map((row) => ({
      query: String(row.query), semanticQuery: String(row.semantic_query),
      lexicalCandidates: Number(row.lexical_candidates), semanticCandidates: Number(row.semantic_candidates),
      entityCandidates: Number(row.entity_candidates), fusedCandidates: Number(row.fused_candidates),
      returnedResults: Number(row.returned_results), semanticThreshold: row.semantic_threshold == null ? null : Number(row.semantic_threshold),
      reranker: row.reranker == null ? null : String(row.reranker), durationMs: Number(row.duration_ms)
    }))
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

  chatMessagePage(sessionId: number, beforeId: number | null = null, limit = 40): { messages: ChatMessage[]; hasEarlier: boolean } {
    const boundedLimit = Math.max(1, Math.min(200, Math.floor(limit)))
    const parameters: SqlValue[] = beforeId == null ? [sessionId, boundedLimit + 1] : [sessionId, beforeId, boundedLimit + 1]
    const clause = beforeId == null ? 'session_id=?' : 'session_id=? AND id<?'
    const newestFirst = this.rows(`SELECT * FROM chat_messages WHERE ${clause} ORDER BY id DESC LIMIT ?`, parameters).map(mapMessage)
    return { messages: newestFirst.slice(0, boundedLimit).reverse(), hasEarlier: newestFirst.length > boundedLimit }
  }

  async updateChatMessageFeedback(messageId: number, feedback: ChatFeedback | null): Promise<void> {
    this.db.run("UPDATE chat_messages SET feedback=? WHERE id=? AND role='assistant'", [feedback, messageId])
    await this.flush()
  }

  listRagFeedback(limit = 30): RagFeedbackRecord[] {
    return this.rows('SELECT * FROM rag_feedback ORDER BY updated_at DESC LIMIT ?', [Math.max(1, Math.min(200, limit))]).map(mapRagFeedback)
  }

  listLibrarySearchHistory(limit = 20): LibrarySearchHistoryEntry[] {
    return this.rows('SELECT * FROM library_search_history ORDER BY updated_at DESC LIMIT ?', [Math.max(1, Math.min(100, limit))]).map((row) => ({ id: Number(row.id), query: String(row.query), smart: Boolean(row.smart), resultCount: Number(row.result_count), updatedAt: String(row.updated_at) }))
  }

  async saveLibrarySearchHistory(query: string, smart: boolean, resultCount: number): Promise<void> {
    const trimmed = query.trim().slice(0, 500)
    const normalized = trimmed.normalize('NFKC').toLocaleLowerCase()
    if (!normalized) return
    this.db.run(`INSERT INTO library_search_history(normalized_query,query,smart,result_count,updated_at) VALUES(?,?,?,?,?)
      ON CONFLICT(normalized_query,smart) DO UPDATE SET query=excluded.query,result_count=excluded.result_count,updated_at=excluded.updated_at`, [normalized, trimmed, smart ? 1 : 0, Math.max(0, Math.floor(resultCount)), new Date().toISOString()])
    this.db.run('DELETE FROM library_search_history WHERE id NOT IN (SELECT id FROM library_search_history ORDER BY updated_at DESC LIMIT 50)')
    await this.flush()
  }

  async deleteLibrarySearchHistory(id: number): Promise<void> { this.db.run('DELETE FROM library_search_history WHERE id=?', [id]); await this.flush() }
  async clearLibrarySearchHistory(): Promise<void> { this.db.run('DELETE FROM library_search_history'); await this.flush() }

  ragFeedback(id: number): RagFeedbackRecord | null {
    const row = this.rows('SELECT * FROM rag_feedback WHERE id=?', [id])[0]
    return row ? mapRagFeedback(row) : null
  }

  pendingRagFeedback(limit = 10): RagFeedbackRecord[] {
    return this.rows("SELECT * FROM rag_feedback WHERE analysis_status IN ('pending','failed') ORDER BY updated_at ASC LIMIT ?", [Math.max(1, Math.min(100, limit))]).map(mapRagFeedback)
  }

  async updateRagFeedbackAnalysis(id: number, status: RagFeedbackRecord['analysisStatus'], summary: string | null = null, error: string | null = null): Promise<void> {
    const now = new Date().toISOString()
    this.db.run('UPDATE rag_feedback SET analysis_status=?,analysis_summary=?,analysis_error=?,analyzed_at=?,updated_at=? WHERE id=?', [
      status,
      normalizeFeedbackText(summary),
      normalizeFeedbackText(error),
      status === 'applied' ? now : null,
      now,
      id
    ])
    await this.flush()
  }

  async saveChatRagFeedback(messageId: number, feedback: ChatFeedback | null, draft: Partial<RagFeedbackDraft> = {}): Promise<void> {
    this.db.run('BEGIN')
    try {
      this.db.run("UPDATE chat_messages SET feedback=? WHERE id=? AND role='assistant'", [feedback, messageId])
      if (feedback == null) {
        this.db.run('DELETE FROM rag_feedback WHERE source_key=?', [`chat:${messageId}`])
      } else {
        const message = this.rows("SELECT session_id,related_file_ids FROM chat_messages WHERE id=? AND role='assistant'", [messageId])[0]
        if (!message) throw new Error('The assistant message no longer exists')
        const now = new Date().toISOString()
        const rating = draft.rating ?? (feedback === 'helpful' ? 'accurate' : 'inaccurate')
        this.db.run(`INSERT INTO rag_feedback(source_key,source_kind,message_id,session_id,result_file_ids,rating,reason,best_file_id,best_file_reason,analysis_status,created_at,updated_at)
          VALUES(?,?,?,?,?,?,?,?,?,'pending',?,?)
          ON CONFLICT(source_key) DO UPDATE SET rating=excluded.rating,reason=excluded.reason,best_file_id=excluded.best_file_id,best_file_reason=excluded.best_file_reason,analysis_status='pending',analysis_summary=NULL,analysis_error=NULL,updated_at=excluded.updated_at,analyzed_at=NULL`, [
          `chat:${messageId}`, 'chat', messageId, Number(message.session_id), String(message.related_file_ids ?? '[]'), rating,
          normalizeFeedbackText(draft.reason), draft.bestFileId ?? null, normalizeFeedbackText(draft.bestFileReason), now, now
        ])
      }
      this.db.run('COMMIT')
    } catch (error) {
      this.db.run('ROLLBACK')
      throw error
    }
    await this.flush()
  }

  async saveLibrarySearchRagFeedback(query: string, smart: boolean, resultFileIds: number[], draft: RagFeedbackDraft): Promise<void> {
    const normalizedQuery = query.trim().normalize('NFKC').toLocaleLowerCase().slice(0, 500)
    if (!normalizedQuery) throw new Error('A search query is required for feedback')
    const sourceKind = smart ? 'smart_search' : 'search'
    const now = new Date().toISOString()
    this.db.run(`INSERT INTO rag_feedback(source_key,source_kind,search_query,result_file_ids,rating,reason,best_file_id,best_file_reason,analysis_status,created_at,updated_at)
      VALUES(?,?,?,?,?,?,?,?, 'pending',?,?)
      ON CONFLICT(source_key) DO UPDATE SET result_file_ids=excluded.result_file_ids,rating=excluded.rating,reason=excluded.reason,best_file_id=excluded.best_file_id,best_file_reason=excluded.best_file_reason,analysis_status='pending',analysis_summary=NULL,analysis_error=NULL,updated_at=excluded.updated_at,analyzed_at=NULL`, [
      `${sourceKind}:${normalizedQuery}`, sourceKind, query.trim().slice(0, 500), JSON.stringify([...new Set(resultFileIds)].slice(0, 100)), draft.rating,
      normalizeFeedbackText(draft.reason), draft.bestFileId ?? null, normalizeFeedbackText(draft.bestFileReason), now, now
    ])
    await this.flush()
  }

  async createReindexJob(mode: ReindexMode, categories: FileCategory[], fileIds: number[]): Promise<number> {
    const now = new Date().toISOString()
    this.db.run('BEGIN')
    try {
      this.db.run("UPDATE reindex_jobs SET status='interrupted',updated_at=? WHERE status IN ('running','paused','stopping')", [now])
      this.db.run('INSERT INTO reindex_jobs(status,mode,categories,total,created_at,updated_at) VALUES(?,?,?,?,?,?)', ['running', mode, JSON.stringify(categories), fileIds.length, now, now])
      const id = Number(this.scalar('SELECT last_insert_rowid()'))
      for (const fileId of fileIds) this.db.run('INSERT INTO reindex_job_files(job_id,file_id,state,updated_at) VALUES(?,?,?,?)', [id, fileId, 'queued', now])
      this.db.run('COMMIT')
      await this.flush()
      return id
    } catch (error) {
      this.db.run('ROLLBACK')
      throw error
    }
  }

  async updateReindexJobFile(jobId: number, fileId: number, state: ReindexJobFileItem['state'], error: string | null = null): Promise<void> {
    const now = new Date().toISOString()
    this.db.run('UPDATE reindex_job_files SET state=?,error=?,updated_at=? WHERE job_id=? AND file_id=?', [state, error?.slice(0, 1_000) ?? null, now, jobId, fileId])
    const counts = this.rows("SELECT SUM(state='completed') AS completed,SUM(state='failed') AS failed FROM reindex_job_files WHERE job_id=?", [jobId])[0]
    this.db.run('UPDATE reindex_jobs SET completed=?,failed=?,updated_at=? WHERE id=?', [Number(counts?.completed ?? 0), Number(counts?.failed ?? 0), now, jobId])
    await this.flush()
  }

  async updateReindexJob(jobId: number, status: ReindexJobSummary['status'], currentFileName: string | null = null): Promise<void> {
    this.db.run('UPDATE reindex_jobs SET status=?,current_file_name=?,updated_at=? WHERE id=?', [status, currentFileName, new Date().toISOString(), jobId])
    await this.flush()
  }

  latestReindexJob(): ReindexJobSummary | null {
    const job = this.rows('SELECT * FROM reindex_jobs ORDER BY id DESC LIMIT 1')[0]
    if (!job) return null
    const files = this.rows(`SELECT queue.file_id,files.name,files.ext,queue.state,queue.error,queue.updated_at
      FROM reindex_job_files queue JOIN files ON files.id=queue.file_id WHERE queue.job_id=? ORDER BY queue.updated_at DESC`, [Number(job.id)])
      .map((row): ReindexJobFileItem => ({ fileId: Number(row.file_id), name: String(row.name), ext: String(row.ext), state: row.state === 'processing' || row.state === 'completed' || row.state === 'failed' ? row.state : 'queued', error: row.error == null ? null : String(row.error), updatedAt: String(row.updated_at) }))
    return { id: Number(job.id), status: normalizeReindexStatus(String(job.status)), mode: normalizeReindexMode(String(job.mode)), total: Number(job.total), completed: Number(job.completed), failed: Number(job.failed), currentFileName: job.current_file_name == null ? null : String(job.current_file_name), createdAt: String(job.created_at), updatedAt: String(job.updated_at), files }
  }

  async addMessage(
    sessionId: number,
    role: ChatMessage['role'],
    content: string,
    relatedFileIds: number[] = [],
    metrics: Partial<Pick<ChatMessage, 'inputTokens' | 'outputTokens' | 'firstResponseDuration' | 'totalResponseDuration' | 'responseProvider' | 'responseModel'>> = {},
    relatedFileMatches: ChatRelatedFileMatch[] = []
  ): Promise<ChatMessage> {
    const now = new Date().toISOString()
    this.db.run(
      'INSERT INTO chat_messages(session_id,role,content,ts,related_file_ids,input_tokens,output_tokens,first_response_duration,total_response_duration,response_provider,response_model,related_file_matches) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
      [sessionId, role, content, now, JSON.stringify(relatedFileIds), metrics.inputTokens ?? null, metrics.outputTokens ?? null, metrics.firstResponseDuration ?? null, metrics.totalResponseDuration ?? null, metrics.responseProvider ?? null, metrics.responseModel ?? null, JSON.stringify(relatedFileMatches)]
    )
    const id = Number(this.scalar('SELECT last_insert_rowid()'))
    await this.updateChat(sessionId, { updatedAt: now })
    return this.listMessages(sessionId).find((item) => item.id === id)!
  }

  async replaceAssistantMessage(
    messageId: number,
    content: string,
    relatedFileIds: number[],
    metrics: Partial<Pick<ChatMessage, 'inputTokens' | 'outputTokens' | 'firstResponseDuration' | 'totalResponseDuration' | 'responseProvider' | 'responseModel'>>,
    relatedFileMatches: ChatRelatedFileMatch[] = []
  ): Promise<ChatMessage> {
    this.db.run(
      `UPDATE chat_messages SET content=?,ts=?,related_file_ids=?,input_tokens=?,output_tokens=?,
       first_response_duration=?,total_response_duration=?,response_provider=?,response_model=?,related_file_matches=?
       WHERE id=? AND role='assistant'`,
      [content, new Date().toISOString(), JSON.stringify(relatedFileIds), metrics.inputTokens ?? null, metrics.outputTokens ?? null, metrics.firstResponseDuration ?? null, metrics.totalResponseDuration ?? null, metrics.responseProvider ?? null, metrics.responseModel ?? null, JSON.stringify(relatedFileMatches), messageId]
    )
    await this.flush()
    const row = this.rows('SELECT * FROM chat_messages WHERE id=?', [messageId])[0]
    if (!row) throw new Error('The assistant message no longer exists')
    return mapMessage(row)
  }

  replaceWatchDirectoryBaseline(directoryPath: string, entryPaths: string[]): Promise<void> {
    this.db.run('BEGIN')
    try {
      this.db.run('DELETE FROM watch_directory_baseline_entries WHERE directory_path=?', [directoryPath])
      for (const path of entryPaths) this.db.run('INSERT INTO watch_directory_baseline_entries(directory_path,entry_path) VALUES(?,?)', [directoryPath, path])
      this.db.run('COMMIT')
    } catch (error) {
      this.db.run('ROLLBACK')
      throw error
    }
    return this.flush()
  }

  isWatchDirectoryBaselineEntry(directoryPath: string, entryPath: string): boolean {
    return Number(this.scalar('SELECT COUNT(*) FROM watch_directory_baseline_entries WHERE directory_path=? AND entry_path=?', [directoryPath, entryPath]) ?? 0) > 0
  }

  async clearWatchDirectoryBaselines(directoryPaths: string[]): Promise<void> {
    for (const path of directoryPaths) this.db.run('DELETE FROM watch_directory_baseline_entries WHERE directory_path=?', [path])
    await this.flush()
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
    const localModelBytes = await directorySize(join(homedir(), '.ollama', 'models'))
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
      localModelBytes,
      dailyActivity,
      categoryStorage
    }
  }
}

function encryptSecret(value: unknown): unknown {
  if (typeof value !== 'string' || !value || value.startsWith(SECRET_PREFIX)) return value
  if (!safeStorage?.isEncryptionAvailable()) throw new Error('Secure credential storage is unavailable; the API key was not saved')
  return SECRET_PREFIX + safeStorage.encryptString(value).toString('base64')
}

function decryptSecret(value: unknown): unknown {
  if (typeof value !== 'string' || !value.startsWith(SECRET_PREFIX)) return value
  if (!safeStorage?.isEncryptionAvailable()) return ''
  try { return safeStorage.decryptString(Buffer.from(value.slice(SECRET_PREFIX.length), 'base64')) } catch { return '' }
}

function mapFile(row: Record<string, unknown>): FileRecord {
  return { id: Number(row.id), path: String(row.path), name: String(row.name), ext: String(row.ext), size: Number(row.size), mtime: String(row.mtime), category: String(row.category) as FileCategory, sourceDir: String(row.source_dir), indexedAt: row.indexed_at == null ? null : String(row.indexed_at), contentHash: row.content_hash == null ? null : String(row.content_hash), title: row.title == null ? null : String(row.title), contentText: row.content_text == null ? null : String(row.content_text), discoveredAt: String(row.discovered_at), organizedAt: row.organized_at == null ? null : String(row.organized_at), note: row.note == null ? null : String(row.note), organizationSubfolder: row.organization_subfolder == null ? null : String(row.organization_subfolder), isDirectory: Boolean(row.is_directory), indexSignature: row.index_signature == null ? null : String(row.index_signature), creationDate: row.creation_date == null ? null : String(row.creation_date), duplicateOfFileId: row.duplicate_of_file_id == null ? null : Number(row.duplicate_of_file_id), duplicateDetectedAt: row.duplicate_detected_at == null ? null : String(row.duplicate_detected_at) }
}

function mapRule(row: Record<string, unknown>): Rule {
  return { id: Number(row.id), name: String(row.name), type: String(row.type) as Rule['type'], pattern: String(row.pattern), targetFolder: String(row.target_folder), priority: Number(row.priority), enabled: Boolean(row.enabled), action: String(row.action) as Rule['action'] }
}

function mapSession(row: Record<string, unknown>): ChatSession {
  return { id: Number(row.id), title: String(row.title), createdAt: String(row.created_at), updatedAt: String(row.updated_at), attachedFilePath: row.attached_file_path == null ? null : String(row.attached_file_path) }
}

function mapMessage(row: Record<string, unknown>): ChatMessage {
  return {
    id: Number(row.id), sessionId: Number(row.session_id), role: String(row.role) as ChatMessage['role'],
    content: String(row.content), timestamp: String(row.ts),
    relatedFileIds: JSON.parse(String(row.related_file_ids || '[]')) as number[],
    relatedFileMatches: JSON.parse(String(row.related_file_matches || '[]')) as ChatRelatedFileMatch[],
    inputTokens: row.input_tokens == null ? null : Number(row.input_tokens),
    outputTokens: row.output_tokens == null ? null : Number(row.output_tokens),
    firstResponseDuration: row.first_response_duration == null ? null : Number(row.first_response_duration),
    totalResponseDuration: row.total_response_duration == null ? null : Number(row.total_response_duration),
    responseProvider: row.response_provider == null ? null : String(row.response_provider),
    responseModel: row.response_model == null ? null : String(row.response_model),
    feedback: row.feedback === 'helpful' || row.feedback === 'notHelpful' ? row.feedback : null
  }
}

function mapRagFeedback(row: Record<string, unknown>): RagFeedbackRecord {
  const status = String(row.analysis_status)
  return {
    id: Number(row.id),
    sourceKey: String(row.source_key),
    sourceKind: row.source_kind === 'smart_search' ? 'smartSearch' : row.source_kind === 'search' ? 'search' : 'chat',
    messageId: row.message_id == null ? null : Number(row.message_id),
    sessionId: row.session_id == null ? null : Number(row.session_id),
    searchQuery: row.search_query == null ? null : String(row.search_query),
    resultFileIds: JSON.parse(String(row.result_file_ids || '[]')) as number[],
    rating: row.rating === 'accurate' ? 'accurate' : 'inaccurate',
    reason: row.reason == null ? null : String(row.reason),
    bestFileId: row.best_file_id == null ? null : Number(row.best_file_id),
    bestFileReason: row.best_file_reason == null ? null : String(row.best_file_reason),
    analysisStatus: status === 'analyzing' || status === 'applied' || status === 'failed' ? status : 'pending',
    analysisSummary: row.analysis_summary == null ? null : String(row.analysis_summary),
    analysisError: row.analysis_error == null ? null : String(row.analysis_error),
    createdAt: String(row.created_at), updatedAt: String(row.updated_at), analyzedAt: row.analyzed_at == null ? null : String(row.analyzed_at)
  }
}

function normalizeFeedbackText(value: string | null | undefined): string | null {
  const normalized = value?.trim().slice(0, 2_000) ?? ''
  return normalized || null
}

function normalizeReindexStatus(value: string): ReindexJobSummary['status'] {
  return value === 'paused' || value === 'stopping' || value === 'stopped' || value === 'completed' || value === 'completedWithErrors' || value === 'interrupted' ? value : 'running'
}

function normalizeReindexMode(value: string): ReindexMode {
  return value === 'unindexed' || value === 'embeddings' || value === 'media' ? value : 'all'
}

async function directorySize(root: string): Promise<number> {
  const entries = await readdir(root, { withFileTypes: true }).catch(() => [])
  let total = 0
  for (const entry of entries) {
    const path = join(root, entry.name)
    if (entry.isDirectory()) total += await directorySize(path)
    else total += await stat(path).then((value) => value.size).catch(() => 0)
  }
  return total
}
