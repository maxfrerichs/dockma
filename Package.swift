// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "dockma",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "dockma", targets: ["DockmaCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
    ],
    targets: [
        // VM, forwarding, launchd and control logic; testable without the CLI.
        .target(
            name: "DockmaCore",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .executableTarget(
            name: "DockmaCLI",
            dependencies: [
                "DockmaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "DockmaCoreTests",
            dependencies: ["DockmaCore"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
