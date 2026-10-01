import Foundation

/// One exported node: the public handle that goes in the link, and what Mega says about it.
struct MegaExport: Hashable {
    let publicHandle: String
    var expires: Date?
    /// Mega disabled the link after a complaint; it is listed so it can still be removed.
    var takenDown = false
}

extension MegaAPI {
    /// The `ph` array of an `f` response, the way Mega's own clients read it: `h` the node, `ph` the public handle,
    /// `ets` an expiry as a Unix time when the link has one, `down` set when Mega took the link down.
    static func exports(_ entries: [[String: Any]]) -> [String: MegaExport] {
        var result: [String: MegaExport] = [:]
        for entry in entries {
            guard let node = entry["h"] as? String, let handle = entry["ph"] as? String else { continue }
            let expiry = (entry["ets"] as? NSNumber)?.doubleValue ?? 0
            result[node] = MegaExport(publicHandle: handle, expires: expiry > 0 ? Date(timeIntervalSince1970: expiry) : nil,
                                      takenDown: (entry["down"] as? NSNumber)?.intValue == 1)
        }
        return result
    }
}

/// Mega's links are exports of a node, listed with the tree. A file link carries the file's own key in the fragment;
/// a folder link carries the key of the folder's share, which this account holds only when it made the share itself.
/// Revoking is the same `l` command with `d` set, and works the same for both.
extension MegaProvider {
    private func megaLink(_ handle: String, in state: MegaState) -> PublicLink? {
        guard let export = state.exports[handle], let node = state.nodes[handle], node.kind <= 1 else { return nil }
        let url: URL?
        if node.isFolder {
            url = state.shareKeys[handle].flatMap { URL(string: "https://mega.nz/folder/\(export.publicHandle)#\(MegaCrypto.encode($0))") }
        } else {
            url = node.key.isEmpty ? nil : URL(string: "https://mega.nz/file/\(export.publicHandle)#\(MegaCrypto.encode(node.key))")
        }
        // The path is read upwards with the same bound the breadcrumbs use, so a malformed tree cannot loop forever.
        var names: [String] = []
        var current = node.parent
        while let parent = state.nodes[current], parent.kind == 1, names.count < 64 {
            names.append(parent.name)
            current = parent.parent
        }
        return PublicLink(handle: handle, file: Self.megaFile(node), url: url, expires: export.expires,
                          audience: export.takenDown ? L("Mega retiró este enlace") : nil,
                          location: "/" + (names.reversed() + [node.name]).joined(separator: "/"))
    }

    func publicLinks(for file: CloudFile) async throws -> [PublicLink] {
        let state = try await megaTree()
        return megaLink(try megaHandle(file.id, in: state), in: state).map { [$0] } ?? []
    }

    /// Plain file links only, the same ones the quick action makes; the options were already refused upstream.
    func createPublicLink(for file: CloudFile, options: PublicLinkOptions) async throws -> PublicLink {
        _ = try await megaPublicLink(for: file)
        let state = try await megaTree()
        guard let link = megaLink(try megaHandle(file.id, in: state), in: state) else { throw CloudError.message(L("Mega no devolvió el enlace.")) }
        return link
    }

    func revokePublicLink(_ link: PublicLink) async throws {
        let state = try await megaTree()
        _ = try await megaCall(["a": "l", "n": link.handle, "d": 1])
        state.exports[link.handle] = nil
    }

    func allPublicLinks() async throws -> [PublicLink] {
        let state = try await megaTree()
        return state.exports.keys.compactMap { megaLink($0, in: state) }
            .sorted { ($0.location ?? "").localizedStandardCompare($1.location ?? "") == .orderedAscending }
    }
}
