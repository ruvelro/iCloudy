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
    /// Which server to sign in to. It is a setting and not a constant because the platform is resold by several
    /// operators: `cloud.o2online.es` is O2 Spain, `cloud.o2.de` is o2 Germany, and the protocol is the same.
    @Published private(set) var host: String
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

    /// The address O2's own client uses to start the flow.
    var start: URL { O2WebSession.start(host: host) }

    /// Points the window at another operator's server. The view is rebuilt around the new host, so whatever the old
    /// one had loaded is left behind rather than half-replaced.
    func use(host newHost: String) {
        let clean = newHost.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .split(separator: "/").first.map(String.init) ?? ""
        guard !clean.isEmpty, clean != host else { return }
        stop()
        done = false
        canFinishByHand = false
        failed = nil
        status = L("Abriendo el acceso de O2…")
        host = clean
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
                // Any cookie at all appears the moment the first page loads, so offering the way out from there
                // invited people to press it before they had typed anything. A session cookie is the earliest sign
                // that there is something worth keeping.
                self.canFinishByHand = mine.contains { $0.name.uppercased().contains("SESSION") || $0.name == "validationKey" }
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
    @State private var showServer = false
    @State private var server = ""

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
                Button(showServer ? "Ocultar servidor" : "Servidor…") {
                    server = login.host
                    showServer.toggle()
                }.help("Elegir el servidor de otro operador con la misma plataforma")
                Button("Cancelar") { finish() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            if showServer {
                HStack(spacing: 8) {
                    Text("Servidor").font(.caption)
                    TextField("cloud.o2online.es", text: $server).textFieldStyle(.roundedBorder)
                    Button("Cargar") { login.use(host: server) }.disabled(server.trimmingCharacters(in: .whitespaces).isEmpty)
                }.padding(.horizontal, 12).padding(.bottom, 8)
                Text("La plataforma la revenden varios operadores. Déjalo como está para O2 España; para o2 Alemania es cloud.o2.de.")
                    .font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            O2WebView(model: login).id(login.host)
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

/// The sign-in that lives in WebKit's own store, which is not the Keychain and not iCloudy's to keep quietly.
///
/// Signing in happens on O2's pages, and what makes a silent renewal possible is that the session at Telefónica
/// outlives the one at O2. That is a credential in everything but name: with it, opening the sign-in window hands
/// out a working session without anybody typing anything. Disconnecting the account has to take it too, or
/// "disconnect" would mean rather less than it says.
enum O2WebSession {
    /// How this Mac introduces itself to the platform.
    ///
    /// Funambol keeps a list of devices per account. A fresh random identifier on every sign-in and every silent
    /// renewal filled that list with thirty entries a month, and some deployments cap it and start expelling the
    /// oldest — which is one more way for a session to die for no reason anybody can see from here.
    static func deviceID(host: String) -> String {
        let key = "o2DeviceID." + host
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty { return stored }
        let fresh = "web-icloudy-" + UUID().uuidString.prefix(12)
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
    /// Where the sign-in starts. O2's own client does nothing but navigate here; the server takes it from there.
    static func start(host: String) -> URL {
        URL(string: "https://\(host)/sapi/oauth/pkce/authorize?platform=web&deviceid=\(deviceID(host: host))")
            ?? URL(string: "https://\(host)/")!
    }
    /// The operator's own domains, where the sign-in that outlives the O2 session really happens. The silent
    /// renewal keeps cookies from exactly these, so disconnecting has to clear exactly these too: one list, not two
    /// that drift apart.
    static let signInDomains = ["o2online.es", "telefonica.es", "movistar.es"]
    /// Cleared as well, although nothing is ever kept from them: o2 Germany's own domain and Telefónica's other
    /// one. Deleting more than was stored is the safe direction for a disconnection.
    private static let alsoCleared = ["o2.de", "telefonica.com"]
    /// Hosts whose stored data belongs to this sign-in: O2's own server and the operator's identity provider.
    static func belongs(_ record: String, host: String) -> Bool {
        let name = record.lowercased(), server = host.lowercased()
        if server == name || server.hasSuffix("." + name) { return true }
        return signInDomains.contains(name) || alsoCleared.contains(name)
    }
    @MainActor
    static func forget(host: String) async {
        let store = WKWebsiteDataStore.default()
        let types: Set<String> = [WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage,
                                  WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases]
        let records = await store.dataRecords(ofTypes: types)
        let doomed = records.filter { belongs($0.displayName, host: host) }
        guard !doomed.isEmpty else { return }
        await store.removeData(ofTypes: types, for: doomed)
        O2Log.record("sesión web olvidada · \(doomed.count) registros")
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
    /// The same list the sign-in window harvests from and disconnecting clears.
    static let signInDomains = O2WebSession.signInDomains
    init(host: String) { self.host = host }

    /// Returns the new session, or nil when it could not be had without the person taking part.
    func attempt(sso: [HTTPCookie] = [], timeout: TimeInterval = 25) async -> (key: String, cookies: [HTTPCookie], userAgent: String?, sso: [HTTPCookie])? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        self.webView = webView
        defer { self.webView = nil }

        let start = O2WebSession.start(host: host)
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
