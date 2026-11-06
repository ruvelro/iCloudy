// swift-tools-version: 6.0
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
        .executable(name: "iCloudyCLI", targets: ["iCloudyCLI"]),
        .library(name: "iCloudy", targets: ["iCloudy"]),
    ],
    targets: [
        // The whole application lives in this library so the File Provider extension can share the providers, the
        // accounts and the Keychain code with it. The module keeps the name `iCloudy`: tests, the App Intents
        // metadata and the bundle script all address it by that name.
        .target(name: "iCloudy", dependencies: ["iCloudyCommandWire"]),
        // What the app and its command-line companion say to each other, and nothing else, so the companion stays a
        // small binary that does not link the app.
        .target(name: "iCloudyCommandWire"),
        // `icloudy`, the command-line companion, bundled in Contents/Helpers. The target is not called `icloudy`:
        // on a case-insensitive disk its build folder would be the library's.
        .executableTarget(name: "iCloudyCLI", dependencies: ["iCloudyCommandWire"]),
        // The app binary: a main.swift that hands over to the library.
        .executableTarget(name: "iCloudyMain", dependencies: ["iCloudy"]),
        // The Finder extension. An app extension has no main of its own: the system enters through NSExtensionMain.
        .executableTarget(name: "iCloudyFileProvider", dependencies: ["iCloudy"],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        // The app, the library and the extension build in the Swift 6 language mode, with complete data-race
        // checking. The tests stay in Swift 5 mode: their stand-in servers share state with network callbacks on
        // purpose, and rewriting them would change no line of what ships.
        .testTarget(name: "iCloudyTests", dependencies: ["iCloudy", "iCloudyCommandWire", "iCloudyTestBootstrap"], swiftSettings: [.swiftLanguageMode(.v5)]),
        // A load-time hook for the test bundle: it installs the per-test isolation (HTTP stubs, preferences, the
        // Application Support folder) before the first test runs. See Tests/iCloudyTests/TestSupport.swift.
        .target(name: "iCloudyTestBootstrap", path: "Tests/iCloudyTestBootstrap"),
    ]
)
