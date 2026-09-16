import Foundation
import Combine

/// One finished transfer. Unlike the queue, this survives "Limpiar completadas" and app restarts.
struct HistoryEntry: Identifiable, Codable {
    var id = UUID()
    let name: String
    let accountID: String
    /// Destination account of a cross-cloud transfer.
    let targetAccountID: String?
    let direction: TransferDirection
    /// Human-readable destination: remote path for uploads, local folder for downloads.
    let destination: String
    /// Remote folder id for uploads, so the explorer can jump back to it.
    let parent: String
    /// Final local item for downloads (the chosen name, after conflict resolution) plus a bookmark to reach it in the sandbox.
    let localURL: URL?
    let bookmark: Data?
    let bytes: Int64
    let finishedAt: Date
    /// Completion detail, e.g. how many files were verified.
    let summary: String

    init(transfer: Transfer, finishedAt: Date = Date()) {
        name = transfer.name; accountID = transfer.accountID; targetAccountID = transfer.targetAccountID; direction = transfer.direction
        destination = transfer.destination; parent = transfer.parent
        if transfer.direction == .download {
            localURL = transfer.localURL.appendingPathComponent(transfer.names["."] ?? FileNames.safe(transfer.name))
            bookmark = transfer.bookmark
        } else { localURL = nil; bookmark = nil }
        bytes = max(transfer.bytes, transfer.total); self.finishedAt = finishedAt; summary = transfer.detail
    }
}

extension HistoryEntry {
    enum CodingKeys: String, CodingKey { case id, name, accountID, targetAccountID, direction, destination, parent, localURL, bookmark, bytes, finishedAt, summary }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Transferencia"
        accountID = try values.decode(String.self, forKey: .accountID)
        targetAccountID = try values.decodeIfPresent(String.self, forKey: .targetAccountID)
        direction = try values.decode(TransferDirection.self, forKey: .direction)
        destination = try values.decodeIfPresent(String.self, forKey: .destination) ?? ""
        parent = try values.decodeIfPresent(String.self, forKey: .parent) ?? "root"
        localURL = try values.decodeIfPresent(URL.self, forKey: .localURL)
        bookmark = try values.decodeIfPresent(Data.self, forKey: .bookmark)
        bytes = try values.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        finishedAt = try values.decodeIfPresent(Date.self, forKey: .finishedAt) ?? .distantPast
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
    }
}

@MainActor
final class TransferHistory: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published var persistenceError: String?
    let storeURL: URL
    /// Newest first; older entries fall off so the file stays small.
    var limit = 200

    init(storeURL: URL = LocalStore.directory.appendingPathComponent("history.json")) {
        self.storeURL = storeURL
        limit = max(20, Prefs.int(Prefs.historyLimit, default: 200))
        do { entries = try LocalStore.read([HistoryEntry].self, from: storeURL) ?? [] }
        catch { persistenceError = L("No se pudo leer el historial: \(error.localizedDescription)") }
    }
    func record(_ transfer: Transfer) {
        entries.insert(HistoryEntry(transfer: transfer), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }
    func clear() { entries = []; persist() }
    private func persist() {
        do { try LocalStore.save(entries, to: storeURL); persistenceError = nil }
        catch { persistenceError = L("No se pudo guardar el historial: \(error.localizedDescription)") }
    }
}
