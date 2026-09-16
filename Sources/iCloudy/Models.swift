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
enum TransferDirection: String, Codable { case upload, download }
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
    var finished: Bool { [.completed, .cancelled, .failed].contains(state) }
    var failed: Bool { state == .failed }
    var progress: Double { state == .completed ? 1 : (total > 0 ? min(1, Double(bytes) / Double(total)) : 0) }
    var status: String {
        switch state {
        case .queued: return "En cola"
        case .running: return detail.isEmpty ? "Transfiriendo…" : detail
        case .paused: return "En pausa · Reanudar para continuar"
        case .failed: return detail
        case .cancelled: return "Cancelada · Los elementos completados se conservan"
        case .completed: return "Completada"
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
struct Favorite: Identifiable, Codable {
    var id: String { accountID + ":" + file.id }
    let accountID: String
    var file: CloudFile
    var path: [CloudFile]
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

enum FileNames {
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
                  uploads: try values.decodeIfPresent([String: UploadCheckpoint].self, forKey: .uploads) ?? [:])
    }
}

extension Favorite {
    enum CodingKeys: String, CodingKey { case accountID, file, path }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(accountID: try values.decode(String.self, forKey: .accountID),
                  file: try values.decode(CloudFile.self, forKey: .file),
                  path: try values.decodeIfPresent([CloudFile].self, forKey: .path) ?? [])
    }
}
