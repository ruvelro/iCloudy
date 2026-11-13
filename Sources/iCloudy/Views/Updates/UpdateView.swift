import SwiftUI
import AppKit

/// The «Actualizaciones» window: the outcome of the last check and, when there is a newer release, its notes, the
/// download link and the SHA-256 to check it against. Nothing is downloaded from here; the link opens the browser.
struct UpdateView: View {
    static let windowID = "updates"
    @Bindable var checker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch checker.status {
            case .idle, .checking:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Buscando actualizaciones…")
                }
            case .upToDate:
                Label("iCloudy está al día", systemImage: "checkmark.seal").font(.title3.weight(.semibold))
                Text("Tienes la versión \(checker.currentVersion), que es la más reciente publicada.")
                    .foregroundStyle(.secondary)
                footer
            case .failed(let message):
                Label("No se ha podido comprobar si hay una versión nueva", systemImage: "exclamationmark.triangle")
                    .font(.title3.weight(.semibold))
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Reintentar") { Task { await checker.check(manual: true) } }
                }
            case .available(let feed):
                UpdateDetails(feed: feed, checker: checker)
            }
        }
        .padding(20)
        .frame(width: 540, alignment: .leading)
        .onAppear { checker.pendingPrompt = nil }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Volver a buscar") { Task { await checker.check(manual: true) } }
        }
    }
}

private struct UpdateDetails: View {
    let feed: UpdateFeed
    let checker: UpdateChecker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Hay una versión nueva", systemImage: "arrow.down.app").font(.title3.weight(.semibold))
            Text("iCloudy \(feed.version) está disponible; tienes la \(checker.currentVersion).")
            if !feed.signed {
                Text("Esta versión no lleva firma de Apple: la primera vez, macOS pedirá que confirmes que quieres abrirla (botón derecho › Abrir).")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if feed.needsNewerSystem, let minimum = feed.minimumSystemVersion {
                Text("Necesita macOS \(minimum) o posterior, y este Mac tiene una versión anterior.")
                    .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                Text(Self.notes(feed.displayNotes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: 240)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            if let asset = feed.download {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHA-256 de \(asset.name)").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        Text(verbatim: asset.sha256).font(.caption.monospaced()).textSelection(.enabled)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Copiar") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(asset.sha256, forType: .string)
                        }.controlSize(.small)
                    }
                    Text("Compruébala en Terminal con «shasum -a 256» sobre el archivo descargado antes de abrirlo.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("iCloudy no se actualiza solo: descarga el archivo, comprueba la suma y sustituye la app en Aplicaciones. Tus cuentas y tu cola se conservan.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Omitir esta versión") { checker.skip(feed); dismiss() }
                Spacer()
                Button("Ver la versión en GitHub") { NSWorkspace.shared.open(feed.releaseURL) }
                if let asset = feed.download {
                    Button("Descargar") { NSWorkspace.shared.open(asset.url) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Inline Markdown (bold, code, links) with the line breaks of the CHANGELOG kept; plain text if it does not parse.
    static func notes(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// «Buscar actualizaciones…» in the app menu, right under «Acerca de iCloudy».
struct UpdateCommands: Commands {
    let checker: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Buscar actualizaciones…") {
                openWindow(id: UpdateView.windowID)
                Task { await checker.check(manual: true) }
            }
        }
    }
}

/// The settings tab: the automatic check, the installed version and when the last check was.
struct UpdateSettings: View {
    @Bindable var checker: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Toggle("Buscar actualizaciones automáticamente", isOn: $checker.automatic)
                Text("Una vez al día, iCloudy pide a GitHub la ficha de la última versión publicada. No envía nada más que esa petición, y nunca descarga ni instala nada: si hay una versión nueva, te lo dice y tú decides.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Versión instalada") {
                    Text(verbatim: checker.currentVersion + (checker.currentBuild.map { " (\($0))" } ?? ""))
                }
                LabeledContent("Última comprobación") {
                    if let lastCheck = checker.lastCheck {
                        Text(lastCheck, format: .dateTime.day().month().year().hour().minute())
                    } else {
                        Text("Nunca")
                    }
                }
                HStack {
                    Spacer()
                    Button("Buscar ahora") {
                        openWindow(id: UpdateView.windowID)
                        Task { await checker.check(manual: true) }
                    }.disabled(checker.status == .checking)
                }
            }
        }.formStyle(.grouped)
    }
}

/// Runs the daily check while the explorer is open and brings up the update window when it finds something.
struct UpdateCheckTrigger: ViewModifier {
    let checker: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .task { await checker.runSchedule() }
            .onChange(of: checker.pendingPrompt) { _, feed in
                if feed != nil { openWindow(id: UpdateView.windowID) }
            }
    }
}
