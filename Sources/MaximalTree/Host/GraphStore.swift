import Foundation
import MaximalTreeKit

/// Concrete registry the host hands to each plugin's `register(with:)`. Collects
/// contributions into lookup tables the shell and store consume.
@MainActor
final class Registry: PluginRegistry {
    private(set) var providers: [NodeProvider] = []
    private(set) var renderers: [TypeID: TypeRenderer] = [:]
    private(set) var actions: [Action] = []

    func register(provider: NodeProvider) { providers.append(provider) }
    func register(renderer: TypeRenderer) { renderers[renderer.typeID] = renderer }
    func register(action: Action) { actions.append(action) }
}

/// The host's graph store: owns provider routing, the async load path, and drives
/// the observable `HostContext`. Implements `GraphBackend` so all plugin-triggered
/// reads/commands funnel through one object.
@MainActor
final class GraphStore: GraphBackend {
    let context: HostContext
    private let registry: Registry

    // In-flight de-duplication. Kept here (not on HostContext) precisely because
    // GraphStore is not @Observable — touching it during a SwiftUI body is safe.
    private var childrenInFlight: Set<NodeID> = []
    private var relatedInFlight: Set<NodeID> = []

    init(context: HostContext, registry: Registry) {
        self.context = context
        self.registry = registry
        context.backend = self
    }

    func renderer(for type: TypeID) -> TypeRenderer? { registry.renderers[type] }
    var actions: [Action] { registry.actions }

    private func provider(for id: NodeID) -> NodeProvider? {
        guard let scheme = id.scheme else { return nil }
        return registry.providers.first { $0.schemes.contains(scheme) }
    }

    private func provider(forURI uri: String) -> NodeProvider? {
        guard let id = NodeID(uri), let scheme = id.scheme else { return nil }
        return registry.providers.first { $0.schemes.contains(scheme) }
    }

    // MARK: Commands

    func open(_ id: NodeID) {
        context._setFocus(id)
        context._setSelection([id])
        if context.node(id) == nil { ingestNode(id) }
    }

    func select(_ ids: [NodeID]) { context._setSelection(ids) }

    func mount(_ uri: String) {
        guard let p = provider(forURI: uri), let id = p.resolve(uri) else { return }
        var roots = context.roots
        guard !roots.contains(id) else { return }
        roots.append(id)
        context._setRoots(roots)
        ingestNode(id)
    }

    func openURI(_ uri: String) {
        guard let p = provider(forURI: uri), let id = p.resolve(uri) else { return }
        open(id)
    }

    func setRoots(_ ids: [NodeID]) {
        context._setRoots(ids)
        for id in ids { ingestNode(id) }
    }

    // MARK: Async loads

    private func ingestNode(_ id: NodeID) {
        guard let p = provider(for: id) else { return }
        Task { @MainActor in
            if let n = await p.node(for: id) { context._ingest(n) }
        }
    }

    func requestChildren(of id: NodeID) {
        guard context.cachedChildren(of: id) == nil,
              !childrenInFlight.contains(id),
              let p = provider(for: id) else { return }
        childrenInFlight.insert(id)
        Task { @MainActor in
            let page = await p.children(of: id, page: nil)
            for n in page.items { context._ingest(n) }
            context._setChildren(page.items.map(\.id), of: id)
            childrenInFlight.remove(id)
        }
    }

    func requestRelated(of id: NodeID) {
        guard context.cachedRelated(of: id) == nil,
              !relatedInFlight.contains(id),
              let p = provider(for: id) else { return }
        relatedInFlight.insert(id)
        Task { @MainActor in
            let r = await p.related(to: id)
            context._setRelated(r, of: id)
            relatedInFlight.remove(id)
        }
    }
}
