import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum AccountTint: String, Codable, CaseIterable, Identifiable {
    case blue, green, orange, purple, pink, red, teal, gray
    var id: String { rawValue }
    var color: Color {
        switch self { case .blue: return .blue; case .green: return .green; case .orange: return .orange
        case .purple: return .purple; case .pink: return .pink; case .red: return .red; case .teal: return .teal; case .gray: return .gray }
    }
    var title: String {
        switch self { case .blue: return "Azul"; case .green: return "Verde"; case .orange: return "Naranja"
        case .purple: return "Morado"; case .pink: return "Rosa"; case .red: return "Rojo"; case .teal: return "Turquesa"; case .gray: return "Gris" }
    }
}

struct AccountAppearance: Codable, Equatable {
    var alias = ""
    var tint: AccountTint = .blue
    var icon = "automatic"
    var customPNG: Data?
    static let presets: [(id: String, title: String)] = [
        ("automatic", "Proveedor"), ("drive", "Drive"), ("onedrive", "OneDrive"),
        ("briefcase.fill", "Trabajo"), ("person.fill", "Personal"), ("house.fill", "Casa"),
        ("graduationcap.fill", "Estudios"), ("building.2.fill", "Empresa"), ("externaldrive.fill", "Archivo"),
        ("camera.fill", "Fotos"), ("heart.fill", "Familia"), ("star.fill", "Favoritos")
    ]
    func title(for account: Account) -> String {
        let name = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (account.isDemo ? "Demo local" : account.cloud.title) : name
    }
    func validated() throws -> Self {
        var value = self
        value.alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.alias.count <= 60 else { throw CloudError.message(L("El alias admite hasta 60 caracteres.")) }
        guard !value.alias.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw CloudError.message(L("El alias no puede contener saltos de línea ni caracteres de control.")) }
        if icon == "custom" {
            guard let customPNG, customPNG.count <= 2_000_000, NSImage(data: customPNG) != nil else { throw CloudError.message(L("Elige una imagen válida para el icono.")) }
        } else {
            guard ["automatic", "drive", "onedrive"].contains(icon) || NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil else { throw CloudError.message(L("Ese símbolo de macOS no existe. Elige un predefinido o una imagen.")) }
            value.customPNG = nil
        }
        return value
    }
    static func importIcon(from url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 10_000_000 else { throw CloudError.message(L("Elige una imagen de hasta 10 MB.")) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CloudError.message(L("Formato no compatible. Prueba PNG, JPEG, HEIC, GIF o TIFF.")) }
        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CloudError.message(L("No se pudo preparar el icono.")) }
        return png
    }
}

final class AppearanceStore {
    let url: URL
    private(set) var values: [String: AccountAppearance]
    init(url: URL = LocalStore.directory.appendingPathComponent("account-appearance.json")) throws {
        self.url = url; values = try LocalStore.read([String: AccountAppearance].self, from: url) ?? [:]
    }
    func save(_ appearance: AccountAppearance, for accountID: String) throws {
        var updated = values; updated[accountID] = try appearance.validated()
        try LocalStore.save(updated, to: url); values = updated
    }
}

struct AccountIcon: View {
    let account: Account
    let appearance: AccountAppearance
    var size: CGFloat = 28
    private var icon: String { appearance.icon == "automatic" ? (account.isDemo ? "externaldrive.fill" : (account.cloud == .google ? "drive" : "onedrive")) : appearance.icon }
    var body: some View {
        Group {
            if icon == "custom", let png = appearance.customPNG, let image = NSImage(data: png) {
                Image(nsImage: image).resizable().scaledToFit()
            } else if icon == "drive" {
                Canvas { context, canvas in
                    func polygon(_ points: [CGPoint], color: Color) {
                        var path = Path(); path.addLines(points.map { CGPoint(x: $0.x * canvas.width / 32, y: $0.y * canvas.height / 32) }); path.closeSubpath()
                        context.fill(path, with: .color(color))
                    }
                    polygon([.init(x: 11, y: 2), .init(x: 0, y: 22), .init(x: 6, y: 31), .init(x: 17, y: 11)], color: Color(red: 0.06, green: 0.62, blue: 0.35))
                    polygon([.init(x: 11, y: 2), .init(x: 21, y: 2), .init(x: 32, y: 22), .init(x: 21, y: 22)], color: Color(red: 0.98, green: 0.74, blue: 0.02))
                    polygon([.init(x: 6, y: 31), .init(x: 26, y: 31), .init(x: 32, y: 22), .init(x: 11, y: 22)], color: Color(red: 0.26, green: 0.52, blue: 0.96))
                }
            } else if icon == "onedrive" {
                Canvas { context, canvas in
                    var path = Path()
                    path.move(to: CGPoint(x: 3, y: 13))
                    path.addCurve(to: CGPoint(x: 15, y: 7), control1: CGPoint(x: 1, y: 5), control2: CGPoint(x: 10, y: 0))
                    path.addCurve(to: CGPoint(x: 28, y: 13), control1: CGPoint(x: 21, y: 2), control2: CGPoint(x: 29, y: 5))
                    path.addCurve(to: CGPoint(x: 28, y: 25), control1: CGPoint(x: 34, y: 14), control2: CGPoint(x: 34, y: 24))
                    path.addLine(to: CGPoint(x: 6, y: 25))
                    path.addCurve(to: CGPoint(x: 3, y: 13), control1: CGPoint(x: -1, y: 25), control2: CGPoint(x: -3, y: 15)); path.closeSubpath()
                    let scaled = path.applying(CGAffineTransform(scaleX: canvas.width / 32, y: canvas.height / 32))
                    context.fill(scaled, with: .linearGradient(Gradient(colors: [Color(red: 0.02, green: 0.27, blue: 0.65), .cyan]), startPoint: .zero, endPoint: CGPoint(x: canvas.width, y: canvas.height)))
                }
            } else { Image(systemName: icon).resizable().scaledToFit().padding(size * 0.12).foregroundStyle(appearance.tint.color) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct AccountAppearanceEditor: View {
    @ObservedObject var model: AppModel
    let account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AccountAppearance
    @State private var symbol = ""
    @State private var error: String?
    init(model: AppModel, account: Account) {
        self.model = model; self.account = account
        _draft = State(initialValue: model.appearance(for: account))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Personalizar nube").font(.title2.bold())
            HStack(spacing: 12) {
                AccountIcon(account: account, appearance: draft, size: 42)
                VStack(alignment: .leading) {
                    Text(draft.title(for: account)).font(.headline).foregroundStyle(draft.tint.color)
                    Text(account.cloud.title + " · " + account.email).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(draft.tint.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            TextField("Alias (opcional)", text: $draft.alias).textFieldStyle(.roundedBorder)
            HStack {
                Text("Color")
                ForEach(AccountTint.allCases) { tint in
                    Button { draft.tint = tint } label: {
                        Circle().fill(tint.color).frame(width: 24, height: 24)
                            .overlay { if draft.tint == tint { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                    }.buttonStyle(.plain).help(tint.title).accessibilityLabel(tint.title)
                }
            }
            Text("Iconos predefinidos").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                ForEach(AccountAppearance.presets, id: \.id) { preset in
                    Button { draft.icon = preset.id } label: {
                        VStack(spacing: 5) {
                            AccountIcon(account: account, appearance: AccountAppearance(tint: draft.tint, icon: preset.id))
                            Text(LocalizedStringKey(preset.title)).font(.caption2)
                        }.frame(maxWidth: .infinity).padding(8)
                            .background(draft.icon == preset.id ? draft.tint.color.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityLabel(preset.title)
                }
            }
            HStack {
                TextField("Otro símbolo de macOS, p. ej. gamecontroller.fill", text: $symbol).textFieldStyle(.roundedBorder)
                Button("Usar símbolo") {
                    let name = symbol.trimmingCharacters(in: .whitespacesAndNewlines)
                    if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { draft.icon = name; error = nil }
                    else { error = L("Símbolo no encontrado. Puedes usar un predefinido o elegir una imagen.") }
                }
            }
            HStack {
                Button("Elegir imagen del Mac…") { Task { await pickImage() } }
                Text("Hasta 10 MB · Se guarda una copia local").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Solo cambia cómo ves esta cuenta en iCloudy. No se sube nada a la nube.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Restablecer") { draft = AccountAppearance(); error = nil }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") {
                    do { try model.saveAppearance(draft, for: account); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 560)
    }
    private func pickImage() async {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.prompt = L("Usar como icono")
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do { draft.customPNG = try AccountAppearance.importIcon(from: url); draft.icon = "custom"; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

extension AccountAppearance {
    enum CodingKeys: String, CodingKey { case alias, tint, icon, customPNG }
    /// Missing keys fall back to defaults so a new property never discards existing customisations.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(alias: try values.decodeIfPresent(String.self, forKey: .alias) ?? "",
                  tint: try values.decodeIfPresent(String.self, forKey: .tint).flatMap(AccountTint.init(rawValue:)) ?? .blue,
                  icon: try values.decodeIfPresent(String.self, forKey: .icon) ?? "automatic",
                  customPNG: try values.decodeIfPresent(Data.self, forKey: .customPNG))
    }
}
