// swift-tools-version: 6.0
import PackageDescription

// The core of the SDK, alone: nodes, providers, commands, the graph. No UI.
//
// The Mac app does not build through this — it compiles Sources/MaximalTreeCore
// into its MaximalTreeKit framework along with the SwiftUI half (see project.yml).
// This is the same core built on its own, so it can be built and tested with
// nothing but Foundation and Observation: `swift build`, `swift test`, and in
// time a headless host and Linux. Open MaximalTree.xcodeproj for the app.
let package = Package(
    name: "MaximalTreeCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MaximalTreeCore", targets: ["MaximalTreeCore"]),
    ],
    targets: [
        .target(name: "MaximalTreeCore", path: "Sources/MaximalTreeCore"),
        .testTarget(name: "MaximalTreeCoreTests", dependencies: ["MaximalTreeCore"],
                    path: "Tests/MaximalTreeCoreTests"),
    ]
)
