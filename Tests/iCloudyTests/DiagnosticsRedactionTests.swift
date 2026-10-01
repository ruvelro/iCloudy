import XCTest
@testable import iCloudy

/// The redactor is what makes a diagnostic safe to send to somebody else. Each case here is a shape a secret really
/// takes in this app: a token in a query string, a header, Dropbox's JSON argument, an OAuth answer, an FTP password,
/// an upload session address, a server error that repeats what it was sent.
final class DiagnosticsRedactionTests: XCTestCase {
    private let normal = DiagnosticsRedactor(salt: Data("sal-de-prueba-16b".utf8), revealNames: false)
    private let detailed = DiagnosticsRedactor(salt: Data("sal-de-prueba-16b".utf8), revealNames: true)

    private func assertClean(_ text: String, of secrets: [String], file: StaticString = #filePath, line: UInt = #line) {
        for secret in secrets {
            XCTAssertFalse(text.contains(secret), "«\(secret)» sigue en: \(text)", file: file, line: line)
        }
    }

    // MARK: - URLs

    func testTokensInTheQueryStringAreDropped() {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files?access_token=ya29.SECRETO&q=name%3D'Informe.pdf'&pageSize=100")!
        for redactor in [normal, detailed] {
            let (host, path) = redactor.url(url)
            XCTAssertEqual(host, "www.googleapis.com")
            XCTAssertEqual(path, "/drive/v3/files?access_token=…&q=…&pageSize=…")
        }
    }

    func testIdentifiersInThePathBecomeAPlaceholder() {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/1AbCdEfGhIjKlMn/permissions/0987")!
        XCTAssertEqual(normal.url(url).path, "/drive/v3/files/{id}/permissions/{id}")
    }

    func testNamesInAPathOnlyAppearAtTheDetailedLevel() {
        let url = URL(string: "https://nas.local/remote.php/dav/files/ana/Documentos/N%C3%B3mina%20marzo.pdf")!
        let quiet = normal.url(url).path
        XCTAssertEqual(quiet, "/remote.php/dav/files/{id}/{id}/{id}")
        assertClean(quiet, of: ["ana", "Documentos", "Nómina", "marzo"])
        XCTAssertTrue(detailed.url(url).path.contains("Nómina marzo.pdf"), "El nivel detallado sí lleva los nombres")
    }

    func testOneDrivePathAddressingKeepsItsShapeButNotItsNames() {
        let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/root:/Fotos/playa.jpg:/content")!
        XCTAssertEqual(normal.url(url).path, "/v1.0/me/drive/root:/{id}/{id}:/content")
    }

    func testUploadSessionAddressesAreCapabilitiesEvenAtTheDetailedLevel() {
        let addresses = [
            "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=ADPycdtSESSIONCAPABILITY",
            "https://api.onedrive.com/rup/9f8e7d6c5b4a3210fedcba/eyJhbGciOiJSUzI1NiJ9.capability/upload",
            "https://contoso.sharepoint.com/personal/ana_contoso_com/_api/v2.0/drives/b!xyz/items/01ABC:/uploadSession?guid='abc'&tempauth=eyJ0eXAiOiJKV1Q",
            "https://gfs262n304.userstorage.mega.co.nz/dl/Q0FQQUJJTElUWS1NRUdB/0-1048576",
            "https://uc4a1b2c3.dl.dropboxusercontent.com/cd/0/get/CapabilityTokenDropbox123/file",
        ]
        for address in addresses {
            let rendered = detailed.render(URL(string: address)!)
            assertClean(rendered, of: ["SESSIONCAPABILITY", "eyJ", "9f8e7d6c5b4a3210fedcba", "ana_contoso_com",
                                       "Q0FQQUJJTElUWS1NRUdB", "CapabilityTokenDropbox123", "tempauth=eyJ"])
        }
    }

    func testPresignedSignaturesAreNeverKept() {
        let url = URL(string: "https://bucket.s3.eu-west-1.amazonaws.com/fotos/playa.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAFAKE%2F20261001&X-Amz-Signature=deadbeefcafe0123456789&X-Amz-Expires=900")!
        for redactor in [normal, detailed] {
            assertClean(redactor.render(url), of: ["AKIAFAKE", "deadbeefcafe0123456789", "AWS4-HMAC"])
        }
    }

    func testCredentialsInsideAnAddressAreNeverRendered() {
        let url = URL(string: "https://ana:hunter2@nas.example.org:5006/dav/Documentos")!
        for redactor in [normal, detailed] { assertClean(redactor.render(url), of: ["hunter2", "ana:"]) }
        assertClean(normal.text("No se pudo conectar con ftp://pepe:clave-secreta@ftp.example.org/incoming"),
                    of: ["clave-secreta", "pepe"])
    }

    // MARK: - Headers

    func testAuthorizationHeadersAreMaskedWhole() {
        XCTAssertEqual(normal.header(name: "Authorization", value: "Bearer ya29.a0AfH6SMBfaketoken"), DiagnosticsRedactor.mask)
        XCTAssertEqual(detailed.header(name: "authorization", value: "Basic YW5hOmh1bnRlcjI="), DiagnosticsRedactor.mask)
        XCTAssertEqual(normal.header(name: "Cookie", value: "JSESSIONID=abc; validationKey=def"), DiagnosticsRedactor.mask)
        XCTAssertEqual(normal.header(name: "X-Custom-Session-Token", value: "abc"), DiagnosticsRedactor.mask)
        XCTAssertEqual(normal.header(name: "Content-Type", value: "application/json"), "application/json")
    }

    func testBearerTokensInFreeTextAreMasked() {
        let texts = [
            "Authorization: Bearer ya29.a0AfH6SMBfaketoken12345",
            "request failed: bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.c2lnbmF0dXJl was rejected",
            "Set-Cookie: JSESSIONID=0123456789ABCDEF; Path=/; Secure",
            "Proxy-Authorization: Basic YW5hOmh1bnRlcjI=",
        ]
        for text in texts {
            for redactor in [normal, detailed] {
                assertClean(redactor.text(text), of: ["ya29", "eyJ", "0123456789ABCDEF", "YW5hOmh1bnRlcjI"])
            }
        }
    }

    func testDropboxArgumentsLoseTheirPathsAndCursors() {
        let argument = #"{"path":"/Personal/Nóminas/2025.pdf","mode":"overwrite","autorename":false}"#
        let quiet = normal.header(name: "Dropbox-API-Arg", value: argument)
        XCTAssertTrue(quiet.contains("overwrite"), "Los parámetros del protocolo se quedan")
        assertClean(quiet, of: ["Nóminas", "2025.pdf", "Personal"])
        XCTAssertTrue(detailed.header(name: "Dropbox-API-Arg", value: argument).contains("Nóminas"))

        let append = #"{"cursor":{"session_id":"AAEfakeSessionIdentifier0123","offset":4194304},"close":false}"#
        for redactor in [normal, detailed] {
            let cleaned = redactor.header(name: "Dropbox-API-Arg", value: append)
            assertClean(cleaned, of: ["AAEfakeSessionIdentifier0123"])
        }
        assertClean(normal.text("Dropbox-API-Arg: " + argument), of: ["Nóminas"])
    }

    // MARK: - OAuth

    func testOAuthAnswersKeepTheirShapeAndLoseTheirTokens() {
        let answer = #"{"access_token":"ya29.a0AfH6SMBfake","refresh_token":"1//0gLxFAKErefresh","expires_in":3599,"token_type":"Bearer","id_token":"eyJhbGciOiJSUzI1NiJ9.e30.sig","scope":"https://www.googleapis.com/auth/drive"}"#
        for redactor in [normal, detailed] {
            let cleaned = redactor.text(answer)
            assertClean(cleaned, of: ["ya29", "1//0gLx", "FAKErefresh", "eyJ"])
            XCTAssertTrue(cleaned.contains("3599"))
        }
        let refusal = normal.text(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)
        XCTAssertTrue(refusal.contains("invalid_grant"), "El código del error es justo lo que hace falta ver")
    }

    func testFormBodiesLoseTheirSecrets() {
        let body = "client_id=123.apps.googleusercontent.com&client_secret=GOCSPX-fakeSecret42&grant_type=refresh_token&refresh_token=1//0gFAKErefresh&code_verifier=dBjftJeZ4CVP"
        for redactor in [normal, detailed] {
            assertClean(redactor.text(body), of: ["GOCSPX", "1//0gFAKE", "dBjftJeZ4CVP"])
        }
    }

    func testAJSONBodyCutShortStillLosesItsTokens() {
        // A bounded prefix of an answer is no longer valid JSON, so the pairs have to be found inside the text.
        let truncated = #"{"access_token":"ya29.cutShortToken","refresh_token":"1//cutShort","expires_in":35"#
        assertClean(normal.text(truncated), of: ["cutShortToken", "1//cutShort"])
    }

    // MARK: - FTP and SFTP

    func testFTPCredentialsNeverAppear() {
        for redactor in [normal, detailed] {
            XCTAssertEqual(redactor.command("PASS hunter2"), "PASS " + DiagnosticsRedactor.mask)
            XCTAssertEqual(redactor.command("USER ana.garcia"), "USER " + DiagnosticsRedactor.mask)
            XCTAssertEqual(redactor.command("ACCT cuenta-secreta"), "ACCT " + DiagnosticsRedactor.mask)
            XCTAssertEqual(redactor.command("AUTH TLS"), "AUTH TLS", "Los nombres del protocolo no son secretos")
            XCTAssertEqual(redactor.command("PASV"), "PASV")
            assertClean(redactor.text("530 Login incorrect. Sent: USER ana PASS hunter2"), of: ["hunter2", "USER ana"])
        }
    }

    func testFTPArgumentsOnlyAtTheDetailedLevel() {
        XCTAssertEqual(normal.command("STOR /home/ana/nomina.pdf"), "STOR " + DiagnosticsRedactor.hiddenPath)
        XCTAssertEqual(normal.command("CWD Documentos"), "CWD " + DiagnosticsRedactor.hiddenPath)
        XCTAssertTrue(detailed.command("STOR /home/ana/nomina.pdf").contains("nomina.pdf"))
    }

    func testSFTPRequestsAreVerbsAndPathsFollowTheLevel() {
        let record = DiagnosticRecord(.error, stage: DiagnosticStage.sftp, provider: "sftp", url: URL(string: "sftp://nas.local"),
                                      status: 2, command: "OPEN /home/ana/secreto.txt")
        let quiet = DiagnosticsLog.event(from: record, at: Date(), redactor: normal)
        XCTAssertEqual(quiet.message, "OPEN " + DiagnosticsRedactor.hiddenPath)
        XCTAssertEqual(quiet.host, "nas.local")
        XCTAssertTrue(DiagnosticsLog.event(from: record, at: Date(), redactor: detailed).message?.contains("secreto.txt") == true)
        XCTAssertEqual(Diagnostics.sftpVerb(18), "RENAME")
    }

    // MARK: - Server answers and messages

    func testErrorBodiesThatEchoTokensAreCleaned() {
        let page = #"<html><body>Invalid token ya29.A0ARrdaMabcdefghijklmnop1234 for https://graph.microsoft.com/v1.0/me/drive/items/01ABC?access_token=xyzSECRET</body></html>"#
        for redactor in [normal, detailed] {
            let cleaned = redactor.text(page)
            assertClean(cleaned, of: ["ya29", "xyzSECRET", "A0ARrdaM"])
            XCTAssertTrue(cleaned.contains("graph.microsoft.com"), "El servidor sí se ve: es lo que dice adónde se fue")
        }
        let echoed = normal.text("Bad request: validationKey=4f9a8b7c6d5e4f3a2b1c; sid=abcdef123456")
        assertClean(echoed, of: ["4f9a8b7c6d5e4f3a2b1c", "abcdef123456"])
    }

    func testEmailAddressesBecomeAStableHash() {
        let first = normal.text("La cuenta ana.garcia@example.com no existe")
        let second = detailed.text("Otra vez ana.garcia@example.com")
        assertClean(first + second, of: ["ana.garcia", "example.com"])
        XCTAssertTrue(first.contains(normal.email("ana.garcia@example.com")))
        XCTAssertEqual(normal.email("Ana.Garcia@example.com"), normal.email("ana.garcia@example.com"))
        XCTAssertNotEqual(normal.account("google:ana@example.com"), DiagnosticsRedactor(salt: Data("otra-sal-distinta".utf8), revealNames: false).account("google:ana@example.com"),
                          "Con otra sal el resumen es otro: no se puede comparar con listas de direcciones")
        XCTAssertFalse(normal.account("google:ana@example.com").contains("ana"))
    }

    func testNamesInMessagesAreHiddenAtTheNormalLevel() {
        let message = "No se pudo subir «Nómina marzo.pdf»: ya existe en /Users/ana/Documentos/Trabajo y \"Presupuesto 2026.xlsx\" está bloqueado; revisa informe-final.docx"
        assertClean(normal.text(message), of: ["Nómina", "/Users/ana", "Documentos", "Presupuesto", "informe-final"])
        let shown = detailed.text(message)
        XCTAssertTrue(shown.contains("Nómina marzo.pdf") && shown.contains("informe-final.docx"))
    }

    func testProtocolWordsSurviveSoTheRecordStaysUseful() {
        let line = O2Log.describe(path: "media/folder", action: "list", status: 401, error: "SEC-1003",
                                  keyChanged: true, cookieNames: ["JSESSIONID", "validationKey"])
        XCTAssertEqual(normal.text(line), line)
        XCTAssertEqual(normal.text("NSURLErrorDomain -1001 tras 30 s en g.api.mega.co.nz"), "NSURLErrorDomain -1001 tras 30 s en g.api.mega.co.nz")
        XCTAssertEqual(normal.text("path/not_found/"), DiagnosticsRedactor.hiddenPath, "Lo que no es vocabulario del protocolo se oculta")
    }

    func testOrdinaryMessagesPassUntouched() {
        // Every rule compiles, or the redactor would hide the whole text: it fails closed. This is also what makes
        // the log readable at all.
        for message in ["El servicio devolvió HTTP 503. Inténtalo de nuevo más tarde.",
                        "The operation couldn’t be completed. (NSURLErrorDomain error -1001.)",
                        "token renovado", "can't open it's own file", "Content-Type: application/json; charset=utf-8",
                        "renovación silenciosa · acceso restaurado: 3 de 5", "a=us0 · petición sin respuesta"] {
            XCTAssertEqual(normal.text(message), message)
        }
    }

    func testLongOpaqueStringsAreTreatedAsSecrets() {
        XCTAssertTrue(DiagnosticsRedactor.looksSecret("AAEfakeSessionIdentifier0123"))
        XCTAssertTrue(DiagnosticsRedactor.looksSecret("eyJ0eXAiOiJKV1Q"))
        XCTAssertFalse(DiagnosticsRedactor.looksSecret("permissions"))
        XCTAssertFalse(DiagnosticsRedactor.looksSecret("get-storage-space"))
        assertClean(detailed.text("session 7f3a9c2e1b4d6f8a0c2e4b6d8f0a1c3e expired"), of: ["7f3a9c2e1b4d6f8a0c2e4b6d8f0a1c3e"])
    }
}
