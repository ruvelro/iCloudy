import XCTest
@testable import iCloudy

/// The table behind «Más servidores»: every entry is checked the same way, so a new one cannot ship with an address
/// that does not parse, a link over plain HTTP or a placeholder the form never asks for.
final class ServerPresetTests: XCTestCase {
    func testEveryPresetIsWellFormed() throws {
        let presets = ServerPreset.all
        XCTAssertEqual(Set(presets.map(\.id)).count, presets.count, "Preset ids are unique")
        for preset in presets {
            XCTAssertEqual(preset.docs.scheme, "https", "\(preset.id) links its documentation over https")
            XCTAssertFalse(preset.notes.isEmpty, "\(preset.id) says what to know before connecting")
            XCTAssertEqual(preset.cloud.capabilities.signIn, .password, "\(preset.id) goes through a credentials form")
            if let port = preset.port { XCTAssertTrue((1...65535).contains(port), "\(preset.id) has a valid port") }
            if preset.s3Service != nil {
                XCTAssertEqual(preset.cloud, .s3, "\(preset.id) names an S3 service only for S3")
                XCTAssertNil(preset.address(user: "ana", values: [:]), "An S3 preset leaves the address to the S3 form")
                continue
            }
            var values: [ServerPreset.Placeholder: String] = [:]
            for placeholder in preset.extraPlaceholders { values[placeholder] = placeholder == .drive ? "123456" : "nube.ejemplo.com" }
            let address = try XCTUnwrap(preset.address(user: "u123456", values: values), "\(preset.id) builds an address")
            let components = try XCTUnwrap(URLComponents(string: address), "\(preset.id): \(address)")
            XCTAssertEqual(components.scheme, preset.cloud == .sftp ? "sftp" : "https", preset.id)
            XCTAssertFalse(components.host?.isEmpty ?? true, preset.id)
            XCTAssertFalse(address.contains("{"), "\(preset.id) leaves no placeholder behind")
            if !preset.extraPlaceholders.isEmpty {
                XCTAssertNil(preset.address(user: "u123456", values: [:]), "\(preset.id) waits for its placeholders")
            }
        }
    }

    func testAddressesComeOutAsTheServicesDocumentThem() throws {
        func preset(_ id: String) throws -> ServerPreset { try XCTUnwrap(ServerPreset.all.first { $0.id == id }) }
        XCTAssertEqual(try preset("hetzner-sftp").address(user: "u123456", values: [:]), "sftp://u123456.your-storagebox.de:23/home")
        XCTAssertEqual(try preset("hetzner-webdav").address(user: "u123456", values: [:]), "https://u123456.your-storagebox.de")
        XCTAssertEqual(try preset("koofr").address(user: "ana@example.com", values: [:]), "https://app.koofr.net/dav/Koofr")
        XCTAssertEqual(try preset("kdrive").address(user: "ana@example.com", values: [.drive: " 123456 "]), "https://123456.connect.kdrive.infomaniak.com")
        // A server pasted with its scheme and a trailing slash is the same server.
        XCTAssertEqual(try preset("seafile").address(user: "ana", values: [.server: "https://seafile.example.com/"]), "https://seafile.example.com/seafdav")
        XCTAssertEqual(try preset("nextcloud").address(user: "ana", values: [.server: "nube.example.com"]), "https://nube.example.com/remote.php/dav/files/ana")
        XCTAssertEqual(try preset("nextcloud").flavor, "nextcloud")
    }

    func testAPlaceholderCannotEscapeItsPartOfTheAddress() throws {
        let hetzner = try XCTUnwrap(ServerPreset.all.first { $0.id == "hetzner-webdav" })
        XCTAssertNil(hetzner.address(user: "evil.example.com/x?", values: [:]), "A user name cannot rewrite the host")
        XCTAssertNil(hetzner.address(user: "a b", values: [:]))
        let kdrive = try XCTUnwrap(ServerPreset.all.first { $0.id == "kdrive" })
        XCTAssertNil(kdrive.address(user: "ana", values: [.drive: "1@evil.example.com"]))
    }

    func testTheObjectStoragePresetsCoverTheServicesTheyName() {
        let services = Set(ServerPreset.all.compactMap(\.s3Service))
        XCTAssertEqual(services, [.backblaze, .wasabi, .cloudflare, .storj, .idrive])
        XCTAssertEqual(S3Service.storj.endpoint(region: S3Service.storj.defaultRegion), "https://gateway.storjshare.io")
        XCTAssertNil(S3Service.idrive.endpoint(region: "us-east-1"), "iDrive e2 hosts are per account and typed by hand")
        XCTAssertTrue(S3Service.idrive.typesEndpoint)
        XCTAssertTrue(S3Service.storj.prefersPathStyle)
    }

    @MainActor
    func testAnIDriveEndpointTypedWithoutSchemeBecomesHTTPS() throws {
        var form = S3SignIn(service: .idrive, region: "us-east-1")
        form.endpoint = "xyz1.ldn.idrivee2-11.com"
        let endpoint = try S3Authentication.endpoint(for: form, region: "us-east-1")
        XCTAssertEqual(endpoint.url?.absoluteString, "https://xyz1.ldn.idrivee2-11.com")
    }
}
