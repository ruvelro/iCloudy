import AppKit

// Renders Resources/AppIcon.icns from an SF Symbol so the app has an icon without external artwork.
// Run: swift scripts/make-icon.swift
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("iCloudy-\(UUID().uuidString).iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let inset = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
        let background = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.22, yRadius: inset.width * 0.22)
        NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.50, blue: 0.96, alpha: 1), ending: NSColor(calibratedRed: 0.05, green: 0.27, blue: 0.68, alpha: 1))!
            .draw(in: background, angle: -90)
        let configuration = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.46, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return false }
        let tinted = NSImage(size: symbol.size, flipped: false) { symbolRect in
            symbol.draw(in: symbolRect)
            NSColor.white.set(); symbolRect.fill(using: .sourceAtop)
            return true
        }
        let target = NSRect(x: rect.midX - tinted.size.width / 2, y: rect.midY - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height)
        tinted.draw(in: target)
        return true
    }
    let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return representation.representation(using: .png, properties: [:])!
}

for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try process.run(); process.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard process.terminationStatus == 0 else { FileHandle.standardError.write(Data("iconutil falló\n".utf8)); exit(1) }
print("Icono generado en \(root.appendingPathComponent("AppIcon.icns").path)")
