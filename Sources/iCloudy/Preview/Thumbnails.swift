import AppKit
import SwiftUI
import CryptoKit

/// Thumbnails for the grid: asked of the provider once, kept in memory for the run and on disk across runs.
///
/// A key names the account, the item and its modification date, so an edited file draws its new picture and the old
/// one is simply never asked for again. A provider that has no thumbnail for an item is not asked twice in a run.
/// Only a few requests go out at once: a folder of five hundred photos must not open five hundred connections.
@MainActor
final class ThumbnailStore {
    /// Points, as the grid draws them; the provider is asked for twice that, for Retina screens.
    static let side = 64
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloudy/Thumbnails", isDirectory: true)
    }

    var client: ((Account) throws -> CloudAPI)?
    private let memory = NSCache<NSString, NSImage>()
    private var missing: Set<String> = []
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private let limiter = AsyncLimiter(width: 4)

    init() { memory.countLimit = 600 }

    static func isEnabled() -> Bool { Prefs.bool(Prefs.thumbnails, default: true) }

    static func key(_ file: CloudFile, account: Account) -> String {
        let stamp = file.modified.map { String(Int($0.timeIntervalSince1970)) } ?? "-"
        let raw = [account.id, file.id, stamp, String(file.size ?? -1)].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func wants(_ file: CloudFile, account: Account?) -> Bool {
        guard let account, Self.isEnabled(), account.capabilities.thumbnails, ThumbnailRequest.isCandidate(file) else { return false }
        return !missing.contains(Self.key(file, account: account))
    }

    /// What is already in memory, so a cell scrolled back into view draws at once instead of after a hop.
    func cached(_ file: CloudFile, account: Account) -> NSImage? { memory.object(forKey: Self.key(file, account: account) as NSString) }

    func image(for file: CloudFile, account: Account) async -> NSImage? {
        guard wants(file, account: account) else { return nil }
        let key = Self.key(file, account: account)
        if let image = memory.object(forKey: key as NSString) { return image }
        if let running = inFlight[key] { return await running.value }
        let task = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            let url = Self.directory.appendingPathComponent(key + ".jpg")
            if let data = try? await blockingIO({ try Data(contentsOf: url) }), let image = NSImage(data: data) { return image }
            let data: Data? = await limiter.run {
                guard !Task.isCancelled, let api = try? self.client?(account) else { return nil }
                return try? await api.thumbnail(of: file, side: Self.side * 2)
            }
            guard let data, let image = NSImage(data: data) else { return nil }
            _ = try? await blockingIO {
                try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) } else if !Task.isCancelled { missing.insert(key) }
        return image
    }

    func clearMemory() { memory.removeAllObjects(); missing = [] }
}

/// Runs at most `width` operations at once; the rest wait their turn in order.
@MainActor
final class AsyncLimiter {
    private let width: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(width: Int) { self.width = width }

    func run<T>(_ operation: () async -> T) async -> T {
        if running >= width { await withCheckedContinuation { waiting.append($0) } } else { running += 1 }
        defer {
            if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
        }
        return await operation()
    }
}

/// A file's thumbnail where there is one, its icon otherwise and while the thumbnail is on its way.
struct ThumbnailIcon: View {
    let file: CloudFile
    let account: Account?
    let store: ThumbnailStore
    var size: CGFloat = 42
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: CGFloat(ThumbnailStore.side), maxHeight: CGFloat(ThumbnailStore.side))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                    .accessibilityHidden(true)
            } else {
                FileIcon(file: file, size: size)
            }
        }
        .frame(height: CGFloat(ThumbnailStore.side))
        .task(id: account.map { ThumbnailStore.key(file, account: $0) }) {
            guard let account, store.wants(file, account: account) else { image = nil; return }
            image = store.cached(file, account: account)
            if image == nil { image = await store.image(for: file, account: account) }
        }
    }
}
