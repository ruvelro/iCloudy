import XCTest
import Security
@testable import iCloudy

final class KeychainSafetyTests: XCTestCase {
    /// A keychain in memory that can refuse operations and counts them, and that can stand for the real thing's
    /// partition list: a secret the current build may not read, while its attributes stay readable.
    private final class Backend {
        let memory = MemoryKeychain()
        var updateFailure: OSStatus?
        var addFailure: OSStatus?
        var deleteFailure: OSStatus?
        /// Accounts whose secret this build is refused, as the login keychain refuses an item another build created.
        var unreadable: Set<String> = []
        /// Another process creates the single item between this one's lookup and its insertion.
        var raceOnAdd: Data?
        var deletes = 0, updates = 0, secretReads = 0
        var operations: KeychainOperations {
            let base = memory.operations
            return KeychainOperations(update: { query, attributes in
                self.updates += 1
                return self.updateFailure ?? base.update(query, attributes)
            }, add: { attributes, result in
                if let failure = self.addFailure { return failure }
                if let other = self.raceOnAdd {
                    self.raceOnAdd = nil
                    var item = attributes as NSDictionary as! [String: Any]
                    item[kSecValueData as String] = other
                    item[kSecAttrGeneric as String] = Data("other".utf8)
                    self.memory.insert(item)
                    return errSecDuplicateItem
                }
                return base.add(attributes, result)
            }, copy: { query, result in
                let dictionary = query as NSDictionary as! [String: Any]
                if dictionary[kSecReturnData as String] as? Bool == true {
                    self.secretReads += 1
                    if let account = dictionary[kSecAttrAccount as String] as? String, self.unreadable.contains(account),
                       self.memory.item(service: dictionary[kSecAttrService as String] as! String, account: account) != nil {
                        return errSecAuthFailed
                    }
                }
                return base.copy(query, result)
            }, delete: { query in
                self.deletes += 1
                return self.deleteFailure ?? base.delete(query)
            })
        }
        /// An item as 0.6 and earlier wrote it: one per key.
        func legacy(_ key: String, _ value: some Encodable) throws {
            memory.insert([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: KeychainStorage.legacyService,
                           kSecAttrAccount as String: key, kSecValueData as String: try JSONEncoder().encode(value)])
        }
        func hasLegacy(_ key: String) -> Bool { memory.item(service: KeychainStorage.legacyService, account: key) != nil }
        var single: [String: Any]? { memory.item(service: KeychainStorage.service, account: KeychainStorage.account) }
    }

    func testEverythingLivesInOneItemReadOncePerRun() throws {
        let backend = Backend()
        let storage = KeychainStorage(operations: backend.operations)
        try storage.save(["a", "b"], key: "accounts")
        try storage.save("token-a", key: "a")
        try storage.save("token-b", key: "b")
        XCTAssertEqual(backend.memory.items.count, 1, "Una sola entrada, así que una sola petición de permiso por compilación")
        XCTAssertEqual(backend.single?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(backend.single?[kSecAttrLabel as String] as? String, "iCloudy")

        let fresh = KeychainStorage(operations: backend.operations)
        backend.secretReads = 0
        XCTAssertEqual(try fresh.read([String].self, key: "accounts"), ["a", "b"])
        XCTAssertEqual(try fresh.read(String.self, key: "a"), "token-a")
        XCTAssertEqual(try fresh.read(String.self, key: "b"), "token-b")
        XCTAssertNil(try fresh.read(String.self, key: "missing"))
        XCTAssertEqual(backend.secretReads, 1, "El secreto se lee una vez; lo demás sale de memoria")
    }

    func testAnotherProcessWritingIsSeenAndNotOverwritten() throws {
        let backend = Backend()
        let app = KeychainStorage(operations: backend.operations), other = KeychainStorage(operations: backend.operations)
        try app.save("old-a", key: "a")
        XCTAssertEqual(try other.read(String.self, key: "a"), "old-a")
        try other.save("rotated-b", key: "b")
        // The app's copy is stale; renewing from it would use a refresh token the provider has already retired.
        XCTAssertEqual(try app.read(String.self, key: "b"), "rotated-b")
        try other.save("rotated-a", key: "a")
        try app.save("new-c", key: "c")
        XCTAssertEqual(try other.read(String.self, key: "a"), "rotated-a", "Escribir una clave no devuelve las demás a su estado anterior")
        XCTAssertEqual(try other.read(String.self, key: "c"), "new-c")
    }

    func testOldItemsMoveIntoTheSingleOneOnFirstReadAndGo() throws {
        let backend = Backend()
        try backend.legacy("accounts", ["a"])
        try backend.legacy("a", "token-a")
        try backend.legacy("orphan", "token of an account deleted long ago")
        let storage = KeychainStorage(operations: backend.operations)
        XCTAssertEqual(try storage.read([String].self, key: "accounts"), ["a"])
        XCTAssertEqual(try storage.read(String.self, key: "a"), "token-a")
        XCTAssertFalse(backend.hasLegacy("accounts")); XCTAssertFalse(backend.hasLegacy("a"))
        XCTAssertTrue(backend.hasLegacy("orphan"), "Lo que nadie lee no se toca: leerlo pediría permiso")

        backend.secretReads = 0
        let next = KeychainStorage(operations: backend.operations)
        XCTAssertEqual(try next.read(String.self, key: "a"), "token-a")
        XCTAssertNil(try next.read(String.self, key: "never-existed"))
        XCTAssertEqual(backend.secretReads, 1, "Una clave que no existe en ninguna parte no lee nada más")
    }

    func testAnOldItemThisBuildMayNotDeleteNeverComesBack() throws {
        let backend = Backend()
        try backend.legacy("a", "old-token")
        backend.deleteFailure = errSecInvalidOwnerEdit
        let storage = KeychainStorage(operations: backend.operations)
        XCTAssertEqual(try storage.read(String.self, key: "a"), "old-token")
        XCTAssertTrue(backend.hasLegacy("a"))
        try storage.save("renewed", key: "a")
        XCTAssertEqual(try KeychainStorage(operations: backend.operations).read(String.self, key: "a"), "renewed", "La entrada única gana a la copia antigua")

        try storage.delete(key: "a")
        XCTAssertNil(try storage.read(String.self, key: "a"))
        XCTAssertNil(try KeychainStorage(operations: backend.operations).read(String.self, key: "a"), "Desconectar no resucita la copia antigua")

        backend.deleteFailure = nil
        try storage.save("reconnected", key: "a")
        XCTAssertEqual(try KeychainStorage(operations: backend.operations).read(String.self, key: "a"), "reconnected")
    }

    func testAnOldItemThatCannotBeReadIsReportedAndKept() throws {
        let backend = Backend()
        try backend.legacy("a", "token-a")
        backend.unreadable = ["a"]
        let storage = KeychainStorage(operations: backend.operations)
        XCTAssertThrowsError(try storage.read(String.self, key: "a"), "Denegar el permiso no es lo mismo que no tener cuenta")
        XCTAssertTrue(backend.hasLegacy("a"))
        backend.unreadable = []
        XCTAssertEqual(try storage.read(String.self, key: "a"), "token-a")
    }

    func testARefusedSingleItemIsAnErrorAndNothingIsWrittenOverIt() throws {
        let backend = Backend()
        try KeychainStorage(operations: backend.operations).save("token", key: "a")
        backend.unreadable = [KeychainStorage.account]
        let storage = KeychainStorage(operations: backend.operations)
        XCTAssertThrowsError(try storage.read(String.self, key: "a"))
        XCTAssertThrowsError(try storage.save("other", key: "b"), "Sin leer lo que hay, escribir lo borraría todo")
        backend.unreadable = []
        XCTAssertEqual(try storage.read(String.self, key: "a"), "token")
        XCTAssertNil(try storage.read(String.self, key: "b"))
    }

    func testDeniedUpdatePreservesCredentialAndAccountList() throws {
        let backend = Backend(), key = "credential"
        let storage = KeychainStorage(operations: backend.operations)
        try storage.save("old-refresh-token", key: key)
        try storage.save(["account"], key: "accounts")
        let before = backend.single?[kSecValueData as String] as? Data
        backend.updateFailure = errSecAuthFailed
        XCTAssertThrowsError(try storage.save("new-refresh-token", key: key))
        XCTAssertThrowsError(try storage.save(["new-account"], key: "accounts"))
        XCTAssertEqual(backend.single?[kSecValueData as String] as? Data, before)
        XCTAssertEqual(backend.deletes, 0)
        XCTAssertEqual(try storage.read(String.self, key: key), "old-refresh-token")
        XCTAssertEqual(try storage.read([String].self, key: "accounts"), ["account"])
    }

    func testFailedInsertionNeverDeletesAnything() throws {
        let backend = Backend()
        try backend.legacy("other", "existing")
        backend.addFailure = errSecInteractionNotAllowed
        let storage = KeychainStorage(operations: backend.operations)
        XCTAssertThrowsError(try storage.save("new", key: "missing"))
        XCTAssertNil(backend.single)
        XCTAssertEqual(backend.deletes, 0)
        XCTAssertTrue(backend.hasLegacy("other"))
    }

    func testDuplicateInsertionMergesWithoutDeleting() throws {
        let backend = Backend()
        struct Contents: Encodable { let entries: [String: Data]; let retired: [String] }
        backend.raceOnAdd = try JSONEncoder().encode(Contents(entries: ["theirs": try JSONEncoder().encode("from-the-other-process")], retired: []))
        let storage = KeychainStorage(operations: backend.operations)
        try storage.save("latest", key: "shared")
        XCTAssertEqual(try storage.read(String.self, key: "shared"), "latest")
        XCTAssertEqual(try storage.read(String.self, key: "theirs"), "from-the-other-process", "Lo que creó el otro proceso se conserva")
        XCTAssertEqual(backend.memory.items.count, 1)
        XCTAssertEqual(backend.deletes, 0)
        try storage.delete(key: "shared")
        XCTAssertNil(try storage.read(String.self, key: "shared"))
        XCTAssertEqual(try storage.read(String.self, key: "theirs"), "from-the-other-process")
    }
}
