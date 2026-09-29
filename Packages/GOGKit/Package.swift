// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GOGKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "GOGCore", targets: ["GOGCore"])],
    targets: [
        .target(name: "GOGCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "gog-dev", dependencies: ["GOGCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "GOGCoreTests", dependencies: ["GOGCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
