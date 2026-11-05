import Foundation
import Observation

/// Questions a sign-in has to ask the person halfway through, when the server's answer decides what comes next: is
/// this SSH host key the right one, what is Mega's second-factor code, is this the pCloud account you meant. The
/// sign-in code suspends on one of these; the login form, which is on screen while it runs, shows the question and
/// resumes it with the answer.
///
/// One question of each kind at a time. A new one replaces a stale one, which is answered "no".
@MainActor @Observable
final class LoginPrompts {
    static let shared = LoginPrompts()

    struct HostKeyQuestion: Sendable, Equatable {
        /// `host` or `host:port` when the port is not 22.
        let server: String
        let keyType: String
        let fingerprint: String
        init(host: String, port: UInt16, blob: Data) {
            server = port == 22 ? host : host + ":" + String(port)
            keyType = SSHHostKey.type(of: blob)
            fingerprint = SSHHostKey.fingerprint(blob)
        }
    }
    struct CodeQuestion: Sendable, Equatable {
        let service: String
        /// True when a code was already sent and refused.
        let retry: Bool
    }

    struct AccountQuestion: Sendable, Equatable {
        let service: String
        let email: String
    }

    private(set) var hostKey: HostKeyQuestion?
    private(set) var code: CodeQuestion?
    private(set) var account: AccountQuestion?
    @ObservationIgnored private var hostKeyAnswer: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var codeAnswer: CheckedContinuation<String?, Never>?
    @ObservationIgnored private var accountAnswer: CheckedContinuation<Bool, Never>?

    init() {}

    /// True when the person trusts the key. A cancelled sign-in counts as "no".
    func trust(_ question: HostKeyQuestion) async -> Bool {
        answerHostKey(false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                hostKey = question
                hostKeyAnswer = continuation
            }
        } onCancel: {
            Task { @MainActor in self.answerHostKey(false) }
        }
    }
    func answerHostKey(_ trusted: Bool) {
        let waiting = hostKeyAnswer
        hostKeyAnswer = nil; hostKey = nil
        waiting?.resume(returning: trusted)
    }

    /// The code the person typed, or nil when they gave up.
    func code(_ question: CodeQuestion) async -> String? {
        answerCode(nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                code = question
                codeAnswer = continuation
            }
        } onCancel: {
            Task { @MainActor in self.answerCode(nil) }
        }
    }
    /// True when the person recognises the account a sign-in is about to add.
    func confirm(_ question: AccountQuestion) async -> Bool {
        answerAccount(false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                account = question
                accountAnswer = continuation
            }
        } onCancel: {
            Task { @MainActor in self.answerAccount(false) }
        }
    }
    func answerAccount(_ confirmed: Bool) {
        let waiting = accountAnswer
        accountAnswer = nil; account = nil
        waiting?.resume(returning: confirmed)
    }

    func answerCode(_ typed: String?) {
        let waiting = codeAnswer
        codeAnswer = nil; code = nil
        let trimmed = typed?.trimmingCharacters(in: .whitespacesAndNewlines)
        waiting?.resume(returning: trimmed?.isEmpty == false ? trimmed : nil)
    }
}
