import XCTest
@testable import iCloudy

/// The ZIP reader is iCloudy's own, because the sandbox leaves no tool to call. It is held here against archives
/// made by the system's tools, and against the kind nobody should extract.
final class ZipArchiveTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func run(_ tool: String, _ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments)")
    }
    /// A tree with a name that needs UTF-8, an empty file, something compressible and something that is not.
    private func makeTree() throws -> (URL, [String: Data]) {
        let tree = root.appendingPathComponent("Carpeta ñ")
        let noise = Data((0..<300_000).map { UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13) })
        let files: [String: Data] = [
            "leeme.txt": Data(String(repeating: "línea que se repite\n", count: 20_000).utf8),
            "vacío.txt": Data(),
            "dentro/más dentro/canción.bin": noise,
            "dentro/a.txt": Data("a".utf8),
        ]
        for (path, data) in files {
            let url = tree.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return (tree, files)
    }
    private func assertExtracted(_ archive: URL, matches files: [String: Data], under prefix: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let out = root.appendingPathComponent("out-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var reported: Int64 = 0
        let count = try ZipArchive.extract(archive, to: out) { reported = $0 }
        XCTAssertEqual(count, files.count, file: file, line: line)
        for (path, data) in files {
            // macOS hands names back decomposed; the comparison is by content, found by either spelling.
            let url = out.appendingPathComponent(prefix).appendingPathComponent(path)
            XCTAssertEqual(try Data(contentsOf: url), data, path, file: file, line: line)
        }
        XCTAssertEqual(reported, Int64(files.values.reduce(0) { $0 + $1.count }), file: file, line: line)
    }

    func testAnArchiveMadeByTheSystemComesBackByteForByte() throws {
        let (tree, files) = try makeTree()
        let archive = root.appendingPathComponent("sistema.zip")
        try ZipArchive.compress(folder: tree, to: archive)
        XCTAssertTrue(try ZipArchive.entries(of: archive).contains { $0.method == 8 }, "Deflated, as the Finder would")
        try assertExtracted(archive, matches: files, under: "Carpeta ñ")
    }

    func testDittoAndZipArchivesStoredAndDeflated() throws {
        let (tree, files) = try makeTree()
        let ditto = root.appendingPathComponent("ditto.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", tree.path, ditto.path], in: root)
        try assertExtracted(ditto, matches: files, under: "Carpeta ñ")
        let stored = root.appendingPathComponent("stored.zip")
        try run("/usr/bin/zip", ["-r", "-0", "-q", stored.path, tree.lastPathComponent], in: root)
        XCTAssertTrue(try ZipArchive.entries(of: stored).filter { !$0.isDirectory }.allSatisfy { $0.method == 0 })
        try assertExtracted(stored, matches: files, under: "Carpeta ñ")
    }

    func testZip64RecordsAreRead() throws {
        let (tree, files) = try makeTree()
        let archive = root.appendingPathComponent("zip64.zip")
        try run("/usr/bin/zip", ["-r", "-q", "-fz", archive.path, tree.lastPathComponent], in: root)
        try assertExtracted(archive, matches: files, under: "Carpeta ñ")
    }

    func testSeveralItemsAreGatheredUnderTheArchivesName() throws {
        let (tree, files) = try makeTree()
        let loose = root.appendingPathComponent("suelto.txt"); try Data("suelto".utf8).write(to: loose)
        let archive = root.appendingPathComponent("varios.zip")
        try ZipArchive.compress(items: [tree, loose], named: "Archivo", to: archive, staging: root.appendingPathComponent("gather"))
        var expected = Dictionary(uniqueKeysWithValues: files.map { ("Carpeta ñ/" + $0.key, $0.value) })
        expected["suelto.txt"] = Data("suelto".utf8)
        try assertExtracted(archive, matches: expected, under: "Archivo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gather/Archivo").path), "The gathering folder is gone")
    }

    // MARK: - Archives nobody should extract

    /// A one-entry archive written by hand, so the name can be anything.
    private func handmade(name: String, content: Data = Data("x".utf8), method: UInt16 = 0, declaredSize: UInt32? = nil, crc: UInt32? = nil, unixMode: UInt32 = 0o100644, flags: UInt16 = 0x0800) -> URL {
        // One field per statement: a chain of a dozen `+` is more than some compilers will type-check in time.
        func put<T: FixedWidthInteger>(_ value: T, into data: inout Data) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = Data(name.utf8)
        let sum: UInt32 = crc ?? content.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> UInt32 in UInt32(truncatingIfNeeded: iCloudyZipCRC(raw)) }
        let size: UInt32 = declaredSize ?? UInt32(content.count)
        let packed = UInt32(content.count), nameLength = UInt16(bytes.count), zero16 = UInt16(0)
        var local = Data()
        put(UInt32(0x04034b50), into: &local); put(UInt16(20), into: &local); put(flags, into: &local); put(method, into: &local)
        put(zero16, into: &local); put(zero16, into: &local)
        put(sum, into: &local); put(packed, into: &local); put(size, into: &local); put(nameLength, into: &local); put(zero16, into: &local)
        local.append(bytes); local.append(content)
        var central = Data()
        put(UInt32(0x02014b50), into: &central); put(UInt16(0x0314), into: &central); put(UInt16(20), into: &central)
        put(flags, into: &central); put(method, into: &central); put(zero16, into: &central); put(zero16, into: &central)
        put(sum, into: &central); put(packed, into: &central); put(size, into: &central); put(nameLength, into: &central)
        put(zero16, into: &central); put(zero16, into: &central); put(zero16, into: &central); put(zero16, into: &central)
        put(unixMode << 16, into: &central); put(UInt32(0), into: &central)
        central.append(bytes)
        var end = Data()
        put(UInt32(0x06054b50), into: &end); put(zero16, into: &end); put(zero16, into: &end); put(UInt16(1), into: &end); put(UInt16(1), into: &end)
        put(UInt32(central.count), into: &end); put(UInt32(local.count), into: &end); put(zero16, into: &end)
        let url = root.appendingPathComponent(UUID().uuidString + ".zip")
        try! (local + central + end).write(to: url)
        return url
    }
    private func destination() throws -> URL {
        let out = root.appendingPathComponent("destino-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    func testAHandmadeArchiveIsReadAtAll() throws {
        let out = try destination()
        XCTAssertEqual(try ZipArchive.extract(handmade(name: "dentro/hola.txt", content: Data("hola".utf8)), to: out), 1)
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("dentro/hola.txt")), "hola")
    }

    func testNamesThatWouldLeaveTheDestinationAreRefusedBeforeAnythingIsWritten() throws {
        for name in ["../fuera.txt", "dentro/../../fuera.txt", "/etc/fuera.txt", "..\\fuera.txt"] {
            let out = try destination()
            XCTAssertThrowsError(try ZipArchive.extract(handmade(name: name), to: out), name) { XCTAssertEqual($0 as? ZipArchive.Failure, .unsafeName(name)) }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("fuera.txt").path))
        }
    }

    func testLinksAreLeftOutAndResourceForksToo() throws {
        let out = try destination()
        XCTAssertEqual(try ZipArchive.extract(handmade(name: "enlace", content: Data("/etc/passwd".utf8), unixMode: 0o120777), to: out), 0)
        XCTAssertEqual(try ZipArchive.extract(handmade(name: "__MACOSX/._nota.txt"), to: out), 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testADamagedEntryLeavesNoFile() throws {
        let out = try destination()
        XCTAssertThrowsError(try ZipArchive.extract(handmade(name: "roto.txt", content: Data("hola".utf8), crc: 0xDEADBEEF), to: out)) {
            XCTAssertEqual($0 as? ZipArchive.Failure, .damaged("roto.txt"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testAnEntryThatInflatesPastWhatItDeclaredIsStopped() throws {
        // Deflated zeros that claim to be ten bytes long.
        let (tree, _) = try makeTree(); _ = tree
        let big = root.appendingPathComponent("ceros.bin"); try Data(count: 2_000_000).write(to: big)
        let honest = root.appendingPathComponent("ceros.zip")
        try run("/usr/bin/zip", ["-q", "-j", honest.path, big.path], in: root)
        let entry = try XCTUnwrap(ZipArchive.entries(of: honest).first)
        let handle = try FileHandle(forReadingFrom: honest)
        try handle.seek(toOffset: entry.headerOffset)
        let header = try XCTUnwrap(try handle.read(upToCount: 30))
        let skip = Int(header[26]) | Int(header[27]) << 8, extra = Int(header[28]) | Int(header[29]) << 8
        try handle.seek(toOffset: entry.headerOffset + 30 + UInt64(skip + extra))
        let deflated = try XCTUnwrap(try handle.read(upToCount: Int(entry.compressedSize)))
        let out = try destination()
        XCTAssertThrowsError(try ZipArchive.extract(handmade(name: "bomba.bin", content: deflated, method: 8, declaredSize: 10, crc: entry.crc), to: out)) {
            XCTAssertEqual($0 as? ZipArchive.Failure, .damaged("bomba.bin"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testEncryptedAndUnknownArchivesSaySo() throws {
        let out = try destination()
        XCTAssertThrowsError(try ZipArchive.extract(handmade(name: "secreto.txt", flags: 0x0801), to: out)) { XCTAssertEqual($0 as? ZipArchive.Failure, .encrypted) }
        XCTAssertThrowsError(try ZipArchive.extract(handmade(name: "raro.txt", method: 14), to: out)) { XCTAssertEqual($0 as? ZipArchive.Failure, .unsupported("raro.txt")) }
        let notZip = root.appendingPathComponent("texto.zip"); try Data(String(repeating: "esto no es un zip ", count: 10).utf8).write(to: notZip)
        XCTAssertThrowsError(try ZipArchive.extract(notZip, to: out)) { XCTAssertEqual($0 as? ZipArchive.Failure, .notAnArchive) }
    }

    func testCancellingStopsBetweenEntries() throws {
        let (tree, _) = try makeTree()
        let archive = root.appendingPathComponent("cancelar.zip")
        try ZipArchive.compress(folder: tree, to: archive)
        XCTAssertThrowsError(try ZipArchive.extract(archive, to: try destination(), isCancelled: { true })) { XCTAssertTrue($0 is CancellationError) }
    }
}

import zlib
private func iCloudyZipCRC(_ bytes: UnsafeRawBufferPointer) -> uLong {
    crc32(crc32(0, nil, 0), bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
}

/// The two halves together: a transfer of the queue, and what happens to its bytes when it completes.
@MainActor
final class ArchiveStepTests: XCTestCase {
    private var root: URL!
    private var demo: DemoStore!
    private var queue: TransferQueue!
    private var steps: ArchiveSteps!
    private var messages: [(String, Bool)] = []
    private var revealed: [URL] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("steps-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("salida"), withIntermediateDirectories: true)
        demo = try DemoStore(directory: root.appendingPathComponent("demo"))
        let demo = demo!
        queue = TransferQueue(storeURL: root.appendingPathComponent("transfers.json"))
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        steps = ArchiveSteps(root: root.appendingPathComponent("Archives"))
        steps.queue = queue
        steps.report = { [weak self] message, isError in self?.messages.append((message, isError)) }
        steps.reveal = { [weak self] in self?.revealed.append($0) }
        queue.didFinish = { [weak steps] in steps?.handleFinished($0) }
        messages = []; revealed = []
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func settle() async throws {
        for _ in 0..<600 {
            if !queue.isWorking, !queue.items.contains(where: { [.queued, .running].contains($0.state) }), !messages.isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out: \(queue.items.map(\.state)) \(messages)")
    }
    private var output: URL { root.appendingPathComponent("salida") }

    func testDownloadingAsZipLeavesOneArchiveAndNoStaging() async throws {
        let folderID = try demo.add(name: "Fotos", parent: "root", folder: true)
        _ = try demo.add(name: "a.txt", parent: folderID, content: Data("aaa".utf8))
        let sub = try demo.add(name: "2026", parent: folderID, folder: true)
        _ = try demo.add(name: "b.txt", parent: sub, content: Data("bbbb".utf8))
        let folder = try XCTUnwrap(demo.file(folderID))
        let batch = UUID()
        var job = Transfer(batchID: batch, name: "Fotos", destination: "", accountID: Account.demo.id, direction: .download, localURL: try steps.prepareStaging(for: batch), file: folder)
        job.archive = ArchiveStep(kind: .compress, folder: output, name: "Fotos.zip")
        try queue.add([job])
        try await settle()
        XCTAssertEqual(messages.map(\.1), [false], messages.first?.0 ?? "")
        let archive = output.appendingPathComponent("Fotos.zip")
        XCTAssertEqual(revealed, [archive])
        let unpacked = root.appendingPathComponent("comprobar"); try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        XCTAssertEqual(try ZipArchive.extract(archive, to: unpacked), 2)
        XCTAssertEqual(try String(contentsOf: unpacked.appendingPathComponent("Fotos/a.txt")), "aaa")
        XCTAssertEqual(try String(contentsOf: unpacked.appendingPathComponent("Fotos/2026/b.txt")), "bbbb")
        XCTAssertFalse(FileManager.default.fileExists(atPath: steps.staging(for: batch).path), "The staged copy is gone")
        XCTAssertNil(queue.items.first?.archive, "The step ran: a relaunch must not run it again")
    }

    func testSeveralItemsBecomeOneArchiveOnlyWhenAllOfThemArrived() async throws {
        let a = try XCTUnwrap(demo.file(try demo.add(name: "uno.txt", parent: "root", content: Data("1".utf8))))
        let b = try XCTUnwrap(demo.file(try demo.add(name: "dos.txt", parent: "root", content: Data("22".utf8))))
        let batch = UUID()
        let staging = try steps.prepareStaging(for: batch)
        let step = ArchiveStep(kind: .compress, folder: output, name: "Archivo.zip")
        let jobs = [a, b].map { file -> Transfer in
            var job = Transfer(batchID: batch, name: file.name, destination: "", accountID: Account.demo.id, direction: .download, localURL: staging, file: file)
            job.archive = step
            return job
        }
        try queue.add(jobs)
        queue.cancel(jobs[1].id, pause: true)
        for _ in 0..<200 where queue.items.first?.state != .completed { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(messages.isEmpty, "One of the two is still waiting: nothing is compressed yet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("Archivo.zip").path))
        queue.retry(jobs[1].id)
        try await settle()
        let unpacked = root.appendingPathComponent("comprobar"); try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        XCTAssertEqual(try ZipArchive.extract(output.appendingPathComponent("Archivo.zip"), to: unpacked), 2)
        XCTAssertEqual(try String(contentsOf: unpacked.appendingPathComponent("Archivo/dos.txt")), "22")
    }

    func testDownloadingAndExtractingOpensTheArchiveIntoAFolderOfItsOwn() async throws {
        let tree = root.appendingPathComponent("Proyecto")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("código".utf8).write(to: tree.appendingPathComponent("src/main.swift"))
        let local = root.appendingPathComponent("Proyecto.zip")
        try ZipArchive.compress(folder: tree, to: local)
        let remote = try XCTUnwrap(demo.file(try demo.add(name: "Proyecto.zip", parent: "root", content: try Data(contentsOf: local))))
        try FileManager.default.createDirectory(at: output.appendingPathComponent("Proyecto"), withIntermediateDirectories: true)

        let batch = UUID()
        var job = Transfer(batchID: batch, name: remote.name, destination: "", accountID: Account.demo.id, direction: .download, localURL: try steps.prepareStaging(for: batch), file: remote)
        job.archive = ArchiveStep(kind: .extract, folder: output, name: "Proyecto")
        try queue.add([job])
        try await settle()
        XCTAssertEqual(messages.map(\.1), [false], messages.first?.0 ?? "")
        let extracted = output.appendingPathComponent("Proyecto (2)")
        XCTAssertEqual(try String(contentsOf: extracted.appendingPathComponent("Proyecto/src/main.swift")), "código", "A folder already there is never written into")
        XCTAssertFalse(FileManager.default.fileExists(atPath: steps.staging(for: batch).path))
    }

    func testAnArchiveThatCannotBeOpenedSaysSoAndKeepsWhatWasDownloaded() async throws {
        let remote = try XCTUnwrap(demo.file(try demo.add(name: "falso.zip", parent: "root", content: Data(String(repeating: "no soy un zip ", count: 20).utf8))))
        let batch = UUID()
        var job = Transfer(batchID: batch, name: remote.name, destination: "", accountID: Account.demo.id, direction: .download, localURL: try steps.prepareStaging(for: batch), file: remote)
        job.archive = ArchiveStep(kind: .extract, folder: output, name: "falso")
        try queue.add([job])
        try await settle()
        XCTAssertEqual(messages.map(\.1), [true])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [], "No empty folder is left behind")
        XCTAssertTrue(FileManager.default.fileExists(atPath: steps.staging(for: batch).appendingPathComponent("falso.zip").path))
    }

    func testAnUploadedArchiveIsThrownAwayAndStaleStagingIsSwept() async throws {
        let batch = UUID()
        let staging = try steps.prepareStaging(for: batch)
        let archive = staging.appendingPathComponent("subir.zip"); try Data("PK".utf8).write(to: archive)
        var job = Transfer(batchID: batch, name: "subir.zip", destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: archive)
        job.archive = ArchiveStep(kind: .discard)
        try queue.add([job])
        for _ in 0..<300 where FileManager.default.fileExists(atPath: staging.path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(try demo.list("root").contains { $0.name == "subir.zip" })

        let orphan = try steps.prepareStaging(for: UUID())
        steps.cleanStale()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "No job knows this folder any more")
    }

    func testOldQueuesDecodeWithoutAnArchiveStep() throws {
        let legacy = #"{"accountID":"a","direction":"download","localURL":"file:///tmp/"}"#
        XCTAssertNil(try JSONDecoder().decode(Transfer.self, from: Data(legacy.utf8)).archive)
    }
}
