#!/usr/bin/env swift
import AppKit
import WebKit

// Renders the HTML mock-ups in scripts/mockups to PNG files in docs/images, so the screenshots in the README can be
// regenerated when the interface changes instead of being redrawn by hand. They are mock-ups on purpose: real
// screenshots would carry real account names, real file names and real storage figures.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("scripts/mockups")
let output = root.appendingPathComponent("docs/images")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let pages = (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "html" }.sorted { $0.lastPathComponent < $1.lastPathComponent }) ?? []
guard !pages.isEmpty else { print("No hay maquetas en \(source.path)"); exit(1) }

/// The window is drawn at this size and captured at twice the resolution, so the images stay sharp on a Retina
/// display and when GitHub scales them down.
let size = NSSize(width: 1200, height: 780)
let scale: CGFloat = 2

final class Renderer: NSObject, WKNavigationDelegate {
    let view: WKWebView
    var done: ((Data?) -> Void)?
    override init() {
        let configuration = WKWebViewConfiguration()
        view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        super.init()
        view.navigationDelegate = self
    }
    func render(_ page: URL, completion: @escaping (Data?) -> Void) {
        done = completion
        view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give the web view a beat to lay out web fonts and gradients before the snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let configuration = WKSnapshotConfiguration()
            configuration.rect = NSRect(origin: .zero, size: size)
            configuration.snapshotWidth = NSNumber(value: Double(size.width * scale))
            webView.takeSnapshot(with: configuration) { image, error in
                guard let image, error == nil else { self.done?(nil); return }
                guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else { self.done?(nil); return }
                self.done?(png)
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?(nil) }
}

let renderer = Renderer()
var remaining = pages
var failures = 0

func next() {
    guard let page = remaining.first else { NSApplication.shared.terminate(nil); return }
    remaining.removeFirst()
    renderer.render(page) { data in
        let target = output.appendingPathComponent(page.deletingPathExtension().lastPathComponent + ".png")
        if let data { try? data.write(to: target); print("✓ \(target.lastPathComponent)  \(data.count / 1024) KB") }
        else { failures += 1; print("✗ \(page.lastPathComponent)") }
        next()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.main.async { next() }
app.run()
