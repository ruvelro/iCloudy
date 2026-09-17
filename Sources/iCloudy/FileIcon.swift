import SwiftUI

/// The symbol and the colour a file is drawn with, by what the file actually is.
///
/// A list where every row carries the same grey `doc` is a list you have to read word by word. Giving a PDF its red,
/// a spreadsheet its green and a video its indigo means the eye finds the file before the brain reads the name, which
/// is the whole point of showing icons at all.
///
/// The kind is worked out from the extension first and the media type second. The extension wins because providers
/// disagree about media types — the same `.key` arrives as `application/octet-stream` from one and as
/// `application/vnd.apple.keynote` from another — while the name is the same everywhere.
enum FileKind: String {
    case folder, pdf, document, spreadsheet, presentation, image, video, audio, archive, code, text, font, disk, generic

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .pdf: return "doc.richtext.fill"
        case .document: return "doc.text.fill"
        case .spreadsheet: return "tablecells.fill"
        case .presentation: return "rectangle.stack.fill"
        case .image: return "photo.fill"
        case .video: return "film.fill"
        case .audio: return "waveform"
        case .archive: return "doc.zipper"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .text: return "doc.plaintext.fill"
        case .font: return "textformat"
        case .disk: return "opticaldiscdrive.fill"
        case .generic: return "doc.fill"
        }
    }
    /// Colours picked to stay legible on both the light and the dark window background, and to keep the families
    /// people already expect: red for PDF, blue for documents, green for sheets, orange for slides.
    var tint: Color {
        switch self {
        case .folder: return .accentColor
        case .pdf: return Color(red: 0.87, green: 0.33, blue: 0.30)
        case .document: return Color(red: 0.30, green: 0.55, blue: 0.96)
        case .spreadsheet: return Color(red: 0.25, green: 0.62, blue: 0.35)
        case .presentation: return Color(red: 0.87, green: 0.55, blue: 0.24)
        case .image: return Color(red: 0.64, green: 0.45, blue: 0.91)
        case .video: return Color(red: 0.35, green: 0.47, blue: 0.92)
        case .audio: return Color(red: 0.91, green: 0.40, blue: 0.62)
        case .archive: return Color(red: 0.60, green: 0.53, blue: 0.44)
        case .code: return Color(red: 0.20, green: 0.68, blue: 0.68)
        case .text, .font, .disk, .generic: return .secondary
        }
    }

    private static let byExtension: [String: FileKind] = [
        "pdf": .pdf,
        "doc": .document, "docx": .document, "odt": .document, "rtf": .document, "pages": .document,
        "xls": .spreadsheet, "xlsx": .spreadsheet, "ods": .spreadsheet, "csv": .spreadsheet,
        "tsv": .spreadsheet, "numbers": .spreadsheet,
        "ppt": .presentation, "pptx": .presentation, "odp": .presentation, "key": .presentation,
        "jpg": .image, "jpeg": .image, "png": .image, "gif": .image, "heic": .image, "heif": .image,
        "webp": .image, "tiff": .image, "tif": .image, "bmp": .image, "svg": .image, "raw": .image,
        "cr2": .image, "nef": .image, "psd": .image, "ai": .image, "sketch": .image, "fig": .image,
        "mp4": .video, "mov": .video, "m4v": .video, "avi": .video, "mkv": .video, "webm": .video,
        "wmv": .video, "mpg": .video, "mpeg": .video,
        "mp3": .audio, "m4a": .audio, "wav": .audio, "aac": .audio, "flac": .audio, "aiff": .audio,
        "ogg": .audio, "opus": .audio,
        "zip": .archive, "rar": .archive, "7z": .archive, "tar": .archive, "gz": .archive, "bz2": .archive,
        "xz": .archive, "tgz": .archive,
        "swift": .code, "js": .code, "ts": .code, "tsx": .code, "jsx": .code, "py": .code, "rb": .code,
        "go": .code, "rs": .code, "java": .code, "kt": .code, "c": .code, "h": .code, "cpp": .code,
        "hpp": .code, "cs": .code, "php": .code, "sh": .code, "bash": .code, "zsh": .code, "sql": .code,
        "html": .code, "css": .code, "json": .code, "xml": .code, "yml": .code, "yaml": .code, "toml": .code,
        "txt": .text, "md": .text, "log": .text, "plist": .text,
        "ttf": .font, "otf": .font, "woff": .font, "woff2": .font,
        "dmg": .disk, "iso": .disk, "pkg": .disk, "img": .disk,
    ]

    /// Google's own documents have no extension and a media type of their own, so they are matched before anything
    /// else and follow the colours of the Google suite rather than the Office one.
    private static func google(_ mime: String) -> FileKind? {
        switch mime {
        case "application/vnd.google-apps.document": return .document
        case "application/vnd.google-apps.spreadsheet": return .spreadsheet
        case "application/vnd.google-apps.presentation": return .presentation
        case "application/vnd.google-apps.drawing": return .image
        case "application/vnd.google-apps.form": return .text
        default: return nil
        }
    }
    static func of(name: String, mime: String, isFolder: Bool) -> FileKind {
        if isFolder { return .folder }
        if let kind = google(mime) { return kind }
        let ext = (name as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let kind = byExtension[ext] { return kind }
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("text/") { return .text }
        if mime == "application/pdf" { return .pdf }
        if mime.contains("zip") || mime.contains("compressed") || mime.contains("tar") { return .archive }
        return .generic
    }
}

extension CloudFile {
    var kind: FileKind { FileKind.of(name: name, mime: mime, isFolder: isFolder) }
}

/// One file's icon, sized so every row lines up whatever symbol it draws.
struct FileIcon: View {
    let file: CloudFile
    var size: CGFloat = 15
    var body: some View {
        Image(systemName: file.kind.symbol)
            .font(.system(size: size))
            .foregroundStyle(file.kind.tint)
            .frame(width: size + 7, alignment: .center)
            .accessibilityHidden(true)
    }
}

/// One step of the path, drawn as a box rather than as a link.
///
/// A row of underlined links reads as a sentence; a row of boxes reads as a path, which is what it is. The last one
/// is the folder you are looking at, so it is filled rather than hollow and does nothing when clicked.
struct Crumb: View {
    let title: String
    let symbol: String?
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.caption2) }
                Text(title).lineLimit(1)
            }
            .font(.callout)
            .foregroundStyle(current ? Color.primary : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 3.5)
            .background(current ? Color.primary.opacity(0.10) : (hovering ? Color.primary.opacity(0.07) : .clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(current)
        .onHover { hovering = $0 && !current }
        .help(title)
    }
}

/// The two halves of the sidebar.
enum SidebarTab: String, CaseIterable, Identifiable {
    case clouds, favourites
    var id: String { rawValue }
    var title: String { self == .clouds ? L("Nubes") : L("Favoritos") }
}
