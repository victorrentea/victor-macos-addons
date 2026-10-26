// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VictorAddons",
    platforms: [.macOS(.v13)],
    dependencies: [
        // The region selector, shared with Walkie Talkie. A path dependency on
        // purpose: both apps are built on this Mac, from local, and the point of
        // sharing the crop was to be able to edit it and rebuild in one step.
        .package(path: "../victor-mac-kit"),
    ],
    targets: [
        .executableTarget(
            name: "VictorAddons",
            dependencies: [.product(name: "VictorMacKit", package: "victor-mac-kit")],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "VictorAddonsTests",
            dependencies: ["VictorAddons"],
            resources: [.copy("Resources")]
        ),
    ]
)
