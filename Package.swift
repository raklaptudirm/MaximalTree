// swift-tools-version: 6.0
import PackageDescription

// The SDK's core, and the host's engine, alone: nodes, providers, commands, the
// graph, workspaces. No UI.
//
// The Mac app does not build through this — it compiles Sources/MaximalTreeCore
// into its MaximalTreeKit framework along with the SwiftUI half (see project.yml).
// This is the same core built on its own, so it can be built and tested with
// nothing but Foundation and Observation: `swift build`, `swift test`, and in
// time a headless host and Linux. Open MaximalTree.xcodeproj for the app.
//
// Named MaximalTreeKit here too, so that what imports it says the same thing in
// both builds: `import MaximalTreeKit` is the SDK, and where there is no UI the
// SDK is its core. A file that has to compile in both — a core test now, a
// plugin's core half later — needs nothing conditional to do it.
let package = Package(
    name: "MaximalTree",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MaximalTreeKit", targets: ["MaximalTreeKit"]),
    ],
    targets: [
        .target(name: "MaximalTreeKit", path: "Sources/MaximalTreeCore"),
        // The host's engine — workspaces, placements, undo, the graph store,
        // command dispatch — with no shell around it. The Mac app compiles the
        // same folder into itself; building it here is what proves it needs no UI.
        .target(name: "MaximalTreeHost", dependencies: ["MaximalTreeKit"],
                path: "Sources/MaximalTreeHost"),
        // On the engine too, so `swift test` builds it: alone is the only place
        // a reference to one of the app's views would fail to compile.
        .testTarget(name: "MaximalTreeCoreTests", dependencies: ["MaximalTreeKit", "MaximalTreeHost"],
                    path: "Tests/MaximalTreeCoreTests"),
    ]
)
