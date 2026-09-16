// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iCloudy",
    // SwiftUI views already receive their literals as LocalizedStringKey; this declares the source language so a
    // future .lproj can be added without touching the views. Model-layer strings still live in code.
    defaultLocalization: "es",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "iCloudy", targets: ["iCloudy"])],
    targets: [
        .executableTarget(name: "iCloudy"),
        .testTarget(name: "iCloudyTests", dependencies: ["iCloudy"])
    ]
)
