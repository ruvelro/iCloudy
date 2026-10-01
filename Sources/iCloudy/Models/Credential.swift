import Foundation

struct Credential: Codable {
    var accessToken: String
    var refreshToken: String
    var expires: Date
    /// Extra material a provider needs beside the token. Mega keeps its master key here: without it the account's own
    /// session identifier is useless, because every file name and every file key is encrypted under it.
    var secret: String = ""
    /// False for a token that comes without a refresh token. pCloud issues those: they never expire, and once the
    /// provider stops accepting one only a new sign-in brings the account back.
    var isRenewable: Bool { !refreshToken.isEmpty }
    /// A token good until the provider revokes it. The far expiry keeps the refresher from ever trying to renew it.
    static func permanent(accessToken: String) -> Credential {
        Credential(accessToken: accessToken, refreshToken: "", expires: .distantFuture)
    }
}

extension Credential {
    enum CodingKeys: String, CodingKey { case accessToken, refreshToken, expires, secret }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A missing expiry forces a refresh on first use instead of trusting a stale token.
        self.init(accessToken: try values.decode(String.self, forKey: .accessToken),
                  refreshToken: try values.decode(String.self, forKey: .refreshToken),
                  expires: try values.decodeIfPresent(Date.self, forKey: .expires) ?? .distantPast,
                  secret: try values.decodeIfPresent(String.self, forKey: .secret) ?? "")
    }
}
