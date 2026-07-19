import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'
import { stat } from 'node:fs/promises'
import type { DuplicateFileGroup, DuplicateScanProgress, DuplicateTrashResult, FileRecord } from '../shared/types'
import { FileNestDatabase } from './database'

export function duplicateGroups(files: FileRecord[]): DuplicateFileGroup[] {
  const byHash = new Map<string, FileRecord[]>()
  for (const file of files) {
    if (!file.contentHash) continue
    const group = byHash.get(file.contentHash) ?? []
    group.push(file)
    byHash.set(file.contentHash, group)
  }
  return [...byHash.entries()].flatMap(([contentHash, entries]) => {
    const ordered = [...entries].sort(compareOldestFile)
    const linkedOriginalIds = new Set(ordered.flatMap((file) => file.duplicateOfFileId == null ? [] : [file.duplicateOfFileId]))
    const originalIndex = ordered.findIndex((file) => linkedOriginalIds.has(file.id))
    if (originalIndex > 0) ordered.unshift(ordered.splice(originalIndex, 1)[0])
    if (ordered.length < 2) return []
    const duplicateFiles = ordered.slice(1)
    return [{
      contentHash,
      files: ordered,
      retainedFile: ordered[0],
      duplicateFiles,
      reclaimableBytes: duplicateFiles.reduce((sum, file) => sum + file.size, 0)
    }]
  }).sort((left, right) => right.reclaimableBytes - left.reclaimableBytes || left.retainedFile.name.localeCompare(right.retainedFile.name, undefined, { numeric: true }))
}

export class DuplicateFileService {
  constructor(private readonly database: FileNestDatabase) {}

  knownGroups(): DuplicateFileGroup[] {
    return duplicateGroups(this.database.listFiles())
  }

  async scan(onProgress?: (progress: DuplicateScanProgress) => void): Promise<DuplicateFileGroup[]> {
    const candidates = this.database.listFiles().filter((file) => !file.isDirectory)
    const scanned: FileRecord[] = []
    const inventories: Array<{ id: number; contentHash: string; creationDate: string }> = []
    onProgress?.({ scannedCount: 0, totalCount: candidates.length })
    for (let index = 0; index < candidates.length; index += 1) {
      const file = candidates[index]
      try {
        const [contentHash, metadata] = await Promise.all([sha256File(file.path), stat(file.path)])
        const creationDate = metadata.birthtime.toISOString()
        inventories.push({ id: file.id, contentHash, creationDate })
        scanned.push({ ...file, contentHash, creationDate })
      } catch {
        // Files that disappear or become unreadable during a scan are omitted.
      }
      onProgress?.({ scannedCount: index + 1, totalCount: candidates.length })
    }
    await this.database.updateFileInventories(inventories)
    return duplicateGroups(scanned)
  }

  async moveToTrash(
    paths: string[],
    trash: (path: string) => Promise<void>,
    onProgress?: (completedCount: number, totalCount: number, currentFileName: string | null) => void
  ): Promise<DuplicateTrashResult> {
    const groups = this.knownGroups()
    const allowed = new Map(groups.flatMap((group) => group.duplicateFiles.map((file) => [file.path, { file, expectedHash: group.contentHash }] as const)))
    const selected = [...new Set(paths)].flatMap((path) => allowed.get(path) ?? [])
    const failedFileNames: string[] = []
    let movedCount = 0
    onProgress?.(0, selected.length, selected[0]?.file.name ?? null)
    for (let index = 0; index < selected.length; index += 1) {
      const entry = selected[index]
      onProgress?.(index, selected.length, entry.file.name)
      try {
        if (await sha256File(entry.file.path) !== entry.expectedHash) throw new Error('The duplicate changed after scanning')
        await trash(entry.file.path)
        await this.database.deleteFile(entry.file.id)
        movedCount += 1
      } catch {
        failedFileNames.push(entry.file.name)
      }
      onProgress?.(index + 1, selected.length, entry.file.name)
    }
    return { movedCount, failedFileNames }
  }
}

export function sha256File(path: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256')
    const stream = createReadStream(path)
    stream.on('error', reject)
    stream.on('data', (chunk) => hash.update(chunk))
    stream.on('end', () => resolve(hash.digest('hex')))
  })
}

function compareOldestFile(left: FileRecord, right: FileRecord): number {
  const leftAdded = new Date(left.discoveredAt || left.organizedAt || left.indexedAt || left.mtime).getTime()
  const rightAdded = new Date(right.discoveredAt || right.organizedAt || right.indexedAt || right.mtime).getTime()
  return leftAdded - rightAdded || new Date(left.mtime).getTime() - new Date(right.mtime).getTime() || left.path.localeCompare(right.path, undefined, { numeric: true })
}
