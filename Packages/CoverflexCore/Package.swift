// swift-tools-version: 6.0
import PackageDescription

// Shared logic for the app, the widget extension, and the App Intents.
// Kept as a package so `swift test` can run the tests on macOS without a simulator.
let package = Package(
    name: "CoverflexCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoverflexCore", targets: ["CoverflexCore"]),
    ],
    targets: [
        .target(name: "CoverflexCore"),
        .testTarget(name: "CoverflexCoreTests", dependencies: ["CoverflexCore"]),
    ],
    swiftLanguageModes: [.v6]
)
