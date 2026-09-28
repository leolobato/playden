// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EpicKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "EpicCore", targets: ["EpicCore"])],
    targets: [
        .target(name: "EpicCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "EpicCoreTests", dependencies: ["EpicCore"],
                    resources: [.copy("Fixtures")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
