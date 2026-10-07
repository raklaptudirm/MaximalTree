// swift-tools-version: 6.0
import PackageDescription

// The SDK's core, the host's engine and the plugins' core halves, alone: nodes,
// providers, commands, the graph, workspaces. No UI.
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

        // Each plugin's core half: what it does with no window. On the Mac the
        // plugin's bundle compiles its whole folder; here only the Core folder,
        // under the bundle's own module name, so neither half needs an #if.
        .target(name: "ICloud", dependencies: ["MaximalTreeKit"],
                path: "Sources/ICloudPlugin/Core"),
        .target(name: "Web", dependencies: ["MaximalTreeKit"],
                path: "Sources/WebPlugin/Core"),
        .target(name: "YouTube", dependencies: ["MaximalTreeKit"],
                path: "Sources/YouTubePlugin/Core"),

        // On everything above, so `swift test` builds it all: alone is the only
        // place a reference to a view would fail to compile.
        .testTarget(name: "MaximalTreeCoreTests",
                    dependencies: ["MaximalTreeKit", "MaximalTreeHost", "ICloud", "Web", "YouTube"],
                    path: "Tests/MaximalTreeCoreTests"),
    ]
)
