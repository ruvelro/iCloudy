import Foundation
import Security

enum Vault {
    private static let storage = KeychainStorage()
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

final class KeychainStorage: @unchecked Sendable {
    private let operations: KeychainOperations
    private let lock = NSLock()
    init(operations: KeychainOperations = KeychainOperations()) { self.operations = operations }
    private func descriptor(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.icloudy.credentials",
         kSecAttrAccount as String: key]
    }
    func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        lock.lock(); defer { lock.unlock() }
        let query = descriptor(key) as CFDictionary
        let attributes = [kSecValueData as String: data] as CFDictionary
        var status = operations.update(query, attributes)
        if status == errSecItemNotFound {
            var insert = descriptor(key)
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = operations.add(insert as CFDictionary, nil)
            // Another process may have created the item between update and add. Never delete it to retry.
            if status == errSecDuplicateItem { status = operations.update(query, attributes) }
        }
        guard status == errSecSuccess else {
            throw CloudError.message(L("No se pudo guardar en el Llavero (\(String(status))). Puede que haya que volver a conectar esa cuenta."))
        }
    }
    func read<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        lock.lock(); defer { lock.unlock() }
        var query = descriptor(key)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = operations.copy(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CloudError.message(L("No se pudo leer el Llavero (\(String(status))).")) }
        return try JSONDecoder().decode(type, from: data)
    }
    func delete(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        let result = operations.delete(descriptor(key) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw CloudError.message(L("No se pudo eliminar la credencial (\(String(result))).")) }
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
