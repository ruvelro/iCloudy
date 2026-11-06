import Foundation

/// What the explorer window has on screen besides the files: alerts, confirmations and sheets.
///
/// Twenty-seven of these used to sit on the model among the accounts, the queue and the workspace, so a view that
/// presented one sheet named the whole model to do it and anything could open anything. They are the window's state,
/// read as `model.ui.…`; the model sets them when an action needs the person's answer.
@MainActor
@Observable
final class ExplorerPresentation {
    /// The last thing that went wrong. The model reports through `AppModel.error`, which forwards here.
    var error: String?
    /// Non-error feedback, e.g. "link copied". Shown in a plain alert.
    var info: String?
    /// SwiftUI presents one alert at a time, so an error and a piece of good news arriving together meant the second
    /// one never appeared at all. They share a presentation now: the error goes first and the other waits its turn.
    var alertTitle: String { error != nil ? L("No se pudo completar la operación") : L("iCloudy") }
    var alertMessage: String? { error ?? info }
    func dismissAlert() { if error != nil { error = nil } else { info = nil } }

    // MARK: Confirmations

    /// A move from one pane to another account, waiting for confirmation.
    var pendingPaneMove: PaneMoveRequest?
    /// File awaiting confirmation before a public link is created for it.
    var pendingShare: (file: CloudFile, account: Account)?
    /// S3 file awaiting the choice of how long its presigned link lives.
    var pendingTemporaryLink: (file: CloudFile, account: Account)?
    /// Items awaiting confirmation before being sent to the provider's trash.
    var pendingTrash: [CloudFile]?
    /// Items awaiting confirmation before being deleted for good, from the trash or straight from the tree.
    var pendingPurge: [CloudFile]?
    /// True while the confirmation to empty the whole trash is showing.
    var pendingEmptyTrash = false

    // MARK: Sheets

    /// The item whose sharing sheet is open.
    var sharing: SharingRequest?
    /// The item whose public links sheet is open, and the account whose list of every link is open.
    var publicLinkManager: PublicLinksRequest?
    var linkInventory: Account?
    /// The file whose versions sheet is open.
    var versionHistory: VersionsRequest?
    /// A selection whose new names are being chosen.
    var batchRename: BatchRenameRequest?
    /// Move or copy in progress of being targeted; drives the folder picker sheet.
    var relocation: Relocation?
    /// Cross-cloud transfer waiting for its destination account.
    var crossCloud: CrossCloudRequest?
    /// The account whose name and colour are being edited.
    var appearanceAccount: Account?
    var showGlobalSearch = false
    /// «Ir a la carpeta…» (⇧⌘G).
    var showGoToFolder = false
    /// The pane whose breadcrumbs are being typed over as a path (⌘L), if any.
    var editingPath: Int?
    /// The name sheet, for a new folder or a rename.
    var showNameDialog = false
    var editName = ""
    var editingFile: CloudFile?

    // MARK: Connecting

    var showConnect = false
    /// Self-hosted provider whose credentials form is open, if any.
    var serverLogin: Cloud?
    /// The account that form was opened to reconnect, so it arrives with its address and user already written.
    /// Retyping a NAS address from memory to fix a session is a poor way to ask somebody for a password.
    var reconnecting: Account?
    /// Host of the O2 account being connected, which also drives the sign-in window.
    var o2Login: O2LoginRequest?
    /// True while the advanced sheet for shared drives and document libraries is open.
    var showAdvanced = false
    var connecting = false
    var connectionError: String?
}
