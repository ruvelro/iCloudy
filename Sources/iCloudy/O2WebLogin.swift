import SwiftUI
import WebKit

/// Signing in to O2 Cloud happens on O2's own pages, inside a window of its own.
///
/// This is not a shortcut, it is the only way in. The "Acceder" button of O2's web client does nothing but navigate
/// to `/sapi/oauth/pkce/authorize`, and the server takes it from there: it sends the browser to Telefónica's Mi O2
/// sign-in, which asks either for a national identity number and a password or for a mobile number and a code sent
/// by text message, and then brings the session back. None of that can be reproduced from a form inside iCloudy.
///
/// It is also the better arrangement for the person using it. The password, or the code, is typed on O2's pages and
/// iCloudy never sees it. What iCloudy keeps afterwards is the session the server handed out, nothing more.
/// Which server to sign in to, in the shape a sheet can present.
struct O2LoginRequest: Identifiable, Hashable {
    let id: String
    var host: String { id }
}

@MainActor
final class O2WebLoginModel: ObservableObject {
    let host: String
    @Published var status: String = L("Abriendo el acceso de O2…")
    @Published var failed: String?
    /// Receives the session once O2 has granted one.
    var onSuccess: (@MainActor (String, [HTTPCookie], String?, [HTTPCookie]) -> Void)?
    /// The persistent store, on purpose. O2's server ends a session after about an hour of silence, so a Mac that
    /// spends the night switched off always comes back to a dead one. What survives that is the sign-in at
    /// Telefónica, and it only survives if its cookies are kept, exactly as a browser keeps them. With them, renewing
    /// the session needs no typing, and usually no window at all.
    let store = WKWebsiteDataStore.default()
    private var watcher: Task<Void, Never>?
    private var done = false
    private weak var webView: WKWebView?
    /// True once O2's pages have taken the person somewhere other than the sign-in, which is when finishing by hand
    /// makes sense.
    @Published var canFinishByHand = false

    init(host: String) { self.host = host }

    /// The address O2's own client uses to start the flow. The device identifier is opaque to the server and only
    /// distinguishes one signed-in client from another.
    var start: URL {
        URL(string: "https://\(host)/sapi/oauth/pkce/authorize?platform=web&deviceid=web-icloudy-\(UUID().uuidString.prefix(12))")
            ?? URL(string: "https://\(host)/")!
    }

    /// Watches the web view's cookies. The web client stores the key that authorises every later call in a cookie
    /// called `validationKey`, so its appearance is what says the session is ready.
    func watch(_ webView: WKWebView) {
        self.webView = webView
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            for _ in 0..<600 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, !self.done else { return }
                let mine = await self.sessionCookies()
                self.canFinishByHand = !mine.isEmpty
                guard let key = mine.first(where: { $0.name == "validationKey" })?.value, !key.isEmpty else { continue }
                self.done = true
                self.status = L("Sesión iniciada. Cerrando…")
                self.onSuccess?(key, mine, await self.identity(), await self.signInCookies())
                return
            }
            self?.failed = L("No se completó el acceso. Cierra esta ventana y vuelve a intentarlo.")
        }
    }
    func stop() { watcher?.cancel(); watcher = nil }

    /// How this window introduces itself to the server. The session is granted to that identity, so iCloudy keeps
    /// using it instead of presenting itself as a different program halfway through.
    private func identity() async -> String? {
        guard let webView else { return nil }
        let value = try? await webView.evaluateJavaScript("navigator.userAgent")
        return (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func sessionCookies() async -> [HTTPCookie] {
        guard let webView else { return [] }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return cookies.filter { host.hasSuffix($0.domain) || $0.domain.hasSuffix(host) }
    }
    /// The cookies of the sign-in itself, which belong to Telefónica rather than to O2. They are kept because they
    /// are what lets the session be renewed later without asking anyone anything, and because the web view throws
    /// them away when the app quits: they carry no expiry, so WebKit treats them as belonging to that run alone.
    /// Nothing outside the sign-in is taken: the window visits no other site.
    private func signInCookies() async -> [HTTPCookie] {
        guard let webView else { return [] }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return cookies.filter { cookie in
            O2SilentRenewal.signInDomains.contains { cookie.domain.hasSuffix($0) }
                && !(host.hasSuffix(cookie.domain) || cookie.domain.hasSuffix(host))
        }
    }

    /// The way out if the session is established but the key never shows up on its own. Nothing is stored unless the
    /// session really works, because the caller checks it against the server first.
    func finishByHand() async {
        guard !done else { return }
        let cookies = await sessionCookies()
        guard !cookies.isEmpty else {
            failed = L("Todavía no hay sesión. Termina de entrar en la página y vuelve a pulsar.")
            return
        }
        done = true
        onSuccess?(cookies.first { $0.name == "validationKey" }?.value ?? "", cookies, await identity(),
                   await signInCookies())
    }
}

/// The web view itself. Navigation is O2's business, so nothing here steers it.
struct O2WebView: NSViewRepresentable {
    @ObservedObject var model: O2WebLoginModel

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = model.store
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: model.start))
        model.watch(webView)
        return webView
    }
    func updateNSView(_ webView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: O2WebLoginModel
        init(model: O2WebLoginModel) { self.model = model }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            model.failed = error.localizedDescription
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.status = webView.url?.host.map { L("En \($0)") } ?? L("Cargando…")
        }
    }
}

struct O2WebLoginView: View {
    @ObservedObject var model: AppModel
    @StateObject private var login: O2WebLoginModel
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, host: String) {
        self.model = model
        _login = StateObject(wrappedValue: O2WebLoginModel(host: host))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("O2 Cloud", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                Text("Experimental").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                Spacer()
                Text(login.failed ?? login.status).font(.caption).foregroundStyle(login.failed == nil ? Color.secondary : Color.red)
                    .lineLimit(1).truncationMode(.middle)
                if login.canFinishByHand {
                    Button("Ya he entrado") { Task { await login.finishByHand() } }
                        .help("Úsalo solo si has iniciado sesión y esta ventana no se cierra sola")
                }
                Button("Cancelar") { finish() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            O2WebView(model: login)
            Divider()
            Text("Escribes tus datos en las páginas de O2. iCloudy no ve la contraseña ni el código: solo guarda la sesión que devuelve el servidor.")
                .font(.caption2).foregroundStyle(.secondary).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 720, height: 720)
        .onAppear {
            login.onSuccess = { key, cookies, agent, sso in
                Task {
                    await model.completeO2(host: login.host, validationKey: key, cookies: cookies,
                                           userAgent: agent, sso: sso)
                    finish()
                }
            }
        }
        .onDisappear { login.stop() }
    }
    private func finish() {
        login.stop()
        model.o2Login = nil
        dismiss()
    }
}

/// Renews an O2 session without asking the person anything.
///
/// O2's server ends a session after about an hour without requests, so a Mac that was switched off overnight always
/// finds a dead one in the morning. Having to sign in by hand every day would make the provider useless.
///
/// What makes this possible is that the sign-in at Telefónica outlives the session at O2. Loading the same address
/// the web client uses, with the cookies from the last sign-in, ends with the server handing out a new session and
/// no interaction at all. Nothing is typed, nothing is stored beyond what a browser would store, and if Telefónica
/// does want to see the person again, this simply fails and the window is shown instead.
@MainActor
final class O2SilentRenewal {
    private var webView: WKWebView?
    private let host: String
    /// Where the sign-in happens. Cookies from these are kept so it can be repeated without anyone taking part.
    static let signInDomains = ["o2online.es", "telefonica.es", "movistar.es"]
    init(host: String) { self.host = host }

    /// Returns the new session, or nil when it could not be had without the person taking part.
    func attempt(sso: [HTTPCookie] = [], timeout: TimeInterval = 25) async -> (key: String, cookies: [HTTPCookie], userAgent: String?, sso: [HTTPCookie])? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        self.webView = webView
        defer { self.webView = nil }

        let start = URL(string: "https://\(host)/sapi/oauth/pkce/authorize?platform=web&deviceid=web-icloudy-\(UUID().uuidString.prefix(12))")
        guard let start else { return nil }
        // The key from the dead session is still in the store. Clearing it first means that seeing one again can
        // only mean the server has just handed out a new one, rather than this reading its own leftovers.
        let jar = configuration.websiteDataStore.httpCookieStore
        for cookie in await jar.allCookies() where cookie.name == "validationKey" {
            await jar.deleteCookie(cookie)
        }
        // Put the sign-in back the way it was. Without this the web view arrives as a stranger and Telefónica shows
        // its login page, which is exactly what a real record showed happening three times in a row.
        for cookie in sso { await jar.setCookie(cookie) }
        // Counting what was handed over says nothing about what was accepted. WebKit refuses a cookie it considers
        // malformed, and a rejected one looks exactly like one that was never kept. So the jar is read back.
        let present = Set(await jar.allCookies().map(\.name))
        let accepted = sso.filter { present.contains($0.name) }.map(\.name)
        let refused = sso.filter { !present.contains($0.name) }.map(\.name)
        O2Log.record("renovación silenciosa · acceso restaurado: \(accepted.count) de \(sso.count)"
                     + (accepted.isEmpty ? "" : " [\(accepted.joined(separator: ","))]")
                     + (refused.isEmpty ? "" : " · rechazadas [\(refused.joined(separator: ","))]"))
        webView.load(URLRequest(url: start))

        O2Log.record("renovación silenciosa · empieza")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 700_000_000)
            let cookies = await configuration.websiteDataStore.httpCookieStore.allCookies()
            let mine = cookies.filter { host.hasSuffix($0.domain) || $0.domain.hasSuffix(host) }
            if let key = mine.first(where: { $0.name == "validationKey" })?.value, !key.isEmpty {
                let agent = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String
                let fresh = cookies.filter { cookie in
                    Self.signInDomains.contains { cookie.domain.hasSuffix($0) }
                        && !(host.hasSuffix(cookie.domain) || cookie.domain.hasSuffix(host))
                }
                O2Log.record("renovación silenciosa · conseguida sin intervención")
                return (key, mine, agent, fresh)
            }
        }
        // Normally this means Telefónica wants to see the person again. Saying which page it stopped on is the only
        // clue available afterwards, and it is why this is written down at all.
        let stuck = webView.url?.host ?? "sin página"
        O2Log.record("renovación silenciosa · no se pudo, se quedó en \(stuck)")
        return nil
    }
}
