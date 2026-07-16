import PackagePlugin

/// Emits no build commands — linting a dependency's sources during our build has no
/// value to us, and the real plugin's SwiftLint binary is incompatible with the
/// current toolchain.
@main
struct SwiftLintStub: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        []
    }
}
