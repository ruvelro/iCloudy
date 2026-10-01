import XCTest
@testable import iCloudy

/// The whole S3 stack against a real server, MinIO for instance, when `ICLOUDY_S3_URL` names one (see docs/S3.md for
/// how to start it). The address carries the keys and the bucket: `http://clave:secreto@127.0.0.1:9000/pruebas`.
/// Everything this creates lives under a folder of its own, which is deleted at the end.
@MainActor
final class S3IntegrationTests: XCTestCase {
    func testTheWholeStackAgainstARealServerWhenOneIsConfigured() async throws {
        guard let address = ProcessInfo.processInfo.environment["ICLOUDY_S3_URL"], !address.isEmpty,
              var components = URLComponents(string: address) else {
            throw XCTSkip("Sin servidor S3 configurado (ICLOUDY_S3_URL)")
        }
        let accessKey = components.user ?? "", secretKey = components.password ?? ""
        let bucket = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.user = nil; components.password = nil; components.path = ""
        let form = S3SignIn(service: .custom, region: "us-east-1", endpoint: components.url!.absoluteString,
                            accessKey: accessKey, secretKey: secretKey, bucket: bucket)
        let (account, credential) = try await S3Authentication().signIn(form)
        let store = MemoryCredentials(); store.stored[account.id] = credential
        let api = CloudAPI(account: account, credentials: store)

        let stamp = String(Int(Date().timeIntervalSince1970))
        let folderID = try await api.createFolder(name: "Prueba \(stamp)", parent: "root")
        let top = try await api.list(parent: "root")
        XCTAssertTrue(top.contains { $0.id == folderID && $0.isFolder })

        // One small object in a single PUT, and one that needs three parts.
        let small = Data("hola desde iCloudy".utf8)
        var large = Data(capacity: 17 * 1024 * 1024 + 5)
        while large.count < 17 * 1024 * 1024 + 5 { large.append(UInt8(truncatingIfNeeded: large.count % 251)) }
        for (name, payload) in [("pequeño.txt", small), ("grande.bin", large)] {
            let local = FileManager.default.temporaryDirectory.appendingPathComponent("s3-\(stamp)-\(name)")
            try payload.write(to: local)
            defer { try? FileManager.default.removeItem(at: local) }
            let checkpoint = UploadCheckpoint(total: Int64(payload.count), modified: try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let receipt = try await api.resumableUpload(local: local, parent: folderID, name: name, replacing: nil, checkpoint: checkpoint,
                                                        save: { _ in }, progress: { _, _ in })
            XCTAssertEqual(receipt.verification, .verified, "MinIO answers MD5 ETags and composite ETags like S3")
        }
        let listed = try await api.list(parent: folderID)
        XCTAssertEqual(Set(listed.map(\.name)), ["pequeño.txt", "grande.bin"])

        for file in listed {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("s3-\(stamp)-bajada-\(file.name)")
            defer { try? FileManager.default.removeItem(at: destination) }
            let verification = try await api.download(file: file, to: destination)
            XCTAssertEqual(try Data(contentsOf: destination), file.name == "grande.bin" ? large : small)
            XCTAssertEqual(verification, file.name == "grande.bin" ? .unavailable : .verified, "A multipart ETag is not an MD5")
        }

        // A presigned link works with no signing of its own.
        let smallFile = try XCTUnwrap(listed.first { $0.name == "pequeño.txt" })
        let link = try await api.publicLink(for: smallFile)
        let (fetched, response) = try await URLSession.shared.data(from: link)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(fetched, small)

        try await api.rename(file: smallFile, name: "renombrado.txt")
        let subfolder = try await api.createFolder(name: "dentro", parent: folderID)
        let afterRename = try await api.list(parent: folderID)
        let renamed = try XCTUnwrap(afterRename.first { $0.name == "renombrado.txt" })
        try await api.copy(file: renamed, to: subfolder)
        try await api.move(file: renamed, to: subfolder)
        let inside = try await api.list(parent: subfolder)
        XCTAssertEqual(inside.map(\.name), ["renombrado.txt"])
        do {
            try await api.copy(file: CloudFile(id: subfolder + "renombrado.txt", name: "renombrado.txt", mime: "text/plain", size: nil,
                                               modified: nil, webURL: nil, isFolder: false), to: subfolder)
            XCTFail("A copy onto itself is refused")
        } catch {}

        let page = try await api.searchPage(term: "Prueba \(stamp)/gr")
        XCTAssertEqual(page.hits.map(\.file.name), ["grande.bin"])

        let folder = try XCTUnwrap(top.first { $0.id == folderID })
        try await api.trash(file: folder)
        let after = try await api.list(parent: "root")
        XCTAssertFalse(after.contains { $0.id == folderID }, "Deleting a folder removes every key under it")

        var wrong = form; wrong.secretKey = "incorrecta"
        do { _ = try await S3Authentication().signIn(wrong); XCTFail("A wrong secret does not sign in") }
        catch { XCTAssertTrue(error.localizedDescription.contains("firma"), error.localizedDescription) }
    }
}
