import Foundation

/// The profiles of `~/.aws/credentials` and `~/.aws/config`, as the AWS command line writes them: INI sections whose
/// keys are the access key, its secret, the token of temporary keys and the region. Only what a profile states is
/// read; profiles that point elsewhere (SSO, `source_profile`, `credential_process`) have no keys to import and say so.
struct AWSProfile: Equatable, Identifiable {
    var name: String
    var accessKey = ""
    var secretKey = ""
    var sessionToken = ""
    var region = ""
    /// When temporary keys end, if the file says (`aws_session_expiration`, `x_security_token_expires`).
    var expires: Date?
    /// Why the profile cannot be imported as it is, or nil.
    var indirection: String?
    var id: String { name }
    var hasKeys: Bool { !accessKey.isEmpty && !secretKey.isEmpty }
}

enum AWSProfiles {
    /// Reads either file. A section `[profile name]` (the config file's spelling) is the same profile as `[name]`.
    static func parse(_ text: String) -> [AWSProfile] {
        var profiles: [AWSProfile] = []
        var current: AWSProfile?
        func flush() { if let current { if let index = profiles.firstIndex(where: { $0.name == current.name }) { profiles[index] = merge(profiles[index], current) } else { profiles.append(current) } } }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                flush()
                var name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("profile ") { name = String(name.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces) }
                current = name.hasPrefix("sso-session ") || name.hasPrefix("services ") ? nil : AWSProfile(name: name)
                continue
            }
            guard current != nil, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "aws_access_key_id": current?.accessKey = value
            case "aws_secret_access_key": current?.secretKey = value
            case "aws_session_token", "aws_security_token": current?.sessionToken = value
            case "region": current?.region = value
            case "aws_session_expiration", "x_security_token_expires": current?.expires = ISO8601DateFormatter().date(from: value)
            case "sso_start_url", "sso_session": current?.indirection = L("usa AWS SSO; inicia sesión con «aws sso login» y exporta unas credenciales temporales")
            case "credential_process": current?.indirection = L("obtiene sus claves de un programa externo")
            case "source_profile", "role_arn": current?.indirection = L("asume un rol a partir de otro perfil")
            default: break
            }
        }
        flush()
        return profiles
    }

    private static func merge(_ old: AWSProfile, _ new: AWSProfile) -> AWSProfile {
        var merged = old
        if !new.accessKey.isEmpty { merged.accessKey = new.accessKey }
        if !new.secretKey.isEmpty { merged.secretKey = new.secretKey }
        if !new.sessionToken.isEmpty { merged.sessionToken = new.sessionToken }
        if !new.region.isEmpty { merged.region = new.region }
        merged.expires = new.expires ?? old.expires
        merged.indirection = new.indirection ?? old.indirection
        return merged
    }
}

extension S3SignIn {
    /// Fills the keys from a profile. The region is taken only when the service knows it, so a profile meant for
    /// another service does not leave the form pointing at a region that does not exist there.
    mutating func adopt(_ profile: AWSProfile) {
        accessKey = profile.accessKey; secretKey = profile.secretKey
        sessionToken = profile.sessionToken; sessionExpires = profile.expires
        if !profile.region.isEmpty, service.regions.isEmpty || service.regions.contains(profile.region) { region = profile.region }
    }
}
