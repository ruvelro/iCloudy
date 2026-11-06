import XCTest
import CryptoKit
@testable import iCloudy

/// The SSH client at the edges of the protocol, against `FakeSSHServer`: strict key exchange, the first-connection
/// host key question, keyboard-interactive, a rekey with data in flight, and the pin kept in the Keychain.
final class SSHHardeningTests: XCTestCase {
    private var servers: [FakeSSHServer] = []
    override func tearDown() {
        for server in servers { server.stop() }
        servers = []
        super.tearDown()
    }
    private func server(_ configure: (inout FakeSSHServer.Script) -> Void = { _ in }) throws -> FakeSSHServer {
        var script = FakeSSHServer.Script()
        configure(&script)
        let server = try FakeSSHServer(script)
        servers.append(server)
        return server
    }
    private func transport(_ server: FakeSSHServer, password: String = "secreta", expected: Data? = nil,
                           approve: (@Sendable (Data) async -> Bool)? = { _ in true }) -> SSHTransport {
        SSHTransport(host: "127.0.0.1", port: server.port, user: "ana", password: password, expectedHostKey: expected,
                     approveHostKey: approve, timeout: 10)
    }

    // MARK: - Strict key exchange

    func testStrictKexIsAnnouncedAgreedAndTheSequenceNumbersStartAgain() async throws {
        let fake = try server()
        let ssh = transport(fake)
        // The server resets its counters after NEWKEYS and MACs every packet with them: a client that kept counting
        // would fail its very next packet.
        try await ssh.connect()
        let strict = await ssh.strictKex
        XCTAssertTrue(strict)
        XCTAssertTrue(fake.clientKexAlgorithms.contains(SSHTransport.strictKexClient), "El cliente lo anuncia en su primer KEXINIT")
        XCTAssertTrue(fake.waitFor("channel-open"))
        await ssh.close()
    }

    func testWithoutStrictKexTheCountersRunOnAndAStrayIgnoreIsTolerated() async throws {
        let fake = try server { $0.strict = false; $0.junkBeforeKexInit = true }
        let ssh = transport(fake)
        try await ssh.connect()
        let strict = await ssh.strictKex
        XCTAssertFalse(strict)
        await ssh.close()
    }

    func testStrictKexRefusesAPacketBeforeTheServersKexInit() async throws {
        let fake = try server { $0.junkBeforeKexInit = true }
        do { try await transport(fake).connect(); XCTFail("Un IGNORE antes del KEXINIT es el ataque Terrapin") }
        catch { XCTAssertTrue(error is SSHTransport.StrictKexViolation, "\(error)") }
        XCTAssertFalse(fake.events.contains { $0.hasPrefix("recv:50") || $0.hasPrefix("kex:50") }, "No se llega a iniciar sesión")
    }

    func testStrictKexRefusesAnyOtherMessageDuringTheFirstExchange() async throws {
        let fake = try server { $0.junkDuringKex = true }
        do { try await transport(fake).connect(); XCTFail("Un IGNORE en mitad del intercambio estricto se rechaza") }
        catch let error as SSHTransport.StrictKexViolation { XCTAssertEqual(error.type, SSHMessage.ignore) }
    }

    // MARK: - Rekey

    func testNoWindowAdjustmentLeavesDuringARekey() async throws {
        // More than half the client's window, so it wants to widen it while the exchange is still running.
        let amount = SSHTransport.localWindow / 2 + 200_000
        let fake = try server { $0.rekeyWithData = amount }
        let ssh = transport(fake)
        try await ssh.connect()
        let data = try await ssh.read(atLeast: amount)
        XCTAssertEqual(data.count, amount)
        XCTAssertTrue(fake.waitFor("rekey-done"))
        XCTAssertTrue(fake.waitFor("recv:93"), "La ampliación de ventana sale después de NEWKEYS: \(fake.events.suffix(8))")
        XCTAssertFalse(fake.events.contains("kex:93"), "Nada que no sea del intercambio durante el intercambio")
        await ssh.close()
    }

    func testOnlyKeyExchangeAndGenericMessagesMayLeaveDuringAnExchange() {
        for allowed in [SSHMessage.ignore, SSHMessage.debug, SSHMessage.disconnect, SSHMessage.kexInit, SSHMessage.newKeys, SSHMessage.kexECDHInit] {
            XCTAssertTrue(SSHTransport.allowedDuringKeyExchange(allowed), "\(allowed)")
        }
        for held in [SSHMessage.serviceRequest, SSHMessage.serviceAccept, SSHMessage.userauthRequest, SSHMessage.channelWindowAdjust,
                     SSHMessage.channelData, SSHMessage.requestFailure, SSHMessage.channelClose] {
            XCTAssertFalse(SSHTransport.allowedDuringKeyExchange(held), "\(held)")
        }
    }

    // MARK: - The host key on first contact

    func testAnUnknownHostKeyIsShownBeforeAnyCredentialAndCanBeRefused() async throws {
        let fake = try server()
        let shown = Box<Data?>(nil)
        let ssh = transport(fake, approve: { blob in shown.value = blob; return false })
        do { try await ssh.connect(); XCTFail("Sin confirmar la huella no se conecta") }
        catch let error as SSHTransport.HostKeyNotTrusted { XCTAssertEqual(error.offered, SSHHostKey.fingerprint(fake.hostKeyBlob)) }
        XCTAssertEqual(shown.value, fake.hostKeyBlob, "Se pregunta por la clave que el servidor demostró tener")
        XCTAssertTrue(fake.waitFor("closed"))
        XCTAssertFalse(fake.events.contains { $0.hasSuffix(":5") || $0.hasSuffix(":50") }, "Ni la petición de servicio ni la contraseña salen")
    }

    func testAnUnknownHostKeyWithNobodyToAskIsRefused() async throws {
        let fake = try server()
        do { try await transport(fake, approve: nil).connect(); XCTFail("Una clave desconocida nunca se acepta en silencio") }
        catch { XCTAssertTrue(error is SSHTransport.HostKeyNotTrusted, "\(error)") }
    }

    func testAKnownHostKeyIsNotAskedAboutAndAChangedOneIsRefused() async throws {
        let fake = try server()
        let ssh = transport(fake, expected: fake.hostKeyBlob, approve: { _ in XCTFail("Ya se conocía"); return false })
        try await ssh.connect()
        await ssh.close()

        let other = try server()
        do { try await transport(other, expected: fake.hostKeyBlob, approve: { _ in true }).connect(); XCTFail("Otra clave se rechaza") }
        catch let error as SSHTransport.HostKeyChanged { XCTAssertEqual(error.offered, SSHHostKey.fingerprint(other.hostKeyBlob)) }
    }

    // MARK: - The pin in the Keychain

    @MainActor func testSigningInAsksAboutTheKeyAndKeepsThePinInTheKeychainOnly() async throws {
        let fake = try server { $0.sftp = true }
        let asked = Box<[LoginPrompts.HostKeyQuestion]>([])
        let (account, credential) = try await SFTPAuthentication().signInSFTP(
            server: "sftp://127.0.0.1:\(fake.port)/base", username: "ana", password: "secreta",
            trustHostKey: { question in asked.value = asked.value + [question]; return true })
        XCTAssertEqual(asked.value.map(\.fingerprint), [SSHHostKey.fingerprint(fake.hostKeyBlob)])
        XCTAssertEqual(asked.value.first?.server, "127.0.0.1:\(fake.port)")
        XCTAssertEqual(asked.value.first?.keyType, "ssh-ed25519")
        XCTAssertEqual(credential.hostKey, fake.hostKeyBlob.base64EncodedString(), "El pin va al Llavero")
        XCTAssertNil(account.options["hostKey"], "Y no a accounts.json")
        XCTAssertEqual(account.options["hostKeyFingerprint"], SSHHostKey.fingerprint(fake.hostKeyBlob))
    }

    @MainActor func testAnOlderAccountsPinMovesToTheKeychainAndTheKeychainWins() throws {
        let legacy = Data(repeating: 3, count: 51), keychain = Data(repeating: 4, count: 51)
        let account = Account(id: "sftp:nas:22/#ana", cloud: .sftp, name: "nas", email: "ana@nas", clientID: "", clientSecret: nil,
                              serverURL: "sftp://nas/", bookmark: nil, options: ["hostKey": legacy.base64EncodedString()])
        let store = MemoryCredentials()
        store.stored[account.credentialKey] = Credential(accessToken: "x", refreshToken: "", expires: .distantFuture)
        let provider = try XCTUnwrap(CloudAPI(account: account, credentials: store).provider as? SFTPProvider)
        XCTAssertEqual(provider.pinnedHostKey(store.stored[account.credentialKey]), legacy)
        XCTAssertEqual(store.stored[account.credentialKey]?.hostKey, legacy.base64EncodedString(), "Se mueve en la primera lectura")

        // From then on what the account file says no longer matters.
        store.stored[account.credentialKey]?.hostKey = keychain.base64EncodedString()
        XCTAssertEqual(provider.pinnedHostKey(store.stored[account.credentialKey]), keychain)
    }

    // MARK: - keyboard-interactive

    func testKeyboardInteractiveAnswersAHiddenPasswordPrompt() async throws {
        let fake = try server { $0.methods = ["keyboard-interactive"]; $0.interactiveRounds = [[("Password: ", false)]] }
        let ssh = transport(fake)
        try await ssh.connect()
        XCTAssertEqual(fake.interactiveAnswers, [["secreta"]])
        await ssh.close()
    }

    func testKeyboardInteractiveNeverSendsThePasswordToASecondFactorPrompt() async throws {
        let fake = try server { $0.methods = ["keyboard-interactive"]; $0.interactiveRounds = [[("Password: ", false)], [("Verification code: ", false)]] }
        do { try await transport(fake).connect(); XCTFail("Un segundo factor no se contesta con la contraseña") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Verification code"), error.localizedDescription) }
        XCTAssertEqual(fake.interactiveAnswers, [["secreta"]], "La contraseña solo se envió al primer aviso")
    }

    func testKeyboardInteractiveDoesNotRepeatThePasswordWhenAskedAgain() async throws {
        let fake = try server { $0.methods = ["keyboard-interactive"]; $0.interactiveRounds = [[("Password:", false)], [("Password:", false)]] }
        do { try await transport(fake).connect(); XCTFail("Un segundo aviso de contraseña es que la primera no valía") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rechazó el usuario o la contraseña"), error.localizedDescription) }
        XCTAssertEqual(fake.interactiveAnswers.count, 1)
    }

    func testARefusedPasswordIsNotTriedAgainThroughKeyboardInteractive() async throws {
        let fake = try server { $0.methods = ["password", "keyboard-interactive"]; $0.interactiveRounds = [[("Password: ", false)]] }
        do { try await transport(fake, password: "mala").connect(); XCTFail("Una contraseña incorrecta no inicia sesión") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rechazó el usuario o la contraseña"), error.localizedDescription) }
        XCTAssertFalse(fake.events.contains("auth:keyboard-interactive"), "Un segundo intento solo suma otro fallo a la cuenta")
        XCTAssertTrue(fake.interactiveAnswers.isEmpty)
    }

    func testPasswordPromptsAreRecognisedOnlyWhenHidden() {
        XCTAssertTrue(SSHTransport.isPasswordPrompt("Password: ", echo: false))
        XCTAssertTrue(SSHTransport.isPasswordPrompt("(ana@nas) Contraseña:", echo: false))
        XCTAssertTrue(SSHTransport.isPasswordPrompt("Passwort:", echo: false))
        XCTAssertFalse(SSHTransport.isPasswordPrompt("Password: ", echo: true), "Nadie muestra una contraseña al escribirla")
        XCTAssertFalse(SSHTransport.isPasswordPrompt("Verification code: ", echo: false))
        XCTAssertFalse(SSHTransport.isPasswordPrompt("One-time token:", echo: false))
    }

    // MARK: - Packets and host keys

    func testAPacketWithLessThanFourBytesOfPaddingIsRefused() throws {
        let cipher = SSHPacketCipher()
        func packet(padding: Int) -> Data {
            var body = SSHWriter(); body.byte(UInt8(padding)); body.byte(SSHMessage.ignore)
            body.raw(Data(repeating: 0, count: padding))
            var whole = SSHWriter(); whole.uint32(UInt32(body.data.count)); whole.raw(body.data)
            return whole.data
        }
        for (padding, valid) in [(3, false), (4, true)] {
            let bytes = packet(padding: padding)
            let (length, head) = try cipher.packetLength(head: bytes.prefix(4))
            XCTAssertEqual(length, bytes.count - 4)
            if valid { XCTAssertEqual(try cipher.open(head: head, rest: bytes.dropFirst(4), trailer: Data()), Data([SSHMessage.ignore])) }
            else { XCTAssertThrowsError(try cipher.open(head: head, rest: bytes.dropFirst(4), trailer: Data())) }
        }
    }

    func testRSAHostKeysUnder2048BitsAreRefused() throws {
        func blob(bits: Int) -> Data {
            var modulus = Data([0x80]) + Data(repeating: 0x5A, count: bits / 8 - 2) + Data([0x01])
            modulus[modulus.startIndex] = 0xC1
            var writer = SSHWriter(); writer.string("ssh-rsa"); writer.mpint(Data([0x01, 0x00, 0x01])); writer.mpint(modulus)
            return writer.data
        }
        var signature = SSHWriter(); signature.string("rsa-sha2-256"); signature.string(Data(repeating: 1, count: 128))
        XCTAssertThrowsError(try SSHHostKey.verify(blob: blob(bits: 1024), signature: signature.data, message: Data("h".utf8))) {
            // The number is formatted for the locale: "2048" in Spanish, "2,048" in English.
            XCTAssertTrue($0.localizedDescription.filter(\.isNumber).contains("2048"), $0.localizedDescription)
        }
        XCTAssertEqual(SSHHostKey.rsaBits(Data([0x00, 0x01, 0xFF])), 9)
        XCTAssertEqual(SSHHostKey.rsaBits(Data(repeating: 0xFF, count: 256)), 2048)
    }

    // MARK: - RSA private keys through Security.framework

    func testTheReducedCRTExponentsAreComputedExactly() {
        XCTAssertEqual(SSHPrivateKey.remainder(Data([0x01, 0x00]), Data([0x07])), Data([0x04]), "256 mod 7")
        XCTAssertEqual(SSHPrivateKey.remainder(Data([0x06]), Data([0x07])), Data([0x06]))
        XCTAssertEqual(SSHPrivateKey.remainder(Data([0x0E]), Data([0x07])), Data(), "Un múltiplo deja resto cero")
        // 2^64 + 5 mod (2^32 + 1) = (2^32)^2 + 5 ≡ (-1)^2 + 5 = 6.
        let a = Data([0x01] + [UInt8](repeating: 0, count: 7) + [0x05]), m = Data([0x01, 0x00, 0x00, 0x00, 0x01])
        XCTAssertEqual(SSHPrivateKey.remainder(a, m), Data([0x06]))
        XCTAssertEqual(SSHPrivateKey.derInteger(Data()), Data([0x02, 0x01, 0x00]))
        XCTAssertEqual(SSHPrivateKey.derInteger(Data([0x80])), Data([0x02, 0x02, 0x00, 0x80]))
    }

    func testAnRSAClientKeySignsThroughSecurityAndTheServerCanVerifyIt() throws {
        // A key made by Security itself, written as OpenSSH would store it, then read back and used.
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let secKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(secKey, nil) as Data?)
        let fields = try Self.derIntegers(der)   // 0, n, e, d, p, q, dp, dq, qi
        var publicBlob = SSHWriter(); publicBlob.string("ssh-rsa"); publicBlob.mpint(fields[2]); publicBlob.mpint(fields[1])
        XCTAssertEqual(SSHPrivateKey.pkcs1(n: fields[1], e: fields[2], d: fields[3], p: fields[4], q: fields[5], qInverse: fields[8]),
                       der, "La misma clave PKCS#1 que escribe Security, parámetros CRT incluidos")

        let signed = Data("firma".utf8)
        let signature = try SSHPrivateKey.rsaSHA256(signed, der: der)
        var wrapped = SSHWriter(); wrapped.string("rsa-sha2-256"); wrapped.string(signature)
        XCTAssertTrue(try SSHHostKey.verify(blob: publicBlob.data, signature: wrapped.data, message: signed))
    }

    /// The INTEGERs of a DER SEQUENCE, as magnitudes.
    private static func derIntegers(_ der: Data) throws -> [Data] {
        var bytes = Array(der), index = 0
        func length() -> Int {
            let first = Int(bytes[index]); index += 1
            guard first & 0x80 != 0 else { return first }
            var value = 0
            for _ in 0..<(first & 0x7F) { value = value << 8 | Int(bytes[index]); index += 1 }
            return value
        }
        guard bytes[index] == 0x30 else { throw SSHReader.Malformed() }
        index += 1; _ = length()
        var result: [Data] = []
        while index < bytes.count {
            guard bytes[index] == 0x02 else { throw SSHReader.Malformed() }
            index += 1
            let count = length()
            result.append(Data(bytes[index..<index + count].drop { $0 == 0 }))
            index += count
        }
        bytes = []
        return result
    }
}

