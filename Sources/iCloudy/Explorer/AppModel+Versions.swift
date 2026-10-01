import Foundation

/// A file whose versions sheet is open, with where it was opened from so a restore can be traced back there.
struct VersionsRequest: Identifiable {
    let id = UUID()
    let file: CloudFile
    let account: Account
    /// Remote folder holding the file, for "Ir a la carpeta" in the history; the root when it was opened from a list.
    let parent: String
    /// Human-readable location, as the history shows it.
    let location: String
}

extension AppModel {
    /// Why the versions of this item cannot be shown in the current account; the disabled action's help.
    func versionsLimitation(_ file: CloudFile) -> String? { account?.versionsLimitation(for: file) }

    func requestVersions(_ file: CloudFile) {
        guard let account else { return }
        if let reason = account.versionsLimitation(for: file) { error = reason; return }
        let inFolder = collection == .files || !path.isEmpty
        versionHistory = VersionsRequest(file: file, account: account, parent: inFolder ? folderID : "root", location: location)
    }

    /// What the preview and the download of `version` work on: the file itself for the current version, otherwise
    /// an item that names the version and carries its size and checksum.
    static func versionTarget(_ version: FileVersion, of file: CloudFile) -> CloudFile {
        version.isCurrent ? file : VersionedFile.make(file, version: version)
    }

    func previewVersion(_ version: FileVersion, of request: VersionsRequest) throws {
        preview.show(file: Self.versionTarget(version, of: request.file), account: request.account, client: try client(request.account))
    }

    /// Through the transfer queue like any download, so it is verified, resumable and listed in the history.
    func saveVersion(_ version: FileVersion, of request: VersionsRequest, export: (mime: String, ext: String)? = nil) async {
        await saveMany([Self.versionTarget(version, of: request.file)], export: export, targetAccount: request.account)
    }

    /// Restores on the provider, then forgets everything that described the content being replaced and leaves a
    /// note in the transfer history, since the file in the cloud has changed as much as after an upload.
    func restoreVersion(_ version: FileVersion, of request: VersionsRequest) async throws {
        let api = try client(request.account)
        try await api.restoreVersion(version, of: request.file)
        versionRestored(request.file, account: request.account)
        history.record(Self.restoreNote(version, of: request))
    }

    /// The history entry a restore leaves: a finished write to the file's folder, saying which version came back.
    static func restoreNote(_ version: FileVersion, of request: VersionsRequest) -> Transfer {
        let when = version.modified?.formatted(date: .abbreviated, time: .shortened) ?? version.id
        return Transfer(name: request.file.name, destination: request.location, accountID: request.account.id, direction: .upload,
                        localURL: URL(fileURLWithPath: "/"), parent: request.parent, file: request.file, state: .completed,
                        detail: L("Restaurada la versión del \(when)"), bytes: version.size ?? 0, total: version.size ?? 0)
    }

    func deleteVersion(_ version: FileVersion, of request: VersionsRequest) async throws {
        try await client(request.account).deleteVersion(version, of: request.file)
        refreshStorage(request.account, force: true)
    }

    /// After a restore the file has new content under the same id, so whatever was keyed to the old content is
    /// wrong: the cached listing and the provider's caches hold the old size, date and checksum that downloads are
    /// verified against; a copy on this Mac is no longer the cloud's content; an open preview shows the old bytes.
    /// The listing is asked for again, which brings the new checksum, and the copy is flagged as out of date, not
    /// forgotten: the file on disk is still there, it is just not what the cloud has any more.
    func versionRestored(_ file: CloudFile, account: Account) {
        Self.forgetContent(of: file, accountID: account.id, listings: listings, localCopies: localCopies)
        (try? client(account))?.dropCaches()
        if preview.model.account?.id == account.id, let shown = preview.model.file,
           shown.id == file.id || VersionedFile.reference(shown)?.file.id == file.id { preview.close() }
        // Every pane showing the account lists again, not only the focused one: the sheet may have been opened from
        // the other pane, or the focus moved while the restore was running.
        reloadAfterWrite(to: account)
        refreshStorage(account, force: true)
    }

    /// The part of `versionRestored` that lives in stores of its own: the account's cached listings, and the
    /// local copy, whose recorded remote date is pushed back so its badge says it is behind the cloud.
    static func forgetContent(of file: CloudFile, accountID: String, listings: ListingCache, localCopies: LocalCopyIndex) {
        listings.removeAll(accountID: accountID)
        if var copy = localCopies.copies[LocalCopyIndex.key(accountID: accountID, fileID: file.id)] {
            copy.remoteModified = .distantPast
            localCopies.record(copy)
        }
    }
}
