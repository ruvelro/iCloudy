import AppKit
import SwiftUI
import Combine

extension AppModel {
    func loadAccounts() {
        loadingAccounts = true
        Task { [favoritesKey = "accounts"] in
            let stored: [Account]
            do { stored = try await Task.detached { try Vault.read([Account].self, key: favoritesKey) ?? [] }.value }
            catch {
                accountLoadError = error
                loadingAccounts = false
                self.error = L("No se pudieron leer las cuentas guardadas: \(error.localizedDescription)")
                return
            }
            loadingAccounts = false
            // The demo account is local and may already be in the list.
            accounts = stored + accounts.filter(\.isDemo)
            mirrors.start()
            remoteCopies.client = queue.client
            remoteCopies.didComplete = queue.didComplete
            remoteCopies.resume()
            if selectedAccountID == nil { selectedAccountID = accounts.first?.id }
            refreshSpotlightFavorites()
            if let waiting = pendingSpotlightItem { pendingSpotlightItem = nil; openSpotlightItem(identifier: waiting) }
            if account != nil { reload() }
            for account in accounts where account.id != selectedAccountID { refreshStorage(account) }
            o2StoreMigration = Task { await self.moveO2AccountsToOwnStores() }
            startKeepAlive()
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
            self?.expiredAccountIDs.insert(account.id)
            if let reason { self?.expiryReasons[account.id] = reason }
            self?.renewSilently(account)
        }
        sessions.store(client)
        return client
    }

    /// Keeps a bookmark the system had to renew. macOS marks one stale when the folder moves or the volume changes
    /// identity; the old one still resolves for a while and then stops, and the account looks broken out of nowhere.
    func storeRenewedBookmark(_ bookmark: Data, for account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }), accounts[index].bookmark != bookmark else { return }
        accounts[index].bookmark = bookmark
        try? Vault.save(accounts.filter { !$0.isDemo }, key: "accounts")
    }

    func isExpired(_ account: Account) -> Bool { expiredAccountIDs.contains(account.id) }

    /// Accounts that live off this one's credential: the shared drives and document libraries derived from it. They
    /// have no sign-in of their own, so whatever happens to the parent's session happens to them.
    static func dependents(of account: Account, in accounts: [Account]) -> [Account] {
        accounts.filter { $0.id != account.id && $0.credentialKey == account.id }
    }

    /// Reconnecting replaces the client of the account itself; the dependants keep a client that still believes the
    /// old session is gone, so they are reset too. Without this a shared drive stayed "expired" until the next launch.
    func adopt(_ account: Account, credential: Credential?) throws {
        if let credential { try Vault.save(credential, key: account.id) }
        var updated = accounts.filter { $0.id != account.id }; updated.append(account)
        try Vault.save(updated.filter { !$0.isDemo }, key: "accounts")
        accounts = updated
        for member in [account] + Self.dependents(of: account, in: accounts) {
            sessions.remove(member.id)
            expiredAccountIDs.remove(member.id); expiryReasons[member.id] = nil
        }
    }

    /// True while a new session is being fetched without involving the person, so the interface can say so rather
    /// than showing an alarming notice about an account that is about to fix itself.
    func isRenewing(_ account: Account) -> Bool { renewingAccountIDs.contains(account.id) }

    /// What the provider said when it dropped the session, if anything.
    func expiryReason(_ account: Account) -> String? { expiryReasons[account.id] }

    /// Connects a folder of this Mac or of a mounted volume. macOS does the SMB, AFP or NFS work; iCloudy only needs
    /// the user to point at the folder once, which is also what grants access under the sandbox.
    func connectVolume() async {
        guard !connecting else { return }
        connectionError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.prompt = L("Conectar")
        panel.message = L("Elige la carpeta o el volumen que quieres usar como nube. Para un recurso de red, conéctalo antes en el Finder con ⌘K.")
        guard await panel.begin() == .OK, let folder = panel.url else { return }
        connecting = true
        defer { connecting = false }
        do {
            let standardized = folder.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: [.volumeNameKey, .volumeIsRemovableKey])
            let account = Account(id: "volume:" + standardized.path, cloud: .volume,
                                  name: standardized.lastPathComponent,
                                  email: values?.volumeName.map { $0 + " · " + standardized.path } ?? standardized.path,
                                  clientID: "", clientSecret: nil, serverURL: standardized.path,
                                  bookmark: try TransferQueue.bookmark(folder))
            var updated = accounts.filter { $0.id != account.id }; updated.append(account)
            try Vault.save(updated.filter { !$0.isDemo }, key: "accounts")
            accounts = updated; sessions.remove(account.id)
            expiredAccountIDs.remove(account.id); expiryReasons[account.id] = nil
            select(account.id); showConnect = false
        } catch { connectionError = error.localizedDescription }
    }

    /// Adds the shared drive as its own account. It borrows the credential of the account it came from, so there is no
    /// second sign-in and no second copy of the tokens.
    func addScopedDrive(_ drive: RemoteDrive, from parent: Account) {
        let account = Account.scoped(to: drive.id, named: drive.name, from: parent)
        do {
            var updated = accounts.filter { $0.id != account.id }; updated.append(account)
            try Vault.save(updated.filter { !$0.isDemo }, key: "accounts")
            accounts = updated; sessions.remove(account.id)
            showAdvanced = false
            select(account.id); showConnect = false
        } catch { self.error = error.localizedDescription }
    }

    /// Tries to get a new session without involving the person. Only worth attempting for a provider whose sign-in
    /// outlives its session, which is O2: its server gives up after an hour of silence, so a Mac that spent the
    /// night off always wakes to a dead one. Failing here is normal and simply leaves the account marked expired.
    ///
    /// The renewal belongs to the account: disconnecting it, or signing in to it by hand, cancels the renewal and
    /// makes sure nothing it brings back is written.
    func renewSilently(_ account: Account) {
        // The account captured by a client may predate later changes to it; the list holds the current one.
        guard account.cloud.usesWebLogin, let current = accounts.first(where: { $0.id == account.id }),
              !o2Renewals.isRunning(current.id) else { return }
        let host = current.options["host"] ?? "cloud.o2online.es"
        let started = o2Renewals.start(current.id, attempt: { [weak self] () async -> O2SilentRenewal.Renewed? in
            // The account may be moving to a store of its own right now; renewing waits and then uses that one.
            await self?.o2StoreMigration?.value
            guard let self, !Task.isCancelled else { return nil }
            let store = accounts.first { $0.id == current.id }.flatMap(O2WebSession.storeID(of:))
            let stored = try? Vault.read(Credential.self, key: current.credentialKey)
            let sso = stored.map { O2API.restoreSSO($0.secret) } ?? []
            return await O2SilentRenewal(host: host, store: store).attempt(sso: sso)
        }, adopt: { [weak self] renewed, isCurrent in
            await self?.completeO2(host: host, validationKey: renewed.key, cookies: renewed.cookies,
                                   userAgent: renewed.userAgent, sso: renewed.sso, replacing: current,
                                   select: false, isCurrent: isCurrent)
        }, finished: { [weak self] in
            // Released only once the new session has been proved and written. Clearing it before that showed the
            // "expired" notice, with its button, over an account that was about to fix itself.
            self?.renewingAccountIDs.remove(current.id)
        })
        if started { renewingAccountIDs.insert(current.id) }
    }

    /// Stores the session O2 handed out on its own pages. iCloudy never saw the password or the code.
    ///
    /// `isCurrent` comes with a silent renewal and is asked right before anything is written: proving the session
    /// takes a request, and the account may have been disconnected, or signed in to by hand, while it was out.
    /// `webStore` is the WebKit store the sign-in window used, which becomes the account's own.
    func completeO2(host: String, validationKey: String, cookies: [HTTPCookie], userAgent: String?,
                    sso: [HTTPCookie] = [], replacing existing: Account? = nil,
                    select shouldSelect: Bool = true, isCurrent: (@MainActor () -> Bool)? = nil,
                    webStore: UUID? = nil) async {
        // A renewal runs in the background and must not touch the state of a connection sheet somebody may be using.
        if shouldSelect { connectionError = nil; connecting = true }
        defer { if shouldSelect { connecting = false } }
        do {
            guard !validationKey.isEmpty else {
                throw CloudError.message(L("El acceso no terminó de completarse. Vuelve a intentarlo desde la página de O2."))
            }
            let state = O2Session(host: host, validationKey: validationKey, cookies: cookies, userAgent: userAgent)
            let probe = URLSession(configuration: .ephemeral)
            defer { probe.invalidateAndCancel() }
            // Asking who this is proves the session works before anything is written to the Keychain.
            let identity = try await O2API.identity(host: host, state: state, session: probe)

            // Renewing keeps the account it was renewing. The identifier is built from whatever `/profile` answers,
            // and that answer is not always the same field: a renewal that got the phone number where the first
            // sign-in got the e-mail would have created a second account and left the first one expired for good.
            // Its options are read from the list as it is now, after the request: the copy the renewal started with
            // may predate the account's move to a store of its own, and writing that back would undo the move.
            let renewing = existing.map { old in accounts.first { $0.id == old.id } ?? old }
            let account = Account(id: renewing?.id ?? "o2:\(host):\(identity)", cloud: .o2, name: L("O2 Cloud"),
                                  email: renewing?.email ?? identity,
                                  clientID: "", clientSecret: nil, serverURL: "https://" + host, bookmark: nil,
                                  options: O2WebSession.options(keeping: renewing, host: host, store: webStore))
            // Signing in again to an account that already had a store leaves that one behind.
            let previousStore = accounts.first { $0.id == account.id }.flatMap(O2WebSession.storeID(of:))
            let credential = Credential(accessToken: "", refreshToken: "", expires: .distantFuture,
                                        secret: O2API.store(validationKey: validationKey, cookies: cookies,
                                                            userAgent: userAgent, sso: sso))
            // Nothing between this check and the writes below awaits, so it cannot go stale in between.
            if let isCurrent {
                guard isCurrent(), let existing, accounts.contains(where: { $0.id == existing.id }) else {
                    O2Log.record("renovación silenciosa · descartada: la cuenta se desconectó o se volvió a conectar")
                    return
                }
            }
            try Vault.save(credential, key: account.id)
            var updated = accounts.filter { $0.id != account.id }; updated.append(account)
            try Vault.save(updated.filter { !$0.isDemo }, key: "accounts")
            accounts = updated; sessions.remove(account.id)
            // Signing in by hand makes any renewal still out for this account stale: its result would overwrite the
            // session just written with whichever of the two finished last.
            if isCurrent == nil { o2Renewals.invalidate(account.id); renewingAccountIDs.remove(account.id) }
            if let previousStore, previousStore != O2WebSession.storeID(of: account) { discardO2Store(previousStore) }
            expiredAccountIDs.remove(account.id); expiryReasons[account.id] = nil
            lastKeepAlive[account.id] = Date()
            if shouldSelect { select(account.id); showConnect = false }
            else if selectedAccountID == account.id { reload() }
        } catch {
            // A silent renewal has nobody watching the connection sheet, so its failure goes to the diagnostic
            // instead of to a field on a form that is not on screen.
            if shouldSelect { connectionError = error.localizedDescription }
            else { O2Log.record("renovación silenciosa · no se pudo adoptar: \(error.localizedDescription)") }
        }
    }

    /// Opens the Finder's own "Connect to Server" flow. Mounting is not something a sandboxed app may do itself.
    func openFinderConnect() {
        guard let url = URL(string: "smb://") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Connects a server the user hosts: WebDAV or FTP. The password goes straight to the Keychain and never leaves
    /// this Mac except to that server.
    func connectServer(cloud: Cloud, server: String, username: String, password: String, flavor: String? = nil) async {
        guard !connecting else { return }
        connectionError = nil; connecting = true
        defer { connecting = false }
        do {
            let result: (Account, Credential)
            switch cloud {
            case .webdav: result = try await WebDAVAuthentication().signInWebDAV(server: server, username: username, password: password,
                                                                                    existing: accounts)
            case .ftp: result = try await FTPAuthentication().signInFTP(server: server, username: username, password: password)
            case .sftp: result = try await SFTPAuthentication().signInSFTP(server: server, username: username, password: password)
            case .mega: result = try await MegaAuthentication().signInMega(email: username, password: password)
            default: throw CloudError.message(L("\(cloud.title) no se conecta con usuario y contraseña."))
            }
            var (account, credential) = result
            if let flavor { account.options["flavor"] = flavor }
            try Vault.save(credential, key: account.id)
            var updated = accounts.filter { $0.id != account.id }; updated.append(account)
            try Vault.save(updated.filter { !$0.isDemo }, key: "accounts")
            accounts = updated; sessions.remove(account.id)
            expiredAccountIDs.remove(account.id); expiryReasons[account.id] = nil
            serverLogin = nil; reconnecting = nil
            select(account.id); showConnect = false
        } catch { connectionError = error.localizedDescription }
    }

    /// Starts the provider's sign-in for the same cloud; signing in with the same identity replaces the expired session.
    /// Reconnecting has to take the same road the account was created by. Sending a provider that never used OAuth
    /// down the OAuth path produced a message about configuration that had nothing to do with the problem.
    func reconnect(_ account: Account) async {
        connectionError = nil
        switch account.cloud {
        case .volume:
            await connectVolume()
        case let cloud where cloud.usesWebLogin || cloud.usesPasswordLogin:
            // These two sign in from inside the connection sheet, so it has to be on screen to present them. The
            // sheet is opened first and the form a moment later: presenting both in the same turn is a nesting
            // SwiftUI sometimes drops on the floor, leaving a connection sheet and no form.
            reconnecting = account
            showConnect = true
            let host = account.options["host"] ?? "cloud.o2online.es"
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                if cloud.usesWebLogin { self.o2Login = O2LoginRequest(host: host) } else { self.serverLogin = cloud }
            }
        default:
            await connect(cloud: account.cloud)
        }
        if let message = connectionError, !showConnect { error = message; connectionError = nil }
    }

    func enableDemo(select shouldSelect: Bool = true) {
        do {
            if demo == nil { demo = try DemoStore() }
            if !accounts.contains(where: \.isDemo) { accounts.append(.demo) }
            UserDefaults.standard.set(true, forKey: "demoEnabled")
            if shouldSelect { select(Account.demo.id); showConnect = false }
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
        }
    }

    func accountTitle(_ account: Account) -> String { appearance(for: account).title(for: account) }

    func saveAppearance(_ value: AccountAppearance, for account: Account) throws {
        guard let appearanceStore else { throw CloudError.message(L("No se puede guardar la personalización. Se conserva el archivo anterior; revisa el error de carga.")) }
        try appearanceStore.save(value, for: account.id); appearances = appearanceStore.values
    }

    func failNextDemoTransfer() { demo?.failNext = true }

    func connect(cloud: Cloud) async {
        guard !connecting else { return }
        connectionError = nil; connecting = true
        defer { connecting = false }
        do {
            let configuration = try OAuthConfiguration.load()
            let client = try configuration.client(for: cloud)
            let (account, credential) = try await oauth.signIn(cloud: cloud, clientID: client.id, clientSecret: client.secret)
            try adopt(account, credential: credential)
            select(account.id); showConnect = false
        } catch is CancellationError {} catch { connectionError = error.localizedDescription }
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
        // The sign-in at Telefónica outlives the session at O2 and lives in WebKit's own store, not in the Keychain.
        // Left behind, anybody opening "Conectar O2 Cloud" on this Mac walked straight in without typing anything.
        // An account with a store of its own takes the whole store; one still in the shared store clears its part.
        if account.cloud.usesWebLogin {
            let current = accounts.first { $0.id == account.id } ?? account
            if let store = O2WebSession.storeID(of: current) { discardO2Store(store) }
            else {
                let host = current.options["host"] ?? "cloud.o2online.es"
                Task { await O2WebSession.forget(host: host) }
            }
        }
        // A shared drive or a library borrows this account's credential: once that is gone they cannot work and
        // cannot be reconnected on their own, so they leave with it instead of lingering as "expired".
        let leaving = [account] + Self.dependents(of: account, in: accounts)
        do {
            if let shown = preview.model.account, leaving.contains(where: { $0.id == shown.id }) { preview.close() }
            let updated = accounts.filter { member in !leaving.contains { $0.id == member.id } }
            if account.isDemo { UserDefaults.standard.set(false, forKey: "demoEnabled") }
            else { try Vault.save(updated.filter { !$0.isDemo }, key: "accounts"); try Vault.delete(key: account.id) }
            for member in leaving { forget(member) }
            accounts = updated
            if let selected = selectedAccountID, leaving.contains(where: { $0.id == selected }) { select(accounts.first?.id) }
        } catch { self.error = error.localizedDescription }
    }

    // MARK: - O2's WebKit stores

    /// True when some account owns this WebKit store.
    func o2StoreInUse(_ store: UUID) -> Bool { accounts.contains { O2WebSession.storeID(of: $0) == store } }

    /// Removes a store once nobody owns it. Checked again at every step, because removing waits for any web view
    /// still holding the store, and an account may claim it in the meantime.
    func discardO2Store(_ store: UUID) {
        Task { [weak self] in
            await O2WebSession.discard(store, while: { self?.o2StoreInUse(store) == false })
        }
    }

    /// A sign-in window has closed. Its store stays only if an account came out of it.
    func o2LoginEnded(store: UUID) {
        guard !o2StoreInUse(store) else { return }
        discardO2Store(store)
    }

    /// Accounts signed in before each one had a WebKit store of its own all shared the default store, so two of them
    /// shared Telefónica's cookies. Each now gets its own, carrying over what it had, and the shared one is emptied
    /// of O2 only after the accounts are saved pointing at their new stores. If saving fails, the new stores are
    /// dropped and the accounts keep the shared store: renewing still works from there, and nobody is signed out.
    func moveO2AccountsToOwnStores() async {
        let waiting = accounts.filter { $0.cloud.usesWebLogin && O2WebSession.storeID(of: $0) == nil }
        guard !waiting.isEmpty else { return }
        let moved = await O2WebSession.moveToOwnStores(waiting.map { ($0.id, $0.options["host"] ?? "cloud.o2online.es") })
        // The list may have changed while the cookies were copied: an account disconnected in the meantime does not
        // come back, and its new store goes.
        var updated = accounts
        var claimed: Set<UUID> = []
        for index in updated.indices {
            guard let store = moved[updated[index].id], O2WebSession.storeID(of: updated[index]) == nil else { continue }
            updated[index].options[O2WebSession.storeOption] = store.uuidString
            claimed.insert(store)
        }
        do { try Vault.save(updated.filter { !$0.isDemo }, key: "accounts") }
        catch {
            O2Log.record("almacén web propio · no se pudo guardar, se sigue con el compartido: \(error.localizedDescription)")
            for store in moved.values { discardO2Store(store) }
            return
        }
        accounts = updated
        for store in Set(moved.values).subtracting(claimed) { discardO2Store(store) }
        // Nothing in the shared store belongs to anybody any more.
        for host in Set(waiting.map { $0.options["host"] ?? "cloud.o2online.es" }) {
            await O2WebSession.forget(host: host)
        }
    }

    /// Drops everything kept locally about an account: its client, quota, listings, mirrors, index and search rows.
    func forget(_ account: Account) {
        // A renewal still out would write the account straight back, credential and all.
        o2Renewals.invalidate(account.id); renewingAccountIDs.remove(account.id)
        cryptomator.lockAll(storedIn: account.id)
        remoteCopies.removeAccount(account.id)
        quotas.remove(account.id)
        sessions.remove(account.id)
        expiredAccountIDs.remove(account.id); expiryReasons[account.id] = nil
        listings.removeAll(accountID: account.id)
        mirrors.removeAll(accountID: account.id)
        spotlight.removeAccount(account.id)
        localCopies.removeAccount(account.id)
        globalSearch.removeAccount(account.id)
    }

    /// Keeps sessions alive for the providers that end them out of boredom. The cheapest call that proves the
    /// session still works is the one that reads how much space is left, and it has the side benefit of keeping that
    /// number current.
    func startKeepAlive() {
        keepAlive?.cancel()
        guard accounts.contains(where: { $0.cloud.needsKeepAlive }) else { return }
        // Waking from sleep is the dangerous moment: nothing ran while the Mac was asleep, and the session may
        // already be over. Touching it straight away turns a long silence into a short one.
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.touchIdleSessions(force: true, note: "el Mac ha despertado") }
                }
        }
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.keepAliveCheck * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                touchIdleSessions(force: false, note: nil)
            }
        }
    }

    /// Touches the sessions that have gone quiet for too long, deciding by the clock rather than by how long the
    /// sleep above actually lasted.
    func touchIdleSessions(force: Bool, note: String?) {
        if let note { O2Log.record("mantener viva · \(note)") }
        for account in accounts where account.cloud.needsKeepAlive && !isExpired(account) {
            let since = Date().timeIntervalSince(lastKeepAlive[account.id] ?? .distantPast)
            guard force || since >= Self.keepAliveInterval else { continue }
            guard touching.insert(account.id).inserted else { continue }
            refreshStorage(account, force: true) { [weak self] answered in
                self?.touching.remove(account.id)
                // Only a touch that got an answer counts. Marking the clock before asking meant that a failure right
                // after waking, while the Wi-Fi was still coming back, bought another quarter of an hour of silence
                // — which is exactly the gap this exists to prevent.
                guard answered else { O2Log.record("mantener viva · sin respuesta, se reintenta en la próxima ronda"); return }
                self?.lastKeepAlive[account.id] = Date()
            }
        }
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
