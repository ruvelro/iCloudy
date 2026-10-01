import XCTest
@testable import iCloudy

/// A URLProtocol of its own, so these tests never touch the handler other suites install on `StubProtocol`.
private final class DiagnosticsStub: URLProtocol {
    static var status = 200
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let headers = Self.status == 429 ? ["Retry-After": "7"] : [:]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: headers)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class DiagnosticsLogTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diag-" + UUID().uuidString, isDirectory: true)
        folders.append(url)
        return url
    }
    private func event(_ severity: DiagnosticSeverity, _ message: String = "x", stage: String = DiagnosticStage.http) -> DiagnosticRecord {
        DiagnosticRecord(severity, stage: stage, message: message)
    }
    private func waitForEvent(in log: DiagnosticsLog = Diagnostics.shared, _ matches: (DiagnosticEvent) -> Bool) async throws -> DiagnosticEvent {
        for _ in 0..<200 {
            if let found = log.events().last(where: matches) { return found }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CloudError.message("No llegó el evento")
    }

    // MARK: - Levels

    func testLevelsDecideWhatIsKept() {
        for (level, expected) in [(DiagnosticsLevel.off, 0), (.normal, 4), (.detailed, 5)] {
            let log = DiagnosticsLog(directory: nil, level: level)
            for severity in DiagnosticSeverity.allCases { log.record(event(severity)) }
            XCTAssertEqual(log.events().count, expected, "\(level)")
        }
        let normal = DiagnosticsLog(directory: nil, level: .normal)
        normal.record(event(.trace))
        normal.record(event(.error))
        XCTAssertEqual(normal.events().map(\.severity), [.error], "Una petición correcta solo cuenta en el nivel detallado")
    }

    func testChangingTheLevelAppliesToWhatComesNext() {
        let log = DiagnosticsLog(directory: nil, level: .normal)
        log.record(event(.error, "antes"))
        log.level = .off
        log.record(event(.error, "apagado"))
        log.level = .detailed
        log.record(event(.trace, "detalle"))
        XCTAssertEqual(log.events().compactMap(\.message), ["antes", "detalle"])
    }

    func testNamesOnlyReachTheLogAtTheDetailedLevel() {
        let url = URL(string: "https://nas.local/remote.php/dav/files/ana/Informe%20anual.pdf")!
        let quiet = DiagnosticsLog(directory: nil, level: .normal)
        quiet.record(DiagnosticRecord(.error, stage: DiagnosticStage.http, url: url, message: "No se pudo con «Informe anual.pdf»"))
        let loud = DiagnosticsLog(directory: nil, level: .detailed)
        loud.record(DiagnosticRecord(.error, stage: DiagnosticStage.http, url: url, message: "No se pudo con «Informe anual.pdf»"))
        let hidden = quiet.events()[0], shown = loud.events()[0]
        XCTAssertFalse((hidden.path ?? "").contains("Informe") || (hidden.message ?? "").contains("Informe"))
        XCTAssertTrue((shown.path ?? "").contains("Informe anual.pdf") && (shown.message ?? "").contains("Informe anual.pdf"))
    }

    // MARK: - Memory and files

    func testTheRingKeepsOnlyTheMostRecentEvents() {
        var limits = DiagnosticsLog.Limits(); limits.memory = 10
        let log = DiagnosticsLog(directory: nil, limits: limits)
        for index in 0..<25 { log.record(event(.error, "\(index)")) }
        let events = log.events()
        XCTAssertEqual(events.count, 10)
        XCTAssertEqual(events.first?.message, "15")
        XCTAssertEqual(events.last?.message, "24")
    }

    func testWritesAreBatchedNotOnePerEvent() throws {
        let directory = folder()
        var limits = DiagnosticsLog.Limits(); limits.batch = 50; limits.flushDelay = 60
        let log = DiagnosticsLog(directory: directory, limits: limits)
        for index in 0..<5 { log.record(event(.error, "\(index)")) }
        XCTAssertEqual(log.events().count, 5, "En memoria al momento")
        XCTAssertTrue(log.fileURLs().isEmpty, "En disco, todavía no: se espera a juntar más")
        log.flush()
        XCTAssertEqual(DiagnosticsLog.decode(try XCTUnwrap(log.fileURLs().first)).count, 5)
        for index in 5..<55 { log.record(event(.error, "\(index)")) }
        _ = log.events() // Waits for the queue, which wrote the full batch on its own.
        XCTAssertEqual(DiagnosticsLog.decode(try XCTUnwrap(log.fileURLs().first)).count, 55)
    }

    func testFilesAreRotatedPrivateAndBounded() throws {
        let directory = folder()
        var limits = DiagnosticsLog.Limits(); limits.batch = 1; limits.fileBytes = 2_000; limits.files = 3
        let log = DiagnosticsLog(directory: directory, limits: limits)
        for index in 0..<300 { log.record(event(.error, "evento número \(index) con algo de texto para ocupar sitio")) }
        log.flush()
        let files = log.fileURLs()
        XCTAssertLessThanOrEqual(files.count, 3)
        XCTAssertGreaterThan(files.count, 1, "Se ha rotado")
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, file.lastPathComponent)
            XCTAssertLessThan((attributes[.size] as? NSNumber)?.intValue ?? .max, 2_000 + 400, "Ningún archivo pasa mucho del límite")
        }
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((folderAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(log.storedEvents().last?.message?.contains("299") == true, "Lo último siempre está")
    }

    func testOldFilesAndEventsExpire() throws {
        let directory = folder()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var limits = DiagnosticsLog.Limits(); limits.batch = 1
        // A rotated file from long ago, and an old event at the start of the current file.
        let old = DiagnosticEvent(time: Date().addingTimeInterval(-30 * 24 * 3600), severity: .error, stage: "http", message: "viejo")
        let rotated = directory.appendingPathComponent("events.1.jsonl")
        try DiagnosticsLog.line(old).write(to: rotated)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 24 * 3600)], ofItemAtPath: rotated.path)
        try DiagnosticsLog.line(old).write(to: directory.appendingPathComponent("events.jsonl"))
        let log = DiagnosticsLog(directory: directory, limits: limits)
        log.record(event(.error, "nuevo"))
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: rotated.path), "Un archivo pasado de edad se borra")
        XCTAssertEqual(log.storedEvents().compactMap(\.message), ["nuevo"], "Y un evento pasado de edad no se exporta")
        XCTAssertFalse(log.events().contains { $0.message == "viejo" }, "Ni se carga al arrancar")
    }

    func testEventsOfEarlierRunsAreShownAfterARelaunch() {
        let directory = folder()
        let first = DiagnosticsLog(directory: directory)
        first.record(event(.error, "de la sesión anterior"))
        first.flush()
        let second = DiagnosticsLog(directory: directory)
        XCTAssertEqual(second.events().last?.message, "de la sesión anterior")
        second.record(event(.summary, "de esta"))
        XCTAssertEqual(second.events().compactMap(\.message), ["de la sesión anterior", "de esta"])
    }

    func testClearingForgetsEverything() {
        let directory = folder()
        let log = DiagnosticsLog(directory: directory)
        log.record(event(.error))
        log.flush()
        XCTAssertFalse(log.fileURLs().isEmpty)
        log.clear()
        XCTAssertTrue(log.events().isEmpty)
        XCTAssertTrue(log.fileURLs().isEmpty)
    }

    func testRecordingNeverWaitsForTheDisk() {
        // The caller only reads the level and queues the rest; a thousand events cost less than the queue needs to
        // write them. The bound is generous on purpose: the point is that nothing is written on this thread.
        let log = DiagnosticsLog(directory: folder())
        let started = Date()
        for index in 0..<1000 { log.record(event(.error, "Bearer eyJhbGciOiJIUzI1NiJ9.e30.\(index) en https://x.example/a?token=\(index)")) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        log.flush()
    }

    func testTheSuiteNeverWritesToTheRealFolder() {
        XCTAssertNil(Diagnostics.shared.directory)
        XCTAssertTrue(Diagnostics.shared.fileURLs().isEmpty)
    }

    // MARK: - Hooks

    @MainActor
    func testEveryRequestPassingTheGuardIsSeenWithItsContext() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticsStub.self]
        let session = URLSession(configuration: configuration)
        let host = "diag-\(UUID().uuidString.prefix(8).lowercased()).example"
        DiagnosticsStub.status = 503
        let transfer = UUID()
        let context = DiagnosticsContext(account: "dropbox:ana@example.com", provider: "dropbox", transfer: transfer, stage: DiagnosticStage.download)
        let request = URLRequest(url: URL(string: "https://\(host)/2/files/list_folder?access_token=SECRETO")!)
        _ = try await Diagnostics.$context.withValue(context) { try await session.data(for: request, delegate: RedirectGuard.shared) }
        let event = try await waitForEvent { $0.host == host }
        XCTAssertEqual(event.severity, .error)
        XCTAssertEqual(event.status, 503)
        XCTAssertEqual(event.stage, DiagnosticStage.list)
        XCTAssertEqual(event.provider, "dropbox")
        XCTAssertEqual(event.account, Diagnostics.shared.redactor.account("dropbox:ana@example.com"))
        XCTAssertEqual(event.transfer, String(transfer.uuidString.prefix(8)).lowercased())
        XCTAssertEqual(event.path, "/2/files/list_folder?access_token=…")
        XCTAssertNotNil(event.durationMs)
    }

    @MainActor
    func testRateLimitsAreRetriesAndUploadsBelongToTheDestination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticsStub.self]
        let session = URLSession(configuration: configuration)
        let host = "diag-\(UUID().uuidString.prefix(8).lowercased()).example"
        DiagnosticsStub.status = 429
        let context = DiagnosticsContext(account: "google:origen", provider: "google", transfer: UUID(), stage: DiagnosticStage.transfer,
                                         target: "microsoft:destino", targetProvider: "microsoft")
        var request = URLRequest(url: URL(string: "https://\(host)/rup/sesion-capacidad-0123456789/abc")!)
        request.httpMethod = "PUT"
        _ = try await Diagnostics.$context.withValue(context) {
            try await session.upload(for: request, from: Data(count: 1024), delegate: RedirectGuard.shared)
        }
        let event = try await waitForEvent { $0.host == host }
        XCTAssertEqual(event.severity, .retry)
        XCTAssertEqual(event.stage, DiagnosticStage.rateLimit)
        XCTAssertEqual(event.message, "Retry-After 7")
        DiagnosticsStub.status = 200
        let created = URLRequest(url: URL(string: "https://\(host)/upload/created")!)
        Diagnostics.shared.level = .detailed
        defer { Diagnostics.shared.level = .normal }
        var upload = created; upload.httpMethod = "PUT"
        _ = try await Diagnostics.$context.withValue(context) {
            try await session.upload(for: upload, from: Data(count: 1024), delegate: RedirectGuard.shared)
        }
        let chunk = try await waitForEvent { $0.host == host && $0.status == 200 }
        XCTAssertEqual(chunk.stage, DiagnosticStage.uploadChunk)
        XCTAssertEqual(chunk.account, Diagnostics.shared.redactor.account("microsoft:destino"), "La subida es de la cuenta de destino")
        XCTAssertEqual(chunk.provider, "microsoft")
    }

    @MainActor
    func testAStampedRequestNamesItsAccount() throws {
        let account = Account(id: "box:ana@example.com", cloud: .box, name: "Ana", email: "ana@example.com", clientID: "", clientSecret: nil)
        var request = URLRequest(url: URL(string: "https://api.box.com/2.0/folders/0/items")!)
        Diagnostics.stamp(&request, account: account)
        request.setValue("Bearer x", forHTTPHeaderField: "Authorization")
        let stamp = try XCTUnwrap(URLProtocol.property(forKey: "es.ruvelro.icloudy.diagnostics", in: request) as? [String: String])
        XCTAssertEqual(stamp["account"], account.id)
        XCTAssertNil(request.allHTTPHeaderFields?.keys.first { $0.lowercased().contains("diagnos") }, "La marca no viaja como cabecera")
    }

    @MainActor
    func testTheQueueReportsItsTransfers() async throws {
        let root = folder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let source = root.appendingPathComponent("Nómina secreta.pdf")
        try Data(repeating: 1, count: 1000).write(to: source)
        let job = Transfer(name: source.lastPathComponent, destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: source)
        try queue.add([job])
        let event = try await waitForEvent { $0.transfer == String(job.id.uuidString.prefix(8)).lowercased() && $0.severity == .summary }
        XCTAssertEqual(event.stage, DiagnosticStage.upload)
        XCTAssertEqual(event.bytesSent, 1000)
        XCTAssertTrue(event.message?.hasPrefix("completada") == true)
        XCTAssertEqual(event.provider, Cloud.google.rawValue)
        XCTAssertFalse(Diagnostics.shared.events().contains { ($0.message ?? "").contains("Nómina") }, "El nombre del archivo no aparece")
    }

    @MainActor
    func testNetworkChangesAreRecorded() async throws {
        let connectivity = Connectivity()
        connectivity.update(false)
        connectivity.update(true)
        let events = Diagnostics.shared.events().filter { $0.stage == DiagnosticStage.networkChange }
        XCTAssertEqual(events.suffix(2).compactMap(\.message), ["sin red", "red disponible"])
    }
}
