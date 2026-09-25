import XCTest
import CryptoKit
@testable import iCloudy

/// The SSH transport is built from system primitives, so what is worth testing is the plumbing around them: the wire
/// encoding, the packet layout under each cipher, the host key checks and the key schedule. The whole stack is then
/// run against a real server when `ICLOUDY_SFTP_URL` names one (see docs/FTP.md for how to start the stand-in).
final class SFTPTests: XCTestCase {

    // MARK: - Wire encoding

    func testWireEncodingRoundTripsEveryShape() throws {
        var writer = SSHWriter()
        writer.byte(7); writer.bool(true); writer.uint32(0xDEADBEEF); writer.uint64(1 << 40)
        writer.string("hola"); writer.nameList(["a", "b-c"]); writer.nameList([])
        writer.mpint(Data([0x80, 0x01]))            // high bit set: needs a sign byte
        writer.mpint(Data([0x00, 0x00, 0x7F]))      // leading zeros are dropped
        var reader = SSHReader(writer.data)
        XCTAssertEqual(try reader.byte(), 7)
        XCTAssertTrue(try reader.bool())
        XCTAssertEqual(try reader.uint32(), 0xDEADBEEF)
        XCTAssertEqual(try reader.uint64(), 1 << 40)
        XCTAssertEqual(try reader.text(), "hola")
        XCTAssertEqual(try reader.nameList(), ["a", "b-c"])
        XCTAssertEqual(try reader.nameList(), [])
        XCTAssertEqual(try reader.mpint(), Data([0x80, 0x01]))
        XCTAssertEqual(try reader.mpint(), Data([0x7F]))
        XCTAssertTrue(reader.isAtEnd)
        XCTAssertThrowsError(try reader.uint32(), "Leer más allá del final es un mensaje malformado")

        var signed = SSHWriter(); signed.mpint(Data([0x80]))
        XCTAssertEqual(Array(signed.data), [0, 0, 0, 2, 0x00, 0x80], "RFC 4251: 0x80 se codifica como 00 80")
    }

    // MARK: - Packet layout

    private func pair(cipher: String, mac: String) throws -> (SSHPacketCipher, SSHPacketCipher) {
        let key = Data((1...32).map(UInt8.init)).prefix(SSHPacketCipher.keyLength(cipher))
        let iv = Data((100...131).map(UInt8.init)).prefix(SSHPacketCipher.ivLength(cipher))
        let macKey = Data(repeating: 9, count: 32)
        return (try SSHPacketCipher.build(cipher: cipher, mac: mac, key: Data(key), iv: Data(iv), macKey: macKey),
                try SSHPacketCipher.build(cipher: cipher, mac: mac, key: Data(key), iv: Data(iv), macKey: macKey))
    }
    /// Reads a packet the way the transport does: head, length, rest, trailer.
    private func open(_ wire: Data, with cipher: SSHPacketCipher) throws -> Data {
        let head = Data(wire.prefix(cipher.headLength))
        let (length, kept) = try cipher.packetLength(head: head)
        let restCount = 4 + length - kept.count
        let rest = Data(wire[head.count..<head.count + restCount])
        let trailer = Data(wire[(head.count + restCount)...])
        XCTAssertEqual(trailer.count, cipher.trailerLength)
        return try cipher.open(head: kept, rest: rest, trailer: trailer)
    }

    func testEveryCipherRoundTripsPacketsOfAnySizeAndKeepsThemAligned() throws {
        for (cipher, mac) in [("aes256-gcm@openssh.com", "hmac-sha2-256"), ("aes128-gcm@openssh.com", "hmac-sha2-256"),
                              ("aes256-ctr", "hmac-sha2-256-etm@openssh.com"), ("aes128-ctr", "hmac-sha2-256")] {
            let (sender, receiver) = try pair(cipher: cipher, mac: mac)
            for size in [0, 1, 5, 11, 12, 15, 16, 17, 100, 3000] {
                let payload = Data((0..<size).map { UInt8($0 % 251) })
                let wire = try sender.seal(payload)
                // The encrypted part is block aligned; with a length in the clear that part starts after the length.
                let clearLength = cipher.contains("gcm") || mac.contains("etm")
                let aligned = (wire.count - receiver.trailerLength - (clearLength ? 4 : 0)) % 16
                XCTAssertEqual(aligned, 0, "\(cipher)/\(mac) con \(size) bytes no queda alineado")
                XCTAssertEqual(try open(wire, with: receiver), payload, "\(cipher)/\(mac) con \(size) bytes")
            }
            XCTAssertEqual(sender.sequence, 10); XCTAssertEqual(receiver.sequence, 10)
        }
        let (plainOut, plainIn) = (SSHPacketCipher(), SSHPacketCipher())
        XCTAssertEqual(try open(try plainOut.seal(Data("kexinit".utf8)), with: plainIn), Data("kexinit".utf8))
    }

    func testATamperedPacketIsRefusedUnderEveryCipher() throws {
        for (cipher, mac) in [("aes256-gcm@openssh.com", "hmac-sha2-256"), ("aes256-ctr", "hmac-sha2-256-etm@openssh.com"), ("aes128-ctr", "hmac-sha2-256")] {
            let (sender, receiver) = try pair(cipher: cipher, mac: mac)
            var wire = try sender.seal(Data(repeating: 0x41, count: 40))
            wire[wire.count - 20] ^= 0x01
            XCTAssertThrowsError(try open(wire, with: receiver), "\(cipher)/\(mac) aceptó un paquete alterado")
        }
    }

    func testTheGCMNonceCountsPacketsSoNoTwoShareOne() throws {
        let (sender, receiver) = try pair(cipher: "aes128-gcm@openssh.com", mac: "")
        let first = try sender.seal(Data("uno".utf8)), second = try sender.seal(Data("dos".utf8))
        XCTAssertNotEqual(first.dropFirst(4).prefix(3), second.dropFirst(4).prefix(3), "Con el mismo nonce el mismo prefijo daría el mismo cifrado")
        XCTAssertEqual(try open(first, with: receiver), Data("uno".utf8))
        XCTAssertEqual(try open(second, with: receiver), Data("dos".utf8))
    }

    // MARK: - Host keys and key schedule

    func testAnEd25519HostKeyIsVerifiedAgainstTheExchangeHashAndNamedLikeOpenSSH() throws {
        let key = Curve25519.Signing.PrivateKey()
        var blob = SSHWriter(); blob.string("ssh-ed25519"); blob.string(key.publicKey.rawRepresentation)
        let hash = Data(SHA256.hash(data: Data("H".utf8)))
        var signature = SSHWriter(); signature.string("ssh-ed25519"); signature.string(try key.signature(for: hash))
        XCTAssertTrue(try SSHHostKey.verify(blob: blob.data, signature: signature.data, message: hash))
        XCTAssertFalse(try SSHHostKey.verify(blob: blob.data, signature: signature.data, message: Data("otro".utf8)))
        XCTAssertEqual(SSHHostKey.type(of: blob.data), "ssh-ed25519")
        let fingerprint = SSHHostKey.fingerprint(blob.data)
        XCTAssertTrue(fingerprint.hasPrefix("SHA256:"), fingerprint)
        XCTAssertFalse(fingerprint.hasSuffix("="), "OpenSSH quita el relleno del base64")
        XCTAssertEqual(fingerprint.count, 7 + 43)
    }

    func testAnECDSAHostKeyIsVerifiedFromItsTwoIntegers() throws {
        let key = P256.Signing.PrivateKey()
        var blob = SSHWriter(); blob.string("ecdsa-sha2-nistp256"); blob.string("nistp256"); blob.string(key.publicKey.x963Representation)
        let hash = Data(SHA256.hash(data: Data("H".utf8)))
        let raw = try key.signature(for: hash).rawRepresentation
        var inner = SSHWriter(); inner.mpint(raw.prefix(32)); inner.mpint(raw.suffix(32))
        var signature = SSHWriter(); signature.string("ecdsa-sha2-nistp256"); signature.string(inner.data)
        XCTAssertTrue(try SSHHostKey.verify(blob: blob.data, signature: signature.data, message: hash))
        XCTAssertFalse(try SSHHostKey.verify(blob: blob.data, signature: signature.data, message: hash + Data([0])))
    }

    func testAnRSAHostKeyIsRebuiltForSecurityAndOnlySHA2SignaturesCount() throws {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048, kSecAttrIsPermanent: false]
        var error: Unmanaged<CFError>?
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        // PKCS#1: SEQUENCE { INTEGER n, INTEGER e }; pull the two integers back out to build the SSH blob.
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, &error)) as Data
        func integers(_ der: Data) -> [Data] {
            var result: [Data] = []; var index = 0
            func length() -> Int {
                var value = Int(der[index]); index += 1
                if value & 0x80 != 0 { let count = value & 0x7F; value = 0; for _ in 0..<count { value = value << 8 | Int(der[index]); index += 1 } }
                return value
            }
            XCTAssertEqual(der[index], 0x30); index += 1; _ = length()
            while index < der.count { XCTAssertEqual(der[index], 0x02); index += 1; let count = length(); result.append(der[index..<index + count]); index += count }
            return result
        }
        let parts = integers(der)
        var blob = SSHWriter(); blob.string("ssh-rsa"); blob.mpint(parts[1]); blob.mpint(parts[0])
        let hash = Data(SHA256.hash(data: Data("H".utf8)))
        let raw = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, hash as CFData, &error)) as Data
        var good = SSHWriter(); good.string("rsa-sha2-256"); good.string(raw)
        XCTAssertTrue(try SSHHostKey.verify(blob: blob.data, signature: good.data, message: hash))
        XCTAssertFalse(try SSHHostKey.verify(blob: blob.data, signature: good.data, message: Data("otro".utf8)))
        var legacy = SSHWriter(); legacy.string("ssh-rsa"); legacy.string(raw)
        XCTAssertFalse(try SSHHostKey.verify(blob: blob.data, signature: legacy.data, message: hash), "ssh-rsa a secas es SHA-1 y no se acepta")
    }

    func testKeyDerivationFollowsRFC4253AndExtendsPastOneDigest() {
        let k = Data(repeating: 3, count: 32), h = Data(repeating: 4, count: 32), session = Data(repeating: 5, count: 32)
        var encoded = SSHWriter(); encoded.mpint(k)
        let first = Data(SHA256.hash(data: encoded.data + h + Data("C".utf8) + session))
        let derived = SSHKeyDerivation.derive(sharedSecret: k, exchangeHash: h, letter: "C", sessionID: session, length: 48)
        XCTAssertEqual(derived.count, 48)
        XCTAssertEqual(derived.prefix(32), first)
        XCTAssertEqual(derived.suffix(16), Data(SHA256.hash(data: encoded.data + h + first)).prefix(16), "K2 = HASH(K || H || K1)")
        XCTAssertNotEqual(derived, SSHKeyDerivation.derive(sharedSecret: k, exchangeHash: h, letter: "D", sessionID: session, length: 48))
    }

    func testNegotiationTakesTheClientsFirstPreferenceTheServerAlsoLists() {
        XCTAssertEqual(SSHAlgorithms.negotiate(["a", "b", "c"], ["c", "b"]), "b")
        XCTAssertNil(SSHAlgorithms.negotiate(["a"], ["b"]))
        XCTAssertEqual(SSHAlgorithms.negotiate(SSHAlgorithms.ciphers, ["chacha20-poly1305@openssh.com", "aes128-ctr"]), "aes128-ctr")
    }

    // MARK: - The provider's own rules

    @MainActor func testTheSFTPCloudDeclaresWhatSSHGivesAndWhatItDoesNot() throws {
        let capabilities = Cloud.sftp.capabilities
        XCTAssertTrue(capabilities.quota, "OpenSSH informa del espacio con statvfs")
        XCTAssertFalse(capabilities.copy); XCTAssertFalse(capabilities.search); XCTAssertFalse(capabilities.reversibleTrash)
        XCTAssertFalse(capabilities.permanentDelete, "Borrar ya es definitivo")
        XCTAssertTrue(Cloud.sftp.isSelfHosted); XCTAssertTrue(Cloud.sftp.usesPasswordLogin)
        let endpoint = try SFTPProvider.sftpEndpoint("sftp://nas.local/volume1/ana/")
        XCTAssertEqual(endpoint.port, 22); XCTAssertEqual(endpoint.base, "/volume1/ana")
        XCTAssertEqual(try SFTPProvider.sftpEndpoint("sftp://nas.local:2222").base, "/")
        XCTAssertThrowsError(try SFTPProvider.sftpEndpoint("ftp://nas.local"), "Solo el esquema sftp")
        let account = Account(id: "sftp:x", cloud: .sftp, name: "", email: "", clientID: "", clientSecret: nil, serverURL: "sftp://nas.local/volume1")
        XCTAssertEqual(AppModel.collections(for: account), [.files])
    }

    // MARK: - Against a real server

    /// Set ICLOUDY_SFTP_URL, e.g. sftp://ana:secreta@127.0.0.1:2222/, to run the whole stack against a server.
    @MainActor func testTheWholeStackAgainstARealServerWhenOneIsConfigured() async throws {
        guard let url = ProcessInfo.processInfo.environment["ICLOUDY_SFTP_URL"], !url.isEmpty else {
            throw XCTSkip("Sin servidor SFTP configurado (ICLOUDY_SFTP_URL)")
        }
        let (account, credential) = try await SFTPAuthentication().signInSFTP(server: url, username: "", password: "")
        XCTAssertTrue(account.options["hostKeyFingerprint"]?.hasPrefix("SHA256:") == true)
        let store = MemoryCredentials(); store.stored[account.id] = credential
        let api = CloudAPI(account: account, credentials: store)

        let stamp = String(Int(Date().timeIntervalSince1970))
        let folderID = try await api.createFolder(name: "Prueba \(stamp)", parent: "root")
        var listed = try await api.list(parent: "root")
        XCTAssertTrue(listed.contains { $0.id == folderID && $0.isFolder })

        // 1.5 MiB crosses the in-flight window several times and is not a multiple of the block size.
        let payload = Data((0..<(1_572_864 + 17)).map { UInt8(($0 * 7) % 253) })
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-\(stamp).bin")
        try payload.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let checkpoint = UploadCheckpoint(total: Int64(payload.count), modified: try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var progress: [Int64] = []
        let receipt = try await api.resumableUpload(local: local, parent: folderID, name: "datos.bin", replacing: nil, checkpoint: checkpoint,
                                                    save: { _ in }, progress: { sent, _ in progress.append(sent) })
        XCTAssertEqual(receipt.remoteID, folderID + "/datos.bin")
        XCTAssertEqual(progress.last, Int64(payload.count))
        listed = try await api.list(parent: folderID)
        let remote = try XCTUnwrap(listed.first { $0.name == "datos.bin" })
        XCTAssertEqual(remote.size, Int64(payload.count))
        XCTAssertNotNil(remote.modified)

        let downloaded = FileManager.default.temporaryDirectory.appendingPathComponent("sftp-\(stamp)-down.bin")
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try await api.download(file: remote, to: downloaded)
        XCTAssertEqual(try Data(contentsOf: downloaded), payload, "Lo que baja es lo que subió, byte a byte")

        try await api.rename(file: remote, name: "renombrado.bin")
        let inFolder = try await api.list(parent: folderID)
        let renamed = try XCTUnwrap(inFolder.first)
        XCTAssertEqual(renamed.name, "renombrado.bin")
        try await api.move(file: renamed, to: "root")
        let rootAfterMove = try await api.list(parent: "root")
        let moved = try XCTUnwrap(rootAfterMove.first { $0.name == "renombrado.bin" })
        do {
            try await api.rename(file: moved, name: "Prueba \(stamp)")
            XCTFail("Renombrar sobre algo que existe se rechaza antes de tocar el servidor")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Ya existe"), error.localizedDescription) }

        let quota = try await api.storageQuota()
        XCTAssertGreaterThan(quota.total ?? 0, 0, "asyncssh y OpenSSH responden a statvfs@openssh.com")

        let folder = try XCTUnwrap(rootAfterMove.first { $0.id == folderID })
        _ = try await api.createFolder(name: "anidada", parent: folderID)
        try await api.trash(file: folder)
        try await api.trash(file: moved)
        let rootAfterDelete = try await api.list(parent: "root")
        XCTAssertFalse(rootAfterDelete.contains { $0.id == folderID || $0.name == "renombrado.bin" }, "Borrar es recursivo y definitivo")

        // The stored key is what every later session must see; a different one is refused before signing in.
        var impostor = account
        impostor.options["hostKey"] = Data(repeating: 1, count: 51).base64EncodedString()
        let other = CloudAPI(account: impostor, credentials: store)
        do {
            _ = try await other.list(parent: "root")
            XCTFail("Una clave distinta a la guardada tiene que rechazarse")
        } catch let error as SSHTransport.HostKeyChanged {
            XCTAssertTrue(error.offered.hasPrefix("SHA256:"))
        }

        do {
            _ = try await SFTPAuthentication().signInSFTP(server: url.replacingOccurrences(of: "secreta", with: "mala"), username: "", password: "")
            XCTFail("Una contraseña incorrecta no inicia sesión")
        } catch { XCTAssertTrue(error.localizedDescription.contains("usuario o la contraseña"), error.localizedDescription) }
    }
}
