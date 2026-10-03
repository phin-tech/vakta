// swift-tools-version: 5.10
import PackageDescription

// The Extension protocol types shared by Vakta and Swift Extensions (see
// docs/extensions-plan.md). A separate package, so an Extension can depend on
// it without resolving Vakta's own dependencies (libghostty). The JSON on the
// wire is the contract: extensions/protocol/fixtures/*.json, not these types.
let package = Package(
    name: "VaktaExtensionKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "VaktaExtensionKit", targets: ["VaktaExtensionKit"])
    ],
    targets: [
        .target(name: "VaktaExtensionKit", path: "Sources/VaktaExtensionKit")
    ]
)
