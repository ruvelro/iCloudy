import AppKit

/// Everything O2 needs to stay signed in, kept out of the app model.
///
/// O2's server ends a session after about an hour of silence while the sign-in at Telefónica lives much longer, in
/// WebKit's own store. So the app touches idle sessions before the server gives up, touches them again the moment
/// the Mac wakes, renews one quietly from the stored sign-in when it ended anyway, and keeps each account's WebKit
/// store apart from the others. The clock, the sleep and the network calls are seams so all of it can be tested.
@MainActor
final class O2SessionKeeper {
    /// How long a session may go untouched. Measured against O2's server, which let 68 minutes pass and refused at
    /// 80, so a quarter of an hour leaves room for several missed rounds.
    static let keepAliveInterval: TimeInterval = 15 * 60
    /// How often that is checked. Shorter than the interval on purpose: deciding by the clock rather than by how long
    /// the sleep actually lasted is what survives a Mac that spends the night waking in the dark and going back to
    /// sleep. (An earlier note here claimed the system stretched a twenty-minute sleep to forty. It did not: the
    /// script that measured it was dropping one line in three. The shape of the fix stands; the reason given did not.)
    static let keepAliveCheck: TimeInterval = 4 * 60
    static let defaultHost = "cloud.o2online.es"

    private let directory: AccountDirectory
    /// The renewals themselves, so disconnecting or signing in again can cancel one and refuse what it brings back.
    let renewals = O2RenewalTasks()
    /// Moving accounts signed in before WebKit stores were kept apart into stores of their own. Renewals wait for it,
    /// so none runs in a store that is being emptied.
    private(set) var storeMigration: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// When each session last answered a touch.
    private(set) var lastKeepAlive: [String: Date] = [:]
    /// Accounts with a keep-alive request in flight, so a slow one is not asked again on the next round.
    private var touching: Set<String> = []

    // MARK: Seams

    var now: () -> Date = Date.init
    var sleep: (TimeInterval) async -> Void = { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    /// Proves a session alive with the cheapest call there is, and reports whether the provider answered. The app
    /// reads the quota, which has the side benefit of keeping that number current.
    var touch: ((Account, @escaping (Bool) -> Void) -> Void)?
    /// A renewal was adopted: what shows the account should load again.
    var didRenew: ((Account) -> Void)?
    /// Asks O2 who the session belongs to, which is also what proves it works.
    var identify: (String, O2Session) async throws -> String = { host, state in
        let probe = URLSession(configuration: .ephemeral)
        defer { probe.invalidateAndCancel() }
        return try await O2API.identity(host: host, state: state, session: probe)
    }
    /// Tries a new session from the stored sign-in, in the account's WebKit store.
    var attemptRenewal: (String, UUID?, [HTTPCookie]) async -> O2SilentRenewal.Renewed? = { host, store, sso in
        await O2SilentRenewal(host: host, store: store).attempt(sso: sso)
    }
    var readCredential: (String) -> Credential? = { try? Vault.read(Credential.self, key: $0) }
    private let wakeCenter: NotificationCenter

    init(directory: AccountDirectory, wakeCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.directory = directory
        self.wakeCenter = wakeCenter
    }

    // MARK: Keeping sessions alive

    /// Keeps sessions alive for the providers that end them out of boredom.
    func startKeepAlive() {
        keepAlive?.cancel()
        guard directory.accounts.contains(where: { $0.cloud.needsKeepAlive }) else { return }
        // Waking from sleep is the dangerous moment: nothing ran while the Mac was asleep, and the session may
        // already be over. Touching it straight away turns a long silence into a short one.
        if wakeObserver == nil {
            wakeObserver = wakeCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.touchIdleSessions(force: true, note: "el Mac ha despertado") }
            }
        }
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                guard let pause = self?.sleep else { return }
                await pause(Self.keepAliveCheck)
                guard let self, !Task.isCancelled else { return }
                touchIdleSessions(force: false, note: nil)
            }
        }
    }

    func stopKeepAlive() {
        keepAlive?.cancel(); keepAlive = nil
        if let wakeObserver { wakeCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
    }

    /// Touches the sessions that have gone quiet for too long, deciding by the clock rather than by how long the
    /// sleep between rounds actually lasted.
    func touchIdleSessions(force: Bool, note: String?) {
        if let note { O2Log.record("mantener viva · \(note)") }
        for account in directory.accounts where account.cloud.needsKeepAlive && !directory.isExpired(account.id) {
            let since = now().timeIntervalSince(lastKeepAlive[account.id] ?? .distantPast)
            guard force || since >= Self.keepAliveInterval else { continue }
            guard let touch, touching.insert(account.id).inserted else { continue }
            touch(account) { [weak self] answered in
                guard let self else { return }
                touching.remove(account.id)
                // Only a touch that got an answer counts. Marking the clock before asking meant that a failure right
                // after waking, while the Wi-Fi was still coming back, bought another quarter of an hour of silence
                // — which is exactly the gap this exists to prevent.
                guard answered else { O2Log.record("mantener viva · sin respuesta, se reintenta en la próxima ronda"); return }
                lastKeepAlive[account.id] = now()
            }
        }
    }

    // MARK: Renewing

    /// Tries to get a new session without involving the person. Only worth attempting for a provider whose sign-in
    /// outlives its session, which is O2: its server gives up after an hour of silence, so a Mac that spent the
    /// night off always wakes to a dead one. Failing here is normal and simply leaves the account marked expired.
    ///
    /// The renewal belongs to the account: disconnecting it, or signing in to it by hand, cancels the renewal and
    /// makes sure nothing it brings back is written.
    func renewSilently(_ account: Account) {
        // The account captured by a client may predate later changes to it; the list holds the current one.
        guard account.cloud.usesWebLogin, let current = directory.account(account.id),
              !renewals.isRunning(current.id) else { return }
        let host = current.options["host"] ?? Self.defaultHost
        let started = renewals.start(current.id, attempt: { [weak self] () async -> O2SilentRenewal.Renewed? in
            // The account may be moving to a store of its own right now; renewing waits and then uses that one.
            await self?.storeMigration?.value
            guard let self, !Task.isCancelled else { return nil }
            let store = directory.account(current.id).flatMap(O2WebSession.storeID(of:))
            let sso = readCredential(current.credentialKey).map { O2API.restoreSSO($0.secret) } ?? []
            return await attemptRenewal(host, store, sso)
        }, adopt: { [weak self] renewed, isCurrent in
            guard let self else { return }
            do {
                guard let adopted = try await complete(host: host, validationKey: renewed.key, cookies: renewed.cookies,
                                                       userAgent: renewed.userAgent, sso: renewed.sso, replacing: current,
                                                       isCurrent: isCurrent) else { return }
                didRenew?(adopted)
            } catch {
                // Nobody is watching a connection sheet for this, so the failure goes to the diagnostic.
                O2Log.record("renovación silenciosa · no se pudo adoptar: \(error.localizedDescription)")
            }
        }, finished: { [weak self] in
            // Released only once the new session has been proved and written. Clearing it before that showed the
            // "expired" notice, with its button, over an account that was about to fix itself.
            self?.directory.renewingAccountIDs.remove(current.id)
        })
        if started { directory.renewingAccountIDs.insert(current.id) }
    }

    /// Stores the session O2 handed out on its own pages. iCloudy never saw the password or the code. Returns the
    /// account written, or nil when a renewal found its account gone or signed in again by hand meanwhile.
    ///
    /// `isCurrent` comes with a silent renewal and is asked right before anything is written: proving the session
    /// takes a request, and the account may have been disconnected, or signed in to by hand, while it was out.
    /// `webStore` is the WebKit store the sign-in window used, which becomes the account's own.
    func complete(host: String, validationKey: String, cookies: [HTTPCookie], userAgent: String?,
                  sso: [HTTPCookie] = [], replacing existing: Account? = nil,
                  isCurrent: (@MainActor () -> Bool)? = nil, webStore: UUID? = nil) async throws -> Account? {
        guard !validationKey.isEmpty else {
            throw CloudError.message(L("El acceso no terminó de completarse. Vuelve a intentarlo desde la página de O2."))
        }
        let state = O2Session(host: host, validationKey: validationKey, cookies: cookies, userAgent: userAgent)
        // Asking who this is proves the session works before anything is written to the Keychain.
        let identity = try await identify(host, state)

        // Renewing keeps the account it was renewing. The identifier is built from whatever `/profile` answers, and
        // that answer is not always the same field: a renewal that got the phone number where the first sign-in got
        // the e-mail would have created a second account and left the first one expired for good. Its options are
        // read from the list as it is now, after the request: the copy the renewal started with may predate the
        // account's move to a store of its own, and writing that back would undo the move.
        let renewing = existing.map { old in directory.account(old.id) ?? old }
        let account = Account(id: renewing?.id ?? "o2:\(host):\(identity)", cloud: .o2, name: L("O2 Cloud"),
                              email: renewing?.email ?? identity,
                              clientID: "", clientSecret: nil, serverURL: "https://" + host, bookmark: nil,
                              options: O2WebSession.options(keeping: renewing, host: host, store: webStore))
        // Signing in again to an account that already had a store leaves that one behind.
        let previousStore = directory.account(account.id).flatMap(O2WebSession.storeID(of:))
        let credential = Credential(accessToken: "", refreshToken: "", expires: .distantFuture,
                                    secret: O2API.store(validationKey: validationKey, cookies: cookies,
                                                        userAgent: userAgent, sso: sso))
        // Nothing between this check and the writes below awaits, so it cannot go stale in between.
        if let isCurrent {
            guard isCurrent(), let existing, directory.account(existing.id) != nil else {
                O2Log.record("renovación silenciosa · descartada: la cuenta se desconectó o se volvió a conectar")
                return nil
            }
        }
        try directory.adopt(account, credential: credential)
        // Signing in by hand makes any renewal still out for this account stale: its result would overwrite the
        // session just written with whichever of the two finished last.
        if isCurrent == nil { forgetRenewal(account.id) }
        if let previousStore, previousStore != O2WebSession.storeID(of: account) { discardStore(previousStore) }
        lastKeepAlive[account.id] = now()
        return account
    }

    /// A renewal still out would write the account straight back, credential and all.
    func forgetRenewal(_ accountID: String) {
        renewals.invalidate(accountID); directory.renewingAccountIDs.remove(accountID)
    }

    // MARK: WebKit stores

    /// True when some account owns this WebKit store.
    func storeInUse(_ store: UUID) -> Bool { directory.accounts.contains { O2WebSession.storeID(of: $0) == store } }

    /// Removes a store once nobody owns it. Checked again at every step, because removing waits for any web view
    /// still holding the store, and an account may claim it in the meantime.
    func discardStore(_ store: UUID) {
        Task { [weak self] in
            await O2WebSession.discard(store, while: { self?.storeInUse(store) == false })
        }
    }

    /// A sign-in window has closed. Its store stays only if an account came out of it.
    func loginEnded(store: UUID) {
        guard !storeInUse(store) else { return }
        discardStore(store)
    }

    /// The sign-in at Telefónica outlives the session at O2 and lives in WebKit's own store, not in the Keychain.
    /// Left behind, anybody opening "Conectar O2 Cloud" on this Mac walked straight in without typing anything. An
    /// account with a store of its own takes the whole store; one still in the shared store clears its part.
    func signOut(_ account: Account) {
        let current = directory.account(account.id) ?? account
        if let store = O2WebSession.storeID(of: current) { discardStore(store) }
        else {
            let host = current.options["host"] ?? Self.defaultHost
            Task { await O2WebSession.forget(host: host) }
        }
    }

    /// Starts moving the accounts that still share the default store. Renewals wait for it.
    func migrateStores() {
        storeMigration = Task { await self.moveAccountsToOwnStores() }
    }

    /// Accounts signed in before each one had a WebKit store of its own all shared the default store, so two of them
    /// shared Telefónica's cookies. Each now gets its own, carrying over what it had, and the shared one is emptied
    /// of O2 only after the accounts are saved pointing at their new stores. If saving fails, the new stores are
    /// dropped and the accounts keep the shared store: renewing still works from there, and nobody is signed out.
    func moveAccountsToOwnStores() async {
        let waiting = directory.accounts.filter { $0.cloud.usesWebLogin && O2WebSession.storeID(of: $0) == nil }
        guard !waiting.isEmpty else { return }
        let moved = await O2WebSession.moveToOwnStores(waiting.map { ($0.id, $0.options["host"] ?? Self.defaultHost) })
        // The list may have changed while the cookies were copied: an account disconnected in the meantime does not
        // come back, and its new store goes.
        var updated = directory.accounts
        var claimed: Set<UUID> = []
        for index in updated.indices {
            guard let store = moved[updated[index].id], O2WebSession.storeID(of: updated[index]) == nil else { continue }
            updated[index].options[O2WebSession.storeOption] = store.uuidString
            claimed.insert(store)
        }
        do { try directory.replace(updated) }
        catch {
            O2Log.record("almacén web propio · no se pudo guardar, se sigue con el compartido: \(error.localizedDescription)")
            for store in moved.values { discardStore(store) }
            return
        }
        for store in Set(moved.values).subtracting(claimed) { discardStore(store) }
        // Nothing in the shared store belongs to anybody any more.
        for host in Set(waiting.map { $0.options["host"] ?? Self.defaultHost }) {
            await O2WebSession.forget(host: host)
        }
    }
}
