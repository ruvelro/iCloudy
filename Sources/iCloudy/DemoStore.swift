import Foundation

@MainActor
final class DemoStore {
    struct Entry: Codable { var file: CloudFile; var parent: String }
    let directory: URL
    var offline = false
    var failNext = false
    /// Cuts the next download after this many bytes, the way a network drop does. Consumed by that download.
    var failDownloadAfter: Int64?
    var latency: Duration = .milliseconds(60)
    private var entries: [String: Entry]
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL = LocalStore.directory.appendingPathComponent("Demo")) throws {
        self.directory = directory
        entries = try LocalStore.read([String: Entry].self, from: directory.appendingPathComponent("index.json")) ?? [:]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if entries.isEmpty {
            let folder = try add(name: "Proyectos", parent: "root", folder: true)
            _ = try add(name: "Bienvenido.txt", parent: "root", content: Data("Demo local de iCloudy. Estos archivos no se envían a ninguna nube.\nPrueba favoritos, carpetas, conflictos y transferencias.\n".utf8))
            _ = try add(name: "Prueba de transferencia.bin", parent: "root", content: Data(repeating: 42, count: 8 * 1024 * 1024))
            _ = try add(name: "Notas.txt", parent: folder, content: Data("Notas del proyecto de demostración.\n".utf8))
        }
    }
    private func check() throws {
        try Task.checkCancellation()
        if offline { throw URLError(.notConnectedToInternet) }
        if failNext { failNext = false; throw URLError(.networkConnectionLost) }
    }
    func list(_ parent: String) throws -> [CloudFile] {
        try check()
        switch parent {
        case Collection.recent.rootID:
            return entries.values.map(\.file).filter { !$0.isFolder }.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case Collection.shared.rootID:
            return [] // the demo has a single local user; nothing is shared with it
        default:
            return entries.values.filter { $0.parent == parent }.map(\.file).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
    func searchPage(term: String, cursor: String?, accountID: String) throws -> SearchPage {
        try check()
        let offset = cursor.flatMap(Int.init) ?? 0
        guard offset >= 0 else { throw CloudError.message(L("Página no válida.")) }
        let words = term.split(whereSeparator: \.isWhitespace).map(String.init)
        let matches = entries.values.filter { entry in words.allSatisfy { entry.file.name.localizedCaseInsensitiveContains($0) } }.sorted { $0.file.id < $1.file.id }
        let page = matches.dropFirst(offset).prefix(100).map { SearchHit(accountID: accountID, file: $0.file, parentID: $0.parent) }
        return SearchPage(hits: page, next: offset + page.count < matches.count ? String(offset + page.count) : nil)
    }
    func folderTrail(id: String) throws -> [CloudFile] {
        try check()
        var result: [CloudFile] = [], current = id, seen: Set<String> = []
        while current != "root" {
            guard seen.insert(current).inserted, let entry = entries[current], entry.file.isFolder else { throw CloudError.message(L("Carpeta no encontrada.")) }
            result.insert(entry.file, at: 0); current = entry.parent
        }
        return result
    }
    func storageQuota() throws -> StorageQuota {
        try Task.checkCancellation()
        if offline { throw URLError(.notConnectedToInternet) }
        // Do not consume failNext: that switch is reserved for transfer simulation.
        return StorageQuota(used: entries.values.reduce(0) { $0 + ($1.file.size ?? 0) }, total: 5_000_000_000)
    }
    func add(name: String, parent: String, folder: Bool = false, content: Data = Data()) throws -> String {
        try check()
        let id = UUID().uuidString
        if !folder { try content.write(to: directory.appendingPathComponent(id)) }
        entries[id] = Entry(file: CloudFile(id: id, name: name, mime: folder ? "application/vnd.google-apps.folder" : "application/octet-stream", size: folder ? nil : Int64(content.count), modified: Date(), webURL: nil, isFolder: folder), parent: parent)
        try persist()
        return id
    }
    func rename(_ id: String, name: String) throws {
        try check()
        guard let entry = entries[id] else { throw CloudError.message(L("El archivo demo ya no existe.")) }
        entries[id] = Entry(file: CloudFile(id: id, name: name, mime: entry.file.mime, size: entry.file.size, modified: Date(), webURL: nil, isFolder: entry.file.isFolder), parent: entry.parent)
        try persist()
    }
    func move(_ id: String, to parent: String) throws {
        try check()
        guard var entry = entries[id] else { throw CloudError.message(L("El archivo demo ya no existe.")) }
        entry.parent = parent; entries[id] = entry
        try persist()
    }
    @discardableResult func copy(_ id: String, to parent: String) throws -> String {
        try check()
        guard let entry = entries[id] else { throw CloudError.message(L("El archivo demo ya no existe.")) }
        let copyID = UUID().uuidString
        if !entry.file.isFolder { try FileManager.default.copyItem(at: directory.appendingPathComponent(id), to: directory.appendingPathComponent(copyID)) }
        entries[copyID] = Entry(file: CloudFile(id: copyID, name: entry.file.name, mime: entry.file.mime, size: entry.file.size, modified: Date(), webURL: nil, isFolder: entry.file.isFolder), parent: parent)
        for child in entries.values.filter({ $0.parent == id }) { try copy(child.file.id, to: copyID) }
        try persist()
        return copyID
    }
    /// Removes the entry and its descendants; the demo has no recycle bin to restore from.
    func trash(_ id: String) throws {
        try check()
        guard entries[id] != nil else { throw CloudError.message(L("El archivo demo ya no existe.")) }
        var pending = [id]
        while let current = pending.popLast() {
            pending += entries.values.filter { $0.parent == current }.map(\.file.id)
            entries[current] = nil
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(current))
        }
        try persist()
    }
    func publicLink(_ id: String) throws -> URL {
        try check()
        guard entries[id] != nil else { throw CloudError.message(L("El archivo demo ya no existe.")) }
        return URL(string: "https://demo.icloudy.invalid/share/\(id)")!
    }
    private func persist() throws { try LocalStore.save(entries, to: indexURL) }

    func upload(local: URL, parent: String, name: String, replacing: String?, checkpoint: UploadCheckpoint?, save: (UploadCheckpoint) throws -> Void, progress: (Int64, Int64) -> Void) async throws {
        try check()
        let attributes = try local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let total = Int64(attributes.fileSize ?? 0)
        var cursor = checkpoint ?? UploadCheckpoint(total: total, modified: attributes.contentModificationDate)
        guard cursor.total == total, cursor.modified == attributes.contentModificationDate else { throw CloudError.message(L("El archivo de origen ha cambiado. Inicia otra subida.")) }
        if cursor.complete { progress(total, total); return }
        if cursor.url == nil { cursor.url = directory.appendingPathComponent(UUID().uuidString + ".part"); try save(cursor) }
        let temporary = cursor.url!
        guard temporary.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path else { throw CloudError.message(L("Sesión demo no válida.")) }
        if !FileManager.default.fileExists(atPath: temporary.path) { FileManager.default.createFile(atPath: temporary.path, contents: nil) }
        let output = try FileHandle(forWritingTo: temporary)
        let input = try FileHandle(forReadingFrom: local)
        defer { try? output.close(); try? input.close() }
        let actual = try output.seekToEnd()
        cursor.offset = min(Int64(actual), total)
        try input.seek(toOffset: UInt64(cursor.offset))
        progress(cursor.offset, total)
        while cursor.offset < total {
            try await Task.sleep(for: latency)
            try check()
            let data = try input.read(upToCount: 256 * 1024) ?? Data()
            guard !data.isEmpty else { throw CloudError.message(L("El archivo de origen cambió.")) }
            try output.write(contentsOf: data)
            try output.synchronize()
            cursor.offset += Int64(data.count)
            try save(cursor); progress(cursor.offset, total)
        }
        let id = replacing ?? temporary.deletingPathExtension().lastPathComponent
        let target = directory.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: target) }
        entries[id] = Entry(file: CloudFile(id: id, name: name, mime: "application/octet-stream", size: total, modified: Date(), webURL: nil, isFolder: false), parent: parent)
        try persist()
        cursor.complete = true; try save(cursor); progress(total, total)
    }
    func download(_ file: CloudFile, to target: URL, maxBytes: Int64? = nil, progress: (Int64, Int64) -> Void) async throws {
        try check()
        let source = directory.appendingPathComponent(file.id)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw CloudError.message(L("El destino ya existe.")) }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var bytes: Int64 = 0
        while true {
            try await Task.sleep(for: latency)
            try check()
            let data = try input.read(upToCount: 256 * 1024) ?? Data()
            if data.isEmpty { break }
            if let maxBytes, bytes + Int64(data.count) > maxBytes { throw CloudError.message(L("La vista previa supera el límite de descarga autorizado.")) }
            try output.write(contentsOf: data)
            bytes += Int64(data.count); progress(bytes, file.size ?? bytes)
            if let limit = failDownloadAfter, bytes >= limit { failDownloadAfter = nil; throw URLError(.networkConnectionLost) }
        }
    }
}
