import XCTest
@testable import iCloudy

/// Managed offline copies: pins that survive a restart, refreshes that fetch only what changed, a budget that never
/// evicts a pinned copy, pins that follow renames and moves, and nothing left behind when an account goes.
@MainActor
final class OfflineTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }
    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offline-tests-" + UUID().uuidString)
        roots.append(root)
        return root
    }
    private func makeStore(_ root: URL) -> OfflineStore {
        let store = OfflineStore(root: root.appendingPathComponent("Offline"), indexURL: root.appendingPathComponent("offline.json"))
        store.budget = { nil }
        store.keepPreviews = { true }
        return store
    }
    private func fixture() throws -> (OfflineStore, OfflineRefresher, DemoStore, CloudAPI) {
        let root = temporaryRoot()
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud"))
        demo.latency = .zero
        let store = makeStore(root)
        let api = CloudAPI(account: .demo, demo: demo)
        let refresher = OfflineRefresher(store: store)
        refresher.client = { _ in api }
        return (store, refresher, demo, api)
    }
    private func entry(_ id: String, size: Int64, pinned: String? = nil, accessed: TimeInterval = 0, account: String = "a",
                       modified: Date? = nil, checksum: ContentHash? = nil) -> OfflineEntry {
        OfflineEntry(accountID: account, fileID: id, name: id, relativePath: "x/" + id, size: size, remoteModified: modified,
                     checksum: checksum, pinFolder: pinned, savedAt: Date(), lastAccess: Date(timeIntervalSince1970: accessed))
    }
    private func remote(_ id: String, size: Int64?, modified: Date? = nil, checksum: ContentHash? = nil, folder: Bool = false) -> CloudFile {
        CloudFile(id: id, name: id, mime: folder ? "application/vnd.google-apps.folder" : "text/plain", size: size,
                  modified: modified, webURL: nil, isFolder: folder, checksum: checksum)
    }
    private func pinned(_ result: OfflineStore.PinResult, file: StaticString = #filePath, line: UInt = #line) throws -> OfflinePin {
        guard case .pinned(let pin) = result else { XCTFail("Expected a new pin, got \(result)", file: file, line: line); throw CancellationError() }
        return pin
    }

    // MARK: - Pins

    func testAPinnedFileIsKeptReadOnlyAndSurvivesARestartAndUnpinningDeletesIt() async throws {
        let (store, refresher, demo, _) = try fixture()
        let id = try demo.add(name: "Informe.txt", parent: "root", content: Data("hola".utf8))
        let file = try XCTUnwrap(demo.file(id))
        let pin = try pinned(store.pin(file, accountID: Account.demo.id, parentID: "root"))
        XCTAssertEqual(store.pin(file, accountID: Account.demo.id, parentID: "root"), .alreadyPinned)
        XCTAssertEqual(store.status(for: file, accountID: Account.demo.id), .updating, "Pinned but not yet fetched")

        refresher.refresh(); await refresher.wait()
        let copy = try XCTUnwrap(store.localURL(for: file, accountID: Account.demo.id, acceptChanged: false))
        XCTAssertEqual(try Data(contentsOf: copy), Data("hola".utf8))
        XCTAssertTrue(copy.path.hasPrefix(store.directory(of: pin).path), "The copy lives in the pin's own folder")
        let permissions = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o444, "Managed copies are read-only")
        XCTAssertEqual(store.status(for: file, accountID: Account.demo.id), .available)

        store.flush()
        let reopened = makeStore(store.root.deletingLastPathComponent())
        XCTAssertEqual(reopened.pins.map(\.file.id), [id])
        XCTAssertEqual(reopened.status(for: file, accountID: Account.demo.id), .available)

        reopened.unpin(pin.folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path), "Unpinning deletes the copy, read-only or not")
        XCTAssertNil(reopened.status(for: file, accountID: Account.demo.id))
        let again = makeStore(store.root.deletingLastPathComponent())
        XCTAssertTrue(again.pins.isEmpty && again.entries.isEmpty)
    }

    func testAnUnreadableIndexIsKeptAsideAndReportedRatherThanOverwritten() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("offline.json")
        try Data("{ not json".utf8).write(to: index)
        let store = makeStore(root)
        XCTAssertTrue(store.pins.isEmpty)
        XCTAssertEqual(store.notices.count, 1)
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("offline.json.corrupt-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(kept[0])), Data("{ not json".utf8))
    }

    func testGoogleDocumentsAreRefusedBecauseThereAreNoBytesToKeep() throws {
        let store = makeStore(temporaryRoot())
        let document = CloudFile(id: "d", name: "Doc", mime: "application/vnd.google-apps.document", size: nil, modified: nil, webURL: nil, isFolder: false)
        guard case .refused = store.pin(document, accountID: "a", parentID: "root") else { return XCTFail("A Google document cannot be pinned") }
        XCTAssertTrue(store.pins.isEmpty)
    }

    // MARK: - Refresh decisions

    func testRefreshDecisionComparesOnlyWhatBothSidesCarry() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let md5 = ContentHash(algorithm: .md5, value: "aaaa")
        let kept = entry("f", size: 10, modified: date, checksum: md5)
        XCTAssertFalse(OfflinePolicy.needsDownload(kept, remote: remote("f", size: 10, modified: date, checksum: md5), localExists: true))
        XCTAssertTrue(OfflinePolicy.needsDownload(kept, remote: remote("f", size: 11, modified: date, checksum: md5), localExists: true), "Size changed")
        XCTAssertTrue(OfflinePolicy.needsDownload(kept, remote: remote("f", size: 10, modified: date.addingTimeInterval(60), checksum: md5), localExists: true), "Date changed")
        XCTAssertTrue(OfflinePolicy.needsDownload(kept, remote: remote("f", size: 10, modified: date, checksum: ContentHash(algorithm: .md5, value: "bbbb")), localExists: true), "Hash changed")
        XCTAssertFalse(OfflinePolicy.needsDownload(kept, remote: remote("f", size: 10, modified: date.addingTimeInterval(0.5), checksum: md5), localExists: true),
                       "A server rounding its dates is not a change")
        XCTAssertFalse(OfflinePolicy.needsDownload(kept, remote: remote("f", size: nil, modified: nil, checksum: nil), localExists: true),
                       "A field missing on one side is not evidence of a change")
        XCTAssertFalse(OfflinePolicy.needsDownload(kept, remote: remote("f", size: 10, modified: date, checksum: ContentHash(algorithm: .sha1, value: "cc")), localExists: true),
                       "Two different algorithms cannot be compared")
        XCTAssertTrue(OfflinePolicy.needsDownload(kept, remote: remote("f", size: 10, modified: date, checksum: md5), localExists: false), "The copy was deleted")
        XCTAssertTrue(OfflinePolicy.needsDownload(nil, remote: remote("f", size: 10), localExists: false), "Never fetched")
    }

    func testARefreshDownloadsAgainOnlyWhatChanged() async throws {
        let (store, refresher, demo, _) = try fixture()
        let id = try demo.add(name: "a.txt", parent: "root", content: Data("uno".utf8))
        _ = try pinned(store.pin(try XCTUnwrap(demo.file(id)), accountID: Account.demo.id, parentID: "root"))
        refresher.refresh(); await refresher.wait()
        let first = try XCTUnwrap(store.entries.values.first)

        refresher.refresh(); await refresher.wait()
        XCTAssertEqual(store.entries.values.first?.savedAt, first.savedAt, "An unchanged file is not fetched again")

        // The demo stamps a rename with a new date: the copy is fetched again and follows the new name.
        try await Task.sleep(for: .milliseconds(1100))
        try demo.rename(id, name: "b.txt")
        refresher.refresh(); await refresher.wait()
        let renamed = try XCTUnwrap(store.entries.values.first)
        XCTAssertNotEqual(renamed.savedAt, first.savedAt)
        XCTAssertEqual(renamed.name, "b.txt")
        XCTAssertTrue(renamed.relativePath.hasSuffix("/b.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(of: first).path), "The old name does not linger")
        XCTAssertEqual(store.entries.count, 1)
    }

    func testAPinnedFolderPicksUpNewChildrenAndDropsDeletedOnes() async throws {
        let (store, refresher, demo, _) = try fixture()
        let folder = try demo.add(name: "Fotos", parent: "root", folder: true)
        let first = try demo.add(name: "uno.jpg", parent: folder, content: Data(repeating: 1, count: 5))
        let sub = try demo.add(name: "Viaje", parent: folder, folder: true)
        _ = try demo.add(name: "dos.jpg", parent: sub, content: Data(repeating: 2, count: 7))
        let pin = try pinned(store.pin(try XCTUnwrap(demo.file(folder)), accountID: Account.demo.id, parentID: "root"))
        refresher.refresh(); await refresher.wait()
        XCTAssertEqual(store.entries(of: pin.folder).count, 2)
        XCTAssertEqual(store.usage(of: pin), 12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.location(of: pin).appendingPathComponent("Viaje/dos.jpg").path),
                      "The folder keeps its shape on disk")

        _ = try demo.add(name: "tres.jpg", parent: sub, content: Data(repeating: 3, count: 3))
        try demo.deletePermanently(first)
        refresher.refresh(scope: .pins([pin.folder])); await refresher.wait()
        XCTAssertEqual(Set(store.entries(of: pin.folder).map(\.name)), ["dos.jpg", "tres.jpg"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location(of: pin).appendingPathComponent("uno.jpg").path))
        XCTAssertNil(store.pin(folder: pin.folder)?.lastError)
    }

    func testAPinnedItemDeletedInTheCloudIsUnpinnedWithANotice() async throws {
        let (store, refresher, demo, _) = try fixture()
        let id = try demo.add(name: "a.txt", parent: "root", content: Data("x".utf8))
        let pin = try pinned(store.pin(try XCTUnwrap(demo.file(id)), accountID: Account.demo.id, parentID: "root"))
        refresher.refresh(); await refresher.wait()
        XCTAssertEqual(store.entries.count, 1)

        try demo.deletePermanently(id)
        refresher.refresh(); await refresher.wait()
        XCTAssertNil(store.pin(folder: pin.folder))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory(of: pin).path))
        XCTAssertEqual(store.notices.count, 1, "The user is told, not left wondering where the pin went")
    }

    func testDeletingFromICloudyUnpinsAtOnce() throws {
        let store = makeStore(temporaryRoot())
        let folder = remote("/docs", size: nil, folder: true)
        _ = try pinned(store.pin(remote("/docs/a.txt", size: 1), accountID: "a", parentID: "/docs"))
        _ = try pinned(store.pin(remote("/otros/b.txt", size: 1), accountID: "a", parentID: "/otros"))
        store.itemDeleted(folder, accountID: "a")
        XCTAssertEqual(store.pins.map(\.file.id), ["/otros/b.txt"])
        XCTAssertEqual(store.notices.count, 1)
    }

    func testRefreshingDoesNothingOffline() async throws {
        let (store, refresher, demo, _) = try fixture()
        let id = try demo.add(name: "a.txt", parent: "root", content: Data("x".utf8))
        _ = try pinned(store.pin(try XCTUnwrap(demo.file(id)), accountID: Account.demo.id, parentID: "root"))
        refresher.isOnline = { false }
        refresher.refresh(); await refresher.wait()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(refresher.isRunning)
    }

    // MARK: - Budget

    func testEvictionTakesTheLeastRecentlyUsedPreviewsAndNeverAPinnedCopy() {
        let entries = [entry("viejo", size: 40, accessed: 1), entry("nuevo", size: 40, accessed: 3),
                       entry("medio", size: 40, accessed: 2), entry("fijado", size: 50, pinned: "p", accessed: 0)]
        let plan = OfflinePolicy.plan(entries, budget: 150, incoming: 30)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.evict, ["a\u{1F}viejo", "a\u{1F}medio"], "Oldest access first, and only as many as needed")
        XCTAssertEqual(plan.pinnedBytes, 80)

        let noLimit = OfflinePolicy.plan(entries, budget: nil, incoming: 1_000_000)
        XCTAssertTrue(noLimit.fits && noLimit.evict.isEmpty)

        let tooBig = OfflinePolicy.plan(entries, budget: 70, incoming: 30)
        XCTAssertFalse(tooBig.fits, "Pinned copies alone would exceed the budget")
        XCTAssertTrue(tooBig.evict.isEmpty, "Previews are not thrown away for a copy that will not fit anyway")

        let preview = OfflinePolicy.plan(entries, budget: 100, incoming: 60, pinned: false)
        XCTAssertFalse(preview.fits, "A preview larger than what the pinned copies leave free is not kept")

        let replacing = OfflinePolicy.plan(entries, budget: 130, incoming: 60, replacing: "a\u{1F}fijado")
        XCTAssertTrue(replacing.fits, "The bytes of the copy being replaced do not count twice")
    }

    func testPinningOverTheBudgetIsRefusedAndLoweringItKeepsPinnedCopies() async throws {
        let (store, refresher, demo, _) = try fixture()
        let small = try demo.add(name: "small.txt", parent: "root", content: Data(repeating: 1, count: 40))
        let big = try demo.add(name: "big.txt", parent: "root", content: Data(repeating: 2, count: 80))
        store.budget = { 100 }
        _ = try pinned(store.pin(try XCTUnwrap(demo.file(small)), accountID: Account.demo.id, parentID: "root"))
        refresher.refresh(); await refresher.wait()
        guard case .refused(let reason) = store.pin(try XCTUnwrap(demo.file(big)), accountID: Account.demo.id, parentID: "root") else {
            return XCTFail("40 + 80 bytes do not fit in 100")
        }
        XCTAssertTrue(reason.contains("big.txt"))

        // A cached preview that fits now, and a budget lowered under the pinned copy afterwards.
        let source = store.root.deletingLastPathComponent().appendingPathComponent("preview.bin")
        try Data(repeating: 9, count: 30).write(to: source)
        store.cachePreview(remote("p", size: 30), accountID: Account.demo.id, from: source)
        for _ in 0..<200 where store.cachedBytes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.cachedBytes, 30)
        XCTAssertFalse(store.overBudget)

        store.budget = { 20 }
        store.enforceBudget()
        XCTAssertEqual(store.cachedBytes, 0, "The preview is evicted")
        XCTAssertEqual(store.pinnedBytes, 40, "The pinned copy is never evicted")
        XCTAssertTrue(store.overBudget, "And the user is warned instead")
    }

    func testAFolderThatOutgrowsTheBudgetStopsWithAnErrorInsteadOfEvictingPins() async throws {
        let (store, refresher, demo, _) = try fixture()
        let folder = try demo.add(name: "Grande", parent: "root", folder: true)
        _ = try demo.add(name: "a.bin", parent: folder, content: Data(repeating: 1, count: 60))
        _ = try demo.add(name: "b.bin", parent: folder, content: Data(repeating: 2, count: 60))
        store.budget = { 100 }
        let pin = try pinned(store.pin(try XCTUnwrap(demo.file(folder)), accountID: Account.demo.id, parentID: "root"))
        refresher.refresh(); await refresher.wait()
        XCTAssertEqual(store.entries(of: pin.folder).count, 1, "What fits is kept")
        XCTAssertNotNil(store.pin(folder: pin.folder)?.lastError)
        guard case .failed = store.status(for: try XCTUnwrap(demo.file(folder)), accountID: Account.demo.id) else { return XCTFail("The badge shows the error") }
        XCTAssertEqual(store.notices.count, 1)
    }

    // MARK: - Previews

    func testAKeptPreviewServesOfflineButCarriesNoBadge() async throws {
        let store = makeStore(temporaryRoot())
        let source = store.root.deletingLastPathComponent().appendingPathComponent("p.txt")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("vista".utf8).write(to: source)
        let date = Date(timeIntervalSince1970: 5_000)
        let file = remote("p", size: 5, modified: date)
        store.cachePreview(file, accountID: "a", from: source)
        for _ in 0..<200 where store.entries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let url = try XCTUnwrap(store.localURL(for: file, accountID: "a", acceptChanged: false))
        XCTAssertEqual(try Data(contentsOf: url), Data("vista".utf8))
        XCTAssertNil(store.status(for: file, accountID: "a"), "A cache may be evicted at any time, so it promises nothing")
        let newer = remote("p", size: 5, modified: date.addingTimeInterval(3600))
        XCTAssertNil(store.localURL(for: newer, accountID: "a", acceptChanged: false), "Online, a stale copy is not shown")
        XCTAssertNotNil(store.localURL(for: newer, accountID: "a", acceptChanged: true), "Offline, it is better than nothing")
    }

    func testThePreviewUsesTheOfflineCopyWithoutTheNetworkAndKeepsWhatItDownloads() async throws {
        let (store, refresher, demo, api) = try fixture()
        let id = try demo.add(name: "nota.txt", parent: "root", content: Data("sin red".utf8))
        let file = try XCTUnwrap(demo.file(id))
        _ = try pinned(store.pin(file, accountID: Account.demo.id, parentID: "root"))
        refresher.refresh(); await refresher.wait()

        let preview = PreviewModel(store: try PreviewStore(root: store.root.deletingLastPathComponent().appendingPathComponent("previews")))
        preview.availableCapacity = { 2_000_000_000 }
        preview.localSource = { file, account in store.localURL(for: file, accountID: account.id, acceptChanged: true) }
        var downloaded: [String] = []
        preview.didDownload = { file, _, _ in downloaded.append(file.id) }
        demo.offline = true
        preview.open(file: file, account: .demo, client: api)
        for _ in 0..<300 where preview.phase == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(preview.phase, .ready, "The network is down, and the copy on this Mac is enough")
        XCTAssertEqual(preview.text, "sin red")
        XCTAssertTrue(downloaded.isEmpty, "A local copy is not reported as a new download")
        preview.close()

        // Without a copy, the preview downloads as always and hands the result over to be kept.
        demo.offline = false
        let other = try demo.add(name: "otra.txt", parent: "root", content: Data("con red".utf8))
        preview.open(file: try XCTUnwrap(demo.file(other)), account: .demo, client: api)
        for _ in 0..<300 where preview.phase == .loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(preview.phase, .ready)
        XCTAssertEqual(downloaded, [other])
        preview.close()
    }

    // MARK: - Identity changes

    func testPinsFollowRenamesAndMovesOfPathAddressedItems() throws {
        let store = makeStore(temporaryRoot())
        let folderPin = try pinned(store.pin(remote("/docs", size: nil, folder: true), accountID: "a", parentID: "/"))
        let filePin = try pinned(store.pin(remote("/docs/notas/a.txt", size: 3), accountID: "a", parentID: "/docs/notas"))
        store.record(entry("/docs/x/y.txt", size: 2, pinned: folderPin.folder))
        store.record(entry("/docs/notas/a.txt", size: 3, pinned: filePin.folder))
        store.record(entry("/docs/x/y.txt", size: 2, pinned: folderPin.folder, account: "b"))

        let change = RemoteIdentityChange(oldID: "/docs", newID: "/papeles", name: "papeles", descendants: true)
        let affected = store.remap(change, accountID: "a")
        XCTAssertEqual(affected, [folderPin.folder, filePin.folder])
        XCTAssertEqual(store.pin(folder: folderPin.folder)?.file.id, "/papeles")
        XCTAssertEqual(store.pin(folder: folderPin.folder)?.file.name, "papeles")
        XCTAssertEqual(store.pin(folder: filePin.folder)?.file.id, "/papeles/notas/a.txt")
        XCTAssertEqual(store.pin(folder: filePin.folder)?.parentID, "/papeles/notas", "The parent moved along with it")
        XCTAssertNotNil(store.entries["a\u{1F}/papeles/x/y.txt"])
        XCTAssertNil(store.entries["a\u{1F}/docs/x/y.txt"])
        XCTAssertNotNil(store.entries["b\u{1F}/docs/x/y.txt"], "Another account is left alone")
        XCTAssertEqual(store.status(for: remote("/papeles/notas/a.txt", size: 3), accountID: "a"), .available)

        // A move of an item addressed by id keeps the id and changes the folder it is listed in.
        let moved = try pinned(store.pin(remote("id-1", size: 1), accountID: "a", parentID: "carpeta-1"))
        store.remap(RemoteIdentityChange(oldID: "id-1", newID: "id-1", name: "id-1", descendants: false), accountID: "a", newParentID: "carpeta-2")
        XCTAssertEqual(store.pin(folder: moved.folder)?.parentID, "carpeta-2")
        store.flush()
        XCTAssertEqual(makeStore(store.root.deletingLastPathComponent()).pin(folder: filePin.folder)?.file.id, "/papeles/notas/a.txt", "And it is saved")
    }

    // MARK: - Accounts

    func testRemovingAnAccountDeletesItsOfflineDataAndNothingElse() async throws {
        let (store, refresher, demo, _) = try fixture()
        let id = try demo.add(name: "a.txt", parent: "root", content: Data(repeating: 1, count: 9))
        _ = try pinned(store.pin(try XCTUnwrap(demo.file(id)), accountID: Account.demo.id, parentID: "root"))
        refresher.refresh(); await refresher.wait()
        let other = store.root.appendingPathComponent(OfflineStore.accountFolder("google:2") + "/cache/x/b.txt")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 2, count: 4).write(to: other)
        store.record(OfflineEntry(accountID: "google:2", fileID: "b", name: "b.txt", relativePath: OfflineStore.accountFolder("google:2") + "/cache/x/b.txt",
                                  size: 4, remoteModified: nil, checksum: nil, pinFolder: nil, savedAt: Date(), lastAccess: Date()))
        XCTAssertEqual(store.bytes(accountID: Account.demo.id), 9, "What the disconnect confirmation reports")

        store.removeAccount(Account.demo.id)
        XCTAssertTrue(store.pins.isEmpty)
        XCTAssertEqual(store.bytes(accountID: Account.demo.id), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent(OfflineStore.accountFolder(Account.demo.id)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(store.bytes(), 4)
        XCTAssertTrue(makeStore(store.root.deletingLastPathComponent()).pins.isEmpty, "The removal is saved at once")
    }

    func testAccountFoldersAreSafeAndDistinct() {
        let webdav = OfflineStore.accountFolder("webdav:http://nas:8080/dav#ana")
        XCTAssertFalse(webdav.contains("/") || webdav.contains(":"))
        XCTAssertNotEqual(webdav, OfflineStore.accountFolder("webdav:http_//nas_8080/dav#ana"), "Ids that sanitise alike still differ")
    }
}
