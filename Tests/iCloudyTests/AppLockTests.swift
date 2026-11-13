import XCTest
@testable import iCloudy

/// The lock is a privacy screen: what matters is when it closes, that only the owner opens it, and that nothing
/// walks around it.
@MainActor
final class AppLockTests: XCTestCase {
    private struct Refused: LocalizedError { var errorDescription: String? { "No coincide" } }
    private var asked: [String] = []

    private func model(enabled: Bool, idle: Int = 5, vaults: Bool = true, answer: @escaping () throws -> Void = {}) -> AppModel {
        let defaults = UserDefaults(suiteName: "lock-" + UUID().uuidString)!
        defaults.set(enabled, forKey: Prefs.appLock); defaults.set(idle, forKey: Prefs.appLockIdleMinutes); defaults.set(vaults, forKey: Prefs.appLockVaults)
        let model = AppModel()
        model.lockDefaults = defaults
        model.confirmOwner = { [weak self] reason in self?.asked.append(reason); try answer() }
        model.isLocked = model.lockPolicy.enabled
        return model
    }
    override func setUp() async throws { asked = [] }

    func testItOpensLockedOnlyWhenTheLockIsOn() {
        XCTAssertTrue(model(enabled: true).isLocked)
        XCTAssertFalse(model(enabled: false).isLocked)
        let off = model(enabled: false)
        off.lock()
        XCTAssertFalse(off.isLocked, "Locking does nothing while the setting is off")
    }

    func testOnlyAConfirmedOwnerUnlocks() async {
        let refused = model(enabled: true) { throw Refused() }
        await refused.unlock()
        XCTAssertTrue(refused.isLocked); XCTAssertEqual(refused.lockProblem, "No coincide")
        let cancelled = model(enabled: true) { throw CancellationError() }
        await cancelled.unlock()
        XCTAssertTrue(cancelled.isLocked); XCTAssertNil(cancelled.lockProblem, "Cancelling is not an error to show")
        let owner = model(enabled: true)
        await owner.unlock()
        XCTAssertFalse(owner.isLocked)
        XCTAssertEqual(asked.count, 3)
    }

    func testTheSettingItselfIsBehindTheCheck() async {
        let intruder = model(enabled: true) { throw Refused() }
        intruder.isLocked = false
        let refusal = await intruder.setLockEnabled(false)
        XCTAssertEqual(refusal, "No coincide")
        XCTAssertTrue(intruder.lockPolicy.enabled, "Whoever the lock is meant to stop cannot switch it off")
        let owner = model(enabled: false)
        let accepted = await owner.setLockEnabled(true)
        XCTAssertNil(accepted)
        XCTAssertTrue(owner.lockPolicy.enabled)
        XCTAssertFalse(owner.isLocked, "Turning it on does not lock the person out mid-sentence")
        owner.lock()
        XCTAssertTrue(owner.isLocked)
    }

    func testAnAbsenceLongerThanTheSettingLocksAndAShorterOneDoesNot() {
        let policy = AppLockPolicy(enabled: true, idleMinutes: 5)
        let now = Date()
        XCTAssertFalse(policy.locksAfterAbsence(since: now.addingTimeInterval(-299), now: now))
        XCTAssertTrue(policy.locksAfterAbsence(since: now.addingTimeInterval(-300), now: now))
        XCTAssertFalse(policy.locksAfterAbsence(since: nil, now: now))
        XCTAssertFalse(AppLockPolicy(enabled: true, idleMinutes: 0).locksAfterAbsence(since: .distantPast, now: now), "Zero is 'only at launch and with the screen'")
        XCTAssertFalse(AppLockPolicy(enabled: false, idleMinutes: 5).locksAfterAbsence(since: .distantPast, now: now))

        let model = model(enabled: true)
        model.isLocked = false
        model.resignedAt = Date().addingTimeInterval(-3600)
        model.appBecameActive()
        XCTAssertTrue(model.isLocked)
    }

    func testLockingTakesTheSearchAwayWithIt() {
        let model = model(enabled: true)
        model.isLocked = false
        model.ui.showGlobalSearch = true
        model.lock()
        XCTAssertTrue(model.isLocked); XCTAssertFalse(model.ui.showGlobalSearch)
    }

    func testARememberedVaultPassphraseWaitsForTheOwner() async {
        let unprotected = model(enabled: true, vaults: false) { throw Refused() }
        let free = await unprotected.ownerConfirmed(for: "abrir")
        XCTAssertTrue(free, "With the option off nothing is asked")
        XCTAssertTrue(asked.isEmpty)
        let off = model(enabled: false) { throw Refused() }
        let withoutLock = await off.ownerConfirmed(for: "abrir")
        XCTAssertTrue(withoutLock)
        let refused = model(enabled: true) { throw Refused() }
        let denied = await refused.ownerConfirmed(for: "abrir la bóveda")
        XCTAssertFalse(denied)
        XCTAssertEqual(asked, ["abrir la bóveda"])
        XCTAssertEqual(refused.error, "No coincide")
    }

    func testTheDefaultsAreFiveMinutesAndVaultsProtected() {
        let policy = AppLockPolicy.stored(in: UserDefaults(suiteName: "lock-" + UUID().uuidString)!)
        XCTAssertEqual(policy, AppLockPolicy(enabled: false, idleMinutes: 5, protectsVaults: true))
    }
}
