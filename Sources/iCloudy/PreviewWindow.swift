import SwiftUI
import AppKit
import QuickLookUI

@MainActor
final class PreviewWindow: NSObject, NSWindowDelegate {
    let model = PreviewModel()
    private var window: NSPanel?
    private weak var quickLook: PreviewContainer?
    var isVisible: Bool { window?.isVisible == true }
    var download: ((CloudFile, Account) -> Void)?
    var openBrowser: ((CloudFile) -> Void)?

    override init() {
        super.init()
        model.willDiscard = { [weak self] in
            self?.quickLook?.retire()
            self?.quickLook = nil
        }
    }
    func show(file: CloudFile, account: Account, client: CloudAPI) {
        model.open(file: file, account: account, client: client)
        if window == nil {
            let panel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 780, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 480, height: 350)
            panel.delegate = self; panel.center(); window = panel
        }
        window?.title = "Vista previa · " + file.name
        window?.contentView = NSHostingView(rootView: PreviewContent(model: model, owner: self))
        window?.makeKeyAndOrderFront(nil)
    }
    fileprivate func attach(_ view: PreviewContainer) { quickLook = view }
    func close() {
        model.close()
        window?.contentView = nil
        window?.orderOut(nil)
    }
    func windowWillClose(_ notification: Notification) { close() }
    func saveCopy() async {
        guard let source = model.localURL, let file = model.file, let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FileNames.safe(file.name)
        panel.prompt = "Guardar copia"
        panel.message = "Se guardará una copia local, sin modificar el archivo de la nube. Elige un nombre que no exista."
        guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url else { return }
        guard model.localURL == source else { model.saveError = "La vista previa cambió; vuelve a elegir Guardar copia."; return }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do { try model.saveCopy(to: destination) }
        catch { model.saveError = "No se pudo guardar la copia. Si ya existe un archivo con ese nombre, elige otro. \(error.localizedDescription)" }
    }
}

private final class PreviewPanel: NSPanel {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || event.keyCode == 49 { performClose(nil) }
        else { super.keyDown(with: event) }
    }
}

/// SwiftUI teardown can follow explicit window cleanup. Quick Look close is not idempotent.
@MainActor
final class PreviewContainer: NSView {
    private var preview: QLPreviewView?
    private(set) var retired = false
    init(url: URL) {
        super.init(frame: .zero)
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false; view.autostarts = false
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        preview = view; view.previewItem = url as NSURL
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func retire() {
        guard !retired else { return }
        retired = true
        preview?.previewItem = nil
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
    }
}

private struct NativePreview: NSViewRepresentable {
    let url: URL
    let owner: PreviewWindow
    func makeNSView(context: Context) -> PreviewContainer {
        let view = PreviewContainer(url: url)
        owner.attach(view)
        return view
    }
    func updateNSView(_ view: PreviewContainer, context: Context) {
        owner.attach(view)
    }
    static func dismantleNSView(_ view: PreviewContainer, coordinator: ()) {
        view.retire()
    }
}

private struct PlainTextPreview: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        let view = NSTextView(frame: .zero)
        view.isEditable = false; view.isRichText = false; view.isSelectable = true
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .textColor; view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 16, height: 16)
        view.autoresizingMask = [.width]; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.string = text; scroll.documentView = view
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        if let textView = view.documentView as? NSTextView, textView.string != text { textView.string = text }
    }
}

private struct PreviewContent: View {
    @ObservedObject var model: PreviewModel
    let owner: PreviewWindow
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(model.file?.name ?? "Vista previa").font(.headline).lineLimit(1)
                    Text(model.account?.email ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.phase == .ready { Button("Guardar copia…") { Task { await owner.saveCopy() } } }
                Button(model.phase == .loading ? "Cancelar" : "Cerrar") { owner.close() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider()
            Group {
                switch model.phase {
                case .idle: Color.clear
                case .confirmation:
                    VStack(spacing: 18) {
                        Image(systemName: "arrow.down.doc").font(.largeTitle)
                        Text(model.confirmationText).multilineTextAlignment(.center)
                        Button("Descargar temporalmente") { model.start() }.buttonStyle(.borderedProminent)
                    }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loading:
                    VStack(spacing: 16) {
                        if model.total > 0 { ProgressView(value: min(Double(model.received) / Double(model.total), 1)).frame(width: 250) }
                        else { ProgressView() }
                        Text("Preparando vista previa…")
                        Text(ByteCountFormatter.string(fromByteCount: model.received, countStyle: .decimal) + (model.total > 0 ? " / " + ByteCountFormatter.string(fromByteCount: model.total, countStyle: .decimal) : " descargados"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    if let text = model.text {
                        VStack(spacing: 0) {
                            if model.textTruncated { Text("Mostrando solo el primer MB de texto. Guardar copia conserva el archivo completo.").font(.caption).padding(8) }
                            if text.isEmpty { Text("Archivo de texto vacío").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                            else { PlainTextPreview(text: text) }
                        }
                    } else if let url = model.localURL { NativePreview(url: url, owner: owner).id(url) }
                case .unsupported:
                    unavailable("Vista previa no disponible", message: "Esta versión permite PDF, imágenes y texto. Los documentos de Google se abren en el navegador o se exportan desde su menú.")
                case .failed(let message):
                    unavailable("No se pudo previsualizar", message: message)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Text("Solo lectura · Copia temporal que se elimina al cerrar").font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .alert("Vista previa", isPresented: Binding(get: { model.saveError != nil }, set: { if !$0 { model.saveError = nil } })) {
            Button("Aceptar") { model.saveError = nil }
        } message: { Text(model.saveError ?? "") }
    }
    private func unavailable(_ title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "doc.questionmark")
        } description: { Text(message) } actions: {
            if let file = model.file, let account = model.account {
                if !file.isGoogleDocument { Button("Descargar…") { owner.download?(file, account) } }
                if file.webURL != nil { Button("Abrir en navegador") { owner.openBrowser?(file) } }
            }
        }
    }
}
