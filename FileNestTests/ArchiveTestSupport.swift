import Foundation
import ZIPFoundation

enum ArchiveTestSupport {
    static func write(entries: [String: String], to url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for path in entries.keys.sorted() {
            let data = Data(entries[path, default: ""].utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                guard start < data.count else { return Data() }
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
    }
}
