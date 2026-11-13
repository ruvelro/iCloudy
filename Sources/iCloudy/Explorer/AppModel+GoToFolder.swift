import Foundation

/// A place typed by hand: «Documentos/Facturas», or «Dropbox:/Fotos/2024» to name the account too.
struct FolderAddress: Equatable {
    /// The account the text named, or nil when it named none and the focused one is meant.
    var accountID: String?
    /// The path from the top of the account, without leading or trailing slashes.
    var path: String

    /// Reads «cuenta:/ruta» and plain «ruta». The account is matched by what the sidebar calls it (its alias), its
    /// name, its address or its provider's name, ignoring case; text before a colon that names no account is taken
    /// as part of the path, so a folder called «Notas: 2024» still opens.
    static func parse(_ text: String, accounts: [Account], title: (Account) -> String) -> FolderAddress {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var accountID: String?
        var rest = Substring(trimmed)
        if let colon = trimmed.firstIndex(of: ":") {
            let label = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let matches: (Account) -> Bool = { account in
                [title(account), account.name, account.email, account.cloud.title].contains { $0.localizedCaseInsensitiveCompare(label) == .orderedSame }
            }
            if !label.isEmpty, let account = accounts.first(where: matches) {
                accountID = account.id
                rest = trimmed[trimmed.index(after: colon)...]
            }
        }
        // «~/Fotos», «/Fotos» and «Fotos/» all mean the same folder.
        if rest.hasPrefix("~") { rest = rest.dropFirst() }
        let parts = rest.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return FolderAddress(accountID: accountID, path: parts.joined(separator: "/"))
    }
}

extension AppModel {
    /// The focused tab's place as Go to Folder reads it, so the field starts with where the tab stands.
    func pathText(for tab: BrowserState) -> String {
        guard tab.collection == .files else { return "" }
        return tab.path.map(\.name).joined(separator: "/")
    }

    /// The same, with the account in front: what «Copiar ruta» puts on the pasteboard and Go to Folder reads back.
    func addressText(accountID: String?, path: [CloudFile], file: CloudFile? = nil) -> String {
        let account = browsable(accountID)
        let names = path.map(\.name) + (file.map { [$0.name] } ?? [])
        return (account.map { accountTitle($0) } ?? "") + ":/" + names.joined(separator: "/")
    }

    /// Opens what `text` names: a folder in the focused tab, or the folder of a file with that file selected.
    /// Throws what went wrong (a step that is not there, an account that is not connected) for the sheet to show.
    func goToFolder(_ text: String, defaultAccount: Account? = nil) async throws {
        let address = FolderAddress.parse(text, accounts: accounts, title: { accountTitle($0) })
        guard let account = address.accountID.flatMap({ id in accounts.first { $0.id == id } }) ?? defaultAccount ?? account else {
            throw CloudError.message(L("Elige una cuenta o escribe su nombre delante de la ruta, como «Dropbox:/Fotos»."))
        }
        try await open(path: address.path, in: account)
    }

    /// Opens a path of an account in the focused tab. The path is walked from the top of the account, one listing
    /// per step, the way `FileShortcuts` resolves it; a file opens its folder with the file selected. Meant to be the
    /// one way in for anything that names a place by path: Go to Folder, the path bar, and a URL or an intent.
    func open(path: String, in account: Account, tab: BrowserState.ID? = nil) async throws {
        let tab = tab ?? workspace.current.id
        let place = try await resolve(path: path, in: account)
        preview.close(); globalSearch.cancel(); ui.showGlobalSearch = false
        go(to: BrowserLocation(accountID: account.id, collection: .files, path: place.trail), tab: tab)
        if let file = place.file, !file.isFolder { workspace.update(tab) { $0.selection = [file.id] } }
    }
}
