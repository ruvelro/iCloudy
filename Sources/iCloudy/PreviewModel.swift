import Foundation
import Combine
import ImageIO
import PDFKit
import AVFoundation

enum PreviewKind: Equatable {
    case pdf, image(String), text
    /// Google Docs, Sheets and Slides exported to a temporary PDF through `files.export`.
    case exportedPDF
    /// Audio or video played locally with AVKit after the whole file is downloaded; no streaming.
    case media(String)
    /// Word, Excel, PowerPoint, RTF and iWork files rendered by Quick Look's own sandboxed previewer.
    case office(String)
    var localExtension: String {
        switch self {
        case .pdf, .exportedPDF: return "pdf"
        case .image(let ext), .media(let ext), .office(let ext): return ext
        case .text: return "txt"
        }
    }
    /// Only these kinds go through QLPreviewView; text has its own viewer and media its own player.
    var usesQuickLook: Bool {
        switch self { case .pdf, .exportedPDF, .image, .office: return true; case .text, .media: return false }
    }
    var exportMime: String? { self == .exportedPDF ? "application/pdf" : nil }
    static let mediaExtensions: Set<String> = ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf"]
    static let officeExtensions: Set<String> = ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "pages", "numbers", "key"]
    static let exportableGoogleMimes: Set<String> = ["application/vnd.google-apps.document", "application/vnd.google-apps.spreadsheet", "application/vnd.google-apps.presentation", "application/vnd.google-apps.drawing"]
    static func forFile(_ file: CloudFile) -> PreviewKind? {
        guard !file.isFolder else { return nil }
        if file.isGoogleDocument { return exportableGoogleMimes.contains(file.mime) ? .exportedPDF : nil }
        let ext = (file.name as NSString).pathExtension.lowercased()
        // Explicit allowlist; never send arbitrary code, HTML, SVG or packages to Quick Look.
        if ext == "pdf" { return .pdf }
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp"].contains(ext) { return .image(ext) }
        if ["txt", "md", "markdown", "csv", "tsv", "log", "json", "yaml", "yml", "xml", "swift", "py", "js", "ts", "tsx", "jsx", "css", "sh", "c", "h", "cpp", "rs", "go", "java", "sql", "toml", "ini", "conf"].contains(ext) { return .text }
        if mediaExtensions.contains(ext) { return .media(ext) }
        if officeExtensions.contains(ext) { return .office(ext) }
        return nil
    }
    /// Cheap structural check before handing a downloaded file to a system framework.
    static func looksValid(_ kind: PreviewKind, at url: URL) -> Bool {
        guard case .office(let ext) = kind, let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        let head = handle.readData(ofLength: 8)
        switch ext {
        case "docx", "xlsx", "pptx", "pages", "numbers", "key": return head.starts(with: [0x50, 0x4B]) // zip container
        case "doc", "xls", "ppt": return head.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) // OLE compound file
        case "rtf": return head.starts(with: Array("{\\rtf".utf8))
        default: return true
        }
    }
}

/// Only owns UUID-named preview directories under a dedicated private cache root.
final class PreviewStore {
    let root: URL
    init(root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloudy/Previews-v1", isDirectory: true)) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CloudError.message("La carpeta temporal no es segura.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        for child in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where owns(child) {
            try FileManager.default.removeItem(at: child)
        }
    }
    private func owns(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
            && url.lastPathComponent.hasPrefix("preview-")
            && UUID(uuidString: String(url.lastPathComponent.dropFirst(8))) != nil
    }
    func create() throws -> URL {
        let directory = root.appendingPathComponent("preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    func remove(_ directory: URL) throws {
        guard owns(directory) else { throw CloudError.message("Se rechazó eliminar un directorio ajeno a la vista previa.") }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    func capacity() throws -> Int64 {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) else {
            throw CloudError.message("No se pudo comprobar el espacio libre para la vista previa.")
        }
        return capacity
    }
}

@MainActor
final class PreviewModel: ObservableObject {
    static let automaticLimit: Int64 = 100_000_000
    static let textLimit = 1_000_000
    enum Phase: Equatable { case idle, confirmation, loading, ready, unsupported, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var file: CloudFile?
    @Published private(set) var account: Account?
    @Published private(set) var received: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var localURL: URL?
    @Published private(set) var text: String?
    /// What the ready file is, so the window can pick the right viewer.
    var kind: PreviewKind? { file.flatMap(PreviewKind.forFile) }
    @Published private(set) var textTruncated = false
    @Published var saveError: String?
    var willDiscard: (() -> Void)?
    var availableCapacity: (() throws -> Int64)?
    private let store: PreviewStore?
    private let initializationError: String?
    private var directory: URL?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var client: CloudAPI?

    init(store: PreviewStore? = nil) {
        do { self.store = try store ?? PreviewStore(); initializationError = nil }
        catch { self.store = nil; initializationError = error.localizedDescription }
    }
    var authorizedLimit: Int64 { max(Self.automaticLimit, file?.size ?? 0) }
    var confirmationText: String {
        let size = file?.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .decimal) } ?? "tamaño desconocido"
        return "Este archivo tiene \(size). Se descargará temporalmente, con un máximo de \(ByteCountFormatter.string(fromByteCount: authorizedLimit, countStyle: .decimal)). ¿Continuar?"
    }
    func open(file: CloudFile, account: Account, client: CloudAPI) {
        if self.file == file, self.account?.id == account.id, phase == .ready || phase == .loading { return }
        close()
        self.file = file; self.account = account; self.client = client
        guard let kind = PreviewKind.forFile(file) else { phase = .unsupported; return }
        guard store != nil else { phase = .failed(initializationError ?? "No se pudo preparar la vista previa."); return }
        // Exports have no size, but Drive caps them at 10 MB, well under the automatic limit.
        if kind != .exportedPDF, file.size == nil || file.size! < 0 || file.size! > Self.automaticLimit { phase = .confirmation }
        else { start() }
    }
    func start() {
        guard let file, let kind = PreviewKind.forFile(file), let client, let store, phase != .loading else { return }
        let request = UUID(); generation = request
        let limit = authorizedLimit
        do {
            let free = try availableCapacity?() ?? store.capacity()
            // Reserve enough for the allowed download plus some filesystem headroom.
            guard free >= 20_000_000, limit <= free - 20_000_000 else { throw CloudError.message("No hay espacio libre suficiente para esta vista previa.") }
            let folder = try store.create(); directory = folder
            let destination = folder.appendingPathComponent("contenido." + kind.localExtension)
            phase = .loading; received = 0; total = max(0, file.size ?? 0)
            task = Task { [weak self] in
                guard let self else { return }
                var retained = false
                defer {
                    if !retained { try? store.remove(folder) }
                    if generation == request { task = nil }
                }
                do {
                    try await client.download(file: file, to: destination, exportMime: kind.exportMime, maxBytes: limit) { [weak self] bytes, expected in
                        guard let self, self.generation == request, self.phase == .loading else { return }
                        self.received = bytes; self.total = expected
                    }
                    try Task.checkCancellation()
                    guard generation == request else { return }
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                    switch kind {
                    case .text:
                        let handle = try FileHandle(forReadingFrom: destination)
                        defer { try? handle.close() }
                        let data = try handle.read(upToCount: Self.textLimit + 1) ?? Data()
                        textTruncated = data.count > Self.textLimit
                        let prefix = Data(data.prefix(Self.textLimit))
                        if prefix.starts(with: [0xff, 0xfe]) || prefix.starts(with: [0xfe, 0xff]) {
                            guard let value = String(data: prefix, encoding: .utf16) else { throw CloudError.message("Codificación de texto no compatible.") }
                            text = value
                        } else {
                            guard !prefix.contains(0) else { throw CloudError.message("Este archivo contiene datos binarios, no texto plano.") }
                            text = String(decoding: prefix, as: UTF8.self)
                        }
                    case .pdf, .exportedPDF:
                        guard PDFDocument(url: destination) != nil else { throw CloudError.message("El archivo no es un PDF válido.") }
                    case .media:
                        let asset = AVURLAsset(url: destination)
                        guard try await asset.load(.isPlayable) else { throw CloudError.message("Este archivo de audio o vídeo no se puede reproducir en este Mac.") }
                    case .office:
                        guard PreviewKind.looksValid(kind, at: destination) else { throw CloudError.message("El contenido no corresponde a un documento de Office válido.") }
                    case .image:
                        guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                            throw CloudError.message("El archivo no es una imagen compatible.")
                        }
                    }
                    localURL = destination; phase = .ready; retained = true
                } catch {
                    guard generation == request, !Task.isCancelled else { return }
                    phase = .failed(error.localizedDescription)
                }
            }
        } catch { phase = .failed(error.localizedDescription) }
    }
    func saveCopy(to destination: URL) throws {
        guard phase == .ready, let localURL else { throw CloudError.message("La vista previa todavía no está lista.") }
        // No overwrite: preserve existing local files, even if the save panel approved replacement.
        try FileManager.default.copyItem(at: localURL, to: destination)
    }
    func close() {
        willDiscard?() // Detach the native viewer before unlinking its file.
        generation = UUID(); task?.cancel(); task = nil
        localURL = nil; text = nil; textTruncated = false
        if let directory {
            do { try store?.remove(directory) } catch { saveError = "No se pudo limpiar el temporal; se reintentará al arrancar: \(error.localizedDescription)" }
        }
        directory = nil; client = nil; file = nil; account = nil; phase = .idle
    }
}
