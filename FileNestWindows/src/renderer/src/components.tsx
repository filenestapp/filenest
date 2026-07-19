import { useEffect, useMemo, useState, type ButtonHTMLAttributes, type ReactNode } from 'react'
import { Archive, AudioLines, Code2, Copy, ExternalLink, File, FileImage, FileText, Film, FolderOpen, Maximize2, Minimize2, RefreshCw, Trash2, X } from 'lucide-react'
import type { AppLanguage, DocumentChunk, FileCategory, FileRecord } from '../../shared/types'
import { translate } from './i18n'

export function IconButton({ label, children, className = '', ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { label: string; children: ReactNode }): React.JSX.Element {
  return <button type="button" className={`icon-button ${className}`} aria-label={label} title={label} {...props}>{children}</button>
}

export function FileTypeIcon({ file, size = 22 }: { file: FileRecord; size?: number }): React.JSX.Element {
  const common = { size, strokeWidth: 1.7 }
  if (file.ext === 'pdf') return <span className="file-icon file-icon-pdf"><FileText {...common} /></span>
  if (file.category === 'images') return <span className="file-icon file-icon-image"><FileImage {...common} /></span>
  if (file.category === 'videos') return <span className="file-icon file-icon-video"><Film {...common} /></span>
  if (file.category === 'audio') return <span className="file-icon file-icon-audio"><AudioLines {...common} /></span>
  if (file.category === 'code') return <span className="file-icon file-icon-code"><Code2 {...common} /></span>
  if (file.category === 'archives') return <span className="file-icon file-icon-archive"><Archive {...common} /></span>
  return <span className="file-icon"><File {...common} /></span>
}

export const categoryLabels: Record<FileCategory, string> = { documents: 'Documents', images: 'Images', videos: 'Videos', audio: 'Audio', code: 'Code', archives: 'Archives', other: 'Other' }

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MB`
  return `${(bytes / 1024 ** 3).toFixed(1)} GB`
}

export function formatDate(value: string, language: AppLanguage, compact = false): string {
  const locale = language === 'en' ? 'en-US' : 'zh-CN'
  return new Intl.DateTimeFormat(locale, compact ? { month: 'short', day: 'numeric' } : { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(value))
}

export function FileInspector({ file, language, onClose }: { file: FileRecord; language: AppLanguage; onClose(): void }): React.JSX.Element {
  const t = (value: string): string => translate(value, language)
  const [previewUrl, setPreviewUrl] = useState<string | null>(null)
  const [note, setNote] = useState(file.note ?? '')
  const [summary, setSummary] = useState('')
  const [busy, setBusy] = useState(false)
  const [expanded, setExpanded] = useState(false)
  const [chunks, setChunks] = useState<DocumentChunk[]>([])
  const [chunkCount, setChunkCount] = useState(0)
  useEffect(() => {
    setNote(file.note ?? '')
    setSummary('')
    void window.fileNest.getPreviewUrl(file.path).then(setPreviewUrl).catch(() => setPreviewUrl(null))
    void Promise.all([
      window.fileNest.getDocumentChunkCount(file.id),
      window.fileNest.getDocumentChunks(file.id, 0, 20)
    ]).then(([count, values]) => { setChunkCount(count); setChunks(values) }).catch(() => { setChunkCount(0); setChunks([]) })
  }, [file.id, file.note, file.path])
  const copyPath = (): void => { void navigator.clipboard.writeText(file.path) }
  const saveNote = async (): Promise<void> => { setBusy(true); try { await window.fileNest.saveFileNote(file.id, note) } finally { setBusy(false) } }
  const generateSummary = async (): Promise<void> => {
    setBusy(true)
    try {
      const generated = await window.fileNest.summarizeFile(file.id)
      setSummary(generated)
      setNote(generated)
    } finally {
      setBusy(false)
    }
  }
  return (
    <aside className={`inspector ${expanded ? 'expanded' : ''}`} aria-label={t('File Preview')}>
      <header className="inspector-header"><div className="inspector-title"><FileTypeIcon file={file} /><strong title={file.name}>{file.name}</strong></div><div className="inline-actions"><IconButton label={expanded ? t('Restore Preview') : t('Expand Preview')} onClick={() => setExpanded((value) => !value)}>{expanded ? <Minimize2 size={17} /> : <Maximize2 size={17} />}</IconButton><IconButton label={t('Cancel')} onClick={onClose}><X size={18} /></IconButton></div></header>
      <div className="inspector-scroll">
        <section className="inspector-section"><div className="field-label">{t('Relevance')}</div><span className="status-badge success">● {t('Best Match')}</span></section>
        <section className="inspector-section"><div className="field-label">{t('Location')}</div><p className="path-text">{file.path}</p><button className="text-action" onClick={() => void window.fileNest.showInExplorer(file.path)}><FolderOpen size={15} />{t('Show in File Explorer')}</button></section>
        <section className="inspector-section detail-grid"><div><div className="field-label">{t('Modified')}</div><p>{formatDate(file.mtime, language)}</p></div><div><div className="field-label">{t('Created')}</div><p>{formatDate(file.creationDate ?? file.discoveredAt, language)}</p></div><div><div className="field-label">{t('Category')}</div><p>{t(categoryLabels[file.category])} · {formatBytes(file.size)}</p></div></section>
        <section className="inspector-section"><div className="field-label">{t('Quick Actions')}</div><div className="stacked-actions"><button className="text-action" onClick={() => void window.fileNest.openFile(file.path)}><ExternalLink size={15} />{t('Open')}</button><button className="text-action" onClick={copyPath}><Copy size={15} />{t('Copy File Path')}</button></div></section>
        <section className="inspector-section"><div className="field-label">{t('File Preview')}</div><Preview file={file} url={previewUrl} /></section>
        {chunks.length > 0 && <section className="inspector-section"><div className="field-label">{t('Structured Content')} · {chunkCount}</div><div className="chunk-list">{chunks.map((chunk) => <article key={chunk.index}><header><strong>{t(chunk.kind)}</strong><span>{chunk.sectionPath.join(' / ')}{chunk.pageStart != null ? ` · p.${chunk.pageStart}` : ''}</span></header><p>{chunk.text}</p></article>)}</div>{chunks.length < chunkCount && <button className="secondary-button" onClick={() => void window.fileNest.getDocumentChunks(file.id, chunks.length, 20).then((values) => setChunks((current) => [...current, ...values]))}>{t('Load More')}</button>}</section>}
        <section className="inspector-section"><div className="field-label">{t('Note')}</div><textarea className="note-editor" value={note} onChange={(event) => setNote(event.target.value)} placeholder={t('Note')} /><div className="inline-actions"><button className="secondary-button" disabled={busy} onClick={() => void saveNote()}>{t('Save Note')}</button><button className="secondary-button" disabled={busy} onClick={() => void generateSummary()}>{t('Generate Summary')}</button></div>{summary && <p className="summary-text">{summary}</p>}</section>
        <section className="inspector-section index-status"><div><div className="field-label">{t('Index Status')}</div><strong className={file.indexedAt ? 'success-text' : 'warning-text'}>{file.indexedAt ? `● ${t('Indexed')}` : t('Not Indexed')}</strong>{file.indexedAt && <small>{formatDate(file.indexedAt, language)}</small>}</div><IconButton label={t('Reindex')} onClick={() => void window.fileNest.reindexFile(file.id)}><RefreshCw size={16} /></IconButton></section>
        <section className="inspector-section danger-zone"><button className="text-action danger" onClick={() => { if (confirm(`${t('Delete')} ${file.name}?`)) void window.fileNest.trashFile(file.id).then(onClose) }}><Trash2 size={15} />{t('Move to Recycle Bin')}</button></section>
      </div>
    </aside>
  )
}

function Preview({ file, url }: { file: FileRecord; url: string | null }): React.JSX.Element {
  const t = (value: string): string => translate(value, document.documentElement.lang === 'zh-CN' ? 'zh-Hans' : 'en')
  if (!url) return <div className="preview-empty"><FileText size={30} /><span>{t('No Preview Available')}</span></div>
  if (file.category === 'images') return <img className="file-preview-image" src={url} alt={file.name} />
  if (file.ext === 'pdf') return <object className="file-preview-pdf" data={url} type="application/pdf"><div className="preview-empty"><FileText size={30} /><span>{file.name}</span></div></object>
  return <div className="preview-text">{(file.contentText ?? file.title ?? file.name).slice(0, 1_800)}</div>
}
