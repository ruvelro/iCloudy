import Foundation
import Security

enum Cloud: String, Codable, CaseIterable, Identifiable {
    case google, microsoft
    var id: String { rawValue }
    var title: String { self == .google ? "Google Drive" : "OneDrive" }
    var tokenURL: String { self == .google ? "https://oauth2.googleapis.com/token" : "https://login.microsoftonline.com/common/oauth2/v2.0/token" }
}

struct Account: Codable, Identifiable, Hashable {
    let id: String
    let cloud: Cloud
    let name: String
    let email: String
    let clientID: String
    let clientSecret: String?
    var isDemo: Bool { id.hasPrefix("demo:") }
    static let demo = Account(id: "demo:local", cloud: .google, name: "Demo local", email: "Sin conexión · datos de prueba", clientID: "", clientSecret: nil)
}

struct Credential: Codable {
    var accessToken: String
    var refreshToken: String
    var expires: Date
}

struct CloudFile: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let mime: String
    let size: Int64?
    let modified: Date?
    let webURL: URL?
    let isFolder: Bool
    var isGoogleDocument: Bool { mime.hasPrefix("application/vnd.google-apps.") && !isFolder }
    /// What a Google document becomes when it leaves Drive: an Office file it can round-trip, or PDF for drawings.
    var crossCloudExport: (mime: String, ext: String)? {
        switch mime {
        case "application/vnd.google-apps.document": return ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx")
        case "application/vnd.google-apps.spreadsheet": return ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx")
        case "application/vnd.google-apps.presentation": return ("application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx")
        case "application/vnd.google-apps.drawing": return ("application/pdf", "pdf")
        default: return nil
        }
    }
    var exportOptions: [(title: String, mime: String, ext: String)] {
        switch mime {
        case "application/vnd.google-apps.document": return [("PDF", "application/pdf", "pdf"), ("Word", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx")]
        case "application/vnd.google-apps.spreadsheet": return [("Excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx"), ("PDF", "application/pdf", "pdf")]
        case "application/vnd.google-apps.presentation": return [("PowerPoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx"), ("PDF", "application/pdf", "pdf")]
        default: return []
        }
    }
    var icon: String {
        if isFolder { return "folder.fill" }
        if isGoogleDocument { return "doc.richtext" }
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        return "doc"
    }
}

enum ConflictChoice: String, Codable { case skip, copy, replace }
enum TransferState: String, Codable { case queued, running, paused, failed, cancelled, completed }
enum TransferDirection: String, Codable {
    case upload, download
    /// From one connected account to another: bytes are staged in a scratch folder, never kept.
    case transfer
}
struct UploadCheckpoint: Codable {
    var url: URL?
    var offset: Int64 = 0
    var total: Int64 = 0
    var modified: Date?
    var complete = false
}
struct Transfer: Identifiable, Codable {
    var id = UUID()
    var batchID = UUID()
    var name: String
    var destination: String
    var accountID: String
    var direction: TransferDirection
    var localURL: URL
    var bookmark: Data?
    var parent = "root"
    var file: CloudFile?
    var exportMime: String?
    var exportExtension: String?
    var state: TransferState = .queued
    var detail = ""
    var bytes: Int64 = 0
    var total: Int64 = 0
    var bytesPerSecond: Double = 0
    var attempts = 0
    var batchChoice: ConflictChoice?
    var completedPaths: Set<String> = []
    var folders: [String: String] = [:]
    var uncertainFolders: Set<String> = []
    var names: [String: String] = [:]
    var replacements: [String: String] = [:]
    var uploads: [String: UploadCheckpoint] = [:]
    /// Files whose provider checksum matched the bytes sent, and files that could not be checked (resumed, or no hash).
    var verifiedFiles = 0
    var unverifiedFiles = 0
    /// Destination account of a cross-cloud transfer; `accountID` is then the source.
    var targetAccountID: String?
    var finished: Bool { [.completed, .cancelled, .failed].contains(state) }
    var failed: Bool { state == .failed }
    var progress: Double { state == .completed ? 1 : (total > 0 ? min(1, Double(bytes) / Double(total)) : 0) }
    var status: String {
        switch state {
        case .queued: return "En cola"
        case .running: return detail.isEmpty ? "Transfiriendo…" : detail
        case .paused: return detail.isEmpty ? "En pausa · Reanudar para continuar" : detail
        case .failed: return detail
        case .cancelled: return "Cancelada · Los elementos completados se conservan"
        case .completed: return detail.isEmpty ? "Completada" : detail
        }
    }
    var metrics: String {
        let done = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let size = total > 0 ? " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file) : ""
        guard state == .running, bytesPerSecond > 0 else { return done + size }
        let speed = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
        let eta = total > bytes ? " · ~\(Int(Double(total - bytes) / bytesPerSecond)) s" : ""
        return done + size + " · " + speed + eta
    }
}
/// Top-level views of an account. `files` is the browsable tree; the others are provider-computed lists.
enum Collection: String, Codable, CaseIterable, Identifiable {
    case files, recent, shared
    var id: String { rawValue }
    var title: String {
        switch self { case .files: return "Mis archivos"; case .recent: return "Recientes"; case .shared: return "Compartido conmigo" }
    }
    var icon: String {
        switch self { case .files: return "folder"; case .recent: return "clock"; case .shared: return "person.2" }
    }
    /// Pseudo-parent handed to `CloudAPI.list`; never a real item id.
    var rootID: String {
        switch self { case .files: return "root"; case .recent: return "recent"; case .shared: return "sharedWithMe" }
    }
    static let virtualRoots: Set<String> = [Collection.recent.rootID, Collection.shared.rootID]
}

struct Favorite: Identifiable, Codable {
    var id: String { accountID + ":" + file.id }
    let accountID: String
    var file: CloudFile
    var path: [CloudFile]
    var collection: Collection = .files
}

/// Runs blocking file-system work off the main actor. Network calls were already asynchronous; disk reads, directory
/// walks and moves were not, and on slow or external volumes they froze the interface.
func blockingIO<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
}

enum LocalStore {
    static var directory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloudy", isDirectory: true) }
    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

enum CloudError: LocalizedError {
    case message(String)
    /// The provider no longer accepts the stored credential; only a new sign-in fixes it.
    case sessionExpired(String?)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .sessionExpired(let detail):
            let base = "La sesión de esta cuenta ha caducado o el acceso se ha revocado. Vuelve a conectar la cuenta desde la barra lateral."
            return detail.map { base + " Detalle del proveedor: \($0)" } ?? base
        }
    }
    var isSessionExpired: Bool { if case .sessionExpired = self { return true } else { return false } }
}

enum Vault {
    static func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.icloudy.credentials", kSecAttrAccount as String: key]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw CloudError.message("No se pudo guardar en el Llavero (\(result)).") }
        } else if status != errSecSuccess { throw CloudError.message("No se pudo actualizar el Llavero (\(status)).") }
    }
    static func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.icloudy.credentials", kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CloudError.message("No se pudo leer el Llavero (\(status)).") }
        return try JSONDecoder().decode(type, from: data)
    }
    static func delete(key: String) throws {
        let result = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.icloudy.credentials", kSecAttrAccount as String: key] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CloudError.message("No se pudo eliminar la credencial (\(result)).") }
    }
}

/// Abstracts the Keychain so token handling can be tested without touching the user's real keychain.
protocol CredentialStore {
    func read(_ key: String) throws -> Credential?
    func save(_ credential: Credential, key: String) throws
}
struct KeychainCredentialStore: CredentialStore {
    func read(_ key: String) throws -> Credential? { try Vault.read(Credential.self, key: key) }
    func save(_ credential: Credential, key: String) throws { try Vault.save(credential, key: key) }
}

enum FileNames {
    private static let oneDriveForbidden = CharacterSet(charactersIn: "\"*:<>?/\\|")
    private static let oneDriveReserved: Set<String> = ["CON", "PRN", "AUX", "NUL", "COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", ".LOCK", "DESKTOP.INI"]
    /// Returns a user-facing problem, or nil when the provider will accept the name. OneDrive is far stricter than Drive.
    /// Reference: https://support.microsoft.com/office/invalid-file-names-and-file-types-in-onedrive-and-sharepoint
    static func problem(with name: String, for cloud: Cloud) -> String? {
        if name.isEmpty || name == "." || name == ".." { return "Introduce un nombre válido." }
        if name.contains("/") || name.contains("\0") { return "El nombre no puede contener barras." }
        guard cloud == .microsoft else { return nil }
        if name.unicodeScalars.contains(where: { oneDriveForbidden.contains($0) }) { return "OneDrive no admite los caracteres \" * : < > ? / \\ | en los nombres." }
        if name.hasPrefix(" ") || name.hasSuffix(" ") { return "OneDrive no admite espacios al principio o al final del nombre." }
        if name.hasSuffix(".") { return "OneDrive no admite nombres que terminen en punto." }
        if name.hasPrefix("~$") || name.contains("_vti_") { return "OneDrive reserva los nombres que empiezan por ~$ o contienen _vti_." }
        let stem = (name as NSString).deletingPathExtension.uppercased()
        if oneDriveReserved.contains(name.uppercased()) || oneDriveReserved.contains(stem) { return "«\(name)» es un nombre reservado por OneDrive." }
        if name.count > 255 { return "OneDrive limita los nombres a 255 caracteres." }
        return nil
    }
    static func safe(_ name: String) -> String {
        let result = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\0", with: "_")
        return result.isEmpty || result == "." || result == ".." ? "archivo" : result
    }
    static func available(in folder: URL, name: String) -> URL {
        let original = folder.appendingPathComponent(safe(name))
        var candidate = original
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let ext = original.pathExtension
            let stem = original.deletingPathExtension().lastPathComponent
            candidate = folder.appendingPathComponent("\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)"))
            number += 1
        }
        return candidate
    }
}

// MARK: - Tolerant decoding
// Stores in Application Support and the Keychain outlive app versions. Every persisted type fills missing keys with
// defaults, so adding a property never invalidates an existing file. Renaming or removing one still needs a migration.

extension Account {
    enum CodingKeys: String, CodingKey { case id, cloud, name, email, clientID, clientSecret }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let email = try values.decodeIfPresent(String.self, forKey: .email) ?? ""
        self.init(id: try values.decode(String.self, forKey: .id),
                  cloud: try values.decode(Cloud.self, forKey: .cloud),
                  name: try values.decodeIfPresent(String.self, forKey: .name) ?? email,
                  email: email,
                  clientID: try values.decodeIfPresent(String.self, forKey: .clientID) ?? "",
                  clientSecret: try values.decodeIfPresent(String.self, forKey: .clientSecret))
    }
}

extension Credential {
    enum CodingKeys: String, CodingKey { case accessToken, refreshToken, expires }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A missing expiry forces a refresh on first use instead of trusting a stale token.
        self.init(accessToken: try values.decode(String.self, forKey: .accessToken),
                  refreshToken: try values.decode(String.self, forKey: .refreshToken),
                  expires: try values.decodeIfPresent(Date.self, forKey: .expires) ?? .distantPast)
    }
}

extension CloudFile {
    enum CodingKeys: String, CodingKey { case id, name, mime, size, modified, webURL, isFolder }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let mime = try values.decodeIfPresent(String.self, forKey: .mime) ?? "application/octet-stream"
        self.init(id: try values.decode(String.self, forKey: .id),
                  name: try values.decodeIfPresent(String.self, forKey: .name) ?? "archivo",
                  mime: mime,
                  size: try values.decodeIfPresent(Int64.self, forKey: .size),
                  modified: try values.decodeIfPresent(Date.self, forKey: .modified),
                  webURL: try values.decodeIfPresent(URL.self, forKey: .webURL),
                  isFolder: try values.decodeIfPresent(Bool.self, forKey: .isFolder) ?? (mime == "application/vnd.google-apps.folder"))
    }
}

extension UploadCheckpoint {
    enum CodingKeys: String, CodingKey { case url, offset, total, modified, complete }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: try values.decodeIfPresent(URL.self, forKey: .url),
                  offset: try values.decodeIfPresent(Int64.self, forKey: .offset) ?? 0,
                  total: try values.decodeIfPresent(Int64.self, forKey: .total) ?? 0,
                  modified: try values.decodeIfPresent(Date.self, forKey: .modified),
                  complete: try values.decodeIfPresent(Bool.self, forKey: .complete) ?? false)
    }
}

extension Transfer {
    enum CodingKeys: String, CodingKey {
        case id, batchID, name, destination, accountID, direction, localURL, bookmark, parent, file, exportMime, exportExtension
        case state, detail, bytes, total, bytesPerSecond, attempts, batchChoice, completedPaths, folders, uncertainFolders, names, replacements, uploads
        case verifiedFiles, unverifiedFiles, targetAccountID
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown states written by a newer version become paused: the user decides whether to resume.
        let state = try values.decodeIfPresent(String.self, forKey: .state).flatMap(TransferState.init(rawValue:)) ?? .paused
        self.init(id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  batchID: try values.decodeIfPresent(UUID.self, forKey: .batchID) ?? UUID(),
                  name: try values.decodeIfPresent(String.self, forKey: .name) ?? "Transferencia",
                  destination: try values.decodeIfPresent(String.self, forKey: .destination) ?? "",
                  accountID: try values.decode(String.self, forKey: .accountID),
                  direction: try values.decode(TransferDirection.self, forKey: .direction),
                  localURL: try values.decode(URL.self, forKey: .localURL),
                  bookmark: try values.decodeIfPresent(Data.self, forKey: .bookmark),
                  parent: try values.decodeIfPresent(String.self, forKey: .parent) ?? "root",
                  file: try values.decodeIfPresent(CloudFile.self, forKey: .file),
                  exportMime: try values.decodeIfPresent(String.self, forKey: .exportMime),
                  exportExtension: try values.decodeIfPresent(String.self, forKey: .exportExtension),
                  state: state,
                  detail: try values.decodeIfPresent(String.self, forKey: .detail) ?? "",
                  bytes: try values.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0,
                  total: try values.decodeIfPresent(Int64.self, forKey: .total) ?? 0,
                  bytesPerSecond: try values.decodeIfPresent(Double.self, forKey: .bytesPerSecond) ?? 0,
                  attempts: try values.decodeIfPresent(Int.self, forKey: .attempts) ?? 0,
                  batchChoice: try values.decodeIfPresent(String.self, forKey: .batchChoice).flatMap(ConflictChoice.init(rawValue:)),
                  completedPaths: try values.decodeIfPresent(Set<String>.self, forKey: .completedPaths) ?? [],
                  folders: try values.decodeIfPresent([String: String].self, forKey: .folders) ?? [:],
                  uncertainFolders: try values.decodeIfPresent(Set<String>.self, forKey: .uncertainFolders) ?? [],
                  names: try values.decodeIfPresent([String: String].self, forKey: .names) ?? [:],
                  replacements: try values.decodeIfPresent([String: String].self, forKey: .replacements) ?? [:],
                  uploads: try values.decodeIfPresent([String: UploadCheckpoint].self, forKey: .uploads) ?? [:],
                  verifiedFiles: try values.decodeIfPresent(Int.self, forKey: .verifiedFiles) ?? 0,
                  unverifiedFiles: try values.decodeIfPresent(Int.self, forKey: .unverifiedFiles) ?? 0,
                  targetAccountID: try values.decodeIfPresent(String.self, forKey: .targetAccountID))
    }
}

extension Favorite {
    enum CodingKeys: String, CodingKey { case accountID, file, path, collection }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(accountID: try values.decode(String.self, forKey: .accountID),
                  file: try values.decode(CloudFile.self, forKey: .file),
                  path: try values.decodeIfPresent([CloudFile].self, forKey: .path) ?? [],
                  collection: try values.decodeIfPresent(String.self, forKey: .collection).flatMap(Collection.init(rawValue:)) ?? .files)
    }
}
