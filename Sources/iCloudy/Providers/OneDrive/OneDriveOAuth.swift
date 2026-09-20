import Foundation

extension OAuthProviderSettings {
    static let microsoft = OAuthProviderSettings(
        authorizationEndpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize", tokenEndpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
        profileEndpoint: "https://graph.microsoft.com/v1.0/me?$select=id,displayName,mail,userPrincipalName", identityKey: "id", profileMethod: "GET",
        toleratesAnyPort: false, usesClientSecret: false,
        authorizationParameters: ["scope": "openid profile email offline_access User.Read Files.ReadWrite",
        "prompt": "select_account"])
}
