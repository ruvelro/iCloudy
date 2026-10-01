import XCTest
@testable import iCloudy

/// Stands in for the model while it is being built and its accounts are read from the Keychain.
@MainActor
private final class LoadingModel: AccountLoading {
    var loadingAccounts = true
    var accountLoadError: Error?
}

/// Dock drops, the Services menu and Shortcuts can launch the app and arrive before there is a model to act on.
@MainActor
final class ColdStartTests: XCTestCase {
    func testARequestThatArrivesBeforeTheModelWaitsForItsAccounts() async throws {
        // A file dropped on the Dock that launches the app used to find no model and vanish without a word.
        var model: LoadingModel?
        _ = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(40))
            model = LoadingModel()
            try await Task.sleep(for: .milliseconds(40))
            model?.loadingAccounts = false
        }
        let ready = try await ColdStart.ready(timeout: .seconds(5)) { model }
        XCTAssertTrue(ready === model)
        XCTAssertFalse(ready.loadingAccounts, "Only handed over once the accounts are there")
    }

    func testAKeychainThatNeverAnswersEndsInAClearErrorAndNotAHang() async {
        let model = LoadingModel()
        do {
            _ = try await ColdStart.ready(timeout: .milliseconds(60)) { model }
            XCTFail("It must give up")
        } catch {
            XCTAssertEqual(error as? ColdStartError, .stillLoading)
        }
    }

    func testNoModelAtAllAndAnUnreadableKeychainAreToldApart() async {
        do {
            _ = try await ColdStart.ready(timeout: .milliseconds(30)) { nil as LoadingModel? }
            XCTFail("There is no model")
        } catch { XCTAssertEqual(error as? ColdStartError, .notRunning) }

        let broken = LoadingModel()
        broken.loadingAccounts = false
        broken.accountLoadError = CloudError.message("errSecInteractionNotAllowed")
        do {
            _ = try await ColdStart.ready(timeout: .seconds(5)) { broken }
            XCTFail("The accounts could not be read")
        } catch {
            XCTAssertEqual(error as? ColdStartError, .accountsUnreadable("errSecInteractionNotAllowed"))
        }
    }
}
