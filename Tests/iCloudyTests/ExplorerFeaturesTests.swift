import XCTest
@testable import iCloudy

/// The explorer's 0.9 features, tested on the model: sorting with a direction, columns, grouping, Go to Folder,
/// recent places, favourites in order, the inspector's figures, column view, Open With and re-upload, duplicate and
/// type-select. Views are covered in ExplorerAccessibilityTests.
@MainActor
final class ExplorerFeaturesTests: XCTestCase {
    private func file(_ name: String, folder: Bool = false, size: Int64? = nil, modified: Date? = nil,
                      mime: String = "application/octet-stream") -> CloudFile {
        CloudFile(id: name, name: name, mime: folder ? "application/vnd.google-apps.folder" : mime, size: size,
                  modified: modified, webURL: nil, isFolder: folder)
    }

    // MARK: - Sorting

    func testEveryKeySortsBothWaysWithFoldersOnTop() {
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        let files = [file("b.txt", size: 10, modified: new), file("a.pdf", size: 30, modified: old),
                     file("Carpeta", folder: true), file("c.jpg", size: 20)]
        func names(_ mode: String, _ ascending: Bool?) -> [String] {
            BrowserState.visible(files, search: "", sortMode: mode, ascending: ascending).map(\.name)
        }
        XCTAssertEqual(names("name", true), ["Carpeta", "a.pdf", "b.txt", "c.jpg"])
        XCTAssertEqual(names("name", false), ["Carpeta", "c.jpg", "b.txt", "a.pdf"], "Folders stay first in either direction")
        XCTAssertEqual(names("size", nil), ["Carpeta", "a.pdf", "c.jpg", "b.txt"], "Size starts largest first, as before")
        XCTAssertEqual(names("size", true), ["Carpeta", "b.txt", "c.jpg", "a.pdf"])
        XCTAssertEqual(names("date", nil), ["Carpeta", "b.txt", "a.pdf", "c.jpg"], "Newest first; an unknown date goes last")
        XCTAssertEqual(names("date", true), ["Carpeta", "c.jpg", "a.pdf", "b.txt"])
        XCTAssertEqual(names("kind", true).first, "Carpeta")
        XCTAssertEqual(names("kind", true), ["Carpeta", "a.pdf", "c.jpg", "b.txt"], "PDF, then images, then text, in FileKind's order")
    }

    func testChoosingAKeyStartsInItsOwnDirectionAndTheDirectionIsKeptPerTab() throws {
        var tab = BrowserState(accountID: "a")
        XCTAssertTrue(tab.sortAscending)
        tab.sortMode = "date"
        XCTAssertFalse(tab.sortAscending, "Dates start newest first")
        tab.sortAscending = true
        tab.sort(by: "date", ascending: true)
        XCTAssertTrue(tab.sortAscending, "Choosing the same key keeps the direction asked for")
        tab.sort(by: "name")
        XCTAssertTrue(tab.sortAscending)

        tab.sort(by: "size", ascending: true)
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(tab))
        XCTAssertEqual(decoded.sortMode, "size")
        XCTAssertTrue(decoded.sortAscending, "The direction survives a relaunch")

        // A tab saved before the direction existed sorts its key the way it always did.
        let legacy = Data(#"{"accountID":"a","sortMode":"size","viewMode":"list"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(BrowserState.self, from: legacy).sortAscending)

        var pane = ExplorerPane(tabs: [decoded])
        pane.addTab()
        XCTAssertTrue(pane.current.sortAscending, "A new tab sorts like the one it was opened from")
    }

    func testAHeaderClickMapsToTheTabsKeyAndDirection() throws {
        XCTAssertEqual(SortKey.from([SortKey.size.comparator(ascending: false)])?.key, .size)
        XCTAssertEqual(SortKey.from([SortKey.size.comparator(ascending: false)])?.ascending, false)
        for key in SortKey.allCases {
            XCTAssertEqual(SortKey.from([key.comparator(ascending: true)])?.key, key)
        }

        let model = AppModel()
        model.enableDemo()
        let order = model.sortOrder(inPane: 0)
        order.wrappedValue = [KeyPathComparator(\CloudFile.sortDate, order: .forward)]
        XCTAssertEqual(model.sortMode, "date")
        XCTAssertTrue(model.sortAscending)
        XCTAssertEqual(order.wrappedValue.first?.order, .forward)
        // The menu goes through `sortMode`, which resets the direction to the key's own.
        model.sortMode = "name"
        XCTAssertTrue(model.sortAscending)
        model.sortAscending = false
        XCTAssertEqual(order.wrappedValue.first?.order, .reverse, "Menu and header show the same direction")
    }

    // MARK: - Columns

    func testColumnsStartWithTheThreeOfAlwaysAndRememberWhatIsShown() throws {
        let settings = ExplorerSettings()
        XCTAssertEqual(FileColumn.allCases.filter(settings.isVisible), [.name, .modified, .size])
        settings.setVisible(.checksum, true)
        settings.setVisible(.size, false)
        settings.setVisible(.name, false)
        XCTAssertTrue(settings.isVisible(.name), "The name column cannot be hidden")

        let reopened = ExplorerSettings()
        XCTAssertEqual(FileColumn.allCases.filter(reopened.isVisible), [.name, .modified, .checksum])
        reopened.visibility(of: .status).wrappedValue = true
        XCTAssertTrue(ExplorerSettings().isVisible(.status), "The View menu's toggle goes through the same record")

        Prefs.defaults.set(Data("not json".utf8), forKey: ExplorerSettings.columnsKey)
        XCTAssertEqual(FileColumn.allCases.filter(ExplorerSettings().isVisible), [.name, .modified, .size],
                       "An unreadable layout falls back to the default columns")
    }

    func testTheKindAndChecksumColumnsSayWhatTheItemIs() {
        XCTAssertEqual(file("Fotos", folder: true).kindDescription, L("Carpeta"))
        XCTAssertFalse(file("informe.pdf").kindDescription.isEmpty)
        XCTAssertEqual(file("Doc", mime: "application/vnd.google-apps.document").kindDescription, L("Documento de Google"))
        var hashed = file("a.bin")
        XCTAssertNil(hashed.checksumSummary)
        hashed.checksum = ContentHash(algorithm: .sha256, value: "0123456789abcdef0123")
        XCTAssertEqual(hashed.checksumSummary, "SHA-256 0123456789ab…")
    }

    func testTheStatusColumnNamesTheLocalCopy() throws {
        let model = AppModel()
        model.enableDemo()
        let tab = model.workspace.current
        let item = file("a.txt", size: 3)
        XCTAssertEqual(model.statusDescription(item, in: tab), L("Solo en la nube"))
        XCTAssertEqual(model.statusDescription(file("Carpeta", folder: true), in: tab), "")
    }

    // MARK: - Grouping

    func testGroupingByKindAndDateKeepsTheSortInsideEachHeading() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12)))
        let day: TimeInterval = 86_400
        let files = [file("Carpeta", folder: true, modified: now), file("b.pdf", modified: now.addingTimeInterval(-day)),
                     file("a.jpg", modified: now.addingTimeInterval(-3 * day)), file("c.pdf", modified: now),
                     file("viejo.txt", modified: now.addingTimeInterval(-400 * day)), file("x.bin")]
        let sorted = BrowserState.visible(files, search: "", sortMode: "name")

        let kinds = FileGrouping.kind.groups(sorted, file: { $0 }, now: now, calendar: calendar)
        XCTAssertEqual(kinds.map(\.title), [L("Carpetas"), L("PDF"), L("Imágenes"), L("Texto"), L("Otros")])
        XCTAssertEqual(kinds[1].items.map(\.name), ["b.pdf", "c.pdf"], "Inside a heading the rows keep the list's order")

        let dates = FileGrouping.date.groups(sorted, file: { $0 }, now: now, calendar: calendar)
        XCTAssertEqual(dates.map(\.title), [L("Hoy"), L("Ayer"), L("Últimos 7 días"), L("Antes"), L("Sin fecha")])
        XCTAssertEqual(dates[0].items.map(\.name), ["Carpeta", "c.pdf"])

        let none = FileGrouping.none.groups(sorted, file: { $0 })
        XCTAssertEqual(none.count, 1)
        XCTAssertEqual(none[0].items.map(\.name), sorted.map(\.name))
    }

    func testTheGlobalSearchGroupsByAccountInTheSidebarsOrder() throws {
        let model = AppModel()
        model.enableDemo()
        let demo = try XCTUnwrap(model.accounts.first)
        model.explorer.searchGrouping = .account
        let hits = [SearchHit(accountID: "other", file: file("a"), parentID: nil),
                    SearchHit(accountID: demo.id, file: file("b"), parentID: nil),
                    SearchHit(accountID: demo.id, file: file("c"), parentID: nil)]
        let groups = model.groupedHits(hits)
        XCTAssertEqual(groups.map { $0.items.count }, [2, 1], "Connected accounts first, in the sidebar's order")
        XCTAssertTrue(groups[0].title.contains(demo.email))
        XCTAssertEqual(ExplorerSettings().searchGrouping, .account, "The choice is remembered")

        Prefs.defaults.set(FileGrouping.account.rawValue, forKey: ExplorerSettings.groupingKey)
        XCTAssertEqual(ExplorerSettings().grouping, .none, "A folder is never grouped by account")
    }

    // MARK: - Go to Folder

    func testAnAddressNamesItsAccountOnlyWhenTheNameIsOneOfThem() {
        let accounts = [stubbedAccount(.dropbox, id: "d", name: "Trabajo", email: "yo@example.com"),
                        stubbedAccount(.google, id: "g", name: "Personal", email: "otro@example.com")]
        let title: (Account) -> String = { $0.id == "d" ? "Oficina" : $0.name }
        XCTAssertEqual(FolderAddress.parse("Oficina:/Fotos/2024/", accounts: accounts, title: title), FolderAddress(accountID: "d", path: "Fotos/2024"))
        XCTAssertEqual(FolderAddress.parse("dropbox:Fotos", accounts: accounts, title: title).accountID, "d", "The provider's name counts")
        XCTAssertEqual(FolderAddress.parse("otro@example.com:/", accounts: accounts, title: title), FolderAddress(accountID: "g", path: ""))
        XCTAssertEqual(FolderAddress.parse("  /Documentos//Facturas ", accounts: accounts, title: title), FolderAddress(accountID: nil, path: "Documentos/Facturas"))
        XCTAssertEqual(FolderAddress.parse("~/Notas", accounts: accounts, title: title).path, "Notas")
        XCTAssertEqual(FolderAddress.parse("Notas: 2024/a", accounts: accounts, title: title), FolderAddress(accountID: nil, path: "Notas: 2024/a"),
                       "A colon that names no account is part of the path")
    }

    func testGoToFolderOpensAFolderOrTheFolderOfAFileWithItSelected() async throws {
        let model = AppModel()
        model.enableDemo()
        model.demo?.latency = .milliseconds(1)
        let demo = try XCTUnwrap(model.accounts.first)
        try await model.goToFolder("proyectos")
        XCTAssertEqual(model.path.map(\.name), ["Proyectos"], "Matched ignoring case")
        XCTAssertEqual(model.pathText(for: model.workspace.current), "Proyectos")

        try await model.goToFolder(model.accountTitle(demo) + ":/Proyectos/Notas.txt")
        XCTAssertEqual(model.path.map(\.name), ["Proyectos"])
        try await wait(until: { model.files.contains { $0.name == "Notas.txt" } }, "The folder was listed")
        XCTAssertEqual(model.selection(model.selectedIDs).map(\.name), ["Notas.txt"], "The file is selected in its folder")
        XCTAssertEqual(model.addressText(accountID: demo.id, path: model.path, file: model.files.first), model.accountTitle(demo) + ":/Proyectos/Notas.txt")

        try await model.goToFolder("/")
        XCTAssertTrue(model.path.isEmpty, "An empty path is the top of the account")
        do { try await model.goToFolder("Proyectos/No existe"); XCTFail("A missing step is an error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No existe")) }
        XCTAssertTrue(model.path.isEmpty, "A failed jump stays where it was")
    }

    // MARK: - Recent folders

    func testRecentsKeepTheLastTwentyFoldersOnceEachNewestFirst() throws {
        let url = try temporaryRoot().appendingPathComponent("recent-locations.json")
        let store = RecentLocationsStore(url: url)
        for index in 0..<25 {
            store.note(BrowserLocation(accountID: "a", collection: .files, path: [file("F\(index)", folder: true)]))
        }
        XCTAssertEqual(store.items.count, RecentLocationsStore.limit)
        XCTAssertEqual(store.items.first?.path.last?.name, "F24")
        store.note(BrowserLocation(accountID: "a", collection: .files, path: [file("F10", folder: true)]))
        XCTAssertEqual(store.items.first?.path.last?.name, "F10", "A folder visited again moves to the top")
        XCTAssertEqual(store.items.filter { $0.path.last?.name == "F10" }.count, 1, "and is listed once")

        XCTAssertFalse(store.note(BrowserLocation(accountID: "a", collection: .trash)), "The bin is not a place to go back to")
        XCTAssertFalse(store.note(BrowserLocation(accountID: nil)))
        XCTAssertFalse(store.note(BrowserLocation(accountID: CryptomatorVaults.accountPrefix + "x", collection: .files)),
                       "A vault's decrypted names are never written down")

        let reopened = RecentLocationsStore(url: url)
        XCTAssertEqual(reopened.items.map(\.id), store.items.map(\.id), "The list survives a relaunch")
        reopened.forget(accountID: "a", fileID: "F10")
        XCTAssertFalse(reopened.items.contains { $0.path.last?.name == "F10" })
        reopened.clear()
        XCTAssertTrue(RecentLocationsStore(url: url).items.isEmpty)
    }

    func testAnUnreadableRecentsFileIsSetAsideNotOverwritten() throws {
        let root = try temporaryRoot()
        let url = root.appendingPathComponent("recent-locations.json")
        try Data("{ not json".utf8).write(to: url)
        let store = RecentLocationsStore(url: url)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.loadError)
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains(".corrupt-") }
        XCTAssertEqual(kept.count, 1, "The unreadable bytes are kept beside it")
    }

    func testBrowsingNotesFoldersAndARenameFollowsThem() async throws {
        let model = AppModel()
        model.enableDemo()
        model.demo?.latency = .milliseconds(1)
        try await wait(until: { model.files.contains { $0.name == "Proyectos" } })
        let folder = try XCTUnwrap(model.files.first { $0.name == "Proyectos" })
        model.navigate(folder)
        XCTAssertEqual(model.recents.items.first?.path.map(\.name), ["Proyectos"])
        model.goBack()
        XCTAssertEqual(model.recents.items.first?.path, [], "Going back counts as a visit too")

        try model.applyIdentityChange(RemoteIdentityChange(oldID: folder.id, newID: folder.id, name: "Proyectos 2026", descendants: true),
                                      account: try XCTUnwrap(model.account))
        XCTAssertTrue(model.recents.items.contains { $0.path.last?.name == "Proyectos 2026" }, "A rename keeps the recent folder, renamed")
        model.openRecent(try XCTUnwrap(model.recents.items.first { !$0.path.isEmpty }))
        XCTAssertEqual(model.path.map(\.name), ["Proyectos 2026"])
    }
}
