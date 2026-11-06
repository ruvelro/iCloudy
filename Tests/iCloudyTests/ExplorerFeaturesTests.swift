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

    // MARK: - Favourites in order

    func testFavouritesCanBeReorderedAndKeepTheirOrder() throws {
        let url = try temporaryRoot().appendingPathComponent("favorites.json")
        let store = FavoritesStore(url: url)
        for name in ["A", "B", "C", "D"] { store.toggle(file(name, folder: true), accountID: "x", path: [], collection: .files) }
        store.move("x:D", to: "x:A")
        XCTAssertEqual(store.items.map(\.file.name), ["D", "A", "B", "C"], "Dragged onto the first, it becomes the first")
        store.move("x:D", by: 1)
        XCTAssertEqual(store.items.map(\.file.name), ["A", "D", "B", "C"])
        XCTAssertFalse(store.canMove("x:A", by: -1))
        store.move("x:A", by: -1)
        XCTAssertEqual(store.items.first?.file.name, "A", "Nothing moves past the edge")
        XCTAssertTrue(store.canMove("x:C", by: -1))
        XCTAssertEqual(FavoritesStore(url: url).items.map(\.file.name), ["A", "D", "B", "C"], "The order is saved")
    }

    // MARK: - Open With and re-upload

    /// The demo with its listing in place and an editor that opens nothing, writing its copies in a test folder.
    private func editingModel() async throws -> (AppModel, DemoStore) {
        let model = AppModel()
        model.enableDemo()
        let demo = try XCTUnwrap(model.demo)
        demo.latency = .milliseconds(1)
        model.editor.root = try temporaryRoot("icloudy-editing")
        model.editor.launch = { _, _ in nil }
        model.editor.settle = .milliseconds(20)
        try await wait(until: { model.files.contains { $0.name == "Bienvenido.txt" } }, "The demo folder was listed")
        return (model, demo)
    }

    private func upload(_ data: Data, named name: String, replacing model: AppModel) async throws {
        let source = try temporaryRoot().appendingPathComponent(name)
        try data.write(to: source)
        var job = Transfer(name: name, destination: "", accountID: Account.demo.id, direction: .upload, localURL: source,
                           bookmark: try TransferQueue.bookmark(source), parent: "root")
        job.batchChoice = .replace
        try model.queue.add([job])
        try await wait(until: { !model.queue.isWorking && model.queue.items.first { $0.id == job.id }?.finished == true })
    }

    func testASaveInTheOtherAppIsNoticedAndUploadedOverTheOriginal() async throws {
        let (model, demo) = try await editingModel()
        let original = try XCTUnwrap(model.files.first { $0.name == "Bienvenido.txt" })
        let opened = await model.openWith(original); let id = try XCTUnwrap(opened)
        let session = try XCTUnwrap(model.editor.session(id))
        XCTAssertEqual(session.state, .watching)
        XCTAssertTrue(session.localURL.path.hasPrefix(model.editor.root.path), "The copy is private to iCloudy")
        XCTAssertEqual(try Data(contentsOf: session.localURL), try Data(contentsOf: demo.directory.appendingPathComponent(original.id)))
        XCTAssertEqual(model.statusDescription(original, in: model.workspace.current), session.stateTitle)

        // Opening it again hands over the same copy.
        let again = await model.openWith(original)
        XCTAssertEqual(again, id)
        XCTAssertEqual(model.editor.sessions.count, 1)

        // A save that changes nothing is not a change.
        try Data(contentsOf: session.localURL).write(to: session.localURL, options: .atomic)
        try await assertStays({ model.editor.session(id)?.state == .watching }, for: .milliseconds(300))

        let edited = Data("Editado en otra aplicación.\n".utf8)
        try edited.write(to: session.localURL, options: .atomic)
        try await wait(until: { model.editor.session(id)?.state == .changed }, "The save was noticed")

        await model.uploadEdits(id)
        try await wait(until: { model.editor.session(id)?.state == .watching && !model.queue.isWorking }, "The change went up")
        let files = try demo.list("root")
        XCTAssertEqual(files.filter { $0.name.hasPrefix("Bienvenido") }.count, 1, "The original was replaced, not duplicated")
        let remote = try XCTUnwrap(files.first { $0.name == "Bienvenido.txt" })
        XCTAssertEqual(try Data(contentsOf: demo.directory.appendingPathComponent(remote.id)), edited)
        XCTAssertEqual(model.queue.items.last?.verifiedFiles, 1, "Through the queue, with its check")
        XCTAssertEqual(model.editor.session(id)?.file.size, Int64(edited.count), "The session knows the new version")

        model.stopEditing(id)
        XCTAssertNil(model.editor.session(id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.localURL.path), "Closing removes the private copy")
    }

    func testWhenTheCloudChangedMeanwhileBothVersionsAreKept() async throws {
        let (model, demo) = try await editingModel()
        let original = try XCTUnwrap(model.files.first { $0.name == "Bienvenido.txt" })
        let opened = await model.openWith(original); let id = try XCTUnwrap(opened)
        let local = try XCTUnwrap(model.editor.session(id)?.localURL)

        let theirs = Data("Cambiado por otra persona, más largo que antes.\n".utf8)
        try await upload(theirs, named: "Bienvenido.txt", replacing: model)

        let mine = Data("Mi versión.\n".utf8)
        try mine.write(to: local, options: .atomic)
        try await wait(until: { model.editor.session(id)?.state == .changed })
        await model.uploadEdits(id)
        try await wait(until: { model.editor.session(id)?.state == .watching && !model.queue.isWorking }, "The copy went up")

        let files = try demo.list("root")
        let kept = try XCTUnwrap(files.first { $0.name == "Bienvenido (mi versión).txt" }, "Mine is kept beside theirs: \(files.map(\.name))")
        let other = try XCTUnwrap(files.first { $0.name == "Bienvenido.txt" })
        XCTAssertEqual(try Data(contentsOf: demo.directory.appendingPathComponent(other.id)), theirs, "Their version is untouched")
        XCTAssertEqual(try Data(contentsOf: demo.directory.appendingPathComponent(kept.id)), mine)
        XCTAssertEqual(model.editor.session(id)?.keptAs, kept.name, "Later saves go to my copy")
        XCTAssertNotNil(model.info, "The person is told why there are two files now")

        // A second save replaces my copy, not theirs.
        let more = Data("Mi versión, segunda vez.\n".utf8)
        try more.write(to: local, options: .atomic)
        try await wait(until: { model.editor.session(id)?.state == .changed })
        await model.uploadEdits(id)
        try await wait(until: { model.editor.session(id)?.state == .watching && !model.queue.isWorking })
        let after = try demo.list("root")
        XCTAssertEqual(after.filter { $0.name.hasPrefix("Bienvenido") }.count, 2)
        XCTAssertEqual(try Data(contentsOf: demo.directory.appendingPathComponent(try XCTUnwrap(after.first { $0.name == kept.name }).id)), more)
        XCTAssertEqual(try Data(contentsOf: demo.directory.appendingPathComponent(other.id)), theirs)
    }

    func testWithTheSettingOnSavesGoUpByThemselves() async throws {
        let (model, demo) = try await editingModel()
        Prefs.defaults.set(true, forKey: ExternalEditor.autoUploadKey)
        let original = try XCTUnwrap(model.files.first { $0.name == "Bienvenido.txt" })
        let opened = await model.openWith(original); let id = try XCTUnwrap(opened)
        let local = try XCTUnwrap(model.editor.session(id)?.localURL)
        let edited = Data("Subido solo.\n".utf8)
        try edited.write(to: local, options: .atomic)
        try await wait(until: {
            (try? Data(contentsOf: demo.directory.appendingPathComponent(original.id))) == edited && model.editor.session(id)?.state == .watching
        }, "The save went up without asking")
    }

    func testFoldersAndGoogleDocumentsAreNotOpenedWithAnotherApp() throws {
        let model = AppModel()
        model.enableDemo()
        XCTAssertNotNil(model.openWithLimitation(file("Carpeta", folder: true)))
        XCTAssertNotNil(model.openWithLimitation(file("Doc", mime: "application/vnd.google-apps.document")))
        XCTAssertNil(model.openWithLimitation(file("a.txt")))
        XCTAssertEqual(ExternalEditor.keptName(for: "Informe.docx", existing: ["Informe.docx"]), "Informe (mi versión).docx")
        XCTAssertNotEqual(ExternalEditor.keptName(for: "Informe.docx", existing: ["Informe (mi versión).docx"]), "Informe (mi versión).docx")
        let a = file("a", size: 3, modified: Date(timeIntervalSince1970: 10))
        XCTAssertTrue(ExternalEditor.sameVersion(a, a))
        XCTAssertFalse(ExternalEditor.sameVersion(a, file("a", size: 4, modified: Date(timeIntervalSince1970: 10))))
    }

    // MARK: - Inspector

    func testTheInspectorDescribesOneItemOrAddsUpSeveral() async throws {
        let model = AppModel()
        model.enableDemo()
        model.demo?.latency = .milliseconds(1)
        try await wait(until: { model.files.count >= 3 })
        XCTAssertEqual(model.inspectorSummary().content, .nothing)

        let welcome = try XCTUnwrap(model.files.first { $0.name == "Bienvenido.txt" })
        model.selectedIDs = [welcome.id]
        guard case .single(let item) = model.inspectorSummary().content else { return XCTFail("One item selected") }
        XCTAssertEqual(item.file, welcome)
        XCTAssertEqual(item.address, model.accountTitle(try XCTUnwrap(model.account)) + ":/Bienvenido.txt")
        XCTAssertEqual(item.local, .cloudOnly)
        XCTAssertNil(item.editing)
        XCTAssertFalse(item.hasVersions, "The demo keeps no versions, so none are asked for")
        XCTAssertFalse(item.kind.isEmpty)

        model.selectedIDs = Set(model.files.map(\.id))
        guard case .many(let totals) = model.inspectorSummary().content else { return XCTFail("Several selected") }
        XCTAssertEqual(totals.count, model.files.count)
        XCTAssertEqual(totals.folders, 1)
        XCTAssertEqual(totals.bytes, model.files.reduce(0) { $0 + ($1.isFolder ? 0 : ($1.size ?? 0)) })
        XCTAssertEqual(totals.unknownSizes, 0)

        // What the filter hides is not counted, like every other action on the selection.
        model.search = "Bienvenido"
        guard case .single = model.inspectorSummary().content else { return XCTFail("Only the visible row counts") }
    }

    // MARK: - Column view

    func testColumnsFollowThePathAndTheKeyboardMovesBetweenThem() async throws {
        let model = AppModel()
        model.enableDemo()
        model.demo?.latency = .milliseconds(1)
        model.viewMode = "columns"
        try await wait(until: { model.files.contains { $0.name == "Proyectos" } })
        XCTAssertEqual(model.columns(inPane: 0).map(\.role), [.current], "At the top there is one column")

        // ↓ from nothing selected takes the first item: the folder, which is listed first.
        model.columnStep(1, pane: 0)
        let folder = try XCTUnwrap(model.selection(model.selectedIDs).first)
        XCTAssertEqual(folder.name, "Proyectos")
        var columns = model.columns(inPane: 0)
        XCTAssertEqual(columns.map(\.role), [.current, .preview], "A selected folder shows what it holds in the next column")
        XCTAssertNil(columns[1].files, "Asked for by the view")
        await model.loadColumn(columns[1], inPane: 0)
        columns = model.columns(inPane: 0)
        XCTAssertEqual(columns[1].files?.map(\.name), ["Notas.txt"])

        model.columnStep(1, pane: 0)
        XCTAssertNotEqual(model.selection(model.selectedIDs).first?.name, "Proyectos", "↓ moves within the open folder")
        model.columnStep(-1, pane: 0)
        model.columnStep(-5, pane: 0)
        XCTAssertEqual(model.selection(model.selectedIDs).first?.name, "Proyectos", "and stops at the top")

        // → goes in; the column above keeps the folder highlighted.
        XCTAssertEqual(model.columnRight(pane: 0)?.name, "Proyectos")
        XCTAssertEqual(model.path.map(\.name), ["Proyectos"])
        columns = model.columns(inPane: 0)
        XCTAssertEqual(columns.map(\.role), [.ancestor, .current])
        XCTAssertEqual(columns[0].highlighted, [folder.id])
        XCTAssertEqual(columns[0].files?.contains { $0.name == "Bienvenido.txt" }, true, "The column above is drawn from what was listed")
        try await wait(until: { model.files.contains { $0.name == "Notas.txt" } })

        // A click in the column above climbs there and selects what was clicked.
        let welcome = try XCTUnwrap(columns[0].files?.first { $0.name == "Bienvenido.txt" })
        model.columnClick(welcome, column: columns[0], pane: 0)
        XCTAssertTrue(model.path.isEmpty)
        XCTAssertEqual(model.selectedIDs, [welcome.id])

        // ← from inside a folder climbs and selects the folder that was open.
        model.columnClick(folder, column: model.columns(inPane: 0)[0], pane: 0)
        _ = model.columnRight(pane: 0)
        model.columnLeft(pane: 0)
        XCTAssertTrue(model.path.isEmpty)
        XCTAssertEqual(model.selectedIDs, [folder.id])

        // A click in the look ahead goes into that folder with the item selected.
        await model.loadColumn(model.columns(inPane: 0)[1], inPane: 0)
        let preview = model.columns(inPane: 0)[1]
        let notes = try XCTUnwrap(preview.files?.first)
        model.columnClick(notes, column: preview, pane: 0)
        XCTAssertEqual(model.path.map(\.name), ["Proyectos"])
        XCTAssertEqual(model.selectedIDs, [notes.id])
        XCTAssertFalse(model.columnRight(pane: 0) != nil, "→ on a file goes nowhere")
    }

    // MARK: - Preview

    func testThePictureViewerZoomsInStepsAndFitsTurnedPictures() {
        XCTAssertEqual(ZoomableImage.step(1, by: 1), 1.5)
        XCTAssertEqual(ZoomableImage.step(1, by: -1), 0.75)
        XCTAssertEqual(ZoomableImage.step(8, by: 1), 8, "No further than the last step")
        XCTAssertEqual(ZoomableImage.step(0.25, by: -1), 0.25)
        XCTAssertEqual(ZoomableImage.step(1.2, by: 1), 1.5, "From between steps, to the next one")
        let fitted = ZoomableImage.fitted(CGSize(width: 2000, height: 1000), turns: 0, in: CGSize(width: 500, height: 500))
        XCTAssertEqual(fitted, CGSize(width: 500, height: 250))
        let turned = ZoomableImage.fitted(CGSize(width: 2000, height: 1000), turns: 1, in: CGSize(width: 500, height: 500))
        XCTAssertEqual(turned, CGSize(width: 500, height: 250), "Turned upright it is 250 wide and 500 high")
        XCTAssertEqual(ZoomableImage.fitted(CGSize(width: 100, height: 50), turns: 0, in: CGSize(width: 500, height: 500)),
                       CGSize(width: 100, height: 50), "A small picture is not blown up")
    }

    func testAFileOpenedFromOutsideTheTabHasNowhereToUploadTo() async throws {
        let (model, _) = try await editingModel()
        let other = try XCTUnwrap(model.files.first { $0.name == "Bienvenido.txt" })
        model.search = "nada que coincida"
        let opened = await model.openWith(other, application: nil, in: model.account)
        let session = try XCTUnwrap(opened.flatMap { model.editor.session($0) })
        XCTAssertTrue(session.canUpload, "Filtered out of view is still in the tab's folder")
        model.stopEditing(session.id)
        model.go(to: BrowserLocation(accountID: model.account?.id, collection: .recent))
        let fromRecents = await model.openWith(other, application: nil, in: model.account)
        XCTAssertEqual(fromRecents.flatMap { model.editor.session($0) }?.canUpload, false, "Recientes is a list, not a folder")
    }

    // MARK: - Keyboard

    func testTypeSelectAddsUpLettersAndStartsAgainAfterAPause() {
        let files = BrowserState.visible([file("Álbum", folder: true), file("bienvenido.txt"), file("Bitácora.md"), file("zeta")],
                                         search: "", sortMode: "name")
        var typing = TypeSelect()
        let start = Date()
        XCTAssertEqual(TypeSelect.match(typing.type("b", at: start), in: files)?.name, "bienvenido.txt")
        XCTAssertEqual(TypeSelect.match(typing.type("it", at: start.addingTimeInterval(0.3)), in: files)?.name, "Bitácora.md",
                       "Letters typed together add up")
        XCTAssertEqual(TypeSelect.match(typing.type("a", at: start.addingTimeInterval(2)), in: files)?.name, "Álbum",
                       "A pause starts again, and accents do not matter")
        XCTAssertEqual(TypeSelect.match("c", in: files)?.name, "zeta", "Nothing starts with it: the next name after it")
        XCTAssertNil(TypeSelect.match("zz", in: files))
    }

    func testDuplicateCopiesInPlaceUnderANameOfItsOwn() async throws {
        let model = AppModel()
        model.enableDemo()
        let demo = try XCTUnwrap(model.demo)
        demo.latency = .milliseconds(1)
        try await wait(until: { model.files.contains { $0.name == "Bienvenido.txt" } })
        let welcome = try XCTUnwrap(model.files.first { $0.name == "Bienvenido.txt" })
        XCTAssertNil(model.duplicateLimitation([welcome]))
        await model.duplicate([welcome])
        await model.duplicate([welcome])
        XCTAssertNil(model.error)
        let names = try demo.list("root").map(\.name)
        XCTAssertTrue(names.contains("Bienvenido copia.txt"), "\(names)")
        XCTAssertTrue(names.contains("Bienvenido copia (2).txt"), "A second duplicate does not clash with the first")
        XCTAssertEqual(names.filter { $0 == "Bienvenido.txt" }.count, 1, "The original keeps its name")
        XCTAssertEqual(AppModel.duplicateName("Proyectos", isFolder: true, existing: []), "Proyectos copia")

        XCTAssertNotNil(model.duplicateLimitation([]))
        model.go(to: BrowserLocation(accountID: model.account?.id, collection: .recent))
        XCTAssertNotNil(model.duplicateLimitation([welcome]), "Recientes has no folder to duplicate into")
        XCTAssertNil(model.ejectable, "A cloud is not ejected")
    }
}
