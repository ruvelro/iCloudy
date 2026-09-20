import XCTest
@testable import iCloudy

@MainActor
final class AccountServicesTests: XCTestCase {
    private func account(_ id: String = "google:test") -> Account {
        Account(id: id, cloud: .google, name: "Test", email: "", clientID: "", clientSecret: nil)
    }

    func testReplacingClientInvalidatesOnlyThePreviousSession() {
        let registry = AccountClientRegistry()
        let original = CloudAPI(account: account())
        let other = CloudAPI(account: account("google:other"))
        registry.store(original)
        registry.store(other)
        registry.store(original)
        XCTAssertFalse(original.invalidated, "Storing the same client is not a reconnection")
        let replacement = CloudAPI(account: account())
        registry.store(replacement)
        XCTAssertTrue(original.invalidated)
        XCTAssertTrue(registry.cached(for: account().id) === replacement)
        XCTAssertFalse(other.invalidated)
        registry.remove(account().id)
        XCTAssertTrue(replacement.invalidated)
        XCTAssertNil(registry.cached(for: account().id))
        XCTAssertTrue(registry.cached(for: other.account.id) === other)
    }

    func testClearingDemoClientsClosesTheirProvidersAndPreservesRealAccounts() {
        let registry = AccountClientRegistry()
        let demo = CloudAPI(account: account("demo:google"))
        let real = CloudAPI(account: account())
        registry.store(demo)
        registry.store(real)
        registry.remove { $0.hasPrefix("demo:") }
        XCTAssertTrue(demo.invalidated)
        XCTAssertFalse(real.invalidated)
        XCTAssertNil(registry.cached(for: demo.account.id))
    }

    func testRemovedAccountCannotBeRestoredByALateQuotaResponse() async {
        let quotas = StorageQuotaController()
        let started = expectation(description: "Request started")
        let finished = expectation(description: "Cancelled request finished")
        var pending: CheckedContinuation<StorageQuota, Error>?
        quotas.refresh(account(), fetch: {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }, completion: { success in
            XCTAssertFalse(success)
            finished.fulfill()
        })
        await fulfillment(of: [started], timeout: 2)
        quotas.remove(account().id)
        pending?.resume(returning: StorageQuota(used: 10, total: 100))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertNil(quotas.states[account().id])
    }

    func testForcedQuotaRefreshWinsOverAnOlderRequestAndThenUsesTheCache() async {
        let quotas = StorageQuotaController()
        let started = expectation(description: "Old request started")
        let oldFinished = expectation(description: "Old request completed")
        let freshFinished = expectation(description: "Fresh request completed")
        var pending: CheckedContinuation<StorageQuota, Error>?
        quotas.refresh(account(), fetch: {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }, completion: { success in XCTAssertFalse(success); oldFinished.fulfill() })
        await fulfillment(of: [started], timeout: 2)
        quotas.refresh(account(), force: true, fetch: { StorageQuota(used: 20, total: 100) }, completion: { success in
            XCTAssertTrue(success)
            freshFinished.fulfill()
        })
        await fulfillment(of: [freshFinished], timeout: 2)
        pending?.resume(returning: StorageQuota(used: 10, total: 100))
        await fulfillment(of: [oldFinished], timeout: 2)
        guard case .available(let quota) = quotas.states[account().id] else { return XCTFail("Expected available quota") }
        XCTAssertEqual(quota.used, 20)
        var reused = false
        quotas.refresh(account(), fetch: { XCTFail("A fresh quota should be cached"); return StorageQuota(used: 0, total: 0) }, completion: { reused = $0 })
        XCTAssertTrue(reused)
    }
}
