import Foundation

extension OAuthProviderSettings {
    static let box = OAuthProviderSettings(
        authorizationEndpoint: "https://account.box.com/api/oauth2/authorize", tokenEndpoint: "https://api.box.com/oauth2/token",
        profileEndpoint: "https://api.box.com/2.0/users/me", identityKey: "id", profileMethod: "GET",
        toleratesAnyPort: true, usesClientSecret: true,
        authorizationParameters: [:])
}
