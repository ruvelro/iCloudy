import Foundation

/// What a public link lets its holder do. Every provider has these two; a link that only previews is shown as a view
/// link with downloading switched off.
enum LinkAccess: String, Codable, CaseIterable, Identifiable {
    case view, edit
    var id: String { rawValue }
    var title: String {
        switch self { case .view: return L("Solo ver"); case .edit: return L("Ver y editar") }
    }
}

/// One public link on one item, as the provider lists it. Links are read back from the provider every time, so
/// nothing here is kept between runs.
struct PublicLink: Identifiable, Hashable {
    /// What the provider needs to revoke the link: the permission id in Drive and Graph, the share id in Nextcloud,
    /// the URL itself in Dropbox, and the item's own id in Box and Mega, which allow one link per item.
    let handle: String
    let file: CloudFile
    /// Nil when the provider lists the link without an address iCloudy can rebuild, such as a Mega folder exported
    /// from another client whose share key never reached this account.
    let url: URL?
    var access = LinkAccess.view
    var expires: Date?
    var hasPassword = false
    /// Nil when the provider has no such switch or does not say.
    var allowsDownload: Bool?
    /// Who can actually open it, when that is narrower than "anyone": a OneDrive organisation link, a Box company link.
    var audience: String?
    /// Where the item lives, for the account-wide list.
    var location: String?
    /// A link inherited from a parent folder is revoked there, not on this item.
    var isInherited = false
    var id: String { file.id + "\u{1F}" + handle }
    var canRevoke: Bool { !isInherited }
}

/// The settings a new link is created with. Options the provider does not support are refused before anything is
/// sent, so a link never comes out more open than the person asked for.
struct PublicLinkOptions: Equatable {
    var access = LinkAccess.view
    var expires: Date?
    var password: String?
    var allowDownload = true
    /// True when nothing beyond a plain view link was asked for.
    var isPlain: Bool { access == .view && expires == nil && (password ?? "").isEmpty && allowDownload }
}

/// What the provider can do with public links beyond creating a plain one. `CloudCapabilities.publicLinks` says
/// whether there are links at all; this says how far they can be managed from iCloudy.
struct LinkFeatures: Equatable {
    /// Links on an item can be listed, created with options and revoked.
    var manage = false
    var expiration = false
    var password = false
    /// Links that let anyone edit, and whether that extends to folders.
    var edit = false
    var editFolders = false
    /// Downloading can be switched off on a view link.
    var downloadToggle = false
    /// Every link of the account can be listed at once, not only those of one item.
    var inventory = false

    /// Why `options` cannot be honoured here, or nil when they can.
    func refusal(of options: PublicLinkOptions, for file: CloudFile, cloud: Cloud) -> String? {
        guard manage else { return L("\(cloud.title) no gestiona enlaces públicos desde iCloudy.") }
        if options.access == .edit, !edit || (file.isFolder && !editFolders) {
            return file.isFolder && edit
                ? L("\(cloud.title) solo crea enlaces de edición para archivos, no para carpetas.")
                : L("\(cloud.title) no crea enlaces de edición desde iCloudy.")
        }
        if options.expires != nil, !expiration { return L("\(cloud.title) no admite fecha de caducidad en los enlaces.") }
        if !(options.password ?? "").isEmpty, !password { return L("\(cloud.title) no protege los enlaces con contraseña.") }
        if !options.allowDownload, !downloadToggle { return L("\(cloud.title) no permite desactivar la descarga de un enlace.") }
        return nil
    }
}

/// Date formats the link APIs expect. Dropbox insists on whole seconds and a literal Z, which is also what the
/// others accept, so one formatter serves them all.
enum LinkDates {
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
    /// The calendar day of `date` where the person is, which is what Nextcloud takes as an expiry.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    /// Nextcloud answers "2026-10-31 00:00:00", in the server's own zone, which it does not name.
    static func ocs(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: text) ?? {
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: text)
        }()
    }
    /// The last second of the chosen day, so a link set to expire "on the 31st" still works all through the 31st.
    static func endOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }
}
