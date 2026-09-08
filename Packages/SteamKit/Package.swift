// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SteamKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SteamCore", targets: ["SteamCore"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(name: "SteamProto",
                dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .systemLibrary(name: "CLzma", pkgConfig: "liblzma", providers: [.brew(["xz"])]),
        .systemLibrary(name: "CZstd", pkgConfig: "libzstd", providers: [.brew(["zstd"])]),
        .target(name: "SteamCore", dependencies: ["SteamProto", "CLzma", "CZstd"],
                resources: [.copy("Resources/steampipe")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SteamCoreTests", dependencies: ["SteamCore", "SteamProto"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
