import XCTest
@testable import iCloudy

/// The export is the one thing that leaves the Mac. These tests seed every kind of secret the app handles into every
/// way an event can be recorded, export, and then search the result byte by byte, the way somebody grepping the
/// package would.
final class DiagnosticsExportTests: XCTestCase {
    /// Fake, but shaped like the real thing.
    private static let secrets = [
        "ya29.a0AfH6SMBfakeAccessToken0123456789",
        "1//0gLxFAKErefreshTokenABCDEFG",
        "GOCSPX-fakeClientSecret42xyz",
        "hunter2-fake-password",
        "fakeCookieValue0123456789ABCDEF",
        "validationKeyValue9876543210abc",
        "deadbeefcafe0123456789abcdef0123",
        "AKIAFAKEACCESSKEY0001",
        "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.c2lnbmF0dXJlZmFrZQ",
        "fakeUploadSessionCapability1234567",
        "AAEfakeDropboxSession0123456789",
        "megaSidFake0123456789abcdefXYZ",
        "ana.garcia@example.com",
        "Nómina marzo",
        "/Users/ana/Documentos",
        "Presupuesto confidencial",
    ]

    private var folders: [URL] = []
    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diag-export-" + UUID().uuidString, isDirectory: true)
        folders.append(url)
        return url
    }

    /// Every way an event reaches the log, each carrying secrets.
    private func seed(_ log: DiagnosticsLog) {
        let s = Self.secrets
        let records = [
            DiagnosticRecord(.error, stage: DiagnosticStage.http, provider: "google", account: "google:\(s[12])", transfer: UUID(),
                             method: "GET", url: URL(string: "https://www.googleapis.com/drive/v3/files?access_token=\(s[0])&q=name%3D'\(s[13]).pdf'"),
                             status: 401, message: "Authorization: Bearer \(s[0])"),
            DiagnosticRecord(.error, stage: DiagnosticStage.auth, provider: "google", account: "google:\(s[12])",
                             message: #"{"access_token":"\#(s[0])","refresh_token":"\#(s[1])","id_token":"\#(s[8])","expires_in":3599}"#),
            DiagnosticRecord(.error, stage: DiagnosticStage.auth, message: "client_id=1.apps&client_secret=\(s[2])&refresh_token=\(s[1])"),
            DiagnosticRecord(.error, stage: DiagnosticStage.ftp, provider: "ftp", account: "ftp:ftp.example.org#\(s[12])",
                             url: URL(string: "ftp://ftp.example.org"), status: 530, command: "PASS \(s[3])"),
            DiagnosticRecord(.error, stage: DiagnosticStage.ftp, provider: "ftp", url: URL(string: "ftp://ftp.example.org"),
                             status: 550, command: "STOR \(s[14])/\(s[13]).pdf"),
            DiagnosticRecord(.error, stage: DiagnosticStage.sftp, provider: "sftp", url: URL(string: "sftp://nas.local"),
                             status: 3, command: "OPEN \(s[14])/\(s[15]).xlsx"),
            DiagnosticRecord(.notice, stage: DiagnosticStage.o2, provider: "o2",
                             message: O2Log.describe(path: "media/folder", action: "list", status: 200, error: "SEC-1003",
                                                     keyChanged: true, cookieNames: ["JSESSIONID", "validationKey"])),
            DiagnosticRecord(.notice, stage: DiagnosticStage.o2, provider: "o2",
                             message: "no se pudo adoptar: Set-Cookie: JSESSIONID=\(s[4]); validationKey=\(s[5])"),
            DiagnosticRecord(.error, stage: DiagnosticStage.uploadChunk, provider: "s3", method: "PUT",
                             url: URL(string: "https://bucket.s3.amazonaws.com/\(s[13]).pdf?X-Amz-Credential=\(s[7])&X-Amz-Signature=\(s[6])"),
                             status: 403),
            DiagnosticRecord(.retry, stage: DiagnosticStage.uploadChunk, provider: "microsoft", method: "PUT",
                             url: URL(string: "https://api.onedrive.com/rup/\(s[9])/\(s[8])"), status: 503, attempt: 2),
            DiagnosticRecord(.error, stage: DiagnosticStage.uploadChunk, provider: "dropbox",
                             message: #"Dropbox-API-Arg: {"cursor":{"session_id":"\#(s[10])","offset":0},"commit":{"path":"\#(s[14])/\#(s[13]).pdf"}}"#),
            DiagnosticRecord(.retry, stage: DiagnosticStage.mega, provider: "mega", method: "POST",
                             url: URL(string: "https://g.api.mega.co.nz/cs?id=7&sid=\(s[11])"), status: 500),
            DiagnosticRecord(.error, stage: DiagnosticStage.download, provider: "box",
                             error: CloudError.message("La suma de verificación de «\(s[13]).pdf» no coincide. Detalle: <html>token \(s[0]) for \(s[12])</html>")),
            DiagnosticRecord(.error, stage: DiagnosticStage.http, provider: "webdav",
                             url: URL(string: "https://ana:\(s[3])@nas.example.org/remote.php/dav/files/ana/\(s[15]).xlsx"), status: 423),
        ]
        for record in records { Diagnostics.record(record, in: log) }
    }

    private func exportedText(_ package: DiagnosticsExport.Package) throws -> String {
        let destination = folder()
        try DiagnosticsExport.write(package, to: destination)
        let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(package.fileNames))
        for file in files {
            let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(mode, 0o600, file.lastPathComponent)
        }
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    private func assertNoSecrets(_ text: String, allowing allowed: Set<String> = [], file: StaticString = #filePath, line: UInt = #line) {
        for secret in Self.secrets where !allowed.contains(secret) {
            XCTAssertFalse(text.contains(secret), "«\(secret)» ha salido en la exportación", file: file, line: line)
            // A recognisable piece is as bad as the whole: a token cut in half still identifies it.
            if secret.count >= 20 {
                let core = String(secret.dropFirst(4).prefix(12))
                XCTAssertFalse(text.contains(core), "Un trozo de «\(secret)» ha salido", file: file, line: line)
            }
        }
        for marker in ["Bearer ya29", "PASS hunter", "sid=mega", "X-Amz-Signature=dead"] {
            XCTAssertFalse(text.contains(marker), marker, file: file, line: line)
        }
    }

    func testTheExportCarriesNoSecretAtTheNormalLevel() throws {
        let log = DiagnosticsLog(directory: folder(), level: .normal)
        seed(log)
        let legacy = folder().appendingPathComponent("o2-diagnostico.txt")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "2026-09-17T10:00:00Z media list · HTTP 200 · validationKey=\(Self.secrets[5])\n".write(to: legacy, atomically: true, encoding: .utf8)
        let accounts = [Account(id: "google:\(Self.secrets[12])", cloud: .google, name: Self.secrets[15], email: Self.secrets[12], clientID: "c", clientSecret: Self.secrets[2])]
        let snapshot = DiagnosticsExport.snapshot(accounts: accounts, transfers: [], level: .normal)
        let package = DiagnosticsExport.prepare(snapshot, log: log, legacyO2: legacy)
        XCTAssertEqual(package.eventCount, 14)
        XCTAssertNotNil(package.legacyO2)
        assertNoSecrets(try exportedText(package))
    }

    func testEventsRecordedWithNamesLoseThemWhenExportedAtTheNormalLevel() throws {
        let log = DiagnosticsLog(directory: folder(), level: .detailed)
        seed(log)
        XCTAssertTrue(log.events().contains { ($0.message ?? "").contains("Nómina marzo") || ($0.path ?? "").contains("Nómina marzo") },
                      "Con el nivel detallado aceptado, los nombres sí se anotan")
        log.level = .normal
        let snapshot = DiagnosticsExport.snapshot(accounts: [], transfers: [], level: .normal)
        let package = DiagnosticsExport.prepare(snapshot, log: log, legacyO2: nil)
        XCTAssertFalse(package.includesNames)
        assertNoSecrets(try exportedText(package))
    }

    func testTheDetailedExportShowsNamesButStillNoSecret() throws {
        let log = DiagnosticsLog(directory: folder(), level: .detailed)
        seed(log)
        let snapshot = DiagnosticsExport.snapshot(accounts: [], transfers: [], level: .detailed)
        let package = DiagnosticsExport.prepare(snapshot, log: log, legacyO2: nil)
        XCTAssertTrue(package.includesNames)
        let text = try exportedText(package)
        XCTAssertTrue(text.contains("Nómina marzo"), "El nivel detallado exporta los nombres, que es para lo que existe")
        // Paths and names are what the detailed level is for; credentials and addresses never are.
        assertNoSecrets(text, allowing: ["Nómina marzo", "/Users/ana/Documentos", "Presupuesto confidencial"])
    }

    func testTheSummaryDescribesTheSetupWithoutNamingAnybody() throws {
        let accounts = [
            Account(id: "google:\(Self.secrets[12])", cloud: .google, name: "Ana García", email: Self.secrets[12], clientID: "", clientSecret: nil),
            Account(id: "google:otra@example.com", cloud: .google, name: "Otra", email: "otra@example.com", clientID: "", clientSecret: nil),
            Account(id: "ftp:ftp.example.org#ana", cloud: .ftp, name: "Servidor", email: "ana@ftp.example.org", clientID: "", clientSecret: nil),
        ]
        var failed = Transfer(name: "\(Self.secrets[13]).pdf", destination: "Drive", accountID: accounts[0].id, direction: .upload,
                              localURL: URL(fileURLWithPath: "\(Self.secrets[14])/x.pdf"))
        failed.state = .failed
        let queued = Transfer(name: "otro.pdf", destination: "Drive", accountID: accounts[0].id, direction: .download,
                              localURL: URL(fileURLWithPath: "/tmp/x"))
        let snapshot = DiagnosticsExport.snapshot(accounts: accounts, transfers: [failed, queued], level: .normal)
        let summary = DiagnosticsExport.summary(snapshot, events: [])
        XCTAssertTrue(summary.contains("Versión de la app:"))
        XCTAssertTrue(summary.contains("macOS:"))
        XCTAssertTrue(summary.contains("- google: 2 · capacidades:"))
        XCTAssertTrue(summary.contains("search") && summary.contains("trashListing"), "Las capacidades se leen del propio tipo")
        XCTAssertTrue(summary.contains("- ftp: 1"))
        XCTAssertTrue(summary.contains("- failed: 1") && summary.contains("- queued: 1"))
        for private_ in ["Ana García", "otra@example.com", "ftp.example.org", "otro.pdf"] + Self.secrets {
            XCTAssertFalse(summary.contains(private_), private_)
        }
    }

    func testTheArchiveIsARealZip() throws {
        let log = DiagnosticsLog(directory: folder(), level: .normal)
        seed(log)
        let package = DiagnosticsExport.prepare(DiagnosticsExport.snapshot(accounts: [], transfers: [], level: .normal), log: log, legacyO2: nil)
        let destination = folder().appendingPathComponent("iCloudy-diagnostico.zip")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DiagnosticsExport.archive(package, to: destination)
        let data = try Data(contentsOf: destination)
        XCTAssertEqual(data.prefix(2), Data("PK".utf8))
        // The names of the entries are stored as they are, so the archive can be checked for them without unzipping.
        let listing = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(listing.contains("events.jsonl") && listing.contains("summary.txt"))
    }

    func testEventsAreOneJSONObjectPerLine() throws {
        let log = DiagnosticsLog(directory: folder(), level: .normal)
        seed(log)
        let package = DiagnosticsExport.prepare(DiagnosticsExport.snapshot(accounts: [], transfers: [], level: .normal), log: log, legacyO2: nil)
        let lines = String(decoding: package.events, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 14)
        for line in lines {
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertNotNil(object["time"]); XCTAssertNotNil(object["stage"]); XCTAssertNotNil(object["severity"])
        }
    }
}
