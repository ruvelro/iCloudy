import Foundation
import AppKit
import SwiftUI

/// A remote file that also exists on this Mac, and where it came from.
struct LocalCopy: Codable, Equatable, Identifiable {
    enum Origin: String, Codable { case download, upload, preview, mirror }
    let accountID: String
    let fileID: String
    var name: String
    /// Absolute path of the local file, plus the bookmark needed to reach it again under the sandbox.
    var path: String
    var bookmark: Data?
    var size: Int64
    /// Remote modification date when the copy was made, so a stale copy can be told from a current one.
    var remoteModified: Date?
    var savedAt: Date
    var origin: Origin
    var id: String { LocalCopyIndex.key(accountID: accountID, fileID: fileID) }
    var url: URL { URL(fileURLWithPath: path) }
}

extension LocalCopy {
    enum CodingKeys: String, CodingKey { case accountID, fileID, name, path, bookmark, size, remoteModified, savedAt, origin }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try values.decode(String.self, forKey: .accountID)
        fileID = try values.decode(String.self, forKey: .fileID)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        path = try values.decode(String.self, forKey: .path)
        bookmark = try values.decodeIfPresent(Data.self, forKey: .bookmark)
        size = try values.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        remoteModified = try values.decodeIfPresent(Date.self, forKey: .remoteModified)
        savedAt = try values.decodeIfPresent(Date.self, forKey: .savedAt) ?? .distantPast
        origin = try values.decodeIfPresent(String.self, forKey: .origin).flatMap(Origin.init(rawValue:)) ?? .download
    }
}

/// Where a file lives right now, from iCloudy's point of view.
enum LocalCopyStatus: Equatable {
    /// Only in the provider. Nothing of it is on this Mac.
    case cloudOnly
    /// A copy exists on this Mac and the cloud has not changed since it was made.
    case downloaded(LocalCopy)
    /// A copy exists, but the provider reports a newer version: the local file is behind.
    case outdated(LocalCopy)

    var copy: LocalCopy? {
        switch self { case .cloudOnly: return nil; case .downloaded(let copy), .outdated(let copy): return copy }
    }
    var symbol: String {
        switch self {
        case .cloudOnly: return "icloud"
        case .downloaded: return "checkmark.circle.fill"
        case .outdated: return "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90.icloud.fill"
        }
    }
    var label: String {
        switch self {
        case .cloudOnly: return L("Solo en la nube")
        case .downloaded: return L("Descargado en este Mac")
        case .outdated: return L("Copia local desactualizada")
        }
    }
}

/// Remembers which remote files also exist on this Mac. Entries are created when iCloudy itself puts a file on disk
/// (a download, the source of an upload, or an explicitly saved preview), never by scanning the user's folders.
@MainActor
final class LocalCopyIndex: ObservableObject {
    @Published private(set) var copies: [String: LocalCopy] = [:]
    let storeURL: URL
    private var verifying = false
    /// Delay before a coalesced write reaches disk. Every file of a transfer records a copy, and writing the whole
    /// index for each one turned a ten-thousand-file upload into ten thousand growing writes on the main actor.
    var flushDelay: Duration = .seconds(2)
    private var dirty = false
    private var flushTask: Task<Void, Never>?

    init(storeURL: URL = LocalStore.directory.appendingPathComponent("local-copies.json")) {
        self.storeURL = storeURL
        copies = Snapshot.read(from: storeURL)
    }
    nonisolated static func key(accountID: String, fileID: String) -> String { accountID + "\u{1F}" + fileID }

    func status(for file: CloudFile, accountID: String) -> LocalCopyStatus {
        // Folders are never marked: iCloudy cannot tell whether everything inside is still present and current.
        guard !file.isFolder, let copy = copies[Self.key(accountID: accountID, fileID: file.id)] else { return .cloudOnly }
        if let remote = file.modified, let saved = copy.remoteModified, remote > saved.addingTimeInterval(1) { return .outdated(copy) }
        return .downloaded(copy)
    }
    func record(_ copy: LocalCopy) {
        copies[copy.id] = copy
        persist(coalesce: true)
    }
    func forget(accountID: String, fileID: String) {
        copies[Self.key(accountID: accountID, fileID: fileID)] = nil
        persist()
    }
    func removeAccount(_ accountID: String) {
        copies = copies.filter { $0.value.accountID != accountID }
        persist()
    }
    /// Forgets every local copy. The files themselves are left alone: this only clears what iCloudy remembers.
    func clear() {
        copies = [:]
        persist()
    }
    var totalBytes: Int64 { copies.values.reduce(0) { $0 + $1.size } }

    /// Drops entries whose file the user has since moved or deleted. Runs off the main actor and only for the files
    /// currently on screen, so browsing never pays for the whole index.
    func verify(_ files: [CloudFile], accountID: String) {
        guard !verifying else { return }
        let candidates = files.compactMap { copies[Self.key(accountID: accountID, fileID: $0.id)] }
        guard !candidates.isEmpty else { return }
        verifying = true
        Task { [weak self] in
            let paths = candidates.map(\.path)
            let missing = (try? await blockingIO { paths.filter { !FileManager.default.fileExists(atPath: $0) } }) ?? []
            guard let self else { return }
            self.verifying = false
            guard !missing.isEmpty else { return }
            let gone = Set(missing)
            self.copies = self.copies.filter { !gone.contains($0.value.path) }
            self.persist()
        }
    }
    /// Opens the Finder on the local file, resolving the bookmark first so the sandbox grants access.
    func reveal(_ copy: LocalCopy) -> Bool {
        var target = copy.url
        if let bookmark = copy.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                let scoped = resolved.startAccessingSecurityScopedResource()
                defer { if scoped { resolved.stopAccessingSecurityScopedResource() } }
                if FileManager.default.fileExists(atPath: target.path) { NSWorkspace.shared.activateFileViewerSelecting([target]); return true }
                target = resolved
            }
        }
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([target])
        return true
    }
    /// Writes now, or soon. A coalesced write is scheduled; anything the user would notice losing writes at once.
    private func persist(coalesce: Bool = false) {
        guard coalesce else { flushTask?.cancel(); flushTask = nil; dirty = false; write(); return }
        dirty = true
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            guard let delay = self?.flushDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flush()
        }
    }
    /// Writes whatever is pending. Called before the process exits, so a transfer that just finished is not forgotten.
    func flush() {
        guard dirty else { return }
        dirty = false
        write()
    }
    private func write() { Snapshot.write(copies, to: storeURL) }
}

/// What the index looks like on disk.
///
/// Bookmarks live in a table of their own because every file of a folder upload is given the same one, and a copy
/// per entry turned the index of a large transfer into tens of megabytes that were read and rewritten in full.
private struct Snapshot: Codable {
    var copies: [Entry] = []
    var bookmarks: [String: Data] = [:]

    struct Entry: Codable {
        var accountID: String, fileID: String, name: String, path: String
        var bookmarkID: String?
        /// Written by versions that kept a bookmark inside every entry. Still read, never written again.
        var bookmark: Data?
        var size: Int64, remoteModified: Date?, savedAt: Date, origin: String
    }
    private static func digest(_ data: Data) -> String {
        String(data.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 16)
    }
    static func read(from url: URL) -> [String: LocalCopy] {
        // A file written before bookmarks were shared is a plain array; both shapes are accepted.
        if let snapshot = try? LocalStore.read(Snapshot.self, from: url), !snapshot.copies.isEmpty {
            let restored = snapshot.copies.map { entry in
                LocalCopy(accountID: entry.accountID, fileID: entry.fileID, name: entry.name, path: entry.path,
                          bookmark: entry.bookmark ?? entry.bookmarkID.flatMap { snapshot.bookmarks[$0] },
                          size: entry.size, remoteModified: entry.remoteModified, savedAt: entry.savedAt,
                          origin: LocalCopy.Origin(rawValue: entry.origin) ?? .download)
            }
            return Dictionary(restored.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        }
        let legacy = (try? LocalStore.read([LocalCopy].self, from: url)) ?? []
        return Dictionary(legacy.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
    }
    static func write(_ copies: [String: LocalCopy], to url: URL) {
        var snapshot = Snapshot()
        for copy in copies.values {
            var id: String?
            if let bookmark = copy.bookmark {
                let key = digest(bookmark)
                snapshot.bookmarks[key] = bookmark
                id = key
            }
            snapshot.copies.append(Entry(accountID: copy.accountID, fileID: copy.fileID, name: copy.name,
                                         path: copy.path, bookmarkID: id, bookmark: nil, size: copy.size,
                                         remoteModified: copy.remoteModified, savedAt: copy.savedAt,
                                         origin: copy.origin.rawValue))
        }
        try? LocalStore.save(snapshot, to: url)
    }
}

/// The badge shown next to a file: filled when the file is on this Mac, hollow when it only lives in the cloud.
struct LocalCopyBadge: View {
    let status: LocalCopyStatus
    var size: CGFloat = 13
    var body: some View {
        Image(systemName: status.symbol)
            .font(.system(size: size))
            .foregroundStyle(tint)
            .help(help)
            .accessibilityLabel(status.label)
    }
    private var tint: Color {
        switch status {
        case .cloudOnly: return .secondary
        case .downloaded: return .green
        case .outdated: return .orange
        }
    }
    private var help: String {
        guard let copy = status.copy else { return L("Solo en la nube. iCloudy no ha descargado este archivo.") }
        switch status {
        case .outdated: return L("Copia local desactualizada en \(copy.path). La versión de la nube es más reciente.")
        default: return L("Descargado en este Mac: \(copy.path)")
        }
    }
}
