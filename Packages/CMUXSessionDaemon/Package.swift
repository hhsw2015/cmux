// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXSessionDaemon",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXSessionDaemon",
            targets: ["CMUXSessionDaemon"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXSessionDaemon"
        ),
        .testTarget(
            name: "CMUXSessionDaemonTests",
            dependencies: ["CMUXSessionDaemon"]
        ),
    ]
)
