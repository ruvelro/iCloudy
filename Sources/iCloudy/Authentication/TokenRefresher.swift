import Foundation

/// One token refresh at a time per Keychain entry, shared by every client that reads it.
///
/// A shared drive or a document library borrows the credential of the account it came from, so two `CloudAPI`s read
/// and write the same entry. Microsoft rotates the refresh token on every use and retires the previous one, so two
/// clients refreshing at the same moment leave one of them holding a token the provider has already thrown away, and
/// that account goes to "expired" for a reason nobody can see.
@MainActor
enum TokenRefresher {
    private static var inFlight: [String: Task<Credential, Error>] = [:]
    static func refresh(key: String, _ work: @escaping () async throws -> Credential) async throws -> Credential {
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await work() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
}

