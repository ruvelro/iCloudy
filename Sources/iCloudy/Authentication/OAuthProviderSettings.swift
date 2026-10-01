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
    /// True when the provider may come back without the `state` it was given. pCloud drops it on some of its
    /// sign-in paths; a `state` that is present still has to match.
    var toleratesMissingState = false

    static func settings(for cloud: Cloud) -> Self? {
        switch cloud {
        case .google: return .google
        case .microsoft: return .microsoft
        case .dropbox: return .dropbox
        case .box: return .box
        case .pcloud: return .pcloud
        default: return nil
        }
    }
}
