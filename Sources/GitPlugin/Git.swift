import SwiftUI
import MaximalTreeKit
import MaximalEditorKit

// MARK: - Plugin

@objc(GitPlugin)
final class GitPlugin: NSObject, Plugin {
    override init() { super.init() }

    func register(with registry: PluginRegistry) {
        GitCore.register(with: registry)

        registerActions(with: registry)
        // The repo canvas writes its commit message in the app's editor, so
        // the actions its keys name have to exist whether or not the plugin
        // that usually registers them happens to be loaded.
        EditorKeys.register(with: registry)

        registry.register(canvas: CanvasContribution(priority: 10,
            matches: { $0.type == TypeID("git.commit") }) { id, host in
                AnyView(CommitCanvas(nodeID: id).environment(host))
        })
        registry.register(canvas: CanvasContribution(priority: 10,
            matches: { $0.type == TypeID("git.stagedfile")
                    || $0.type == TypeID("git.unstagedfile") }) { id, host in
                AnyView(WorkingCopyFileCanvas(nodeID: id).environment(host))
        })
        // A changed file's canvas is its diff. Without this it fell through to
        // the generic list canvas, which had nothing to list.
        registry.register(canvas: CanvasContribution(priority: 10,
            matches: { $0.type == TypeID("git.commitfile") }) { id, host in
                AnyView(CommitFileCanvas(nodeID: id).environment(host))
        })
        // A repository gets its status rather than a list of its four folders,
        // which said nothing a sidebar row didn't.
        registry.register(canvas: CanvasContribution(priority: 20,
            matches: { $0.type == TypeID("git.repo") },
            keys: GitActions.canvasKeys) { id, host in
                AnyView(RepoCanvas(nodeID: id).environment(host))
        })
        registry.register(canvas: CanvasContribution(priority: 0,
            matches: { $0.type.raw.hasPrefix("git.") }) { id, host in
                AnyView(GitListCanvas(nodeID: id).environment(host))
        })
        registry.register(inspector: InspectorContribution(
            matches: { $0.type.raw.hasPrefix("git.") }) { id, host in
                AnyView(GitInspector(nodeID: id).environment(host))
        })
    }
}
