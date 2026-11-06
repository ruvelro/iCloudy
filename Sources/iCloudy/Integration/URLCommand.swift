import Foundation
import AppKit

/// What an `icloudy://` link asks for. Any app, script or web page can open one, so a link only ever shows things:
/// it opens a folder, reveals an item or starts a search. Nothing a link says is a reason to delete, move, overwrite
/// or send anything.
///
///     icloudy://open?account=<id, alias, name or e-mail>&path=/Fotos/2024
///     icloudy://reveal?account=…&path=/Fotos/2024/playa.jpg
///     icloudy://search?q=factura
///     icloudy://<account>/Fotos/2024          (the short form of open)
enum URLCommand: Equatable {
    case open(account: String, path: [String])
    case reveal(account: String, path: [String])
    case search(query: String)

    static let scheme = "icloudy"
    /// Long enough for any real path; a link built to exhaust memory or the log is refused instead.
    static let maximumLength = 8192

    enum Failure: LocalizedError, Equatable {
        case notICloudy, tooLong, unknown(String), missing(String), invalidPath
        var errorDescription: String? {
            switch self {
            case .notICloudy: return L("Ese enlace no es de iCloudy.")
            case .tooLong: return L("El enlace de iCloudy es demasiado largo.")
            case .unknown(let command): return L("iCloudy no sabe hacer «\(command)» desde un enlace.")
            case .missing(let field): return L("Al enlace de iCloudy le falta «\(field)».")
            case .invalidPath: return L("La ruta del enlace de iCloudy no es válida.")
            }
        }
    }

    static func parse(_ url: URL) throws -> URLCommand {
        guard url.scheme?.lowercased() == scheme else { throw Failure.notICloudy }
        guard url.absoluteString.count <= maximumLength else { throw Failure.tooLong }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw Failure.invalidPath }
        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] where fields[item.name] == nil { fields[item.name] = item.value ?? "" }
        let host = (components.host ?? "").removingPercentEncoding ?? ""
        switch host.lowercased() {
        case "open", "reveal":
            guard let account = clean(fields["account"]), !account.isEmpty else { throw Failure.missing("account") }
            let path = try segments(fields["path"] ?? "")
            return host.lowercased() == "open" ? .open(account: account, path: path) : .reveal(account: account, path: path)
        case "search":
            guard let query = clean(fields["q"])?.trimmingCharacters(in: .whitespaces), !query.isEmpty else { throw Failure.missing("q") }
            return .search(query: String(query.prefix(256)))
        case "":
            throw Failure.missing("account")
        default:
            // icloudy://account/path, where the host is the account as people would write it.
            guard let account = clean(host) else { throw Failure.invalidPath }
            if ["delete", "trash", "remove", "move", "rename", "upload", "put", "empty"].contains(host.lowercased()) {
                throw Failure.unknown(host)
            }
            return .open(account: account, path: try segments(components.percentEncodedPath.removingPercentEncoding ?? ""))
        }
    }

    /// A value without control characters, which have no business in a name or a path.
    static func clean(_ value: String?) -> String? {
        guard let value, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    /// The path as names from the top of the account. `.` and `..` are refused rather than resolved: a link names a
    /// place, it does not walk out of one.
    static func segments(_ path: String) throws -> [String] {
        guard let path = clean(path), path.count <= 4096 else { throw Failure.invalidPath }
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { throw Failure.invalidPath }
        return parts
    }

    /// The link that opens `path` of `account`, as the app hands it out ("Copiar enlace de iCloudy").
    static func link(_ command: URLCommand) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        switch command {
        case .open(let account, let path), .reveal(let account, let path):
            if case .open = command { components.host = "open" } else { components.host = "reveal" }
            components.queryItems = [URLQueryItem(name: "account", value: account), URLQueryItem(name: "path", value: "/" + path.joined(separator: "/"))]
        case .search(let query):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        return components.url
    }
}

extension AppModel {
    /// The account a link names: by id first, then by alias, name or e-mail, ignoring case. A name that two accounts
    /// share is refused rather than guessed.
    func account(named reference: String) throws -> Account {
        if let exact = accounts.first(where: { $0.id == reference }) { return exact }
        let matches = accounts.filter { account in
            [accountTitle(account), account.name, account.email].contains { $0.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        }
        guard !matches.isEmpty else { throw CloudError.notFound(L("No hay ninguna cuenta conectada que se llame «\(reference)».")) }
        guard matches.count == 1 else { throw CloudError.message(L("Hay varias cuentas que se llaman «\(reference)». Usa el identificador de la cuenta.")) }
        return matches[0]
    }

    /// Runs what an `icloudy://` link asks for, once the accounts are loaded.
    func handle(_ url: URL) async {
        do {
            let command = try URLCommand.parse(url)
            // There is no application object when the model runs under the tests.
            NSApp?.activate(ignoringOtherApps: true)
            switch command {
            case .open(let reference, let path): try await openLink(account: try account(named: reference), path: path, revealing: false)
            case .reveal(let reference, let path): try await openLink(account: try account(named: reference), path: path, revealing: true)
            case .search(let query): startGlobalSearch(query)
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Shows the folder `path` names, or the folder that holds the item it names. With `revealing` the item is also
    /// selected; without, a file opens in the preview, as a Spotlight result does. This is the one place links,
    /// the command line and the App Intents go through to show a place.
    func openLink(account: Account, path: [String], revealing: Bool) async throws {
        let place = try await resolve(path: path.joined(separator: "/"), in: account)
        preview.close(); globalSearch.cancel(); ui.showGlobalSearch = false
        if let file = place.file, file.isFolder, !revealing {
            go(to: BrowserLocation(accountID: account.id, collection: .files, path: place.trail))
            return
        }
        let folderTrail = place.file?.isFolder == true ? Array(place.trail.dropLast()) : place.trail
        go(to: BrowserLocation(accountID: account.id, collection: .files, path: folderTrail))
        guard let file = place.file else { return }
        if revealing { selectedIDs = [file.id] }
        else { preview.show(file: file, account: account, client: try client(account)) }
    }

    /// The `icloudy://` link that reveals `file` in the open folder, for pasting into notes, scripts or a chat.
    func copyICloudyLink(_ file: CloudFile) {
        guard let account, collection == .files,
              let link = URLCommand.link(.reveal(account: account.id, path: path.map(\.name) + [file.name])) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }
}
