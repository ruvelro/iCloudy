import Foundation

/// OneDrive's recycle bin has no listing in Microsoft Graph for third parties, but an item in it can be put back by
/// its id (`POST /items/{id}/restore`, OneDrive personal). So iCloudy remembers what it sent there itself and lists
/// that: not the whole bin, only what was deleted from this app in the last 30 days, which is as long as OneDrive
/// keeps it. The interface says as much.
@MainActor
final class OneDriveBinJournal {
    struct Entry: Codable, Equatable {
        let file: CloudFile
        let deleted: Date
    }
    static let shared = OneDriveBinJournal(url: LocalStore.directory.appendingPathComponent("onedrive-bin.json"))
    static let retention: TimeInterval = 30 * 86_400
    static let limit = 1_000

    private let url: URL
    private var entries: [String: [Entry]]

    init(url: URL) {
        self.url = url
        do { entries = try LocalStore.read([String: [Entry]].self, from: url) ?? [:] }
        catch {
            // An unreadable journal is set aside rather than overwritten by the next record: it is the only list
            // of restorable OneDrive items the app has.
            _ = try? LocalStore.setAside(url)
            entries = [:]
        }
    }

    func items(accountID: String, now: Date = Date()) -> [Entry] {
        (entries[accountID] ?? []).filter { now.timeIntervalSince($0.deleted) < Self.retention }
    }
    func record(_ file: CloudFile, accountID: String, now: Date = Date()) throws {
        var list = items(accountID: accountID, now: now).filter { $0.file.id != file.id }
        list.insert(Entry(file: file, deleted: now), at: 0)
        entries[accountID] = Array(list.prefix(Self.limit))
        try persist()
    }
    func forget(_ id: String, accountID: String) throws {
        entries[accountID]?.removeAll { $0.file.id == id }
        try persist()
    }
    func forgetAccount(_ accountID: String) { entries[accountID] = nil; try? persist() }
    private func persist() throws { try LocalStore.save(entries, to: url) }
}

extension OneDriveProvider {
    var binJournal: OneDriveBinJournal { .shared }

    func oneDriveBinList() -> [CloudFile] {
        binJournal.items(accountID: account.id).map { entry in
            CloudFile(id: entry.file.id, name: entry.file.name, mime: entry.file.mime, size: entry.file.size, modified: entry.deleted,
                      webURL: nil, isFolder: entry.file.isFolder)
        }
    }

    func oneDriveRestore(_ file: CloudFile) async throws {
        var request = try await request(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/restore")!, method: "POST", body: [:])
        let (data, response) = try await send(&request)
        do { try HTTP.validate(response, data: data) }
        catch let error as ServiceError where error.status == 404 {
            // Dropping a stale entry is housekeeping: failing to write it must not hide the real answer.
            try? binJournal.forget(file.id, accountID: account.id)
            throw CloudError.message(L("«\(file.name)» ya no está en la papelera de OneDrive: se vació o se restauró desde otro sitio."))
        }
        catch let error as ServiceError where [400, 403, 405, 501].contains(error.status) {
            throw CloudError.message(L("OneDrive solo deja restaurar desde otras aplicaciones en las cuentas personales. Restáuralo desde la papelera de la web de OneDrive."))
        }
        // The item is back; a stale entry only means it is still offered, and restoring it again says so.
        try? binJournal.forget(file.id, accountID: account.id)
    }

    /// Records a successful recycle-bin move. The item is already in OneDrive's bin, so a failure here is reported
    /// as such: the person must know that this app will not be able to list it for restoring.
    func rememberTrashed(_ file: CloudFile) throws {
        do { try binJournal.record(file, accountID: account.id) }
        catch {
            throw CloudError.message(L("«\(file.name)» está en la papelera de OneDrive, pero iCloudy no pudo apuntarlo para restaurarlo desde aquí: ") + error.localizedDescription + L(" Puedes restaurarlo desde la web de OneDrive."))
        }
    }
}
