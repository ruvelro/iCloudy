import Foundation

struct OAuthProviderSettings {
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let profileEndpoint: String
    let identityKey: String
    let profileMethod: String
    let toleratesAnyPort: Bool
    let usesClientSecret: Bool
    let authorizationParameters: [String: String]

    static func settings(for cloud: Cloud) -> Self? {
        switch cloud {
        case .google: return .google
        case .microsoft: return .microsoft
        case .dropbox: return .dropbox
        case .box: return .box
        default: return nil
        }
    }
}
