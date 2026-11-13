import XCTest
@testable import iCloudy

/// The permission bits of an SFTP server, read and written the way `ls -l` and `chmod` do.
final class POSIXModeTests: XCTestCase {
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
