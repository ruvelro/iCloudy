import Foundation
import Combine
import SwiftUI

extension Prefs {
    /// Whether the public links of every account are looked over once a day.
    static let linkAudit = "linkAuditEnabled"
    /// Whether a link anyone can open, for ever and without a password, is something to be told about.
    static let linkAuditOpen = "linkAuditOpenLinks"
}

/// Why a public link is worth a second look.
enum LinkConcern: Int, CaseIterable, Comparable {
    /// It stops working within days: whoever relies on it will need another.
    case expiringSoon
    /// Anyone with the address opens it, with no date after which they cannot and no password.
    case openForever
    /// Its date has passed. It opens nothing, and it is still on the list.
    case expired
    static func < (left: LinkConcern, right: LinkConcern) -> Bool { left.rawValue < right.rawValue }
    var title: String {
        switch self {
        case .expiringSoon: return L("Caducan pronto")
        case .openForever: return L("Abiertos sin fecha ni contraseña")
        case .expired: return L("Ya caducados")
        }
    }
    var explanation: String {
        switch self {
        case .expiringSoon: return L("Dejarán de funcionar en unos días. Si alguien los sigue usando, necesitará uno nuevo.")
        case .openForever: return L("Cualquiera que tenga la dirección puede abrirlos, sin límite de tiempo. Revoca los que ya no hagan falta.")
        case .expired: return L("Ya no abren nada. Revocarlos solo limpia la lista.")
        }
    }
}

struct LinkFinding: Identifiable, Equatable {
    let accountID: String
    let link: PublicLink
    let concern: LinkConcern
    var id: String { accountID + "\u{1F}" + link.id }
}

/// Pure judgement of a list of links.
enum LinkAudit {
    static let soon: TimeInterval = 7 * 86_400

    static func concern(of link: PublicLink, now: Date = Date(), includingOpen: Bool = true) -> LinkConcern? {
        // A link inherited from a folder is judged, and revoked, on that folder.
        guard !link.isInherited else { return nil }
        if let expires = link.expires {
            if expires <= now { return .expired }
            return expires.timeIntervalSince(now) <= soon ? .expiringSoon : nil
        }
        // An audience narrower than "anyone" (a company, an organisation) is not open in the sense that matters.
        guard includingOpen, !link.hasPassword, link.audience == nil else { return nil }
        return .openForever
    }

    static func findings(_ links: [PublicLink], accountID: String, now: Date = Date(), includingOpen: Bool = true) -> [LinkFinding] {
        links.compactMap { link in concern(of: link, now: now, includingOpen: includingOpen).map { LinkFinding(accountID: accountID, link: link, concern: $0) } }
            .sorted { $0.concern != $1.concern ? $0.concern < $1.concern : ($0.link.expires ?? .distantFuture) < ($1.link.expires ?? .distantFuture) }
    }
}

/// Looks over the public links of every account that can list them, once a day, and keeps what it found for the
/// sidebar to mention. Nothing is revoked from here without the person saying so, link by link.
@MainActor
final class LinkAuditor: ObservableObject {
    @Published private(set) var findings: [LinkFinding] = []
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    /// Accounts whose links could not be listed this time, with the reason.
    @Published private(set) var failures: [String: String] = [:]
    var accounts: (() -> [Account])?
    var client: ((Account) throws -> CloudAPI)?
    var defaults: UserDefaults = .standard
    var interval: Duration = .seconds(24 * 3600)
    private var timer: Task<Void, Never>?

    var enabled: Bool { defaults.object(forKey: Prefs.linkAudit) as? Bool ?? true }
    var includesOpenLinks: Bool { defaults.object(forKey: Prefs.linkAuditOpen) as? Bool ?? true }

    /// Called once the accounts are read. The first look waits a moment, so it does not compete with the launch.
    func start(after delay: Duration = .seconds(20)) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.interval else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refresh(force: Bool = false) async {
        guard force || enabled else { findings = []; return }
        guard !checking, let accounts, let client else { return }
        checking = true
        defer { checking = false }
        var found: [LinkFinding] = [], failed: [String: String] = [:]
        for account in accounts() where account.capabilities.links.inventory && !account.isDemo {
            do { found += LinkAudit.findings(try await client(account).allPublicLinks(), accountID: account.id, includingOpen: includesOpenLinks) }
            catch is CancellationError { return }
            catch { failed[account.id] = error.localizedDescription }
        }
        findings = found; failures = failed; lastChecked = Date()
    }

    /// A link was revoked from the review: it leaves the list at once, without asking every provider again.
    func forget(_ finding: LinkFinding) { findings.removeAll { $0.id == finding.id } }
    func forgetAccount(_ id: String) { findings.removeAll { $0.accountID == id }; failures[id] = nil }

    var summary: String? {
        guard !findings.isEmpty else { return nil }
        let soon = findings.filter { $0.concern == .expiringSoon }.count
        if soon > 0 { return soon == 1 ? L("1 enlace público caduca pronto") : L("\(soon) enlaces públicos caducan pronto") }
        return findings.count == 1 ? L("1 enlace público que revisar") : L("\(findings.count) enlaces públicos que revisar")
    }
}

/// The line in the sidebar, shown only when there is something to say.
struct LinkAuditNotice: View {
    let model: AppModel
    @ObservedObject var auditor: LinkAuditor
    var body: some View {
        if let summary = auditor.summary {
            Button { model.showLinkReview = true } label: {
                Label(summary, systemImage: "link.badge.plus").font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).foregroundStyle(.orange).padding(8)
            .help("Abre la revisión de enlaces públicos")
        }
    }
}

/// The review: every link worth a second look, by reason, with the two things to do about it.
struct LinkReviewView: View {
    @Bindable var model: AppModel
    @ObservedObject var auditor: LinkAuditor
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var pendingRevoke: LinkFinding?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Revisión de enlaces públicos").font(.title3.weight(.semibold))
                    if let checked = auditor.lastChecked {
                        Text("Comprobado \(checked.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if auditor.checking || working { ProgressView().controlSize(.small) }
                Button { Task { await auditor.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Comprobar ahora").accessibilityLabel("Comprobar ahora").disabled(auditor.checking || working)
            }
            Text("Solo aparecen las cuentas que dejan listar todos sus enlaces: Google Drive, Dropbox, pCloud, Mega y Nextcloud. En OneDrive y Box hay que mirar cada elemento.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                if auditor.findings.isEmpty {
                    Text(auditor.checking ? "Comprobando…" : "Ningún enlace necesita atención.").foregroundStyle(.secondary)
                }
                ForEach(LinkConcern.allCases, id: \.self) { concern in
                    let group = auditor.findings.filter { $0.concern == concern }
                    if !group.isEmpty {
                        Section {
                            ForEach(group) { finding in
                                VStack(alignment: .leading, spacing: 2) {
                                    PublicLinkRow(link: finding.link, showsItem: true, busy: working,
                                                  copy: { if let url = finding.link.url { model.copyToPasteboard(url); notice = L("Enlace copiado."); problem = nil } },
                                                  revoke: { pendingRevoke = finding })
                                    if let account = model.accounts.first(where: { $0.id == finding.accountID }) {
                                        Text(model.accountTitle(account) + " · " + account.email).font(.caption2).foregroundStyle(.tertiary).padding(.leading, 28)
                                    }
                                }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(concern.title)
                                Text(concern.explanation).font(.caption2).foregroundStyle(.secondary).textCase(nil)
                            }
                        }
                    }
                }
            }.frame(minHeight: 260, maxHeight: 420)
            ForEach(auditor.failures.sorted { $0.key < $1.key }, id: \.key) { accountID, reason in
                if let account = model.accounts.first(where: { $0.id == accountID }) {
                    Label("\(model.accountTitle(account)): \(reason)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            if let problem { Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            else if let notice { Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green) }
            HStack { Spacer(); Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 620)
        .confirmationDialog("¿Revocar este enlace?", isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
                            titleVisibility: .visible, presenting: pendingRevoke) { finding in
            Button("Revocar enlace", role: .destructive) { Task { await revoke(finding) } }
            Button("Cancelar", role: .cancel) { pendingRevoke = nil }
        } message: { finding in
            Text("Quien tenga el enlace dejará de poder abrir «\(finding.link.file.name)». No se puede deshacer: un enlace nuevo tendrá otra dirección.")
        }
    }

    private func revoke(_ finding: LinkFinding) async {
        pendingRevoke = nil
        guard !working, let account = model.accounts.first(where: { $0.id == finding.accountID }) else { return }
        working = true; problem = nil; notice = nil
        defer { working = false }
        do {
            try await model.client(account).revokePublicLink(finding.link)
            auditor.forget(finding)
            notice = L("Enlace revocado. Ya no abre «\(finding.link.file.name)».")
        } catch { problem = error.localizedDescription }
    }
}

/// The review's two switches, in the settings.
struct LinkAuditSettings: View {
    let model: AppModel
    @AppStorage(Prefs.linkAudit) private var enabled = true
    @AppStorage(Prefs.linkAuditOpen) private var openLinks = true
    var body: some View {
        Section {
            Toggle("Revisar los enlaces públicos una vez al día", isOn: $enabled)
            if enabled { Toggle("Avisar también de los abiertos sin fecha ni contraseña", isOn: $openLinks) }
            Button("Abrir la revisión de enlaces…") { model.showLinkReview = true; NSApp.activate(ignoringOtherApps: true) }
            Text("iCloudy pide a cada cuenta la lista de sus enlaces y avisa en la barra lateral de los que caducan en una semana, de los caducados y de los que cualquiera puede abrir para siempre. No revoca nada por su cuenta.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: enabled) { Task { await model.linkAuditor.refresh() } }
        .onChange(of: openLinks) { Task { await model.linkAuditor.refresh() } }
    }
}
