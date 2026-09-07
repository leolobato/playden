// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BigScreenKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Focus", targets: ["Focus"]),
        .library(name: "Input", targets: ["Input"]),
    ],
    targets: [
        .target(name: "Domain"),
        .target(name: "Focus"),
        .target(name: "Input", dependencies: ["Focus"]),
        .testTarget(name: "FocusTests", dependencies: ["Focus"]),
    ]
)
