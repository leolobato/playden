// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlaydenKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Artwork", targets: ["Artwork"]),
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Focus", targets: ["Focus"]),
        .library(name: "Input", targets: ["Input"]),
        .library(name: "Catalog", targets: ["Catalog"]),
        .library(name: "Sources", targets: ["Sources"]),
        .library(name: "Runner", targets: ["Runner"]),
        .library(name: "Installs", targets: ["Installs"]),
        .library(name: "Sessions", targets: ["Sessions"]),
    ],
    dependencies: [
        .package(path: "../SteamKit"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "Artwork"),
        .testTarget(name: "ArtworkTests", dependencies: ["Artwork"]),
        .target(name: "Domain", resources: [.copy("Resources/profiles.json")]),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .target(name: "Sessions", dependencies: ["Domain", "Catalog", "Installs"]),
        .testTarget(name: "SessionsTests", dependencies: ["Sessions", "Domain", "Catalog"]),
        .target(name: "Runner", dependencies: ["Domain"]),
        .target(name: "Installs", dependencies: ["Domain", "Catalog", "Runner"]),
        .testTarget(name: "InstallsTests", dependencies: ["Installs", "Domain"]),
        .testTarget(name: "RunnerTests", dependencies: ["Runner", "Domain"]),
        .target(name: "SteamCloudProto", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .target(name: "Sources", dependencies: ["Domain", "SteamCloudProto", .product(name: "SteamCore", package: "SteamKit")], resources: [.copy("Resources/Steamless")]),
        .testTarget(name: "SourcesTests", dependencies: ["Sources", "Domain", "SteamCloudProto", "Runner"]),
        .target(name: "Catalog", dependencies: ["Domain", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "CatalogTests", dependencies: ["Catalog", "Domain"]),
        .target(name: "Focus"),
        .target(name: "Input", dependencies: ["Focus"]),
        .testTarget(name: "InputTests", dependencies: ["Input"]),
        .testTarget(name: "FocusTests", dependencies: ["Focus"]),
    ]
)
