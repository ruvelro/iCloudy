import Foundation

/// Typing the first letters of a name selects the first item that starts with them, as in the Finder. Letters typed
/// within a second of each other add up; a pause starts again.
struct TypeSelect {
    static let pause: TimeInterval = 1
    private(set) var typed = ""
    private var last: Date?

    /// Adds what was typed and returns the whole prefix so far.
    mutating func type(_ characters: String, at date: Date = Date()) -> String {
        if let last, date.timeIntervalSince(last) > Self.pause { typed = "" }
        last = date
        typed += characters
        return typed
    }

    /// The first item whose name starts with `prefix`, ignoring case and accents; failing that, the first one that
    /// sorts after it, so typing past every name lands at the end rather than nowhere.
    static func match(_ prefix: String, in files: [CloudFile]) -> CloudFile? {
        guard !prefix.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .anchored]
        if let hit = files.first(where: { $0.name.range(of: prefix, options: options) != nil }) { return hit }
        return files.filter { $0.name.localizedStandardCompare(prefix) == .orderedDescending }
            .min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension AppModel {
    /// Why ⌘D cannot duplicate these items here, or nil when it can.
    ///
    /// A duplicate is a copy on the server into the same folder, renamed afterwards. Only providers whose folders
    /// take two items of the same name for that moment can do it: Drive, Mega and the demo. The rest would refuse
    /// the copy, or (WebDAV, a volume) answer that it is the same item; downloading and uploading again is not what
    /// ⌘D promises, so there it is disabled with the reason.
    func duplicateLimitation(_ files: [CloudFile]) -> String? {
        guard let account, !files.isEmpty else { return L("Selecciona lo que quieras duplicar.") }
        guard workspace.current.collection == .files, !inTrash else { return L("Abre su carpeta en «Mis archivos» para duplicarlo.") }
        if let reason = account.limitation(.copy, for: files) { return reason }
        guard account.isDemo || [.google, .mega].contains(account.cloud), !CryptomatorVaults.isVaultAccount(account.id) else {
            return L("\(account.cloud.title) no hace copias en la misma carpeta desde iCloudy. Usa «Copiar a…» con otra carpeta.")
        }
        return nil
    }

    /// The name a duplicate takes: «Informe copia.docx», numbered when that is taken too.
    static func duplicateName(_ name: String, isFolder: Bool, existing: [String]) -> String {
        let ext = isFolder ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        return TransferQueue.unique(L("\(base) copia") + (ext.isEmpty ? "" : "." + ext), existing: existing)
    }

    /// ⌘D: copies each item on the server into its own folder and gives the copy a name of its own.
    func duplicate(_ files: [CloudFile]) async {
        if let reason = duplicateLimitation(files) { error = reason; return }
        guard let account else { return }
        let parent = folderID
        var done = 0
        do {
            let api = try client(account)
            for file in files {
                let before = Set(try await api.list(parent: parent).map(\.id))
                try await api.copy(file: file, to: parent)
                let after = try await api.list(parent: parent)
                // The copy is the one item of that name the folder did not have a moment ago.
                guard let copy = after.first(where: { !before.contains($0.id) && $0.name == file.name }) else {
                    throw CloudError.message(L("La copia de «\(file.name)» no apareció en la carpeta."))
                }
                try await api.rename(file: copy, name: Self.duplicateName(file.name, isFolder: file.isFolder, existing: after.map(\.name)))
                done += 1
            }
        } catch {
            self.error = (done > 0 ? L("Se duplicaron \(done) de \(files.count). ") : L("")) + error.localizedDescription
        }
        reloadAfterWrite(to: account)
    }

    /// What ⌘E puts away: an unlocked vault, or a volume, which is disconnected after asking. Nil when the focused
    /// account is neither; ejecting a cloud makes no sense.
    var ejectable: Account? {
        guard let account else { return nil }
        return CryptomatorVaults.isVaultAccount(account.id) || account.cloud == .volume ? account : nil
    }

    /// ⌘E: locks the vault, or asks before disconnecting the volume.
    func eject() {
        guard let target = ejectable else { return }
        if CryptomatorVaults.isVaultAccount(target.id) { lockVault(target.id); return }
        guard canDisconnect(target) else { error = L("Pausa o termina las transferencias de esta cuenta"); return }
        ui.pendingDisconnect = target
    }
}
