// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iCloudy",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "iCloudy", targets: ["iCloudy"])],
    targets: [
        .executableTarget(name: "iCloudy"),
        .testTarget(name: "iCloudyTests", dependencies: ["iCloudy"])
    ]
)
