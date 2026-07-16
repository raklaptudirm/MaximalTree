// swift-tools-version: 6.0
import PackageDescription

// A do-nothing stand-in for github.com/lukepistrol/SwiftLintPlugin.
//
// CodeEditSourceEditor attaches that SwiftLint build-tool plugin to its own target,
// so merely depending on the package makes SwiftLint run over *their* sources during
// *our* build — and the pinned SwiftLint binary can't load sourcekitd on the current
// Xcode/macOS beta toolchain, which fails the build outright.
//
// A local package overrides a transitive remote one of the same identity, so this
// satisfies the `.plugin(name: "SwiftLint", package: "SwiftLintPlugin")` reference
// while emitting no build commands. We don't want a dependency's linter running on
// our builds regardless — it only ever lints code we don't own.
let package = Package(
    name: "SwiftLintPlugin",
    products: [
        .plugin(name: "SwiftLint", targets: ["SwiftLintStub"])
    ],
    targets: [
        .plugin(
            name: "SwiftLintStub",
            capability: .buildTool(),
            path: "Plugins/SwiftLintStub"
        )
    ]
)
