import Foundation
import AppKit

extension AppModel {
    /// Connects the iCloud Drive folder of this Mac. Under the sandbox only a folder the person picks can be read, so
    /// the panel opens on it and the person confirms; the bookmark then keeps the access, as for any volume.
    func connectICloudDrive() async {
        guard !ui.connecting else { return }
        ui.connectionError = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.prompt = L("Conectar")
        panel.message = L("Confirma la carpeta de iCloud Drive (o elige una carpeta dentro de ella). iCloudy solo verá lo que hay dentro.")
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            panel.directoryURL = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        }
        guard await panel.begin() == .OK, let folder = panel.url else { return }
        ui.connecting = true
        defer { ui.connecting = false }
        do {
            let account = try Self.iCloudDriveAccount(folder: folder, bookmark: try TransferQueue.bookmark(folder))
            try directory.adopt(account, credential: nil)
            select(account.id); ui.showConnect = false
        } catch { ui.connectionError = error.localizedDescription }
    }

    /// The account for a folder of iCloud Drive, refusing any folder that is not in it.
    nonisolated static func iCloudDriveAccount(folder: URL, bookmark: Data?) throws -> Account {
        let standardized = folder.standardizedFileURL
        let ubiquitous = (try? standardized.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
        guard ubiquitous || standardized.path.contains("/Library/Mobile Documents/") else {
            throw CloudError.message(L("Esa carpeta no está en iCloud Drive. Elige «iCloud Drive» o una carpeta dentro de él."))
        }
        let top = standardized.lastPathComponent == "com~apple~CloudDocs"
        var account = Account(id: "volume:" + standardized.path, cloud: .volume,
                              name: top ? L("iCloud Drive") : standardized.lastPathComponent,
                              email: top ? L("iCloud Drive de este Mac") : L("iCloud Drive") + " · " + standardized.lastPathComponent,
                              clientID: "", clientSecret: nil, serverURL: standardized.path, bookmark: bookmark)
        account.options["flavor"] = Account.iCloudFlavor
        return account
    }

    /// Downloads an iCloud item now, or removes its download, and shows the folder again with the new state.
    func setUbiquitousDownload(_ file: CloudFile, downloaded: Bool) async {
        guard let account, account.capabilities.ubiquitousItems else { return }
        do {
            guard let volume = try client(account).provider as? VolumeProvider else { return }
            if downloaded { try await volume.startUbiquitousDownload(file) } else { try await volume.evictUbiquitousItem(file) }
            reload(fresh: true)
        } catch { self.error = error.localizedDescription }
    }
}
