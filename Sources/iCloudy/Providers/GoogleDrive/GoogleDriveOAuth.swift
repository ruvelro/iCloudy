import Foundation

extension OAuthProviderSettings {
    static let google = OAuthProviderSettings(
        authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth", tokenEndpoint: "https://oauth2.googleapis.com/token",
        profileEndpoint: "https://openidconnect.googleapis.com/v1/userinfo", identityKey: "sub", profileMethod: "GET",
        toleratesAnyPort: true, usesClientSecret: true,
        authorizationParameters: ["scope": "openid email profile https://www.googleapis.com/auth/drive",
        "access_type": "offline",
        "prompt": "consent select_account"],
        requiredScopes: ["https://www.googleapis.com/auth/drive"])
}
