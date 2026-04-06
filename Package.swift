// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VictorAddons",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VictorAddons",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "VictorAddonsTests",
            dependencies: ["VictorAddons"],
            resources: [.copy("Resources")]
        ),
    ]
)
