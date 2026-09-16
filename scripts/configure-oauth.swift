import Foundation

// Developer-only setup. OAuth metadata is bundled when the app is built.
struct Configuration: Codable {
    var googleClientID = ""
    var googleDesktopClientSecret = ""
    var microsoftClientID = ""
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
        if args.contains("--require-oauth") && !(googleValid && microsoftValid) {
            fail("No se puede preparar una distribución: faltan clientes OAuth válidos de Google y Microsoft. Consulta docs/OAUTH.md.")
        }
        print("OAuth Google: \(googleValid ? "configurado" : "pendiente") · Microsoft: \(microsoftValid ? "configurado" : "pendiente")")
        exit(0)
    }
    guard !args.isEmpty, args.count.isMultiple(of: 2) else {
        fail("Uso: swift scripts/configure-oauth.swift --google /ruta/cliente-desktop.json --microsoft APPLICATION_CLIENT_ID\nPuedes configurar un proveedor cada vez. No se imprimen los valores.")
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
        default: fail("Opción no reconocida: \(args[index])")
        }
    }
    let encoder = PropertyListEncoder(); encoder.outputFormat = .xml
    try encoder.encode(config).write(to: destination, options: .atomic)
    print("Configuración guardada en Configuration/OAuth.local.plist. Compila con bash scripts/build-app.sh --require-oauth.")
} catch { fail("No se pudo leer o guardar la configuración OAuth. Comprueba la ruta y el formato del archivo.") }
