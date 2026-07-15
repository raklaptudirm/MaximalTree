import SwiftUI
import AppKit
import MaximalTreeKit

@main
struct MaximalTreeApp: App {
    @State private var model = AppModel(host: HostContext())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model.host)
                .environment(model)
                .task { model.start() }
        }
        .commands { AppCommands(model: model) }
    }
}

/// Wires the host together: loads plugins, builds the store, restores the workspace.
/// Owns the objects the shell reaches for; `host` is the observable one plugins see.
@MainActor
@Observable
final class AppModel {
    let host: HostContext
    private let pluginHost = PluginHost()
    private let workspaceStore = WorkspaceStore()
    private(set) var store: GraphStore?

    /// Whether the command palette overlay is showing.
    var paletteVisible = false

    init(host: HostContext) { self.host = host }

    /// Actions (from any plugin) that apply to the current selection. Feeds both
    /// the menu bar and the command palette from the one registry.
    func applicableActions() -> [Action] {
        guard let store else { return [] }
        let ctx = ActionContext(host: host)
        return store.actions.filter { $0.appliesTo.matches(ctx) }
    }

    func run(_ action: Action) {
        action.handler(ActionContext(host: host))
        paletteVisible = false
    }

    func start() {
        guard store == nil else { return }
        // Under XCTest the test bundle compiles the plugin's sources directly; don't
        // also dlopen the .bundle into the same process, or the @objc principal class
        // collides. Tests exercise provider logic without the running host.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !underTest { pluginHost.loadAll() }
        let store = GraphStore(context: host, registry: pluginHost.registry)
        self.store = store

        let providers = pluginHost.registry.providers
        let roots = workspaceStore.resolvedRoots(using: providers) {
            providers.flatMap { $0.roots() }   // empty workspace → provider defaults (home dir)
        }
        store.setRoots(roots)
    }

    /// Prompt for a folder and mount it as a new root, then persist the workspace.
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Mount"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Pass the raw file URL; the FileSystem provider owns `file:` and canonicalizes
        // it on resolve. The host stays ignorant of what a path is.
        store?.mount(url.absoluteString)
        workspaceStore.save(roots: host.roots)
    }
}
