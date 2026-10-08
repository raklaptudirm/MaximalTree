// swift-tools-version: 6.0
import PackageDescription

// The SDK's core, the host's engine and the plugins' core halves, alone: nodes,
// providers, commands, the graph, workspaces. No UI.
//
// The Mac app does not build through this — it compiles Sources/MaximalTreeCore
// into its MaximalTreeKit framework along with the SwiftUI half (see project.yml).
// This is the same core built on its own, so it can be built and tested with
// nothing but Foundation and Observation: `swift build` and `swift test`, on a
// Mac or on Linux (CI runs both). Open MaximalTree.xcodeproj for the app.
//
// Named MaximalTreeKit here too, so that what imports it says the same thing in
// both builds: `import MaximalTreeKit` is the SDK, and where there is no UI the
// SDK is its core. A file that has to compile in both — a core test now, a
// plugin's core half later — needs nothing conditional to do it.

/// Each plugin's core half: what it does with no window. On the Mac the plugin's
/// bundle compiles its whole folder; here only the Core folder, under the
/// bundle's own module name, so neither half needs an #if.
var pluginCores: [Target] = [
    .target(name: "FileSystem", dependencies: ["MaximalTreeKit"],
            path: "Sources/FileSystemPlugin/Core"),
    .target(name: "Git", dependencies: ["MaximalTreeKit"],
            path: "Sources/GitPlugin/Core"),
    // Typst's engine is a Rust library, built by cargo as the Mac app builds
    // (see project.yml); this links the same one. On Linux, Rust's standard
    // library needs the system libraries a Mac links implicitly.
    .systemLibrary(name: "TypstFFI", path: "Vendor/typst-ffi/include"),
    .target(name: "Typst", dependencies: ["MaximalTreeKit", "TypstFFI"],
            path: "Sources/TypstPlugin/Core",
            linkerSettings: [
                .unsafeFlags(["-L", Context.packageDirectory + "/Vendor/typst-ffi/target/release"]),
                .linkedLibrary("typst_ffi"),
            ] + ["m", "dl", "pthread", "rt", "util"].map {
                .linkedLibrary($0, .when(platforms: [.linux]))
            }),
    .target(name: "Web", dependencies: ["MaximalTreeKit"],
            path: "Sources/WebPlugin/Core"),
    .target(name: "YouTube", dependencies: ["MaximalTreeKit"],
            path: "Sources/YouTubePlugin/Core"),
]
// iCloud Drive is Apple's: anywhere else there is no drive for it to serve.
#if canImport(Darwin)
pluginCores.append(.target(name: "ICloud", dependencies: ["MaximalTreeKit"],
                           path: "Sources/ICloudPlugin/Core"))
#endif

let package = Package(
    name: "MaximalTree",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "MaximalTreeKit", targets: ["MaximalTreeKit"]),
        .executable(name: "mtree", targets: ["mtree"]),
    ],
    targets: [
        .target(name: "MaximalTreeKit", path: "Sources/MaximalTreeCore"),
        // The host's engine — workspaces, placements, undo, the graph store,
        // command dispatch — with no shell around it. The Mac app compiles the
        // same folder into itself; building it here is what proves it needs no UI.
        .target(name: "MaximalTreeHost", dependencies: ["MaximalTreeKit"],
                path: "Sources/MaximalTreeHost"),

        // On everything above, so `swift test` builds it all: alone is the only
        // place a reference to a view would fail to compile.
        .testTarget(name: "MaximalTreeCoreTests",
                    dependencies: ["MaximalTreeKit", "MaximalTreeHost"]
                        + pluginCores.filter { $0.type == .regular }.map { .target(name: $0.name) },
                    path: "Tests/MaximalTreeCoreTests"),
        // MaximalTree with no window: the engine and every plugin core, asked
        // from a shell. See Sources/mtree.
        .executableTarget(name: "mtree",
                          dependencies: ["MaximalTreeKit", "MaximalTreeHost"]
                              + pluginCores.filter { $0.type == .regular }.map { .target(name: $0.name) },
                          path: "Sources/mtree"),
        // The engine driven the way that tool drives it, with real plugins.
        .testTarget(name: "HeadlessTests", dependencies: ["MaximalTreeHost", "FileSystem"],
                    path: "Tests/HeadlessTests"),
        // The plugins' cores, tested alone — for what differs by platform.
        // Not in the Mac app's suite, which has its own tests of all of this.
        .testTarget(name: "PluginCoreTests", dependencies: ["YouTube"],
                    path: "Tests/PluginCoreTests"),
    ] + pluginCores
)
