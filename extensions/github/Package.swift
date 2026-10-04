// swift-tools-version: 5.10
import PackageDescription

// The GitHub pull request Extension, a Built-in Extension shipped inside
// Vakta.app (docs/github-extension-plan.md). A separate package: Vakta runs
// it as a child process and never links it.
let package = Package(
    name: "VaktaGitHub",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "vakta-github", targets: ["VaktaGitHub"])
    ],
    dependencies: [
        .package(path: "../../Packages/VaktaExtensionKit")
    ],
    targets: [
        // Pure: remotes, PR state, GraphQL text and parsing, refresh planning,
        // View Documents and Effects.
        .target(
            name: "GitHubCore",
            dependencies: [.product(name: "VaktaExtensionKit", package: "VaktaExtensionKit")],
            path: "Sources/GitHubCore"
        ),
        // I/O: the stdio protocol loop, git, gh, and HTTPS.
        .executableTarget(
            name: "VaktaGitHub",
            dependencies: [
                "GitHubCore",
                .product(name: "VaktaExtensionKit", package: "VaktaExtensionKit")
            ],
            path: "Sources/VaktaGitHub"
        ),
        .testTarget(
            name: "GitHubCoreTests",
            dependencies: ["GitHubCore"],
            path: "Tests/GitHubCoreTests"
        )
    ]
)
