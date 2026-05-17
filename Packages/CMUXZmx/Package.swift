// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXZmx",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXZmx",
            targets: ["CMUXZmx"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXZmx"
        ),
        .testTarget(
            name: "CMUXZmxTests",
            dependencies: ["CMUXZmx"]
        ),
    ]
)
