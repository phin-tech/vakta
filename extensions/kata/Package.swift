// swift-tools-version: 5.10
import PackageDescription

// The Kata Extension for Vakta (docs/extensions-plan.md). A separate package,
// never a target of Vakta's own manifest: Vakta runs it as a child process.
let package = Package(
    name: "KataVakta",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "kata-vakta", targets: ["KataVakta"])
    ],
    dependencies: [
        .package(path: "../../Packages/VaktaExtensionKit")
    ],
    targets: [
        // Pure: Kata JSON in, View Documents and Effects out.
        .target(
            name: "KataVaktaCore",
            dependencies: [.product(name: "VaktaExtensionKit", package: "VaktaExtensionKit")],
            path: "Sources/KataVaktaCore"
        ),
        // I/O: the stdio protocol loop and the `kata` CLI.
        .executableTarget(
            name: "KataVakta",
            dependencies: [
                "KataVaktaCore",
                .product(name: "VaktaExtensionKit", package: "VaktaExtensionKit")
            ],
            path: "Sources/KataVakta"
        ),
        .testTarget(
            name: "KataVaktaCoreTests",
            dependencies: ["KataVaktaCore"],
            path: "Tests/KataVaktaCoreTests"
        )
    ]
)
