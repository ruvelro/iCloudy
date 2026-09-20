import XCTest
import Security
@testable import iCloudy

final class KeychainSafetyTests: XCTestCase {
    private final class Backend {
        var values: [String: Data] = [:]
        var updateFailure: OSStatus?
        var addFailure: OSStatus?
        var raceOnAdd = false
        var deletes = 0
        var updates = 0
        var operations: KeychainOperations {
            KeychainOperations(update: { query, attributes in
                self.updates += 1
                if let failure = self.updateFailure { return failure }
                let key = (query as NSDictionary)[kSecAttrAccount] as! String
                guard self.values[key] != nil else { return errSecItemNotFound }
                self.values[key] = (attributes as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            }, add: { attributes, _ in
                if let failure = self.addFailure { return failure }
                let key = (attributes as NSDictionary)[kSecAttrAccount] as! String
                if self.raceOnAdd {
                    self.values[key] = Data("old".utf8)
                    return errSecDuplicateItem
                }
                self.values[key] = (attributes as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            }, copy: { query, result in
                let key = (query as NSDictionary)[kSecAttrAccount] as! String
                guard let value = self.values[key] else { return errSecItemNotFound }
                result?.pointee = value as CFData
                return errSecSuccess
            }, delete: { query in
                self.deletes += 1
                self.values[(query as NSDictionary)[kSecAttrAccount] as! String] = nil
                return errSecSuccess
            })
        }
    }
    func testDeniedUpdatePreservesCredentialAndAccountList() throws {
        let backend = Backend(), key = "credential"
        let storage = KeychainStorage(operations: backend.operations)
        try storage.save("old-refresh-token", key: key)
        try storage.save(["account"], key: "accounts")
        let before = backend.values
        backend.updateFailure = errSecAuthFailed
        XCTAssertThrowsError(try storage.save("new-refresh-token", key: key))
        XCTAssertThrowsError(try storage.save(["new-account"], key: "accounts"))
        XCTAssertEqual(backend.values, before)
        XCTAssertEqual(backend.deletes, 0)
        XCTAssertEqual(try storage.read(String.self, key: key), "old-refresh-token")
    }
    func testFailedInsertionNeverDeletesAnything() throws {
        let backend = Backend()
        let storage = KeychainStorage(operations: backend.operations)
        try storage.save("existing", key: "other")
        let before = backend.values
        backend.addFailure = errSecInteractionNotAllowed
        XCTAssertThrowsError(try storage.save("new", key: "missing"))
        XCTAssertEqual(backend.values, before)
        XCTAssertEqual(backend.deletes, 0)
    }
    func testDuplicateInsertionUpdatesWithoutDeleting() throws {
        let backend = Backend(); backend.raceOnAdd = true
        let storage = KeychainStorage(operations: backend.operations)
        try storage.save("latest", key: "shared")
        XCTAssertEqual(try storage.read(String.self, key: "shared"), "latest")
        XCTAssertEqual(backend.updates, 2)
        XCTAssertEqual(backend.deletes, 0)
        try storage.delete(key: "shared")
        XCTAssertNil(try storage.read(String.self, key: "shared"))
        XCTAssertEqual(backend.deletes, 1, "Only an explicit disconnect deletes the entry")
    }
}
