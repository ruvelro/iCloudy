import Foundation

/// How this process was started, said by whoever started it instead of guessed.
///
/// The app used to ask whether a class named `XCTestCase` existed, in three places. That is true in any process that
/// merely links XCTest, and false in a test host that loads it late; and it hid from the reader which behaviour a test
/// run changes. The test bundle sets `isTesting` from its load-time bootstrap, before any of the app's code runs.
enum AppEnvironment {
    /// True inside the test suite: no real Keychain, no stored accounts, no saved tabs, no notifications, no log on disk.
    nonisolated(unsafe) static var isTesting = false
}
