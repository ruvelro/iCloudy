import XCTest
@testable import iCloudy

/// The App Intents' path resolution, the tree-walking search and the inventory sources the comparison and the
/// duplicate finder stand on.
@MainActor
final class ShortcutsAndSearchTests: XCTestCase {
    // MARK: - FileShortcuts: paths as a person says them

    private func demoModel() throws -> (AppModel, DemoStore) {
        let model = AppModel()
        model.enableDemo()
        let demo = try XCTUnwrap(model.demo)
        demo.latency = .milliseconds(1)
        return (model, demo)
    }

    func testAPathIsResolvedFolderByFolderIgnoringCase() async throws {
        let (model, demo) = try demoModel()
        let projects = try XCTUnwrap(demo.list("root").first { $0.name == "Proyectos" })
        let place = try await model.resolve(path: " proyectos / NOTAS.txt ", in: .demo)
        XCTAssertEqual(place.file?.name, "Notas.txt")
        XCTAssertEqual(place.folderID, projects.id, "A file resolves to the folder that holds it")
        XCTAssertEqual(place.trail.map(\.name), ["Proyectos"])
    }

    func testTheEmptyPathIsTheTopAndAFolderIsItsOwnPlace() async throws {
        let (model, _) = try demoModel()
        let top = try await model.resolve(path: "", in: .demo)
        XCTAssertNil(top.file)
        let rootID = try await model.client(.demo).rootID()
        XCTAssertEqual(top.folderID, rootID)
        XCTAssertTrue(top.trail.isEmpty)

        let folder = try await model.resolve(path: "Proyectos/", in: .demo)
        XCTAssertEqual(folder.file?.name, "Proyectos")
        XCTAssertEqual(folder.folderID, folder.file?.id)
        XCTAssertEqual(folder.trail.map(\.name), ["Proyectos"], "A destination folder labels itself")
    }

    func testAnExactNameWinsOverOneThatOnlyMatchesIgnoringCase() async throws {
        let (model, demo) = try demoModel()
        let exact = try demo.add(name: "notas.TXT", parent: "root", content: Data("x".utf8))
        _ = try demo.add(name: "NOTAS.txt", parent: "root", content: Data("y".utf8))
        let place = try await model.resolve(path: "notas.TXT", in: .demo)
        XCTAssertEqual(place.file?.id, exact)
    }

    func testAMissingStepAndAFileUsedAsAFolderAreExplained() async throws {
        let (model, _) = try demoModel()
        do { _ = try await model.resolve(path: "Proyectos/Nada.txt", in: .demo); XCTFail("Nothing is called that") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Nada.txt"), error.localizedDescription) }
        do { _ = try await model.resolve(path: "Bienvenido.txt/dentro", in: .demo); XCTFail("A file has no inside") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Bienvenido.txt"), error.localizedDescription) }
    }

    func testAnAccountTheShortcutNamesMustStillBeConnected() throws {
        let (model, _) = try demoModel()
        XCTAssertEqual(try model.connectedAccount(AccountEntity(.demo, model: model)).id, Account.demo.id)
        let gone = AccountEntity(stubbedAccount(.dropbox, id: "dropbox:gone"), model: model)
        XCTAssertThrowsError(try model.connectedAccount(gone))
    }

    // MARK: - TreeWalkSearch

    private func volume(_ root: URL) -> VolumeProvider {
        let api = CloudAPI(account: Account(id: "volume:walk", cloud: .volume, name: "Prueba", email: "local",
                                            clientID: "", clientSecret: nil, serverURL: root.standardizedFileURL.path))
        return api.provider as! VolumeProvider
    }

    func testAWalkPagesThroughEveryFolderAndFindsEveryMatch() async throws {
        let root = try temporaryRoot("walk")
        let folders = TreeWalkSearch.foldersPerPage + 15
        for index in 0..<folders {
            let folder = root.appendingPathComponent(String(format: "carpeta-%03d", index))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent(index % 5 == 0 ? "Informe-\(index).txt" : "otro-\(index).txt"))
        }
        let provider = volume(root)
        var page = try await provider.walkSearch(term: "informe", cursor: nil)
        var hits = page.hits, pages = 1
        while let next = page.next {
            page = try await provider.walkSearch(term: "informe", cursor: next)
            hits += page.hits; pages += 1
        }
        XCTAssertGreaterThan(pages, 1, "\(folders + 1) folders do not fit in one page of \(TreeWalkSearch.foldersPerPage)")
        XCTAssertEqual(hits.count, (0..<folders).filter { $0 % 5 == 0 }.count)
        XCTAssertFalse(page.incomplete)
        XCTAssertTrue(hits.allSatisfy { $0.accountID == "volume:walk" })
    }

    func testACursorOnlyContinuesTheSearchThatMadeIt() async throws {
        let root = try temporaryRoot("walk")
        for index in 0..<(TreeWalkSearch.foldersPerPage + 2) {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("c\(index)"), withIntermediateDirectories: true)
        }
        let provider = volume(root)
        let first = try await provider.walkSearch(term: "a", cursor: nil)
        let cursor = try XCTUnwrap(first.next)
        do { _ = try await provider.walkSearch(term: "b", cursor: cursor); XCTFail("Another term cannot borrow the walk") }
        catch { XCTAssertEqual(error.localizedDescription, L("Esta búsqueda ha caducado. Vuelve a buscar.")) }
        do { _ = try await provider.walkSearch(term: "a", cursor: cursor); XCTFail("The failed attempt used the cursor up") }
        catch { XCTAssertEqual(error.localizedDescription, L("Esta búsqueda ha caducado. Vuelve a buscar.")) }
    }

    // MARK: - Inventory sources

    func testAMacFolderLeavesOutFinderBookkeepingAndLinks() async throws {
        let root = try temporaryRoot("inventory")
        for name in ["a.txt", ".DS_Store", "._a.txt", ".localized"] { try Data("x".utf8).write(to: root.appendingPathComponent(name)) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("enlace"), withDestinationURL: root.appendingPathComponent("sub"))
        let source = LocalInventorySource(root: root)
        let entries = try await source.children(of: nil)
        XCTAssertEqual(entries.map(\.name).sorted(), ["a.txt", "sub"])
        XCTAssertEqual(entries.first { $0.name == "sub" }?.isFolder, true)
        XCTAssertEqual(entries.first { $0.name == "a.txt" }?.size, 1)
        XCTAssertTrue(source.hashesLocally)
        let digest = try await source.digest(of: try XCTUnwrap(entries.first { $0.name == "a.txt" }), algorithm: .md5)
        XCTAssertEqual(digest, "9dd4e461268c8034f5c8564e155c67a6", "MD5 of \"x\"")
    }

    func testACloudFolderIsListedButNotHashedHere() async throws {
        let directory = try temporaryRoot("inventory-demo")
        let demo = try DemoStore(directory: directory); demo.latency = .milliseconds(1)
        let source = CloudInventorySource(api: CloudAPI(account: .demo, demo: demo), rootID: "root")
        let entries = try await source.children(of: nil)
        XCTAssertEqual(Set(entries.map(\.name)), Set(try demo.list("root").map(\.name)))
        XCTAssertFalse(source.hashesLocally)
        let file = try XCTUnwrap(entries.first { !$0.isFolder })
        do { _ = try await source.digest(of: file, algorithm: .md5); XCTFail("Only a volume hashes on this Mac") } catch {}
        let folder = try XCTUnwrap(entries.first { $0.isFolder })
        let inside = try await source.children(of: folder)
        XCTAssertEqual(inside.map(\.name), ["Notas.txt"])
    }

    func testListingsAreRetriedOnTransientErrorsOnly() async throws {
        var attempts = 0, waits: [Double] = []
        let value = try await ListingRetry.run(attempts: 3, sleep: { waits.append($0) }) { () -> Int in
            attempts += 1
            if attempts < 3 { throw URLError(.networkConnectionLost) }
            return 7
        }
        XCTAssertEqual(value, 7); XCTAssertEqual(attempts, 3); XCTAssertEqual(waits.count, 2)

        attempts = 0
        do {
            _ = try await ListingRetry.run(attempts: 3, sleep: { _ in }) { () -> Int in
                attempts += 1; throw CloudError.message("No existe")
            }
            XCTFail("A refusal is not retried into success")
        } catch {}
        XCTAssertEqual(attempts, 1, "A refusal is not worth asking again")

        attempts = 0
        do {
            _ = try await ListingRetry.run(attempts: 2, sleep: { _ in }) { () -> Int in
                attempts += 1; throw URLError(.timedOut)
            }
            XCTFail("It gives up in the end")
        } catch {}
        XCTAssertEqual(attempts, 3, "The first try and two more")
    }

    // MARK: - Duplicates across a cloud and this Mac

    func testDuplicatesInTheDemoWithoutChecksumsAreOnlyPossible() async throws {
        let directory = try temporaryRoot("duplicates-demo")
        let demo = try DemoStore(directory: directory); demo.latency = .milliseconds(1)
        let folder = try demo.add(name: "Copia", parent: "root", folder: true)
        _ = try demo.add(name: "foto.jpg", parent: "root", content: Data(repeating: 1, count: 300))
        _ = try demo.add(name: "foto.jpg", parent: folder, content: Data(repeating: 1, count: 300))
        _ = try demo.add(name: "otra.jpg", parent: folder, content: Data(repeating: 2, count: 300))
        let api = CloudAPI(account: .demo, demo: demo)
        let report = try await DuplicateScanner().run([.init(key: Account.demo.id, source: CloudInventorySource(api: api, rootID: "root"))], progress: { _ in })
        let pair = try XCTUnwrap(report.groups.first { $0.members.contains { $0.entry.name == "foto.jpg" } })
        XCTAssertEqual(pair.members.count, 2)
        XCTAssertFalse(pair.isConfirmed, "Same name and size, but nothing has read the bytes")
        XCTAssertEqual(report.wasted, 0)
        XCTAssertEqual(report.possibleWasted, 300)
        XCTAssertTrue(DuplicateGrouping.suggestedSelection(report.groups).isEmpty, "A possible duplicate is never pre-selected")
    }
}
