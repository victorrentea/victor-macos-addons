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
        // The private CoreGraphics API behind 🪞 Virtual Desktop's invisible screen
        // (the same declarations DeskPad and BetterDisplay use). Headers only.
        .target(name: "CGVirtualDisplayShim", path: "Sources/CGVirtualDisplayShim"),
        .executableTarget(
            name: "VictorAddons",
            dependencies: [.product(name: "VictorMacKit", package: "victor-mac-kit"), "CGVirtualDisplayShim"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "VictorAddonsTests",
            dependencies: ["VictorAddons"],
            resources: [.copy("Resources")]
        ),
    ]
)
