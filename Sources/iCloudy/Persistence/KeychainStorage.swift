import Foundation
import Security

enum Vault {
    private static let storage = KeychainStorage.shared
    static func save<T: Encodable>(_ value: T, key: String) throws { try storage.save(value, key: key) }
    static func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? { try storage.read(type, key: key) }
    static func delete(key: String) throws { try storage.delete(key: key) }
}

struct KeychainOperations {
    var update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate
    var add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemAdd
    var copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    var delete: (CFDictionary) -> OSStatus = SecItemDelete
}

/// Everything iCloudy keeps in the Keychain, as a single item.
///
/// Why one: the login keychain records, next to each item, the code-directory hash of the build that created it (its
/// partition list), and reading the secret from any other build needs the person's password, whatever certificate
/// signed it. Only a Team ID makes that list survive a rebuild. With an item per key, every new build asked once for
/// the account list and once more for each signed-in cloud; with one item it asks once. Attributes are outside that
/// check, which is what the revision below and the listing of the old items rely on.
///
/// The contents are read once per run and kept here. Another process (a second copy of the app, the Finder
/// extension) may write in between, so each operation first compares the revision stored in the item's attributes
/// and rereads only when it moved: that comparison asks for nothing, rereading the secret might.
final class KeychainStorage: @unchecked Sendable {
    /// The app's store. A test run gets one in memory: loading the real item from the test runner, a build the item
    /// does not know, would stop the run on a password dialog.
    static let shared = KeychainStorage(operations: Diagnostics.underTest ? MemoryKeychain().operations : KeychainOperations())

    static let service = "dev.icloudy.vault"
    static let account = "iCloudy"
    /// Where each key lived as an item of its own, up to 0.6. Read once more, moved into the single item, deleted.
    static let legacyService = "dev.icloudy.credentials"

    private struct Contents: Codable {
        var entries: [String: Data] = [:]
        /// Keys deleted while a copy of theirs may still exist under the old layout. A build that only read that copy
        /// once is not allowed to delete it, and the key must not come back from there.
        var retired: Set<String> = []
    }
    /// What the item held when this process last read or wrote it. `revision` is nil while there is no item.
    private struct Snapshot { var contents: Contents; var revision: Data? }

    private let operations: KeychainOperations
    private let lock = NSLock()
    private var snapshot: Snapshot?
    /// Keys still stored under the old layout, listed from their attributes once per run. Nil when the listing
    /// failed, and then each key is looked up on its own.
    private var legacyKeys: Set<String>?
    private var legacyListed = false

    init(operations: KeychainOperations = KeychainOperations()) { self.operations = operations }

    func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        lock.lock(); defer { lock.unlock() }
        var known = false
        try mutate { known = $0.entries[key] != nil; $0.entries[key] = data; $0.retired.remove(key) }
        // A key written before it was ever read leaves its old copy behind; the new value wins, as it always did.
        if !known { deleteLegacy(key) }
    }

    func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        lock.lock(); defer { lock.unlock() }
        let contents = try current().contents
        if let data = contents.entries[key] { return try JSONDecoder().decode(type, from: data) }
        guard !contents.retired.contains(key), let data = try legacyData(key) else { return nil }
        // The last time this key asks for permission. If the move cannot be written, the value still serves this run
        // and the move is retried on the next read; the old copy goes only once the new one is stored.
        let value = try JSONDecoder().decode(type, from: data)
        if (try? mutate({ $0.entries[key] = data })) != nil { deleteLegacy(key) }
        return value
    }

    func delete(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        let contents = try current().contents
        let legacy = legacyMayExist(key)
        if contents.entries[key] != nil || (legacy && !contents.retired.contains(key)) {
            try mutate { $0.entries[key] = nil; if legacy { $0.retired.insert(key) } }
        }
        if legacy { deleteLegacy(key) }
    }

    // MARK: - The item

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account]
    }

    /// The contents as they are stored now, reread only when the revision moved.
    private func current() throws -> Snapshot {
        if let snapshot, try storedRevision() == snapshot.revision { return snapshot }
        var request = query
        request[kSecReturnData as String] = true; request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = operations.copy(request as CFDictionary, &result)
        let loaded: Snapshot
        if status == errSecItemNotFound { loaded = Snapshot(contents: Contents(), revision: nil) }
        else {
            guard status == errSecSuccess, let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data
            else { throw CloudError.message(L("No se pudo leer el Llavero (\(String(status))).")) }
            loaded = Snapshot(contents: try JSONDecoder().decode(Contents.self, from: data), revision: item[kSecAttrGeneric as String] as? Data ?? Data())
        }
        snapshot = loaded
        return loaded
    }

    /// The revision in the item's attributes, nil when there is no item. Attributes are readable without permission.
    private func storedRevision() throws -> Data? {
        var request = query
        request[kSecReturnAttributes as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = operations.copy(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item = result as? [String: Any] else { throw CloudError.message(L("No se pudo leer el Llavero (\(String(status))).")) }
        return item[kSecAttrGeneric as String] as? Data ?? Data()
    }

    /// Applies a change to the stored contents. An item another process created in the meantime is reread and the
    /// change applied again on top, never overwritten blind; nothing is deleted to make room.
    private func mutate(_ change: (inout Contents) -> Void) throws {
        var status = errSecSuccess
        for _ in 0..<2 {
            var next = try current()
            change(&next.contents)
            if legacyListed, let legacyKeys { next.contents.retired.formIntersection(legacyKeys) }
            let data = try JSONEncoder().encode(next.contents)
            let revision = Data(UUID().uuidString.utf8)
            if next.revision != nil {
                status = operations.update(query as CFDictionary, [kSecValueData as String: data, kSecAttrGeneric as String: revision] as CFDictionary)
            } else { status = errSecItemNotFound }
            if status == errSecItemNotFound {
                var insert = query
                insert[kSecValueData as String] = data
                insert[kSecAttrGeneric as String] = revision
                insert[kSecAttrLabel as String] = "iCloudy"
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = operations.add(insert as CFDictionary, nil)
            }
            if status == errSecSuccess { snapshot = Snapshot(contents: next.contents, revision: revision); return }
            guard status == errSecDuplicateItem else { break }
            snapshot = nil
        }
        throw CloudError.message(L("No se pudo guardar en el Llavero (\(String(status))). Puede que haya que volver a conectar esa cuenta."))
    }

    // MARK: - The old layout

    private func legacyQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.legacyService, kSecAttrAccount as String: key]
    }

    private func legacyMayExist(_ key: String) -> Bool {
        if !legacyListed {
            legacyListed = true
            let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.legacyService,
                                          kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
            var result: CFTypeRef?
            let status = operations.copy(request as CFDictionary, &result)
            if status == errSecItemNotFound { legacyKeys = [] }
            else if status == errSecSuccess, let items = result as? [[String: Any]] {
                legacyKeys = Set(items.compactMap { $0[kSecAttrAccount as String] as? String })
            }
        }
        return legacyKeys?.contains(key) ?? true
    }

    private func legacyData(_ key: String) throws -> Data? {
        guard legacyMayExist(key) else { return nil }
        var request = legacyQuery(key)
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = operations.copy(request as CFDictionary, &result)
        if status == errSecItemNotFound { legacyKeys?.remove(key); return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CloudError.message(L("No se pudo leer el Llavero (\(String(status))).")) }
        return data
    }

    /// Best effort: a build that was allowed to read the old item only once is refused the deletion, without asking.
    /// The copy then stays, unused, because the key is in the single item or retired.
    private func deleteLegacy(_ key: String) {
        guard legacyMayExist(key) else { return }
        let status = operations.delete(legacyQuery(key) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { legacyKeys?.remove(key) }
    }
}

protocol CredentialStore {
    func read(_ key: String) throws -> Credential?
    func save(_ credential: Credential, key: String) throws
}

struct KeychainCredentialStore: CredentialStore {
    func read(_ key: String) throws -> Credential? { try Vault.read(Credential.self, key: key) }
    func save(_ credential: Credential, key: String) throws { try Vault.save(credential, key: key) }
}

/// A keychain kept in a dictionary, with the behaviour of `SecItem` that `KeychainStorage` relies on: items by service
/// and account, data and attributes returned on request, and duplicates refused.
final class MemoryKeychain: @unchecked Sendable {
    private(set) var items: [[String: Any]] = []
    private let lock = NSLock()

    private static let identity = [kSecAttrService as String, kSecAttrAccount as String]
    private func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
        Self.identity.allSatisfy { key in query[key].map { ($0 as? String) == (item[key] as? String) } ?? true }
    }
    func item(service: String, account: String) -> [String: Any]? {
        lock.withLock { items.first { matches($0, [kSecAttrService as String: service, kSecAttrAccount as String: account]) } }
    }
    func data(service: String, account: String) -> Data? { item(service: service, account: account)?[kSecValueData as String] as? Data }
    func insert(_ attributes: [String: Any]) { lock.withLock { items.append(attributes) } }

    var operations: KeychainOperations {
        KeychainOperations(update: { query, changes in
            let query = query as NSDictionary as! [String: Any], changes = changes as NSDictionary as! [String: Any]
            return self.lock.withLock {
                let indices = self.items.indices.filter { self.matches(self.items[$0], query) }
                guard !indices.isEmpty else { return errSecItemNotFound }
                for index in indices { self.items[index].merge(changes) { $1 } }
                return errSecSuccess
            }
        }, add: { attributes, _ in
            let attributes = attributes as NSDictionary as! [String: Any]
            return self.lock.withLock {
                guard !self.items.contains(where: { self.matches($0, attributes) }) else { return errSecDuplicateItem }
                self.items.append(attributes)
                return errSecSuccess
            }
        }, copy: { query, result in
            let query = query as NSDictionary as! [String: Any]
            return self.lock.withLock {
                let found = self.items.filter { self.matches($0, query) }
                guard !found.isEmpty else { return errSecItemNotFound }
                let wantsData = query[kSecReturnData as String] as? Bool == true
                let wantsAttributes = query[kSecReturnAttributes as String] as? Bool == true
                let shaped: [Any] = found.map { item in
                    if wantsAttributes {
                        return wantsData ? item : item.filter { $0.key != kSecValueData as String }
                    }
                    return item[kSecValueData as String] ?? Data()
                }
                let all = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)
                result?.pointee = (all ? shaped as NSArray : shaped[0] as AnyObject) as CFTypeRef
                return errSecSuccess
            }
        }, delete: { query in
            let query = query as NSDictionary as! [String: Any]
            return self.lock.withLock {
                let before = self.items.count
                self.items.removeAll { self.matches($0, query) }
                return self.items.count == before ? errSecItemNotFound : errSecSuccess
            }
        })
    }
}
