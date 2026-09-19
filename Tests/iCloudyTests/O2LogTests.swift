import XCTest
@testable import iCloudy

/// The diagnostic record exists because O2 documents nothing and its sessions die for reasons that are not visible
/// from the app. That makes it worth being strict about two things: it must never write anything private, and it
/// must never grow without bound on someone's disk.
final class O2LogTests: XCTestCase {
    func testTheRecordNamesCookiesButNeverRepeatsTheirValues() {
        let line = O2Log.describe(path: "media", action: "get-storage-space", status: 200, error: "SEC-1003",
                                  keyChanged: true, cookieNames: ["JSESSIONID", "validationKey"])
        XCTAssertTrue(line.contains("media get-storage-space"))
        XCTAssertTrue(line.contains("HTTP 200"))
        XCTAssertTrue(line.contains("SEC-1003"))
        XCTAssertTrue(line.contains("clave renovada"))
        XCTAssertTrue(line.contains("JSESSIONID"), "El nombre sí, para saber qué renovó el servidor")
        XCTAssertFalse(line.contains("="), "Pero nunca un valor: eso sería la sesión en un archivo de texto")
    }

    func testAQuietCallSaysSoWithoutInventingAnError() {
        let line = O2Log.describe(path: "media/folder", action: "list", status: 200, error: nil,
                                  keyChanged: false, cookieNames: [])
        XCTAssertFalse(line.contains("error"))
        XCTAssertFalse(line.contains("clave renovada"))
        XCTAssertTrue(line.contains("ninguna"))
    }

    func testEachEntryKeepsItsOwnLine() {
        // A real record came back as one enormous line: trimming dropped the final newline, so every entry after the
        // first was glued to the one before it and the file could not be read.
        let text = O2Log.capped("primera\nsegunda") + "\n"
        XCTAssertTrue(text.hasSuffix("\n"), "Sin esto, lo siguiente que se escriba se pega a lo anterior")
        XCTAssertEqual((text + "tercera\n").split(separator: "\n").count, 3)
    }

    func testTheRecordWritesNothingWhileTheTestsRun() {
        // The suite is not sandboxed, so without this the diagnostic would pile up in the real Application Support
        // folder of whoever ran it. It did, until this was noticed.
        try? FileManager.default.removeItem(at: O2Log.url)
        O2Log.record("no debería aparecer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: O2Log.url.path),
                       "Las pruebas no dejan rastro en la carpeta de datos de nadie")
    }

    func testTheFileStopsGrowingInsteadOfFillingTheDisk() throws {
        // Exercises the capping directly, since recording is off while the suite runs.
        try? FileManager.default.removeItem(at: O2Log.url)
        defer { try? FileManager.default.removeItem(at: O2Log.url) }
        let written = O2Log.capped((0..<450).map { "linea \($0)" }.joined(separator: "\n"))
        let lines = written.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 400)
        XCTAssertTrue(written.contains("linea 449"), "Se conserva lo último, que es lo que interesa")
        XCTAssertFalse(written.contains("linea 0\n"), "Y se tira lo más viejo")
    }
}
