import Foundation

// Developer-only setup. OAuth metadata is bundled when the app is built.
struct Configuration: Codable {
    var googleClientID = ""
    var googleDesktopClientSecret = ""
    var microsoftClientID = ""
    var dropboxAppKey = ""
    var boxClientID = ""
    var boxClientSecret = ""

    /// A plist written by an older version has none of the newer keys; treat those providers as simply not configured.
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        googleClientID = try values.decodeIfPresent(String.self, forKey: .googleClientID) ?? ""
        googleDesktopClientSecret = try values.decodeIfPresent(String.self, forKey: .googleDesktopClientSecret) ?? ""
        microsoftClientID = try values.decodeIfPresent(String.self, forKey: .microsoftClientID) ?? ""
        dropboxAppKey = try values.decodeIfPresent(String.self, forKey: .dropboxAppKey) ?? ""
        boxClientID = try values.decodeIfPresent(String.self, forKey: .boxClientID) ?? ""
        boxClientSecret = try values.decodeIfPresent(String.self, forKey: .boxClientSecret) ?? ""
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let destination = URL(fileURLWithPath: "Configuration/OAuth.local.plist")
do {
    if args.first == "--validate" {
        guard args.count >= 2 else { fail("Falta la ruta de configuración.") }
        let config = try PropertyListDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let googleValid = config.googleClientID.hasSuffix(".apps.googleusercontent.com") && !config.googleClientID.contains(" ") && config.googleClientID.count > 30
        let microsoftValid = UUID(uuidString: config.microsoftClientID) != nil
        let dropboxValid = config.dropboxAppKey.count >= 10 && config.dropboxAppKey.allSatisfy { $0.isLetter || $0.isNumber }
        let boxValid = config.boxClientID.count >= 20 && config.boxClientID.allSatisfy { $0.isLetter || $0.isNumber }
        // WebDAV needs no registration: the user brings their own server.
        if args.contains("--require-oauth") && !(googleValid && microsoftValid) {
            fail("No se puede preparar una distribución: faltan clientes OAuth válidos de Google y Microsoft. Consulta docs/OAUTH.md.")
        }
        let state = { (ok: Bool) in ok ? "configurado" : "pendiente" }
        print("OAuth Google: \(state(googleValid)) · Microsoft: \(state(microsoftValid)) · Dropbox: \(state(dropboxValid)) · Box: \(state(boxValid)) · WebDAV: no necesita registro")
        exit(0)
    }
    guard !args.isEmpty, args.count.isMultiple(of: 2) else {
        fail("""
        Uso: swift scripts/configure-oauth.swift [--google /ruta/cliente-desktop.json] [--microsoft APPLICATION_CLIENT_ID] [--dropbox APP_KEY] [--box CLIENT_ID:CLIENT_SECRET]
        Puedes configurar un proveedor cada vez. WebDAV no necesita registro. No se imprimen los valores.
        """)
    }
    var config = FileManager.default.fileExists(atPath: destination.path)
        ? try PropertyListDecoder().decode(Configuration.self, from: Data(contentsOf: destination))
        : Configuration()
    for index in stride(from: 0, to: args.count, by: 2) {
        switch args[index] {
        case "--google":
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[index + 1]))) as? [String: Any]
            guard let installed = object?["installed"] as? [String: Any], let id = installed["client_id"] as? String, id.hasSuffix(".apps.googleusercontent.com") else {
                fail("Se requiere el JSON descargado de un cliente Google Desktop (installed). No se aceptan clientes Web ni cuentas de servicio.")
            }
            config.googleClientID = id
            config.googleDesktopClientSecret = installed["client_secret"] as? String ?? ""
        case "--microsoft":
            guard UUID(uuidString: args[index + 1]) != nil else { fail("Microsoft requiere el Application (client) ID en formato UUID, no el tenant ID ni un secreto.") }
            config.microsoftClientID = args[index + 1]
        case "--dropbox":
            let key = args[index + 1]
            guard key.count >= 10, key.allSatisfy({ $0.isLetter || $0.isNumber }) else { fail("Dropbox requiere la App key de la aplicación, no el App secret.") }
            config.dropboxAppKey = key
        case "--box":
            // Box hands out an id and a secret together, separated here by a colon.
            let parts = args[index + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].count >= 20, parts[0].allSatisfy({ $0.isLetter || $0.isNumber }) else {
                fail("Box requiere CLIENT_ID:CLIENT_SECRET de una aplicación OAuth 2.0 personalizada.")
            }
            config.boxClientID = parts[0]; config.boxClientSecret = parts[1]
        default: fail("Opción no reconocida: \(args[index])")
        }
    }
    let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
    try encoder.encode(config).write(to: destination, options: .atomic)
    print("Configuración guardada en Configuration/OAuth.local.plist. Compila con bash scripts/build-app.sh --require-oauth.")
} catch { fail("No se pudo leer o guardar la configuración OAuth. Comprueba la ruta y el formato del archivo.") }
