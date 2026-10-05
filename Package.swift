// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Vakta",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Vakta", targets: ["Vakta"])
    ],
    dependencies: [
        // Prebuilt libghostty xcframework + Swift wrapper.
        // The embedding C API is UNSTABLE upstream, so we pin an EXACT tag
        // rather than a range or branch. Keep in sync with project.yml's
        // packages.libghostty-spm.exactVersion -- see README.md "Pinned
        // dependency" for how to bump both.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.6.20260909"),
        // Extension protocol types (docs/extensions-plan.md). Local and
        // separate so Extensions can use it without resolving libghostty.
        .package(path: "Packages/VaktaExtensionKit")
    ],
    targets: [
        .executableTarget(
            name: "Vakta",
            dependencies: [
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
                .product(name: "GhosttyTheme", package: "libghostty-spm"),
                .product(name: "VaktaExtensionKit", package: "VaktaExtensionKit")
            ],
            path: "Sources/Vakta",
            // The asset catalog (app icon) is consumed by the Xcode/app build
            // only; SwiftPM has nothing to do with it.
            exclude: ["Assets.xcassets"]
        ),
        .testTarget(
            name: "VaktaCoreTests",
            dependencies: [
                "Vakta",
                .product(name: "GhosttyTheme", package: "libghostty-spm")
            ],
            path: "Tests/VaktaCoreTests"
        ),
        .testTarget(
            name: "VaktaIntegrationTests",
            dependencies: ["Vakta"],
            path: "Tests/VaktaIntegrationTests"
        ),
        .testTarget(
            name: "VaktaExtensionKitTests",
            dependencies: [
                .product(name: "VaktaExtensionKit", package: "VaktaExtensionKit")
            ],
            path: "Tests/VaktaExtensionKitTests"
        )
    ]
)
