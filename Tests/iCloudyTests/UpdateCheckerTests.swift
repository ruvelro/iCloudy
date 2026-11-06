import CryptoKit
import SwiftUI
import XCTest
@testable import iCloudy

/// The update checker: version order, the feed the release workflow publishes, and when it asks and what it says.
@MainActor
final class UpdateCheckerTests: XCTestCase {
    private static let feedURL = URL(string: "https://github.com/ruvelro/iCloudy/releases/latest/download/appcast.json")!

    private func feed(version: String = "0.9.0", signed: Bool = false, schema: Int = 1,
                      assetURL: String = "https://github.com/ruvelro/iCloudy/releases/download/v0.9.0/iCloudy-0.9.0-unsigned.dmg") -> Data {
        Data("""
        {
          "schemaVersion": \(schema),
          "version": "\(version)",
          "build": "260",
          "published": "2026-11-20T10:00:00Z",
          "minimumSystemVersion": "14.0",
          "signed": \(signed),
          "releaseURL": "https://github.com/ruvelro/iCloudy/releases/tag/v\(version)",
          "notes": "### Distribución\\n\\n- **Paquetes** firmados.",
          "assets": [
            {"kind": "zip", "name": "iCloudy-0.9.0-unsigned.zip", "url": "https://github.com/ruvelro/iCloudy/releases/download/v0.9.0/iCloudy-0.9.0-unsigned.zip", "size": 10, "sha256": "aa"},
            {"kind": "dmg", "name": "iCloudy-0.9.0-unsigned.dmg", "url": "\(assetURL)", "size": 20, "sha256": "bb"}
          ]
        }
        """.utf8)
    }

    private func checker(version: String = "0.7.0", now: @escaping @Sendable () -> Date = { Date() }) -> UpdateChecker {
        UpdateChecker(currentVersion: version, currentBuild: "247", feedURL: Self.feedURL, session: StubProtocol.session(), now: now)
    }

    // MARK: - Versions

    func testVersionsCompareAsSemVerDoes() throws {
        func v(_ text: String) throws -> AppVersion { try XCTUnwrap(AppVersion(text), text) }
        XCTAssertLessThan(try v("0.7.0"), try v("0.9.0"))
        XCTAssertLessThan(try v("0.9.0"), try v("0.10.0"), "Numbers, not text: 10 is after 9")
        XCTAssertLessThan(try v("0.9.9"), try v("1.0.0"))
        XCTAssertEqual(try v("v1.2.0"), try v("1.2"), "A leading v and a missing patch are the same version")
        XCTAssertEqual(try v("1.0.0+build.5"), try v("1.0.0"), "Build metadata does not order")
        XCTAssertLessThan(try v("1.0.0-rc.1"), try v("1.0.0"), "A pre-release comes before its release")
        XCTAssertLessThan(try v("1.0.0-alpha"), try v("1.0.0-alpha.1"))
        XCTAssertLessThan(try v("1.0.0-alpha.1"), try v("1.0.0-alpha.beta"), "Numeric identifiers sort first")
        XCTAssertLessThan(try v("1.0.0-beta.2"), try v("1.0.0-beta.11"))
        XCTAssertFalse(try v("0.9.0") < v("0.9.0"))
        for invalid in ["", "abc", "1.2.3.4", "1..2", "1.0.0-", "1.0.0-a..b", "1.x.0"] {
            XCTAssertNil(AppVersion(invalid), invalid)
        }
        XCTAssertEqual(try v("v1.0.0-rc.1").description, "1.0.0-rc.1")
    }

    // MARK: - Feed

    func testTheFeedDecodesAndOffersTheDiskImage() throws {
        let decoded = try UpdateChecker.decode(feed())
        XCTAssertEqual(decoded.version, "0.9.0")
        XCTAssertFalse(decoded.signed)
        XCTAssertEqual(decoded.download?.kind, "dmg", "The disk image is what the button downloads")
        XCTAssertEqual(decoded.download?.sha256, "bb")
        XCTAssertNotNil(decoded.published)
        XCTAssertFalse(decoded.needsNewerSystem, "macOS 14 is what the tests run on or newer")
        XCTAssertEqual(decoded.displayNotes, "**Distribución**\n\n- **Paquetes** firmados.")
    }

    func testAFeedWithAPlainHTTPLinkIsRefused() {
        XCTAssertThrowsError(try UpdateChecker.decode(feed(assetURL: "http://example.com/iCloudy.dmg"))) { error in
            XCTAssertEqual(error as? UpdateCheckError, .insecureLink)
        }
        XCTAssertThrowsError(try UpdateChecker.decode(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? UpdateCheckError, .invalidFeed)
        }
        XCTAssertThrowsError(try UpdateChecker.decode(feed(version: "nueva"))) { error in
            XCTAssertEqual(error as? UpdateCheckError, .invalidFeed)
        }
    }

    func testANewerFeedFormatOnlyLinksToTheReleasePage() throws {
        let decoded = try UpdateChecker.decode(feed(schema: UpdateFeed.supportedSchema + 1))
        XCTAssertNil(decoded.download)
        XCTAssertEqual(decoded.releaseURL.absoluteString, "https://github.com/ruvelro/iCloudy/releases/tag/v0.9.0")
    }

    func testReleaseNotesDropGitHubAlertMarkers() throws {
        let notes = UpdateFeed(schemaVersion: 1, version: "0.9.0", build: nil, published: nil, minimumSystemVersion: nil,
                               signed: false, releaseURL: Self.feedURL, notes: "> [!WARNING]\n> **Sin firmar.**\n\n## 0.9\n#hashtag",
                               assets: [])
        XCTAssertEqual(notes.displayNotes, "**Sin firmar.**\n\n**0.9**\n#hashtag")
    }

    // MARK: - Checking

    func testAManualCheckFindsANewerVersionAndRecordsTheCheck() async throws {
        let feedData = feed()
        let requested = Box<URLRequest?>(nil)
        StubProtocol.handler = { request in
            requested.value = request
            return (200, ["Content-Type": "application/json"], feedData)
        }
        let checked = Date(timeIntervalSince1970: 1_800_000_000)
        let checker = checker(now: { checked })
        let status = await checker.check(manual: true)
        guard case .available(let offered) = status else { return XCTFail("Expected a new version, got \(status)") }
        XCTAssertEqual(offered.version, "0.9.0")
        XCTAssertNil(checker.pendingPrompt, "A manual check shows its own window; it does not raise the prompt")
        XCTAssertEqual(checker.lastCheck, checked)
        XCTAssertEqual(Prefs.defaults.object(forKey: Prefs.lastUpdateCheck) as? Date, checked)
        XCTAssertEqual(requested.value?.url, Self.feedURL)
        XCTAssertEqual(requested.value?.value(forHTTPHeaderField: "User-Agent"), "iCloudy/0.7.0")
    }

    func testTheSameOrAnOlderVersionIsUpToDate() async {
        let feedData = feed(version: "0.7.0")
        StubProtocol.handler = { _ in (200, [:], feedData) }
        let same = await checker(version: "0.7.0").check(manual: true)
        XCTAssertEqual(same, .upToDate)
        let newer = await checker(version: "1.0.0").check(manual: true)
        XCTAssertEqual(newer, .upToDate, "A build newer than the release (a local one) is not offered a downgrade")
    }

    func testFailuresAreReportedOnlyWhenTheUserAsked() async {
        StubProtocol.handler = { _ in (404, [:], Data()) }
        let checker = checker()
        let manual = await checker.check(manual: true)
        XCTAssertEqual(manual, .failed(UpdateCheckError.noRelease.localizedDescription))
        XCTAssertNil(checker.lastCheck, "A failed check is not the day's check")

        StubProtocol.handler = { _ in (503, [:], Data()) }
        let quiet = UpdateChecker(currentVersion: "0.7.0", feedURL: Self.feedURL, session: StubProtocol.session())
        let automatic = await quiet.check(manual: false)
        XCTAssertEqual(automatic, .idle, "An automatic check that fails says nothing")
        XCTAssertNil(quiet.pendingPrompt)
        let again = await quiet.check(manual: true)
        XCTAssertEqual(again, .failed(UpdateCheckError.http(503).localizedDescription))
    }

    func testAnAutomaticCheckPromptsOnceAndRespectsASkippedVersion() async {
        let feedData = feed()
        StubProtocol.handler = { _ in (200, [:], feedData) }
        let checker = checker()
        await checker.check(manual: false)
        XCTAssertEqual(checker.pendingPrompt?.version, "0.9.0")

        guard case .available(let offered) = checker.status else { return XCTFail("Expected a new version") }
        checker.skip(offered)
        XCTAssertNil(checker.pendingPrompt)
        XCTAssertEqual(Prefs.defaults.string(forKey: Prefs.skippedUpdateVersion), "0.9.0")

        let reopened = self.checker()
        let quiet = await reopened.check(manual: false)
        XCTAssertEqual(quiet, .upToDate, "A skipped version stays quiet, also after a relaunch")
        XCTAssertNil(reopened.pendingPrompt)
        let asked = await reopened.check(manual: true)
        XCTAssertEqual(asked, .available(offered), "Asking by hand still shows it")
    }

    func testTheDailyCheckIsOffByDefaultAndRunsOnceADay() async {
        let clock = Box(Date(timeIntervalSince1970: 1_800_000_000))
        let requests = Box(0)
        let feedData = feed(version: "0.7.0")
        StubProtocol.handler = { _ in requests.value += 1; return (200, [:], feedData) }
        let checker = checker(now: { clock.value })
        XCTAssertFalse(checker.automatic, "Nothing is sent to GitHub until the user turns it on")
        XCTAssertFalse(checker.isDue)
        await checker.checkIfDue()
        XCTAssertEqual(requests.value, 0)

        checker.automatic = true
        XCTAssertEqual(Prefs.defaults.object(forKey: Prefs.automaticUpdateChecks) as? Bool, true)
        XCTAssertTrue(checker.isDue, "Never checked: due now")
        await checker.checkIfDue()
        XCTAssertEqual(requests.value, 1)
        clock.value += UpdateChecker.interval - 60
        await checker.checkIfDue()
        XCTAssertEqual(requests.value, 1, "Less than a day later: not again")
        clock.value += 120
        await checker.checkIfDue()
        XCTAssertEqual(requests.value, 2, "A day later: again")
        clock.value -= 3 * UpdateChecker.interval
        XCTAssertTrue(checker.isDue, "A last check in the future means the clock moved; check rather than wait for it")
    }

    func testABuildWithoutAVersionNeverChecksByItself() {
        let checker = checker(version: UpdateChecker.placeholderVersion)
        checker.automatic = true
        XCTAssertTrue(checker.isDevelopmentBuild)
        XCTAssertFalse(checker.isDue)
    }

    // MARK: - Views

    /// The window and the settings tab lay out in every state without tripping SwiftUI.
    func testTheUpdateWindowAndTheSettingsTabRender() async throws {
        let feedData = feed()
        StubProtocol.handler = { _ in (200, [:], feedData) }
        let checker = checker()
        var heights: [CGFloat] = []
        func measure(_ view: some View) {
            let hosting = NSHostingView(rootView: view.defaultAppStorage(Prefs.defaults))
            hosting.layoutSubtreeIfNeeded()
            heights.append(hosting.fittingSize.height)
        }
        measure(UpdateView(checker: checker))
        await checker.check(manual: true)
        measure(UpdateView(checker: checker))
        measure(UpdateSettings(checker: checker))
        XCTAssertTrue(heights.allSatisfy { $0 > 40 }, "Every state draws something: \(heights)")
        XCTAssertGreaterThan(heights[1], heights[0], "The offer, with its notes and sum, is taller than the progress line")
    }

    // MARK: - The release pipeline

    /// The feed scripts/release.py writes is the one the app reads, with the sums of the files it was given.
    func testTheReleaseScriptWritesAFeedTheAppReads() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("No python3 on this Mac") }
        let root = try temporaryRoot()
        let zip = root.appendingPathComponent("iCloudy-0.9.0-unsigned.zip"), dmg = root.appendingPathComponent("iCloudy-0.9.0-unsigned.dmg")
        let notes = root.appendingPathComponent("notes.md")
        try Data("zip".utf8).write(to: zip)
        try Data("dmg".utf8).write(to: dmg)
        try Data("### Distribución\n\n- Hola.\n".utf8).write(to: notes)
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", repositoryURL("scripts/release.py").path, "appcast", "--version", "0.9.0", "--build", "260",
                             "--notes", notes.path, "--zip", zip.path, "--dmg", dmg.path, "--out", root.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let decoded = try UpdateChecker.decode(Data(contentsOf: root.appendingPathComponent("appcast.json")))
        XCTAssertEqual(decoded.version, "0.9.0")
        XCTAssertEqual(decoded.build, "260")
        XCTAssertFalse(decoded.signed)
        let expected = SHA256.hash(data: Data("dmg".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(decoded.download?.sha256, expected)
        XCTAssertEqual(decoded.download?.url.absoluteString,
                       "https://github.com/ruvelro/iCloudy/releases/download/v0.9.0/iCloudy-0.9.0-unsigned.dmg")
        XCTAssertEqual(decoded.download?.size, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("appcast.xml").path))
        XCTAssertEqual(UpdateChecker.defaultFeedURL.lastPathComponent, "appcast.json", "The app asks for the file the workflow attaches")
        let workflow = try String(contentsOf: repositoryURL(".github/workflows/release.yml"), encoding: .utf8)
        XCTAssertTrue(workflow.contains("appcast.json"))
    }
}
