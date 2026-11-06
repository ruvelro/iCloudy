import AppKit

extension AppModel {
    /// Asks for a local folder and keeps it as a copy of the given remote folder of the current account.
    func pickDownloadMirror(for folder: CloudFile) async {
        guard let account, folder.isFolder else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("Mantener aquí")
        panel.message = L("La carpeta elegida se mantendrá como copia de «\(folder.name)»: lo nuevo y lo cambiado en la nube se baja y se comprueba. Solo en un sentido: nada del Mac se sube, y lo que cambies aquí se deja como está.")
        guard await panel.begin() == .OK, let local = panel.url else { return }
        do {
            try mirrors.add(local: local, account: account, folder: folder, path: path, mode: .download)
            info = L("«\(local.lastPathComponent)» se mantiene como copia de «\(folder.name)». La primera descarga está en marcha.")
        } catch { self.error = error.localizedDescription }
    }
}
