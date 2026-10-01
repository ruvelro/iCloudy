import Foundation

/// What a provider without a version history answers. The reason is the same one the interface shows beside the
/// disabled action, so a call that slips past the capability check still explains itself.
extension CloudProvider {
    func versions(of file: CloudFile) async throws -> [FileVersion] { throw CloudError.message(account.versionsUnavailable) }
    func versionContentRequest(for file: CloudFile, version: String, exportMime: String?) async throws -> URLRequest {
        throw CloudError.message(account.versionsUnavailable)
    }
    func restoreVersion(_ version: FileVersion, of file: CloudFile) async throws { throw CloudError.message(account.versionsUnavailable) }
    func deleteVersion(_ version: FileVersion, of file: CloudFile) async throws {
        throw CloudError.message(account.versionLimitation(.delete, version: version, of: file) ?? account.versionsUnavailable)
    }
}

/// What can be done with one version of a file.
enum VersionAction { case download, restore, delete }

extension Account {
    /// Why this account has no version history to show, provider by provider.
    var versionsUnavailable: String {
        switch cloud {
        case .webdav: return L("Solo Nextcloud guarda versiones de los archivos. Si este servidor lo es, vuelve a conectarlo con la opción «Servidor Nextcloud u ownCloud» marcada.")
        case .mega: return L("Mega guarda versiones, pero las sirve con un protocolo propio que iCloudy todavía no habla. Consúltalas en mega.nz.")
        case .o2: return L("O2 Cloud no ofrece el historial de versiones a otras aplicaciones.")
        case .volume: return L("Un volumen no guarda versiones de los archivos; de eso se encargan Time Machine o la aplicación que los edita.")
        default: return L("\(cloud.title) no guarda versiones anteriores de los archivos.")
        }
    }

    /// Why "Versiones…" is not available for this item, or nil when it is.
    func versionsLimitation(for file: CloudFile) -> String? {
        guard capabilities.versions else { return versionsUnavailable }
        if file.isFolder { return L("Las carpetas no tienen versiones. Ábrela y consulta las de cada archivo.") }
        if file.mime == "application/vnd.google-apps.shortcut" { return L("Es un acceso directo. Abre el original para ver sus versiones.") }
        if file.mime == "application/vnd.google-apps.form" { return L("Google Drive no guarda versiones de los formularios.") }
        return nil
    }

    /// Why `action` cannot be applied to `version` of `file`, or nil when it can.
    func versionLimitation(_ action: VersionAction, version: FileVersion, of file: CloudFile) -> String? {
        switch action {
        case .download:
            return nil
        case .restore:
            if version.isCurrent { return L("Esta ya es la versión actual.") }
            if file.isGoogleDocument {
                return L("Google Drive no deja restaurar versiones de sus documentos desde otras aplicaciones. Usa «Historial de versiones» en el propio documento, o exporta esta versión.")
            }
            return nil
        case .delete:
            guard capabilities.deletesVersions else {
                switch cloud {
                case .microsoft: return L("OneDrive no permite borrar versiones sueltas desde otras aplicaciones. Las antiguas caducan según la configuración de la biblioteca.")
                case .dropbox: return L("Dropbox no permite borrar revisiones sueltas. Caducan solas según el plan de la cuenta.")
                default: return versionsUnavailable
                }
            }
            if version.isCurrent { return L("La versión actual no se puede borrar. Restaura otra antes, o envía el archivo a la papelera.") }
            if file.isGoogleDocument { return L("Google Drive solo borra versiones de archivos subidos, no de sus propios documentos.") }
            return nil
        }
    }
}
