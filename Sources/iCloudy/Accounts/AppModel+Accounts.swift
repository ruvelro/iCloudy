import AppKit
import SwiftUI
import Combine

extension AppModel {
    func loadAccounts() {
        // A model built by a test must not adopt the accounts stored on this Mac: the task below outlives the test
        // that created it, and once the next asynchronous test gave it a turn it listed real accounts, started the
        // real mirrors and renewed real sessions from inside the test run. The tab store opts out the same way. The
        // model stays "loading", so nothing that waits for the accounts (the offline refresh) starts either.
        loadingAccounts = true
        guard !Diagnostics.underTest else { return }
        Task { [key = AccountDirectory.storageKey] in
            let stored: [Account]
            do { stored = try await Task.detached { try Vault.read([Account].self, key: key) ?? [] }.value }
            catch {
                accountLoadError = error
                loadingAccounts = false
                self.error = L("No se pudieron leer las cuentas guardadas: \(error.localizedDescription)")
                return
            }
            loadingAccounts = false
            // The demo account is local and may already be in the list.
            directory.accounts = stored + accounts.filter(\.isDemo)
            mirrors.start()
            remoteCopies.client = queue.client
            remoteCopies.didComplete = queue.didComplete
            remoteCopies.resume()
            // Tabs restored from the last session may name accounts that are gone; they fall back to the first one.
            workspace.reconcile(with: accounts)
            refreshSpotlightFavorites()
            if let waiting = pendingSpotlightItem { pendingSpotlightItem = nil; openSpotlightItem(identifier: waiting) }
            reloadVisible()
            for account in accounts where account.id != selectedAccountID { refreshStorage(account) }
            o2.migrateStores()
            o2.startKeepAlive()
        }
    }

    func client(_ account: Account) throws -> CloudAPI {
        if account.isCryptomatorVault { guard let vault = cryptomator.client(for: account.id) else { throw CryptomatorError.locked }; return vault }
        if let client = sessions.cached(for: account.id) { return client }
        if account.isDemo && demo == nil { demo = try DemoStore() }
        let client = CloudAPI(account: account, demo: account.isDemo ? demo : nil)
        client.credentialSaveDidFail = { [weak self] message in self?.error = message }
        client.bookmarkDidRenew = { [weak self] bookmark in self?.storeRenewedBookmark(bookmark, for: account) }
        client.sessionDidExpire = { [weak self] reason in
            self?.directory.markExpired(account.id, reason: reason)
            self?.o2.renewSilently(account)
        }
        sessions.store(client)
        return client
    }

    /// Keeps a bookmark the system had to renew. macOS marks one stale when the folder moves or the volume changes
    /// identity; the old one still resolves for a while and then stops, and the account looks broken out of nowhere.
    func storeRenewedBookmark(_ bookmark: Data, for account: Account) {
        // The renewed bookmark works for this run either way; unsaved, the account breaks again on the next launch.
        do { try directory.update(account.id) { $0.bookmark = bookmark } }
        catch { self.error = L("No se pudo guardar el acceso renovado a «\(account.name)»: \(error.localizedDescription) Funciona ahora, pero puede que haya que volver a añadir la carpeta al abrir iCloudy de nuevo.") }
    }

    func isExpired(_ account: Account) -> Bool { directory.isExpired(account.id) }

    static func dependents(of account: Account, in accounts: [Account]) -> [Account] {
        AccountDirectory.dependents(of: account, in: accounts)
    }
    static func placing(_ account: Account, in accounts: [Account]) -> [Account] { AccountDirectory.placing(account, in: accounts) }
    static func moving(_ id: Account.ID, to target: Account.ID, in accounts: [Account]) -> [Account] {
        AccountDirectory.moving(id, to: target, in: accounts)
    }
    static func moving(_ id: Account.ID, by offset: Int, in accounts: [Account]) -> [Account] {
        AccountDirectory.moving(id, by: offset, in: accounts)
    }

    func canMoveAccount(_ account: Account, by offset: Int) -> Bool {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return false }
        return accounts.indices.contains(index + offset)
    }

    func moveAccount(_ id: Account.ID, to target: Account.ID) { reorderAccounts(Self.moving(id, to: target, in: accounts)) }

    func moveAccount(_ account: Account, by offset: Int) { reorderAccounts(Self.moving(account.id, by: offset, in: accounts)) }

    /// The order lives in the same Keychain entry as the accounts, so it is the order they come back in on the next
    /// launch. The demo account is not stored and goes back to the end then.
    private func reorderAccounts(_ updated: [Account]) {
        do { try directory.reorder(updated) }
        catch { self.error = L("No se pudo guardar el orden de las nubes: \(error.localizedDescription)") }
    }

    /// Reconnecting replaces the client of the account itself; the dependants keep a client that still believes the
    /// old session is gone, so they are reset too. Without this a shared drive stayed "expired" until the next launch.
    func adopt(_ account: Account, credential: Credential?) throws { try directory.adopt(account, credential: credential) }

    /// True while a new session is being fetched without involving the person, so the interface can say so rather
    /// than showing an alarming notice about an account that is about to fix itself.
    func isRenewing(_ account: Account) -> Bool { directory.isRenewing(account.id) }

    /// What the provider said when it dropped the session, if anything.
    func expiryReason(_ account: Account) -> String? { directory.expiryReason(account.id) }

    /// Connects a folder of this Mac or of a mounted volume. macOS does the SMB, AFP or NFS work; iCloudy only needs
    /// the user to point at the folder once, which is also what grants access under the sandbox.
    func connectVolume() async {
        guard !ui.connecting else { return }
        ui.connectionError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.prompt = L("Conectar")
        panel.message = L("Elige la carpeta o el volumen que quieres usar como nube. Para un recurso de red, conéctalo antes en el Finder con ⌘K.")
        guard await panel.begin() == .OK, let folder = panel.url else { return }
        ui.connecting = true
        defer { ui.connecting = false }
        do {
            let standardized = folder.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: [.volumeNameKey, .volumeIsRemovableKey])
            let account = Account(id: "volume:" + standardized.path, cloud: .volume,
                                  name: standardized.lastPathComponent,
                                  email: values?.volumeName.map { $0 + " · " + standardized.path } ?? standardized.path,
                                  clientID: "", clientSecret: nil, serverURL: standardized.path,
                                  bookmark: try TransferQueue.bookmark(folder))
            try directory.adopt(account, credential: nil)
            select(account.id); ui.showConnect = false
        } catch { ui.connectionError = error.localizedDescription }
    }

    /// Adds the shared drive as its own account. It borrows the credential of the account it came from, so there is no
    /// second sign-in and no second copy of the tokens.
    func addScopedDrive(_ drive: RemoteDrive, from parent: Account) {
        let account = Account.scoped(to: drive.id, named: drive.name, from: parent)
        do {
            try directory.adopt(account, credential: nil)
            ui.showAdvanced = false
            select(account.id); ui.showConnect = false
        } catch { self.error = error.localizedDescription }
    }

    /// Stores the session O2 handed out on its own pages, from the sign-in window. The connection sheet shows how it
    /// went; the work itself, shared with the silent renewals, is the keeper's.
    func completeO2(host: String, validationKey: String, cookies: [HTTPCookie], userAgent: String?,
                    sso: [HTTPCookie] = [], webStore: UUID? = nil) async {
        ui.connectionError = nil; ui.connecting = true
        defer { ui.connecting = false }
        do {
            guard let account = try await o2.complete(host: host, validationKey: validationKey, cookies: cookies,
                                                      userAgent: userAgent, sso: sso, webStore: webStore) else { return }
            select(account.id); ui.showConnect = false
        } catch { ui.connectionError = error.localizedDescription }
    }

    /// A sign-in window has closed. Its store stays only if an account came out of it.
    func o2LoginEnded(store: UUID) { o2.loginEnded(store: store) }

    /// Opens the Finder's own "Connect to Server" flow. Mounting is not something a sandboxed app may do itself.
    func openFinderConnect() {
        guard let url = URL(string: "smb://") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Connects a server the user hosts: WebDAV or FTP. The password goes straight to the Keychain and never leaves
    /// this Mac except to that server.
    func connectServer(cloud: Cloud, server: String, username: String, password: String, flavor: String? = nil, key: SFTPKeyMaterial? = nil,
                       webdavAuth: WebDAVAuth = .basic) async {
        guard !ui.connecting else { return }
        ui.connectionError = nil; ui.connecting = true
        defer { ui.connecting = false }
        do {
            let result: (Account, Credential)
            switch cloud {
            case .webdav: result = try await WebDAVAuthentication().signInWebDAV(server: server, username: username, password: password,
                                                                                    auth: webdavAuth, existing: accounts)
            case .ftp: result = try await FTPAuthentication().signInFTP(server: server, username: username, password: password)
            case .sftp: result = try await SFTPAuthentication().signInSFTP(server: server, username: username, password: password, key: key)
            case .mega: result = try await MegaAuthentication().signInMega(email: username, password: password)
            default: throw CloudError.message(L("\(cloud.title) no se conecta con usuario y contraseña."))
            }
            var (account, credential) = result
            if let flavor { account.options["flavor"] = flavor }
            try directory.adopt(account, credential: credential)
            ui.serverLogin = nil; ui.reconnecting = nil
            select(account.id); ui.showConnect = false
        } catch { ui.connectionError = error.localizedDescription }
    }

    /// Nextcloud's sign-in in the browser. The form waits while the person signs in there; cancelling the task (the
    /// form's Cancel button, or closing it) stops the polling.
    func connectNextcloud(server: String, flow: NextcloudLoginFlow = NextcloudLoginFlow()) async {
        guard !ui.connecting else { return }
        ui.connectionError = nil; ui.connecting = true
        defer { ui.connecting = false }
        do {
            let (account, credential) = try await flow.signIn(server: server, existing: accounts)
            try directory.adopt(account, credential: credential)
            ui.serverLogin = nil; ui.reconnecting = nil
            select(account.id); ui.showConnect = false
        } catch is CancellationError {} catch { ui.connectionError = error.localizedDescription }
    }

    /// Starts the provider's sign-in for the same cloud; signing in with the same identity replaces the expired session.
    /// Reconnecting has to take the same road the account was created by. Sending a provider that never used OAuth
    /// down the OAuth path produced a message about configuration that had nothing to do with the problem.
    func reconnect(_ account: Account) async {
        ui.connectionError = nil
        switch account.cloud {
        case .volume:
            await connectVolume()
        case let cloud where cloud.usesWebLogin || cloud.usesPasswordLogin:
            // These two sign in from inside the connection sheet, so it has to be on screen to present them. The
            // sheet is opened first and the form a moment later: presenting both in the same turn is a nesting
            // SwiftUI sometimes drops on the floor, leaving a connection sheet and no form.
            ui.reconnecting = account
            ui.showConnect = true
            let host = account.options["host"] ?? O2SessionKeeper.defaultHost
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                if cloud.usesWebLogin { self.ui.o2Login = O2LoginRequest(host: host) } else { self.ui.serverLogin = cloud }
            }
        default:
            await connect(cloud: account.cloud)
        }
        if let message = ui.connectionError, !ui.showConnect { error = message; ui.connectionError = nil }
    }

    func enableDemo(select shouldSelect: Bool = true) {
        do {
            if demo == nil { demo = try DemoStore() }
            if !accounts.contains(where: \.isDemo) { directory.accounts.append(.demo) }
            Prefs.defaults.set(true, forKey: "demoEnabled")
            if shouldSelect { select(Account.demo.id); ui.showConnect = false }
        } catch { self.error = error.localizedDescription }
    }

    func appearance(for account: Account) -> AccountAppearance {
        appearances[account.id] ?? AccountAppearance(tint: Self.defaultTint(account.cloud))
    }

    static func defaultTint(_ cloud: Cloud) -> AccountTint {
        switch cloud {
        case .google: return .green
        case .microsoft: return .blue
        case .dropbox: return .purple
        case .box: return .teal
        case .webdav: return .gray
        case .ftp: return .orange
        case .sftp: return .teal
        case .volume: return .gray
        case .mega: return .red
        case .o2: return .pink
        case .pcloud: return .teal
        case .s3: return .orange
        case .azure: return .blue
        }
    }

    func accountTitle(_ account: Account) -> String { appearance(for: account).title(for: account) }

    func saveAppearance(_ value: AccountAppearance, for account: Account) throws {
        guard let appearanceStore else { throw CloudError.message(L("No se puede guardar la personalización. Se conserva el archivo anterior; revisa el error de carga.")) }
        try appearanceStore.save(value, for: account.id); appearances = appearanceStore.values
    }

    func failNextDemoTransfer() { demo?.failNext = true }

    func connect(cloud: Cloud) async {
        guard !ui.connecting else { return }
        ui.connectionError = nil; ui.connecting = true
        defer { ui.connecting = false }
        do {
            let configuration = try OAuthConfiguration.load()
            let client = try configuration.client(for: cloud)
            let (account, credential) = try await oauth.signIn(cloud: cloud, clientID: client.id, clientSecret: client.secret)
            try adopt(account, credential: credential)
            select(account.id); ui.showConnect = false
        } catch is CancellationError {} catch { ui.connectionError = error.localizedDescription }
    }

    func canDisconnect(_ account: Account) -> Bool {
        guard accounts.contains(where: { $0.id == account.id }) else { return false }
        return ([account] + Self.dependents(of: account, in: accounts)).allSatisfy { !queue.hasActive(accountID: $0.id) }
    }

    func disconnect(_ account: Account) {
        guard canDisconnect(account) else {
            error = L("Pausa o termina las transferencias de esta cuenta antes de desconectarla.")
            return
        }
        if account.cloud.usesWebLogin { o2.signOut(account) }
        // A shared drive or a library borrows this account's credential: once that is gone they cannot work and
        // cannot be reconnected on their own, so they leave with it instead of lingering as "expired".
        let leaving = [account] + Self.dependents(of: account, in: accounts)
        do {
            if let shown = preview.model.account, leaving.contains(where: { $0.id == shown.id }) { preview.close() }
            try directory.remove(account)
            if account.isDemo { Prefs.defaults.set(false, forKey: "demoEnabled") }
            for member in leaving { forget(member) }
            if let selected = selectedAccountID, leaving.contains(where: { $0.id == selected }) { select(accounts.first?.id) }
            retargetTabs(leaving: Set(leaving.map(\.id)))
        } catch { self.error = error.localizedDescription }
    }

    /// Drops everything kept locally about an account: its client, quota, listings, mirrors, index and search rows.
    func forget(_ account: Account) {
        o2.forgetRenewal(account.id)
        cryptomator.lockAll(storedIn: account.id)
        remoteCopies.removeAccount(account.id)
        quotas.remove(account.id)
        directory.forgetSessions([account.id])
        listings.removeAll(accountID: account.id)
        mirrors.removeAll(accountID: account.id)
        spotlight.removeAccount(account.id)
        localCopies.removeAccount(account.id)
        forgetOffline(account.id)
        globalSearch.removeAccount(account.id)
    }

    /// `then` reports whether the provider actually answered, which is what the keep-alive needs to know: this is
    /// the cheapest call that proves an O2 session is still alive, and one that failed must not pass for one that
    /// worked.
    func refreshStorage(_ account: Account, force: Bool = false, then completion: ((Bool) -> Void)? = nil) {
        guard accounts.contains(where: { $0.id == account.id }) else { completion?(false); return }
        quotas.refresh(account, force: force, fetch: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.client(account).storageQuota()
        }, completion: completion)
    }
}
