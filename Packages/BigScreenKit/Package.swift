// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BigScreenKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Focus", targets: ["Focus"]),
        .library(name: "Input", targets: ["Input"]),
        .library(name: "Catalog", targets: ["Catalog"]),
        .library(name: "Sources", targets: ["Sources"]),
    ],
    dependencies: [
        .package(path: "../../../GameNative-macos/swift"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Sources", dependencies: ["Domain", .product(name: "SteamCore", package: "swift")]),
        .testTarget(name: "SourcesTests", dependencies: ["Sources", "Domain"]),
        .target(name: "Catalog", dependencies: ["Domain", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "CatalogTests", dependencies: ["Catalog", "Domain"]),
        .target(name: "Focus"),
        .target(name: "Input", dependencies: ["Focus"]),
        .testTarget(name: "FocusTests", dependencies: ["Focus"]),
    ]
)
