import XCTest
import Network
@testable import iCloudy

/// Explicit FTPS: the control connection starts in the clear and is raised to TLS with `AUTH TLS`. The refusal path
/// runs against the in-process fake server; the happy path needs a real TLS server and runs when `ICLOUDY_FTPS_URL`
/// names one (docs/FTP.md explains how to start the stand-in).
@MainActor
final class FTPSTests: XCTestCase {
    override func tearDown() { StartTLSFramer.trustAnyCertificateForTesting = false }

    func testTheThreeSchemesMapToTheThreeSecurityModesAndTheirDefaultPorts() throws {
        let plain = try FTPProvider.ftpEndpoint("ftp://nas.local/pub")
        XCTAssertEqual(plain.security, .none); XCTAssertEqual(plain.port, 21)
        let implicitTLS = try FTPProvider.ftpEndpoint("ftps://nas.local/pub")
        XCTAssertEqual(implicitTLS.security, .implicitTLS); XCTAssertEqual(implicitTLS.port, 990)
        let explicitTLS = try FTPProvider.ftpEndpoint("ftpes://nas.local/pub")
        XCTAssertEqual(explicitTLS.security, .explicitTLS); XCTAssertEqual(explicitTLS.port, 21, "AUTH TLS se hace en el puerto normal")
        XCTAssertEqual(try FTPProvider.ftpEndpoint("ftpes://nas.local:2121").port, 2121)
        XCTAssertTrue(FTPSession.Security.explicitTLS.encrypted); XCTAssertFalse(FTPSession.Security.none.encrypted)
    }

    func testAServerWithoutAuthTLSIsRefusedBeforeThePasswordIsSent() async throws {
        let server = try FakeFTPServer(files: [:], listings: [:])
        let port = try await server.start()
        defer { server.stop() }
        let account = Account(id: "ftp:test", cloud: .ftp, name: "Prueba", email: "ana@127.0.0.1", clientID: "", clientSecret: nil,
                              serverURL: "ftpes://127.0.0.1:\(port)/")
        let store = MemoryCredentials()
        store.stored[account.id] = Credential(accessToken: Data("ana:secreta".utf8).base64EncodedString(), refreshToken: "", expires: .distantFuture)
        let api = CloudAPI(account: account, credentials: store)
        do {
            _ = try await api.list(parent: "root")
            XCTFail("El servidor falso contesta 502 a AUTH TLS")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no admite FTPS explícito"), error.localizedDescription)
        }
        let log = server.log()
        XCTAssertEqual(log.first, "AUTH TLS", "Lo primero que se envía es la petición de cifrado")
        XCTAssertFalse(log.contains { $0.hasPrefix("PASS") || $0.hasPrefix("USER") }, "Sin TLS no viaja ninguna credencial: \(log)")
    }

    /// Set ICLOUDY_FTPS_URL, e.g. ftpes://ana:secreta@127.0.0.1:2121/, to run against a real explicit-FTPS server.
    /// The stand-in uses a self-signed certificate, which only the test hook accepts.
    func testTheWholeStackAgainstARealExplicitFTPSServerWhenOneIsConfigured() async throws {
        guard let url = ProcessInfo.processInfo.environment["ICLOUDY_FTPS_URL"], !url.isEmpty else {
            throw XCTSkip("Sin servidor FTPS configurado (ICLOUDY_FTPS_URL)")
        }
        StartTLSFramer.trustAnyCertificateForTesting = true
        let (account, credential) = try await FTPAuthentication().signInFTP(server: url, username: "", password: "")
        XCTAssertTrue(account.serverURL?.hasPrefix("ftpes://") == true, "La cuenta recuerda que es FTPS explícito")
        let store = MemoryCredentials(); store.stored[account.id] = credential
        let api = CloudAPI(account: account, credentials: store)

        let stamp = String(Int(Date().timeIntervalSince1970))
        let folderID = try await api.createFolder(name: "Prueba \(stamp)", parent: "root")
        let payload = Data((0..<300_000).map { UInt8(($0 * 13) % 251) })
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("ftps-\(stamp).bin")
        try payload.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let checkpoint = UploadCheckpoint(total: Int64(payload.count), modified: try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let receipt = try await api.resumableUpload(local: local, parent: folderID, name: "datos.bin", replacing: nil, checkpoint: checkpoint,
                                                    save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, folderID + "/datos.bin")
        let listed = try await api.list(parent: folderID)
        let remote = try XCTUnwrap(listed.first { $0.name == "datos.bin" })
        XCTAssertEqual(remote.size, Int64(payload.count))

        let downloaded = FileManager.default.temporaryDirectory.appendingPathComponent("ftps-\(stamp)-down.bin")
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try await api.download(file: remote, to: downloaded)
        XCTAssertEqual(try Data(contentsOf: downloaded), payload, "El canal de datos cifrado entrega lo mismo que subió")

        let root = try await rootListing(api)
        let folder = try XCTUnwrap(root.first { $0.id == folderID })
        try await api.trash(file: folder)
        let after = try await rootListing(api)
        XCTAssertFalse(after.contains { $0.id == folderID })
    }
    private func rootListing(_ api: CloudAPI) async throws -> [CloudFile] { try await api.list(parent: "root") }
}
