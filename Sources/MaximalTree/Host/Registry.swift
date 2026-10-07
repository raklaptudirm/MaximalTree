import Foundation
import MaximalTreeKit

/// The registry the Mac app hands to each plugin's `register(with:)`: the core
/// half the store reads, and what this shell draws with — canvases, inspector
/// sections, the keys each surface declares.
@MainActor
final class Registry: CoreContributions, PluginRegistry {
    private(set) var canvases: [CanvasContribution] = []
    private(set) var inspectors: [InspectorContribution] = []
    private(set) var surfaceKeys: [SurfaceKeys] = []

    func register(canvas: CanvasContribution) { canvases.append(canvas) }
    func register(inspector: InspectorContribution) { inspectors.append(inspector) }
    func register(surfaceKeys keys: SurfaceKeys) { surfaceKeys.append(keys) }

    /// Highest-priority canvas whose matcher accepts the node.
    func canvas(for node: Node) -> CanvasContribution? {
        canvases.filter { $0.matches(node) }.max { $0.priority < $1.priority }
    }

    /// All matching inspector sections, most-specific (highest priority) first.
    /// Inspector sections for a node *and* for everything else it is, each
    /// paired with the identity it should be rendered for — the FileSystem
    /// section of a git repo has to be handed the directory's id, not the
    /// repo's, or it will describe a node it can't read.
    func inspectors(for node: Node, in context: HostContext)
        -> [(contribution: InspectorContribution, id: NodeID)] {
        var sections = inspectors
            .filter { $0.matches(node) }
            .sorted { $0.priority > $1.priority }
            .map { (contribution: $0, id: node.id) }

        for identity in node.identities {
            guard let other = context.node(identity) else { continue }
            sections += inspectors
                .filter { $0.matches(other) }
                .sorted { $0.priority > $1.priority }
                .map { (contribution: $0, id: identity) }
        }
        return sections
    }
}
