import XCTest
@testable import iCloudy

/// The small additions to the providers that were already there: addresses that no longer have to be looked up,
/// and the permission bits of an SFTP server.
final class ProviderExtrasTests: XCTestCase {
    func testTheNewS3ServicesAreOnlyAddresses() {
        XCTAssertEqual(S3Service.googleCloud.endpoint(region: "auto"), "https://storage.googleapis.com")
        XCTAssertEqual(S3Service.storj.endpoint(region: "global"), "https://gateway.storjshare.io")
        XCTAssertEqual(S3Service.storj.endpoint(region: "eu1"), "https://gateway.eu1.storjshare.io")
        XCTAssertEqual(S3Service.hetzner.endpoint(region: "hel1"), "https://hel1.your-objectstorage.com")
        XCTAssertEqual(S3Service.allCases.last, .custom, "'Otro compatible' closes the list")
        for service in [S3Service.googleCloud, .storj, .hetzner] {
            XCTAssertFalse(service.defaultRegion.isEmpty, service.rawValue)
            XCTAssertNotNil(service.endpoint(region: service.defaultRegion).flatMap(URL.init(string:))?.host, service.rawValue)
            XCTAssertTrue(service.regions.isEmpty || service.regions.contains(service.defaultRegion), service.rawValue)
        }
        XCTAssertTrue(S3Service.googleCloud.prefersPathStyle && S3Service.storj.prefersPathStyle)
        // The raw values are what accounts are stored under: the old ones must not have moved.
        XCTAssertEqual(S3Service(rawValue: "aws"), .aws); XCTAssertEqual(S3Service(rawValue: "custom"), .custom)
    }

    func testEveryKnownWebDAVServiceGivesAnAddressTheFormAccepts() throws {
        XCTAssertEqual(Set(WebDAVPreset.all.map(\.id)).count, WebDAVPreset.all.count)
        for preset in WebDAVPreset.all {
            let address = preset.address(server: "nube.ejemplo.com", user: "ana")
            XCTAssertFalse(WebDAVPreset.isIncomplete(address), preset.id)
            let components = try XCTUnwrap(URLComponents(string: address), preset.id)
            XCTAssertEqual(components.scheme, "https", preset.id)
            XCTAssertFalse((components.host ?? "").isEmpty, preset.id)
            XCTAssertFalse(preset.hint.isEmpty, preset.id)
        }
        let nextcloud = try XCTUnwrap(WebDAVPreset.all.first { $0.id == "nextcloud" })
        XCTAssertTrue(nextcloud.nextcloud)
        XCTAssertEqual(nextcloud.address(server: "nube.ejemplo.com", user: "ana"), "https://nube.ejemplo.com/remote.php/dav/files/ana")
        XCTAssertTrue(WebDAVPreset.isIncomplete(nextcloud.address(user: "ana")), "The server is still the person's to type")
        let hetzner = try XCTUnwrap(WebDAVPreset.all.first { $0.id == "hetzner" })
        XCTAssertEqual(hetzner.address(user: "u123456"), "https://u123456.your-storagebox.de")
    }

    func testPermissionBitsReadAndWriteTheWayLsAndChmodDo() {
        XCTAssertEqual(POSIXMode(bits: 0o100644).octal, "644", "The file type is not a permission")
        XCTAssertEqual(POSIXMode(bits: 0o755).symbolic, "rwxr-xr-x")
        XCTAssertEqual(POSIXMode(bits: 0o640).symbolic, "rw-r-----")
        XCTAssertEqual(POSIXMode(bits: 0o4755).symbolic, "rwsr-xr-x"); XCTAssertEqual(POSIXMode(bits: 0o4755).octal, "4755")
        XCTAssertEqual(POSIXMode(bits: 0o2644).symbolic, "rw-r-Sr--", "setgid without execute is a capital S")
        XCTAssertEqual(POSIXMode(bits: 0o1777).symbolic, "rwxrwxrwt")
        XCTAssertEqual(POSIXMode(octal: "755")?.bits, 0o755); XCTAssertEqual(POSIXMode(octal: " 0644 ")?.bits, 0o644)
        for wrong in ["", "75", "888", "rwx", "77777", "-755"] { XCTAssertNil(POSIXMode(octal: wrong), wrong) }
        var mode = POSIXMode(bits: 0o600)
        XCTAssertTrue(mode.allows(.read, .owner)); XCTAssertFalse(mode.allows(.read, .group))
        mode.set(.read, .group, true); mode.set(.read, .others, true); mode.set(.write, .owner, false)
        XCTAssertEqual(mode.octal, "444")
        mode.set(.execute, .owner, true)
        XCTAssertEqual(mode.symbolic, "r-xr--r--")
    }
}
