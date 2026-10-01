import Foundation

enum ConflictChoice: String, Codable { case skip, copy, replace }

enum TransferState: String, Codable { case queued, running, paused, failed, cancelled, completed }

enum TransferDirection: String, Codable {
    case upload, download
    /// From one connected account to another: bytes are staged in a scratch folder, never kept.
    case transfer
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
    /// Google documents a download job exported: Drive lists no size or checksum for them, so there was nothing to check.
    var exportedFiles = 0
    /// How each downloaded file was checked, keyed like `uploads`. A failed check stays recorded on the failed job;
    /// the map is dropped on completion, when the counters above carry the result.
    var downloads: [String: DownloadIntegrity] = [:]
    /// Destination account of a cross-cloud transfer; `accountID` is then the source.
    var targetAccountID: String?
    /// nil for ordinary transfers; mirrors keep the exact remote object and its last observed version per path.
    var mirrorEntries: [String: CloudFile]?
    /// Set when the queue paused this job by itself (no network, outside the schedule, a costly network), so it
    /// resumes on its own when the reason goes away. nil for everything the person paused by hand.
    var hold: TransferHold?
    var finished: Bool { [.completed, .cancelled, .failed].contains(state) }
    var failed: Bool { state == .failed }
    var progress: Double { state == .completed ? 1 : (total > 0 ? min(1, Double(bytes) / Double(total)) : 0) }
    var status: String {
        switch state {
        case .queued: return L("En cola")
        case .running: return detail.isEmpty ? L("Transfiriendo…") : detail
        case .paused: return detail.isEmpty ? L("En pausa · Reanudar para continuar") : detail
        case .failed: return detail
        case .cancelled: return L("Cancelada · Los elementos completados se conservan")
        case .completed: return detail.isEmpty ? L("Completada") : detail
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

extension Transfer {
    /// Records how a downloaded file was checked. Only a download job counts it towards the summary: in a cross-cloud
    /// transfer the counters describe the upload, which is the copy that stays. A file recorded before, by a run that
    /// stopped before marking it complete, is replaced rather than counted twice.
    mutating func recordDownload(_ key: String, _ integrity: DownloadIntegrity) {
        if direction == .download, let previous = downloads[key] { count(previous, -1) }
        downloads[key] = integrity
        if direction == .download { count(integrity, 1) }
    }
    private mutating func count(_ integrity: DownloadIntegrity, _ delta: Int) {
        switch integrity {
        case .verified: verifiedFiles += delta
        case .unavailable: unverifiedFiles += delta
        case .exported: exportedFiles += delta
        case .failed: break
        }
    }
    enum CodingKeys: String, CodingKey {
        case id, batchID, name, destination, accountID, direction, localURL, bookmark, parent, file, exportMime, exportExtension
        case state, detail, bytes, total, bytesPerSecond, attempts, batchChoice, completedPaths, folders, uncertainFolders, names, replacements, uploads
        case verifiedFiles, unverifiedFiles, exportedFiles, downloads, targetAccountID, mirrorEntries
        case hold
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
                  exportedFiles: try values.decodeIfPresent(Int.self, forKey: .exportedFiles) ?? 0,
                  // A state written by a newer version is not worth losing the whole queue over.
                  downloads: (try? values.decodeIfPresent([String: DownloadIntegrity].self, forKey: .downloads)) ?? [:],
                  targetAccountID: try values.decodeIfPresent(String.self, forKey: .targetAccountID),
                  mirrorEntries: try values.decodeIfPresent([String: CloudFile].self, forKey: .mirrorEntries),
                  // A reason added by a newer version is read as none: the job then waits for the person.
                  hold: (try? values.decodeIfPresent(String.self, forKey: .hold)).flatMap { $0.flatMap(TransferHold.init(rawValue:)) })
    }
}
