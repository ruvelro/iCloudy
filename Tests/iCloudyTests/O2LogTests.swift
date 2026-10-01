import XCTest
@testable import iCloudy

/// The diagnostic record exists because O2 documents nothing and its sessions die for reasons that are not visible
/// from the app. That makes it worth being strict about two things: it must never write anything private, and it
/// must never grow without bound on someone's disk. It now lives inside the general diagnostic log, and these tests
/// make sure the move kept both promises and the record itself.
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

    func testEveryCallIsStillRecordedAtTheNormalLevel() throws {
        // The whole point of O2's record is that it notes calls that went well too: the sessions die in silence, and
        // what came before is what explains it. The normal level drops ordinary successes, but not these.
        let log = DiagnosticsLog(directory: nil, level: .normal)
        let line = O2Log.describe(path: "media/folder", action: "list", status: 200, error: nil,
                                  keyChanged: true, cookieNames: ["JSESSIONID", "validationKey"])
        Diagnostics.record(DiagnosticRecord(.notice, stage: DiagnosticStage.o2, provider: "o2", message: line), in: log)
        let event = try XCTUnwrap(log.events().last)
        XCTAssertEqual(event.severity, .notice)
        XCTAssertEqual(event.provider, "o2")
        XCTAssertEqual(event.message, line, "La línea llega entera: nada en ella es privado y el redactor lo sabe")
    }

    func testO2LinesGoToTheSharedLog() throws {
        let marker = "prueba \(UUID().uuidString.prefix(6))"
        O2Log.record("mantener viva · \(marker)")
        let event = try XCTUnwrap(Diagnostics.shared.events().last { $0.message?.contains(marker) == true })
        XCTAssertEqual(event.stage, DiagnosticStage.o2)
        XCTAssertEqual(event.provider, Cloud.o2.rawValue)
    }

    func testTheRecordWritesNothingWhileTheTestsRun() {
        // The suite is not sandboxed, so without this the diagnostic would pile up in the real Application Support
        // folder of whoever ran it. It did, until this was noticed. The old file is looked at, never deleted: it may
        // hold a real record of whoever runs the suite.
        let before = try? O2Log.legacyURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        O2Log.record("no debería aparecer")
        Diagnostics.shared.flush()
        XCTAssertNil(Diagnostics.shared.directory, "Durante las pruebas el registro solo vive en memoria")
        XCTAssertEqual(try? O2Log.legacyURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before,
                       "Las pruebas no dejan rastro en la carpeta de datos de nadie")
    }

    func testTheRecordStopsGrowingInsteadOfFillingTheDisk() {
        var limits = DiagnosticsLog.Limits()
        limits.memory = 400
        let log = DiagnosticsLog(directory: nil, level: .normal, limits: limits)
        for index in 0..<450 { Diagnostics.record(DiagnosticRecord(.notice, stage: DiagnosticStage.o2, message: "linea \(index)"), in: log) }
        let events = log.events()
        XCTAssertEqual(events.count, 400)
        XCTAssertEqual(events.last?.message, "linea 449", "Se conserva lo último, que es lo que interesa")
        XCTAssertFalse(events.contains { $0.message == "linea 0" }, "Y se tira lo más viejo")
    }

    func testTheOldRecordIsExportedAndDeletedWithTheRest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = folder.appendingPathComponent("o2-diagnostico.txt")
        try "2026-09-17T10:00:00Z media/folder list · HTTP 200 · cookies: JSESSIONID\n".write(to: legacy, atomically: true, encoding: .utf8)
        let log = DiagnosticsLog(directory: folder.appendingPathComponent("Diagnostics"))
        let snapshot = DiagnosticsExport.snapshot(accounts: [], transfers: [], level: .normal)
        let package = DiagnosticsExport.prepare(snapshot, log: log, legacyO2: legacy)
        XCTAssertTrue(package.legacyO2?.contains("media/folder list") == true)
        XCTAssertTrue(package.fileNames.contains(DiagnosticsExport.legacyO2Name))
        DiagnosticsExport.clear(log: log, legacyO2: legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    }
}
