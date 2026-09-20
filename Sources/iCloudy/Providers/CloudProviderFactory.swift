import Foundation

@MainActor
enum CloudProviderFactory {
    static func make(account: Account, session: URLSession, tokenProvider: (() async throws -> String)?, credentials: CredentialStore) -> any CloudProvider {
        switch account.cloud {
        case .google: return GoogleDriveProvider(account: account, session: session, tokenProvider: tokenProvider, credentials: credentials)
        case .microsoft: return OneDriveProvider(account: account, session: session, tokenProvider: tokenProvider, credentials: credentials)
        case .dropbox: return DropboxProvider(account: account, session: session, tokenProvider: tokenProvider, credentials: credentials)
        case .box: return BoxProvider(account: account, session: session, tokenProvider: tokenProvider, credentials: credentials)
        case .webdav: return WebDAVProvider(account: account, session: session, tokenProvider: tokenProvider, credentials: credentials)
        case .ftp: return FTPProvider(account: account, session: session, tokenProvider: tokenProvider, credentials: credentials)
        case .volume: return VolumeProvider(account: account, session: session, tokenProvider: tokenProvider, credentials: credentials)
        case .mega: return MegaProvider(account: account, session: session, tokenProvider: tokenProvider, credentials: credentials)
        case .o2: return O2Provider(account: account, session: session, tokenProvider: tokenProvider, credentials: credentials)
        }
    }
}
