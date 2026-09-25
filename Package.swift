// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iCloudy",
    // SwiftUI views already receive their literals as LocalizedStringKey; this declares the source language so a
    // future .lproj can be added without touching the views. Model-layer strings still live in code.
    defaultLocalization: "es",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "iCloudyMain", targets: ["iCloudyMain"]),
        .executable(name: "iCloudyFileProvider", targets: ["iCloudyFileProvider"]),
        .library(name: "iCloudy", targets: ["iCloudy"]),
    ],
    targets: [
        // The whole application lives in this library so the File Provider extension can share the providers, the
        // accounts and the Keychain code with it. The module keeps the name `iCloudy`: tests, the App Intents
        // metadata and the bundle script all address it by that name.
        .target(name: "iCloudy"),
        // The app binary: a main.swift that hands over to the library.
        .executableTarget(name: "iCloudyMain", dependencies: ["iCloudy"]),
        // The Finder extension. An app extension has no main of its own: the system enters through NSExtensionMain.
        .executableTarget(name: "iCloudyFileProvider", dependencies: ["iCloudy"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .testTarget(name: "iCloudyTests", dependencies: ["iCloudy"])
    ]
)
