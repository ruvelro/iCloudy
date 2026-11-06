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
}
