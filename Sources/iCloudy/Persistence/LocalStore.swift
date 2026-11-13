import Foundation

enum LocalStore {
    /// Set by the test suite to a temporary folder per test, so nothing a test does reaches the real Application
    /// Support folder. The app never sets it.
    nonisolated(unsafe) static var directoryOverride: URL?
    static var directory: URL {
        directoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloudy", isDirectory: true)
    }
    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    /// Moves a store that could not be read next to itself, with a `.corrupt-<timestamp>` suffix, so starting over
    /// does not overwrite bytes a later version might still be able to read. Returns where it went.
    @discardableResult
    static func setAside(_ url: URL) throws -> URL {
        let backup = url.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try FileManager.default.moveItem(at: url, to: backup)
        return backup
    }
    /// Waits first for any write of this file the background writer still holds, so what was saved in this process is
    /// what is read back.
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        StoreWriter.shared.flush(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

/// A store's contents with the version of their layout, so a later version can tell an old file from a new one
/// instead of guessing from which fields are missing. Files written before the field existed are the bare contents
/// and read as version 1.
struct StoreEnvelope<Items: Codable & Sendable>: Codable, Sendable {
    static var currentVersion: Int { 1 }
    var schemaVersion: Int
    var items: Items

    init(_ items: Items, schemaVersion: Int = StoreEnvelope.currentVersion) {
        self.items = items; self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, items }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self), container.contains(.items) {
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            items = try container.decode(Items.self, forKey: .items)
        } else {
            schemaVersion = 1
            items = try Items(from: decoder)
        }
    }
}
