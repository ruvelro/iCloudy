import SwiftUI
import AppKit
import QuickLookUI
import AVKit
import UniformTypeIdentifiers

@MainActor
final class PreviewWindow: NSObject, NSWindowDelegate {
    let model = PreviewModel()
    private var window: NSPanel?
    private weak var quickLook: PreviewContainer?
    var isVisible: Bool { window?.isVisible == true }
    var download: ((CloudFile, Account) -> Void)?
    var openBrowser: ((CloudFile) -> Void)?
    /// Reports a copy the user chose to keep, so the explorer can mark that file as present on this Mac.
    var didSaveCopy: ((CloudFile, Account, URL) -> Void)?
    /// «Abrir con…»: the explorer opens its own watched copy in the app, the system's choice when the URL is nil.
    var openWith: ((CloudFile, Account, URL?) -> Void)?

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
            // Quick Look's panel goes full screen; so does this one.
            panel.collectionBehavior.insert(.fullScreenPrimary)
            panel.delegate = self; panel.center(); window = panel
        }
        window?.title = L("Vista previa · \(file.name)")
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
    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    /// The share sheet for the downloaded copy, anchored to the button that asked for it.
    func share(from view: NSView) {
        guard let url = model.localURL else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
    func saveCopy() async {
        guard let source = model.localURL, let file = model.file, let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = FileNames.safe(file.name)
        panel.prompt = L("Guardar copia")
        panel.message = L("Se guardará una copia local, sin modificar el archivo de la nube. Elige un nombre que no exista.")
        guard await panel.beginSheetModal(for: window) == .OK, let destination = panel.url else { return }
        guard model.localURL == source else { model.saveError = L("La vista previa cambió; vuelve a elegir Guardar copia."); return }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        do {
            try model.saveCopy(to: destination)
            if let account = model.account { didSaveCopy?(file, account, destination) }
        }
        catch { model.saveError = L("No se pudo guardar la copia. Si ya existe un archivo con ese nombre, elige otro. \(error.localizedDescription)") }
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

/// Local playback only: the file is complete on disk before the player sees it.
private struct MediaPreview: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player = AVPlayer(url: url) }
            .onDisappear { player?.pause(); player = nil }
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
                    Text(model.file?.name ?? L("Vista previa")).font(.headline).lineLimit(1)
                    Text(model.account?.email ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.phase == .ready, let file = model.file, let account = model.account {
                    PreviewTools(model: model, owner: owner, file: file, account: account)
                }
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
                    } else if let url = model.localURL, case .media = model.kind {
                        MediaPreview(url: url).id(url)
                    } else if let url = model.localURL, case .image = model.kind, let image = NSImage(contentsOf: url) {
                        // Pictures get a viewer of their own, with the zoom and the rotation QLPreviewView keeps to itself.
                        ZoomableImage(image: image).id(url)
                    } else if let url = model.localURL { NativePreview(url: url, owner: owner).id(url) }
                case .unsupported:
                    unavailable(L("Vista previa no disponible"), message: L("Se admiten PDF, imágenes, texto y código, audio y vídeo (MP4, MOV, MP3, M4A, WAV…), documentos de Office e iWork, y Google Docs, Sheets y Slides exportados a PDF. Otros formatos se descargan o se abren en el navegador."))
                case .failed(let message):
                    unavailable(L("No se pudo previsualizar"), message: message)
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

/// The buttons Quick Look has and the preview lacked: full screen, share, and open with another app.
private struct PreviewTools: View {
    @ObservedObject var model: PreviewModel
    let owner: PreviewWindow
    let file: CloudFile
    let account: Account

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button("Aplicación predeterminada") { owner.openWith?(file, account, nil) }
                Divider()
                ForEach(Self.applications(for: file), id: \.self) { app in
                    Button(FileManager.default.displayName(atPath: app.path)) { owner.openWith?(file, account, app) }
                }
            } label: { Label("Abrir con", systemImage: "arrow.up.forward.app") }
                .fixedSize().help("Abre una copia en otra aplicación y sube los cambios que guardes")
            ShareButton(owner: owner)
                .frame(width: 28, height: 22)
                .help("Compartir").accessibilityLabel("Compartir")
            Button { owner.toggleFullScreen() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Pantalla completa (⌃⌘F)").accessibilityLabel("Pantalla completa")
                .keyboardShortcut("f", modifiers: [.command, .control])
        }
    }

    static func applications(for file: CloudFile) -> [URL] {
        let ext = (file.name as NSString).pathExtension
        guard let type = UTType(filenameExtension: ext) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
    }
}

/// An AppKit button, because the sharing picker needs a view to hang from.
private struct ShareButton: NSViewRepresentable {
    let owner: PreviewWindow
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: L("Compartir")) ?? NSImage(),
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .texturedRounded
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) { context.coordinator.owner = owner }
    func makeCoordinator() -> Coordinator { Coordinator(owner: owner) }
    @MainActor final class Coordinator: NSObject {
        var owner: PreviewWindow
        init(owner: PreviewWindow) { self.owner = owner }
        @objc func share(_ sender: NSButton) { owner.share(from: sender) }
    }
}

/// A picture that can be zoomed and turned: ⌘+ and ⌘- zoom, ⌘0 fits it, the arrows turn it.
struct ZoomableImage: View {
    let image: NSImage
    @State private var scale: CGFloat = 1
    @State private var turns = 0
    static let steps: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]

    var body: some View {
        GeometryReader { geometry in
            let fitted = Self.fitted(image.size, turns: turns, in: geometry.size)
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image).resizable().interpolation(.high)
                    .frame(width: fitted.width * scale, height: fitted.height * scale)
                    .rotationEffect(.degrees(Double(turns) * 90))
                    .frame(width: max(geometry.size.width, (turns.isMultiple(of: 2) ? fitted.width : fitted.height) * scale),
                           height: max(geometry.size.height, (turns.isMultiple(of: 2) ? fitted.height : fitted.width) * scale))
            }
            .accessibilityElement().accessibilityLabel("Imagen").accessibilityValue(L("Zoom \(Int(scale * 100)) %"))
        }
        .overlay(alignment: .bottom) {
            HStack(spacing: 4) {
                Button { scale = Self.step(scale, by: -1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command).help("Reducir (⌘-)").accessibilityLabel("Reducir")
                Button { scale = 1 } label: { Text("\(Int(scale * 100)) %").monospacedDigit().frame(minWidth: 44) }
                    .keyboardShortcut("0", modifiers: .command).help("Ajustar a la ventana (⌘0)")
                Button { scale = Self.step(scale, by: 1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("+", modifiers: .command).help("Ampliar (⌘+)").accessibilityLabel("Ampliar")
                Divider().frame(height: 14)
                Button { turns = (turns + 3) % 4 } label: { Image(systemName: "rotate.left") }
                    .help("Girar a la izquierda").accessibilityLabel("Girar a la izquierda")
                Button { turns = (turns + 1) % 4 } label: { Image(systemName: "rotate.right") }
                    .help("Girar a la derecha").accessibilityLabel("Girar a la derecha")
            }
            .buttonStyle(.borderless).padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule()).padding(10)
        }
    }

    /// The next zoom step up or down from `scale`.
    static func step(_ scale: CGFloat, by direction: Int) -> CGFloat {
        direction > 0 ? (steps.first { $0 > scale + 0.001 } ?? steps.last!) : (steps.last { $0 < scale - 0.001 } ?? steps.first!)
    }

    /// The size that fits the picture, turned, inside the window at 100 %. Never larger than the picture itself.
    static func fitted(_ size: CGSize, turns: Int, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return size }
        let turned = turns.isMultiple(of: 2) ? size : CGSize(width: size.height, height: size.width)
        let ratio = min(1, box.width / turned.width, box.height / turned.height)
        return CGSize(width: size.width * ratio, height: size.height * ratio)
    }
}
