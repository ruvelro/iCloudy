import Foundation
import Compression
import zlib

/// Reads and writes ZIP archives without leaving the sandbox.
///
/// Writing is the system's: a file coordinator asked to read a folder "for uploading" hands back a ZIP of it.
/// Reading is done here, because the system offers nothing for it short of launching a tool: the central directory,
/// stored and deflated entries, ZIP64 for archives past 4 GB, and the checks an archive from a stranger needs. A
/// name that would land outside the destination is refused, links are not followed or created, and an entry that
/// inflates to more than it declared stops the extraction.
enum ZipArchive {
    struct Entry: Equatable {
        var name: String
        var compressedSize: UInt64
        var size: UInt64
        var method: UInt16
        var crc: UInt32
        var headerOffset: UInt64
        var isDirectory: Bool
        var isSymbolicLink: Bool
        var isEncrypted: Bool
    }

    enum Failure: LocalizedError, Equatable {
        case notAnArchive
        case damaged(String)
        case unsupported(String)
        case unsafeName(String)
        case encrypted
        var errorDescription: String? {
            switch self {
            case .notAnArchive: return L("El archivo no es un ZIP, o está dañado.")
            case .damaged(let name): return L("«\(name)» está dañado dentro del archivo comprimido: lo extraído no coincide con su suma.")
            case .unsupported(let name): return L("«\(name)» usa un método de compresión que iCloudy no sabe abrir.")
            case .unsafeName(let name): return L("El archivo comprimido contiene una ruta que saldría de la carpeta de destino («\(name)») y no se ha extraído.")
            case .encrypted: return L("El archivo comprimido está protegido con contraseña. Ábrelo con la Utilidad de Compresión.")
            }
        }
    }

    // MARK: - Writing

    /// A ZIP of `folder`, with the folder itself as its top entry, at `destination`. Synchronous and slow: callers
    /// run it off the main thread.
    static func compress(folder: URL, to destination: URL) throws {
        var coordination: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordination) { zipped in
            do { try FileManager.default.copyItem(at: zipped, to: destination) } catch { failure = error }
        }
        if let error = coordination ?? (failure as NSError?) { throw error }
    }

    /// Several items in one archive: they are gathered in a folder named after the archive, which is then
    /// compressed. On the same volume the gathering is a clone and costs nothing.
    static func compress(items: [URL], named name: String, to destination: URL, staging: URL) throws {
        if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return try compress(folder: items[0], to: destination)
        }
        let gathered = staging.appendingPathComponent(FileNames.safe(name), isDirectory: true)
        try FileManager.default.createDirectory(at: gathered, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: gathered) }
        for item in items {
            let scoped = item.startAccessingSecurityScopedResource()
            defer { if scoped { item.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: item, to: FileNames.available(in: gathered, name: item.lastPathComponent))
        }
        try compress(folder: gathered, to: destination)
    }

    // MARK: - Reading

    private static func u16(_ data: Data, _ at: Int) -> UInt16 { UInt16(data[data.startIndex + at]) | UInt16(data[data.startIndex + at + 1]) << 8 }
    private static func u32(_ data: Data, _ at: Int) -> UInt32 { UInt32(u16(data, at)) | UInt32(u16(data, at + 2)) << 16 }
    private static func u64(_ data: Data, _ at: Int) -> UInt64 { UInt64(u32(data, at)) | UInt64(u32(data, at + 4)) << 32 }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { throw Failure.notAnArchive }
        return data
    }

    /// What the archive holds, from its central directory.
    static func entries(of url: URL) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= 22 else { throw Failure.notAnArchive }
        // The end record sits at the very end, after a comment of at most 64 KiB.
        let tailSize = Int(min(length, 22 + 65_535 + 20))
        let tail = try read(handle, at: length - UInt64(tailSize), count: tailSize)
        var end: Int?
        var index = tail.count - 22
        while index >= 0 {
            if u32(tail, index) == 0x0605_4b50 { end = index; break }
            index -= 1
        }
        guard let end else { throw Failure.notAnArchive }
        var count = UInt64(u16(tail, end + 10)), size = UInt64(u32(tail, end + 12)), offset = UInt64(u32(tail, end + 16))
        // ZIP64: a locator right before the end record points at the record with the real numbers.
        if end >= 20, u32(tail, end - 20) == 0x0706_4b50 {
            let record = try read(handle, at: u64(tail, end - 20 + 8), count: 56)
            guard u32(record, 0) == 0x0606_4b50 else { throw Failure.notAnArchive }
            count = u64(record, 32); size = u64(record, 40); offset = u64(record, 48)
        }
        guard offset <= length, size <= length - offset, size <= UInt64(Int32.max) else { throw Failure.notAnArchive }
        let directory = try read(handle, at: offset, count: Int(size))
        var entries: [Entry] = []
        var cursor = 0
        for _ in 0..<count {
            guard cursor + 46 <= directory.count, u32(directory, cursor) == 0x0201_4b50 else { throw Failure.notAnArchive }
            let madeBy = u16(directory, cursor + 4), flags = u16(directory, cursor + 8), method = u16(directory, cursor + 10)
            let crc = u32(directory, cursor + 16)
            var compressed = UInt64(u32(directory, cursor + 20)), plain = UInt64(u32(directory, cursor + 24))
            let nameLength = Int(u16(directory, cursor + 28)), extraLength = Int(u16(directory, cursor + 30)), commentLength = Int(u16(directory, cursor + 32))
            let attributes = u32(directory, cursor + 38)
            var header = UInt64(u32(directory, cursor + 42))
            guard cursor + 46 + nameLength + extraLength + commentLength <= directory.count else { throw Failure.notAnArchive }
            let start = directory.startIndex + cursor + 46
            let rawName = directory[start..<start + nameLength]
            let extra = directory[start + nameLength..<start + nameLength + extraLength]
            // The ZIP64 extra field carries, in this order, only the values that overflowed their 32 bits.
            var field = 0
            while field + 4 <= extra.count {
                let id = u16(extra, field), fieldSize = Int(u16(extra, field + 2))
                guard field + 4 + fieldSize <= extra.count else { break }
                if id == 0x0001 {
                    var at = field + 4
                    if plain == 0xFFFF_FFFF, at + 8 <= field + 4 + fieldSize { plain = u64(extra, at); at += 8 }
                    if compressed == 0xFFFF_FFFF, at + 8 <= field + 4 + fieldSize { compressed = u64(extra, at); at += 8 }
                    if header == 0xFFFF_FFFF, at + 8 <= field + 4 + fieldSize { header = u64(extra, at) }
                }
                field += 4 + fieldSize
            }
            // Bit 11 says UTF-8. Without it the name is in the DOS code page, unless it happens to be valid UTF-8,
            // which is what most tools that forget the bit actually wrote.
            let name: String
            if flags & 0x0800 != 0 || String(data: rawName, encoding: .utf8) != nil { name = String(decoding: rawName, as: UTF8.self) }
            else {
                let dos = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
                name = String(data: rawName, encoding: dos) ?? String(decoding: rawName, as: UTF8.self)
            }
            // Made on Unix: the high half of the external attributes is the file mode.
            let mode = (madeBy >> 8) == 3 ? (attributes >> 16) & 0o170000 : 0
            entries.append(Entry(name: name, compressedSize: compressed, size: plain, method: method, crc: crc, headerOffset: header,
                                 isDirectory: name.hasSuffix("/") || mode == 0o040000, isSymbolicLink: mode == 0o120000,
                                 isEncrypted: flags & 0x0001 != 0))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// The path an entry may be written to under the destination, or nil for what is left out: the resource forks
    /// macOS tucks into `__MACOSX`, and an empty name. A name that would escape the destination throws instead.
    static func relativePath(for name: String) throws -> String? {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"), !normalized.contains("\0") else { throw Failure.unsafeName(name) }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty else { return nil }
        guard !parts.contains("..") else { throw Failure.unsafeName(name) }
        if parts.first == "__MACOSX" { return nil }
        return parts.filter { $0 != "." }.joined(separator: "/")
    }

    /// Extracts everything into `directory`, which must exist. Returns how many files were written. Nothing that is
    /// already there is replaced: the caller hands over a folder of its own.
    @discardableResult
    static func extract(_ url: URL, to directory: URL, progress: ((Int64) -> Void)? = nil, isCancelled: () -> Bool = { false }) throws -> Int {
        let entries = try entries(of: url)
        guard !entries.contains(where: \.isEncrypted) else { throw Failure.encrypted }
        // Every name is judged before a single byte is written.
        let planned = try entries.map { ($0, try relativePath(for: $0.name)) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let base = directory.standardizedFileURL.path
        var written = 0
        var total: Int64 = 0
        for (entry, relative) in planned {
            if isCancelled() { throw CancellationError() }
            guard let relative, !entry.isSymbolicLink else { continue }
            let target = directory.appendingPathComponent(relative)
            guard target.standardizedFileURL.path.hasPrefix(base + "/") else { throw Failure.unsafeName(entry.name) }
            if entry.isDirectory { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true); continue }
            guard entry.method == 0 || entry.method == 8 else { throw Failure.unsupported(entry.name) }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: target)
            do {
                let local = try read(handle, at: entry.headerOffset, count: 30)
                guard u32(local, 0) == 0x0403_4b50 else { throw Failure.notAnArchive }
                let dataStart = entry.headerOffset + 30 + UInt64(u16(local, 26)) + UInt64(u16(local, 28))
                try handle.seek(toOffset: dataStart)
                let crc = try entry.method == 0
                    ? copyStored(handle, to: output, entry: entry) { total += $0; progress?(total) }
                    : inflate(handle, to: output, entry: entry, isCancelled: isCancelled) { total += $0; progress?(total) }
                try output.close()
                guard crc == entry.crc else { throw Failure.damaged(entry.name) }
            } catch {
                try? output.close()
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            written += 1
        }
        return written
    }

    private static func checksum(_ data: Data, _ running: uLong) -> uLong {
        data.withUnsafeBytes { crc32(running, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
    }

    private static func copyStored(_ input: FileHandle, to output: FileHandle, entry: Entry, wrote: (Int64) -> Void) throws -> UInt32 {
        var remaining = entry.compressedSize
        var crc = crc32(0, nil, 0)
        while remaining > 0 {
            let chunk = try autoreleasepool { try input.read(upToCount: Int(min(remaining, 1 << 20))) ?? Data() }
            guard !chunk.isEmpty else { throw Failure.damaged(entry.name) }
            try output.write(contentsOf: chunk)
            crc = checksum(chunk, crc)
            remaining -= UInt64(chunk.count)
            wrote(Int64(chunk.count))
        }
        return UInt32(truncatingIfNeeded: crc)
    }

    private static func inflate(_ input: FileHandle, to output: FileHandle, entry: Entry, isCancelled: () -> Bool, wrote: (Int64) -> Void) throws -> UInt32 {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw Failure.damaged(entry.name) }
        defer { compression_stream_destroy(stream) }
        let capacity = 1 << 18
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        var remaining = entry.compressedSize
        var produced: UInt64 = 0
        var crc = crc32(0, nil, 0)
        var finished = false
        stream.pointee.src_size = 0
        while !finished {
            if isCancelled() { throw CancellationError() }
            let chunk: Data = remaining > 0 ? try autoreleasepool { try input.read(upToCount: Int(min(remaining, 1 << 18))) ?? Data() } : Data()
            guard !chunk.isEmpty || remaining == 0 else { throw Failure.damaged(entry.name) }
            remaining -= UInt64(chunk.count)
            try chunk.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                stream.pointee.src_ptr = source.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
                stream.pointee.src_size = chunk.count
                // The decoder hands out its output in pieces of its own size, not ours: a call that leaves room in
                // the buffer may still have more to give. It is asked again for as long as it gave something.
                var gave = false
                repeat {
                    stream.pointee.dst_ptr = buffer
                    stream.pointee.dst_size = capacity
                    let status = compression_stream_process(stream, remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    guard status != COMPRESSION_STATUS_ERROR else { throw Failure.damaged(entry.name) }
                    let count = capacity - stream.pointee.dst_size
                    gave = count > 0
                    if count > 0 {
                        produced += UInt64(count)
                        // An entry that inflates past what it declared is a bomb or a lie; either way it stops here.
                        guard produced <= entry.size else { throw Failure.damaged(entry.name) }
                        let piece = Data(bytesNoCopy: buffer, count: count, deallocator: .none)
                        try output.write(contentsOf: piece)
                        crc = checksum(piece, crc)
                        wrote(Int64(count))
                    }
                    if status == COMPRESSION_STATUS_END { finished = true }
                } while !finished && (stream.pointee.src_size > 0 || gave)
            }
            if remaining == 0, !finished, chunk.isEmpty { throw Failure.damaged(entry.name) }
        }
        guard produced == entry.size else { throw Failure.damaged(entry.name) }
        return UInt32(truncatingIfNeeded: crc)
    }
}
