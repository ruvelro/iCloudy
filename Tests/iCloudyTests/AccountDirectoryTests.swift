import XCTest
@testable import iCloudy

/// What reaches the Keychain, recorded instead of written.
private final class KeychainRecorder: @unchecked Sendable {
    var saved: [[Account]] = []
    var credentials: [String: Credential] = [:]
    var deleted: [String] = []
    var failing = false
    struct Refused: Error {}

    var keychain: AccountKeychain {
        AccountKeychain(saveAccounts: { [self] accounts in
            if failing { throw Refused() }
            saved.append(accounts)
        }, saveCredential: { [self] credential, key in
            if failing { throw Refused() }
            credentials[key] = credential
        }, deleteCredential: { [self] key in deleted.append(key) })
    }
}

@MainActor
final class AccountDirectoryTests: XCTestCase {
    private func account(_ id: String, cloud: Cloud = .webdav) -> Account {
        Account(id: id, cloud: cloud, name: id, email: id, clientID: "", clientSecret: nil)
    }
    private let credential = Credential(accessToken: "a", refreshToken: "r", expires: .distantFuture)

    func testAdoptingWritesTheKeychainFirstAndResetsTheSessionsOfWhatBorrowsTheCredential() throws {
        let recorder = KeychainRecorder()
        let directory = AccountDirectory(keychain: recorder.keychain)
        let parent = account("google:1", cloud: .google)
        let drive = Account.scoped(to: "0ABC", named: "Equipo", from: parent)
        directory.accounts = [parent, drive, .demo]
        directory.markExpired(parent.id, reason: "caducada")
        directory.markExpired(drive.id, reason: nil)

        try directory.adopt(parent, credential: credential)
        XCTAssertEqual(recorder.credentials[parent.id]?.accessToken, "a")
        XCTAssertEqual(recorder.saved.last?.map(\.id), [parent.id, drive.id], "La demo no se guarda nunca")
        XCTAssertEqual(directory.accounts.map(\.id), [parent.id, drive.id, Account.demo.id], "Reconectar no cambia el orden")
        XCTAssertTrue(directory.expiredAccountIDs.isEmpty, "La unidad compartida tampoco se queda caducada")
        XCTAssertNil(directory.expiryReason(parent.id))
    }

    func testAFailedWriteLeavesTheListAsItWas() {
        let recorder = KeychainRecorder()
        let directory = AccountDirectory(keychain: recorder.keychain)
        directory.accounts = [account("a")]
        recorder.failing = true
        XCTAssertThrowsError(try directory.adopt(account("b"), credential: credential))
        XCTAssertEqual(directory.accounts.map(\.id), ["a"])
    }

    func testRemovingTakesTheDependentsAndTheCredentialAndReorderingPersists() throws {
        let recorder = KeychainRecorder()
        let directory = AccountDirectory(keychain: recorder.keychain)
        var membership = 0
        directory.membershipChanged = { membership += 1 }
        let parent = account("ms:1", cloud: .microsoft)
        let library = Account.scoped(to: "lib", named: "Docs", from: parent)
        directory.accounts = [account("x"), parent, library]
        XCTAssertEqual(membership, 1)

        XCTAssertTrue(try directory.reorder([parent, library, account("x")]))
        XCTAssertFalse(try directory.reorder(directory.accounts), "Sin cambios no se escribe")
        XCTAssertEqual(recorder.saved.count, 1)
        XCTAssertEqual(membership, 1, "Reordenar no cambia qué cuentas hay")

        let leaving = try directory.remove(parent)
        XCTAssertEqual(leaving.map(\.id), [parent.id, library.id])
        XCTAssertEqual(directory.accounts.map(\.id), ["x"])
        XCTAssertEqual(recorder.deleted, [parent.id])
        XCTAssertEqual(recorder.saved.last?.map(\.id), ["x"])
        XCTAssertEqual(membership, 2)
    }

    func testARenewedBookmarkIsKeptInMemoryEvenIfItCannotBeSaved() {
        let recorder = KeychainRecorder()
        let directory = AccountDirectory(keychain: recorder.keychain)
        directory.accounts = [account("volume:/Volumes/NAS", cloud: .volume)]
        recorder.failing = true
        XCTAssertThrowsError(try directory.update("volume:/Volumes/NAS") { $0.bookmark = Data([1]) })
        XCTAssertEqual(directory.accounts.first?.bookmark, Data([1]))
    }

    func testAnSFTPHostKeyLeavesTheAccountListOnlyOnceTheKeychainHoldsIt() throws {
        let recorder = KeychainRecorder()
        var keychain = recorder.keychain
        keychain.readCredential = { [recorder] key in recorder.credentials[key] }
        let directory = AccountDirectory(keychain: keychain)
        var legacy = Account(id: "sftp:nas", cloud: .sftp, name: "NAS", email: "ana@nas", clientID: "", clientSecret: nil)
        legacy.options["hostKey"] = "QUJD"
        directory.accounts = [legacy]

        try directory.replace([legacy])
        XCTAssertEqual(recorder.saved.last?.first?.options["hostKey"], "QUJD", "Sin copia en el Llavero, la de la cuenta es el único pin")

        var moved = Credential(accessToken: "", refreshToken: "", expires: .distantFuture)
        moved.hostKey = "QUJD"
        recorder.credentials[legacy.id] = moved
        try directory.replace([legacy])
        XCTAssertNil(recorder.saved.last?.first?.options["hostKey"])
        XCTAssertNil(directory.accounts.first?.options["hostKey"])
    }

    func testTheModelReadsAndShowsTheDirectory() {
        let model = AppModel()
        model.accounts = [account("a")]
        XCTAssertEqual(model.directory.accounts.map(\.id), ["a"])
        model.directory.markExpired("a", reason: "fuera")
        XCTAssertTrue(model.isExpired(account("a")))
        XCTAssertEqual(model.expiryReason(account("a")), "fuera")
    }
}
