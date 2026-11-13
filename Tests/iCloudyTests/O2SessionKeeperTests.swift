import XCTest
import AppKit
@testable import iCloudy

/// O2's keep-alive and renewals, on a clock the test turns by hand and with no server, WebKit or Keychain.
@MainActor
final class O2SessionKeeperTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var touches: [(id: String, answer: (Bool) -> Void)] = []
    private var saved: [[Account]] = []
    private var credentials: [String: Credential] = [:]

    private func o2(_ id: String) -> Account {
        Account(id: id, cloud: .o2, name: "O2 Cloud", email: id, clientID: "", clientSecret: nil,
                serverURL: "https://cloud.o2online.es", bookmark: nil, options: ["host": "cloud.o2online.es"])
    }

    private func make(_ accounts: [Account], center: NotificationCenter = NotificationCenter()) -> (AccountDirectory, O2SessionKeeper) {
        let directory = AccountDirectory(keychain: AccountKeychain(
            saveAccounts: { [weak self] list in MainActor.assumeIsolated { self?.saved.append(list) } },
            saveCredential: { [weak self] credential, key in MainActor.assumeIsolated { self?.credentials[key] = credential } },
            deleteCredential: { _ in }))
        directory.accounts = accounts
        let keeper = O2SessionKeeper(directory: directory, wakeCenter: center)
        keeper.now = { [unowned self] in clock }
        keeper.touch = { [unowned self] account, answer in touches.append((account.id, answer)) }
        keeper.readCredential = { _ in nil }
        return (directory, keeper)
    }

    func testIdleSessionsAreTouchedByTheClockAndOnlyAnAnswerCounts() {
        let google = Account(id: "google:1", cloud: .google, name: "g", email: "g", clientID: "", clientSecret: nil)
        let (_, keeper) = make([o2("o2:a"), o2("o2:b"), google])

        keeper.touchIdleSessions(force: false, note: nil)
        XCTAssertEqual(touches.map(\.id), ["o2:a", "o2:b"], "Solo las cuentas que caducan por inactividad")
        touches[0].answer(true)
        touches[1].answer(false)
        touches.removeAll()

        clock += 10 * 60
        keeper.touchIdleSessions(force: false, note: nil)
        XCTAssertEqual(touches.map(\.id), ["o2:b"], "La que no contestó se vuelve a tocar; la otra aún no está ociosa")
        touches[0].answer(false)
        touches.removeAll()

        clock += 6 * 60
        keeper.touchIdleSessions(force: false, note: nil)
        XCTAssertEqual(touches.map(\.id), ["o2:a", "o2:b"], "Pasado el intervalo, también la que contestó")
    }

    func testASlowTouchIsNotRepeatedAndExpiredSessionsAreLeftAlone() {
        let (directory, keeper) = make([o2("o2:a"), o2("o2:b")])
        directory.markExpired("o2:b", reason: nil)
        keeper.touchIdleSessions(force: true, note: nil)
        keeper.touchIdleSessions(force: true, note: nil)
        XCTAssertEqual(touches.map(\.id), ["o2:a"], "Una petición en vuelo no se repite, y la caducada no se toca")
        touches[0].answer(true)
        keeper.touchIdleSessions(force: true, note: "forzado")
        XCTAssertEqual(touches.count, 2, "Forzar no mira el reloj")
    }

    func testTheLoopDecidesByTheClockAndWakingTouchesAtOnce() async {
        let center = NotificationCenter()
        let (_, keeper) = make([o2("o2:a")], center: center)
        var rounds = 0
        // Each "sleep" lasts five minutes on the clock and returns at once.
        keeper.sleep = { [unowned self] seconds in
            XCTAssertEqual(seconds, O2SessionKeeper.keepAliveCheck)
            rounds += 1
            clock += 5 * 60
            await Task.yield()
        }
        keeper.touch = { [unowned self] account, answer in touches.append((account.id, answer)); answer(true) }
        keeper.startKeepAlive()
        while rounds < 5 { await Task.yield() }
        keeper.stopKeepAlive()
        // Round 1 touches (never touched), rounds 2-4 are inside the quarter of an hour, round 5 is past it.
        XCTAssertGreaterThanOrEqual(touches.count, 2)
        XCTAssertEqual(touches.count, 2)

        let woke = expectation(description: "toque al despertar")
        keeper.touch = { account, _ in XCTAssertEqual(account.id, "o2:a"); woke.fulfill() }
        keeper.startKeepAlive()
        keeper.sleep = { _ in try? await Task.sleep(for: .seconds(60)) }
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await fulfillment(of: [woke], timeout: 5)
        keeper.stopKeepAlive()
    }

    func testSigningInByHandWritesTheAccountAndStartsItsClock() async throws {
        let (directory, keeper) = make([])
        keeper.identify = { _, _ in "persona@example.com" }
        let account = try await keeper.complete(host: "cloud.o2online.es", validationKey: "clave", cookies: [], userAgent: nil)
        XCTAssertEqual(account?.id, "o2:cloud.o2online.es:persona@example.com")
        XCTAssertEqual(directory.accounts.map(\.id), [account?.id])
        XCTAssertNotNil(credentials[account!.id])
        XCTAssertEqual(keeper.lastKeepAlive[account!.id], clock)

        do { _ = try await keeper.complete(host: "cloud.o2online.es", validationKey: "", cookies: [], userAgent: nil); XCTFail() }
        catch {}
    }

    func testARenewalKeepsTheAccountWhereItWasAndIsDroppedOnceStale() async throws {
        let first = o2("o2:cloud.o2online.es:600000000"), other = o2("o2:otra")
        let (directory, keeper) = make([first, other])
        directory.markExpired(first.id, reason: "sin actividad")
        // This time `/profile` answered with the e-mail; the account is still the one being renewed.
        keeper.identify = { _, _ in "persona@example.com" }
        let kept = try await keeper.complete(host: "cloud.o2online.es", validationKey: "nueva", cookies: [], userAgent: nil,
                                             replacing: first, isCurrent: { true })
        XCTAssertEqual(kept?.id, first.id)
        XCTAssertEqual(directory.accounts.map(\.id), [first.id, other.id])
        XCTAssertFalse(directory.isExpired(first.id))

        let writes = saved.count
        let stale = try await keeper.complete(host: "cloud.o2online.es", validationKey: "vieja", cookies: [], userAgent: nil,
                                              replacing: first, isCurrent: { false })
        XCTAssertNil(stale)
        XCTAssertEqual(saved.count, writes, "Una renovación que ya no vale no escribe nada")
    }

    func testASilentRenewalMarksTheAccountUntilItsSessionIsWritten() async {
        let account = o2("o2:a")
        let (directory, keeper) = make([account])
        directory.markExpired(account.id, reason: nil)
        keeper.identify = { _, _ in "a" }
        keeper.attemptRenewal = { _, _, _ in (key: "nueva", cookies: [], userAgent: nil, sso: []) }
        let renewed = expectation(description: "renovada")
        keeper.didRenew = { adopted in
            XCTAssertEqual(adopted.id, account.id)
            renewed.fulfill()
        }
        keeper.renewSilently(account)
        XCTAssertTrue(directory.isRenewing(account.id))
        keeper.renewSilently(account)
        await fulfillment(of: [renewed], timeout: 5)
        while directory.isRenewing(account.id) { await Task.yield() }
        XCTAssertFalse(directory.isExpired(account.id))
        XCTAssertEqual(credentials.count, 1, "Una sola renovación a la vez")

        // Disconnecting while one is out: nothing it brings back is written.
        directory.markExpired(account.id, reason: nil)
        keeper.attemptRenewal = { _, _, _ in try? await Task.sleep(for: .milliseconds(50)); return (key: "tarde", cookies: [], userAgent: nil, sso: []) }
        keeper.didRenew = { _ in XCTFail("No se adopta tras desconectar") }
        keeper.renewSilently(account)
        keeper.forgetRenewal(account.id)
        XCTAssertFalse(directory.isRenewing(account.id))
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(directory.isExpired(account.id))
    }
}
