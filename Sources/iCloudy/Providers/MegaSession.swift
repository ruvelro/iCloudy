import Foundation

/// One entry of Mega's tree. Mega sends the whole tree in a single response, which is why this provider can search
/// and build breadcrumbs without asking the server anything.
struct MegaNode: Hashable {
    let handle: String
    var parent: String
    /// 0 file, 1 folder, 2 the account's root, 3 inbox, 4 trash.
    let kind: Int
    var name: String
    let size: Int64?
    let modified: Date?
    /// Decrypted node key: 32 bytes for a file, 16 for a folder. Empty when the node was shared with a key that this
    /// account cannot read, in which case the name is unknown too and the node is shown as unavailable.
    let key: Data
    var isFolder: Bool { kind != 0 }
    var isReadable: Bool { !key.isEmpty || kind >= 2 }
    /// The key that decrypts this node's contents and attributes.
    var contentKey: Data { kind == 0 ? (MegaCrypto.unpack(fileKey: key)?.key ?? Data()) : key }
}

/// A signed-in Mega session: the identifier the server accepts, the master key that unwraps every node key, and the
/// tree itself once it has been fetched.
final class MegaState {
    let sid: String
    let masterKey: Data
    var nodes: [String: MegaNode] = [:]
    var children: [String: [String]] = [:]
    var root = ""
    var trash = ""
    var loaded = false
    /// Mega numbers requests so a retried call is not applied twice.
    var sequence = Int.random(in: 0..<1_000_000)
    init(sid: String, masterKey: Data) { self.sid = sid; self.masterKey = masterKey }
}

/// Mega's API is one endpoint that takes an array with a single command and answers with an array or a negative
/// number. This is an unofficial protocol with no published specification, which is why the provider is experimental:
/// Mega can change it without notice and has done so before.
enum MegaAPI {
    static let endpoint = "https://g.api.mega.co.nz/cs"

    /// Turns Mega's numeric failures into something a person can act on. The codes are the ones its own clients use.
    static func failure(_ code: Int) -> CloudError {
        switch code {
        case -3: return .message(L("Mega sigue ocupado con esa operación. Espera unos segundos y vuelve a intentarlo."))
        case -2: return .message(L("Mega rechazó la petición por incorrecta."))
        case -6, -4: return .message(L("Demasiadas peticiones a Mega. Espera un momento y vuelve a intentarlo."))
        case -8, -15: return .sessionExpired(L("La sesión de Mega ha caducado. Vuelve a iniciar sesión."))
        case -9: return .message(L("Ese elemento ya no está en Mega."))
        case -11: return .message(L("La cuenta no tiene permiso para esa operación."))
        case -12: return .message(L("Ya existe un elemento con ese nombre."))
        case -13: return .message(L("La operación quedó incompleta. Vuelve a intentarlo."))
        case -14: return .message(L("La clave no corresponde a ese elemento."))
        case -16: return .message(L("Mega ha bloqueado esta cuenta."))
        case -17: return .message(L("La cuenta de Mega ha superado su cuota."))
        case -26: return .message(L("Esta cuenta tiene verificación en dos pasos. Escribe la contraseña, un espacio y el código de seis dígitos."))
        default: return .message(L("Mega devolvió el error \(code)."))
        }
    }

    /// Sends one command. Mega answers -3 when a value is not ready yet and expects the client to wait and ask again,
    /// so that case is retried here rather than shown to the user.
    static func call(_ payload: [String: Any], sid: String?, sequence: Int,
                     session: URLSession = .shared) async throws -> Any {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [URLQueryItem(name: "id", value: String(sequence))]
            + (sid.map { [URLQueryItem(name: "sid", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [payload])

        // Two different reasons to send the same request again, each with its own budget. Sharing one counter meant
        // that solving a proof of work ate the patience meant for a server that had merely said "wait".
        var proofs = 0
        var waits = 0
        while true {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudError.message(L("Respuesta HTTP no válida.")) }
            // Mega guards its account endpoints with a proof of work: 402 with a challenge and an empty body, which
            // the client has to solve before the same request is accepted.
            if http.statusCode == 402, let challenge = http.value(forHTTPHeaderField: "X-Hashcash"), proofs < Self.maxProofs {
                proofs += 1
                request.setValue(try await solve(challenge), forHTTPHeaderField: "X-Hashcash")
                continue
            }
            guard http.statusCode != 500 else { throw CloudError.message(L("Mega no está disponible en este momento.")) }
            // Mega answers plenty of commands with a bare number: 0 after a rename or a move, a negative code on
            // failure. That is a JSON fragment, which the strict parser refuses, so fragments have to be allowed or
            // every one of those replies looks like a broken response.
            let body = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            var result: Any? = body
            if let list = body as? [Any] { result = list.first }
            if let code = result as? Int, code < 0 {
                guard code == -3, waits < Self.maxWaits else { throw failure(code) }
                // Mega's own clients back off and keep asking. Half a second five times was not nearly enough: a
                // delete would surface "-3" to the user and work fine the moment they tried it again by hand.
                try await Task.sleep(nanoseconds: Self.waitDelay(waits))
                waits += 1
                continue
            }
            guard let result else {
                throw CloudError.message(L("Mega devolvió una respuesta que no se entiende (HTTP \(http.statusCode))."))
            }
            return result
        }
        throw CloudError.message(L("Mega sigue ocupado. Vuelve a intentarlo dentro de un momento."))
    }

    /// Value Mega's own clients send to get transfer addresses over TLS.
    static let useTLS = 2

    /// How many times a request is repeated for each reason, and how long the waits grow.
    static let maxProofs = 2
    static let maxWaits = 8
    /// Doubling from a third of a second, capped so a single call cannot hang for minutes. About half a minute in
    /// total, which is the order Mega's own clients wait before giving up.
    static func waitDelay(_ attempt: Int) -> UInt64 {
        let seconds = min(8.0, 0.3 * pow(2.0, Double(attempt)))
        return UInt64(seconds * 1_000_000_000)
    }

    /// Reads Mega's challenge and spends the work it asks for. The format is version, easiness, when it was issued,
    /// and the token to hash; only the easiness and the token take part in the answer.
    static func solve(_ challenge: String) async throws -> String {
        let parts = challenge.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "1", let easiness = Int(parts[1]), (0..<256).contains(easiness) else {
            throw CloudError.message(L("Mega envió un desafío que no se entiende."))
        }
        let token = parts[3]
        let prefix = try await blockingIO { try MegaCrypto.hashcash(token: token, easiness: easiness) }
        return "1:\(token):\(prefix)"
    }

    /// Signs in and derives the session identifier. The last step is an RSA decryption: Mega hands back a challenge
    /// encrypted with the account's public key, and only the private key inside the account proves who is asking.
    static func signIn(email: String, password: String, code: String?,
                       session: URLSession = .shared) async throws -> (sid: String, masterKey: Data) {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var sequence = Int.random(in: 0..<1_000_000)
        let start = try await call(["a": "us0", "user": email], sid: nil, sequence: sequence, session: session)
        sequence += 1
        let version = (start as? [String: Any])?["v"] as? Int ?? 1

        var login: [String: Any] = ["a": "us", "user": email]
        let derivedKey: Data
        if version >= 2 {
            guard let salt = (start as? [String: Any])?["s"] as? String else {
                throw CloudError.message(L("Mega no devolvió los datos necesarios para iniciar sesión."))
            }
            let derived = try await blockingIO { try MegaCrypto.derive(password: password, salt: MegaCrypto.decode(salt)) }
            derivedKey = derived.key
            login["uh"] = derived.hash
        } else {
            // Accounts created before 2018 still use the original derivation.
            let legacy = try await blockingIO { try MegaCrypto.legacyKey(password: password) }
            derivedKey = legacy
            login["uh"] = try await blockingIO { try MegaCrypto.legacyHash(email, key: legacy) }
        }
        if let code, !code.isEmpty { login["mfa"] = code }

        guard let answer = try await call(login, sid: nil, sequence: sequence, session: session) as? [String: Any],
              let wrappedMaster = answer["k"] as? String else {
            throw CloudError.message(L("Mega no devolvió los datos necesarios para iniciar sesión."))
        }
        // A wrong password produces a key that does not unwrap; that is the only signal Mega gives, so it is the one
        // turned into the message the user needs.
        let wrapped = MegaCrypto.decode(wrappedMaster)
        guard wrapped.count == 16, let masterKey = try? MegaCrypto.ecb(wrapped, key: derivedKey), masterKey.count == 16 else {
            throw CloudError.message(L("La contraseña de Mega no es correcta."))
        }

        guard let wrappedPrivate = answer["privk"] as? String, let challenge = answer["csid"] as? String else {
            throw CloudError.message(L("Esta cuenta de Mega no tiene clave privada. Ábrela una vez en mega.nz y vuelve a intentarlo."))
        }
        let privateKey = try MegaCrypto.ecb(MegaCrypto.decode(wrappedPrivate), key: masterKey)
        // Mega stores the private key as four numbers: the two prime factors, the exponent, and a coefficient it does
        // not need here. The factors arrive in the opposite order to the usual convention, which does not matter for a
        // plain modular exponentiation because their product is the same either way.
        let parts = MegaCrypto.integers(privateKey, count: 4)
        guard parts.count >= 3 else { throw CloudError.message(L("La clave privada de Mega no se pudo leer.")) }
        let encrypted = MegaCrypto.integers(MegaCrypto.decode(challenge), count: 1)
        guard let value = encrypted.first, let arithmetic = MegaMontgomery(modulus: parts[0] * parts[1]) else {
            throw CloudError.message(L("La clave privada de Mega no se pudo leer."))
        }
        let exponent = parts[2]
        let plain = try await blockingIO { arithmetic.power(base: value, exponent: exponent) }
        // The session identifier is the first 43 bytes of the decrypted challenge.
        let sid = MegaCrypto.encode(plain.data.prefix(43))
        guard sid.count > 8 else { throw CloudError.message(L("Mega no aceptó el inicio de sesión.")) }
        return (sid, masterKey)
    }

    /// Unwraps a node key. A node may carry several copies of its key, one per account it was shared with, so every
    /// candidate is tried and the one whose attributes decode is the right one.
    static func decrypt(node: [String: Any], masterKey: Data) -> (key: Data, name: String)? {
        let kind = node["t"] as? Int ?? 0
        let field = node["k"] as? String ?? ""
        let attributes = node["a"] as? String ?? ""
        for part in field.split(separator: "/") {
            // Normally "owner:key". A bare key is accepted too, because that is the shape a request carries and some
            // answers echo it back unchanged.
            let text = part.firstIndex(of: ":").map { String(part[part.index(after: $0)...]) } ?? String(part)
            let blob = MegaCrypto.decode(text)
            guard blob.count == (kind == 0 ? 32 : 16), let key = try? MegaCrypto.ecb(blob, key: masterKey) else { continue }
            let content = kind == 0 ? (MegaCrypto.unpack(fileKey: key)?.key ?? Data()) : key
            guard let values = MegaCrypto.attributes(MegaCrypto.decode(attributes), key: content),
                  let name = values["n"] as? String, !name.isEmpty else { continue }
            return (key, name)
        }
        return nil
    }

    /// Turns one entry of an `f` or `p` response into a node.
    static func node(from entry: [String: Any], masterKey: Data) -> MegaNode? {
        guard let handle = entry["h"] as? String else { return nil }
        let kind = entry["t"] as? Int ?? 0
        let decrypted = kind < 2 ? decrypt(node: entry, masterKey: masterKey) : nil
        let name: String
        switch kind {
        case 2: name = L("Mi nube")
        case 3: name = L("Entrada")
        case 4: name = L("Papelera")
        default: name = decrypted?.name ?? L("Elemento sin acceso")
        }
        let size = entry["s"] as? Int64 ?? (entry["s"] as? Int).map(Int64.init)
        return MegaNode(handle: handle, parent: entry["p"] as? String ?? "", kind: kind, name: name,
                        size: kind == 0 ? size : nil,
                        modified: (entry["ts"] as? Double).map { Date(timeIntervalSince1970: $0) },
                        key: decrypted?.key ?? Data())
    }
    /// Builds the tree from an `f` response, keeping the order Mega sends so parents are known before children.
    static func tree(_ files: [[String: Any]], masterKey: Data) -> MegaState.Tree {
        var nodes: [String: MegaNode] = [:]
        var children: [String: [String]] = [:]
        var root = ""
        var trash = ""
        for entry in files {
            guard let node = node(from: entry, masterKey: masterKey) else { continue }
            if node.kind == 2 { root = node.handle }
            if node.kind == 4 { trash = node.handle }
            nodes[node.handle] = node
            children[node.parent, default: []].append(node.handle)
        }
        return MegaState.Tree(nodes: nodes, children: children, root: root, trash: trash)
    }
}

extension MegaState {
    struct Tree { let nodes: [String: MegaNode]; let children: [String: [String]]; let root: String; let trash: String }
    func adopt(_ tree: Tree) {
        nodes = tree.nodes; children = tree.children
        root = tree.root; trash = tree.trash
        loaded = true
    }
    func next() -> Int { sequence += 1; return sequence }

    // MARK: - Keeping the tree current
    //
    // Mega sends the whole account in a single response, so fetching it again after every rename or move is slow and
    // pointless when the outcome is already known. Each change is applied here instead, and only something that
    // cannot be applied falls back to reloading.

    func rename(_ handle: String, to name: String) {
        guard var node = nodes[handle] else { loaded = false; return }
        node.name = name
        nodes[handle] = node
    }
    func reparent(_ handle: String, to parent: String) {
        guard var node = nodes[handle], nodes[parent] != nil else { loaded = false; return }
        children[node.parent]?.removeAll { $0 == handle }
        node.parent = parent
        nodes[handle] = node
        place(node)
    }
    /// Adds what a `p` response created. Anything that cannot be read forces a reload rather than a hole in the tree.
    func insert(_ entries: [[String: Any]]) {
        guard !entries.isEmpty else { loaded = false; return }
        for entry in entries {
            guard let node = MegaAPI.node(from: entry, masterKey: masterKey) else { loaded = false; continue }
            nodes[node.handle] = node
            place(node)
        }
    }
    private func place(_ node: MegaNode) {
        children[node.parent, default: []].removeAll { $0 == node.handle }
        children[node.parent, default: []].append(node.handle)
    }
}
