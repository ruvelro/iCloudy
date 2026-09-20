import Foundation

enum LoginAddress {
    static func isLocalNetwork(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name.hasSuffix(".local") { return true }
        // An IPv6 literal has no dots either, so it has to be recognised before the bare-name rule below: only
        // loopback and link-local are inside the building, and every other address is as public as any other.
        if name.contains(":") { return name == "::1" || name.hasPrefix("fe80:") || name.hasPrefix("fc") || name.hasPrefix("fd") }
        if !name.contains(".") { return true }   // a bare name resolves only inside the local network
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 127 || parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }

    static func credentials(embeddedIn components: inout URLComponents, username: String, password: String) -> (String, String) {
        let embeddedUser = components.user ?? "", embeddedPassword = components.password ?? ""
        components.user = nil; components.password = nil
        return (username.isEmpty ? embeddedUser : username, password.isEmpty ? embeddedPassword : password)
    }

}
