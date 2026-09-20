import Foundation

extension OAuthProviderSettings {
    static let dropbox = OAuthProviderSettings(
        authorizationEndpoint: "https://www.dropbox.com/oauth2/authorize", tokenEndpoint: "https://api.dropboxapi.com/oauth2/token",
        profileEndpoint: "https://api.dropboxapi.com/2/users/get_current_account", identityKey: "account_id", profileMethod: "POST",
        toleratesAnyPort: false, usesClientSecret: false,
        authorizationParameters: ["token_access_type": "offline",
        "scope": "account_info.read files.metadata.read files.content.read files.content.write sharing.read sharing.write"])
}
