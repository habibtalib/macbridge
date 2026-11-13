// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BridgeCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", .upToNextMajor(from: "157.0.0")),
    ],
    targets: [
        .target(
            name: "BridgeCore",
            dependencies: [.product(name: "WebRTC", package: "WebRTC")],
            // WebRTC's Objective-C delegates call back on its own threads; Swift 5
            // mode keeps that bridging simple.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
