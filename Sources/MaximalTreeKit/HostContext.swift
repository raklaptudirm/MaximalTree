import Foundation
import Observation

/// The single, observable object plugins hold to read graph state and drive the
/// host. Concrete (not a protocol) and living in the SDK so plugin SwiftUI can
/// `@Environment(HostContext.self)` and observe it by reference. The host keeps the
/// real store and drives this through `GraphBackend`; plugins never touch internals.
///
/// The cache dictionaries below are the observable source of truth for the UI. The
/// backend fills them asynchronously; reading `children(of:)`/`related(of:)` during
/// a SwiftUI body kicks off a load (via the backend) and returns what's cached so
/// far, so the view re-renders when the data lands.
@MainActor
@Observable
public final class HostContext {
    /// Top-level entries of the current workspace (the forest's roots).
    public internal(set) var roots: [NodeID] = []
    /// The node whose renderer currently owns the canvas + inspector.
    public internal(set) var focusedNode: NodeID?
    /// Current selection in the explorer (drives action applicability).
    public internal(set) var selection: [NodeID] = []

    // Observable caches, filled by the backend.
    internal var nodes: [NodeID: Node] = [:]
    internal var childrenByParent: [NodeID: [NodeID]] = [:]
    internal var relatedByNode: [NodeID: [Related]] = [:]

    /// Set by the host when it constructs the store. Weak to avoid a retain cycle.
    public weak var backend: GraphBackend?

    public init() {}

    // MARK: Reads (safe to call from a view body)

    public func node(_ id: NodeID) -> Node? { nodes[id] }

    /// Cached children, requesting a load if we've never fetched them.
    public func children(of id: NodeID) -> [NodeID] {
        if childrenByParent[id] == nil { backend?.requestChildren(of: id) }
        return childrenByParent[id] ?? []
    }

    /// Cached forward links, requesting a load if we've never fetched them.
    public func related(of id: NodeID) -> [Related] {
        if relatedByNode[id] == nil { backend?.requestRelated(of: id) }
        return relatedByNode[id] ?? []
    }

    /// Peek at the caches without triggering a load. For the host/backend, which
    /// needs to ask "already fetched?" without kicking off another request.
    public func cachedChildren(of id: NodeID) -> [NodeID]? { childrenByParent[id] }
    public func cachedRelated(of id: NodeID) -> [Related]? { relatedByNode[id] }

    // MARK: Commands (routed to the host)

    public func open(_ id: NodeID) { backend?.open(id) }
    public func select(_ ids: [NodeID]) { backend?.select(ids) }
    public func mount(_ uri: String) { backend?.mount(uri) }
    /// Resolve a raw URI (e.g. a `Related.target`) and focus it, without mounting
    /// it as a root. This is how the inspector follows a reference.
    public func openURI(_ uri: String) { backend?.openURI(uri) }

    /// Perform a write. Fire-and-forget: the host runs it and updates caches/nav from
    /// the reported changes; failures are logged. Check `canApply` first for UI state.
    public func apply(_ mutation: GraphMutation) { backend?.apply(mutation) }

    /// Whether the owning provider can perform `mutation` right now (for enabling UI).
    public func canApply(_ mutation: GraphMutation) -> Bool { backend?.canApply(mutation) ?? false }

    // MARK: Backend-facing mutation (host only)

    public func _ingest(_ node: Node) { nodes[node.id] = node }
    public func _setChildren(_ ids: [NodeID], of parent: NodeID) { childrenByParent[parent] = ids }
    public func _setRelated(_ r: [Related], of id: NodeID) { relatedByNode[id] = r }
    public func _setRoots(_ ids: [NodeID]) { roots = ids }
    public func _setFocus(_ id: NodeID?) { focusedNode = id }
    public func _setSelection(_ ids: [NodeID]) { selection = ids }

    /// Rewrite every cached reference to `old` as `new` after a rename. Note this is
    /// shallow: for a directory rename, descendant URIs also change, so the caller
    /// should also invalidate the renamed node's children (they refetch under the new
    /// path). Files (the common case) have no descendants and remap exactly.
    public func _remap(from old: NodeID, to new: NodeID) {
        if let node = nodes.removeValue(forKey: old) { nodes[new] = node }
        if let kids = childrenByParent.removeValue(forKey: old) { childrenByParent[new] = kids }
        for (parent, kids) in childrenByParent where kids.contains(old) {
            childrenByParent[parent] = kids.map { $0 == old ? new : $0 }
        }
        if let related = relatedByNode.removeValue(forKey: old) { relatedByNode[new] = related }
        roots = roots.map { $0 == old ? new : $0 }
        if focusedNode == old { focusedNode = new }
        selection = selection.map { $0 == old ? new : $0 }
    }

    /// Drop a node that no longer exists from every cache and from open state.
    public func _remove(_ id: NodeID) {
        nodes[id] = nil
        childrenByParent[id] = nil
        relatedByNode[id] = nil
        for (parent, kids) in childrenByParent where kids.contains(id) {
            childrenByParent[parent] = kids.filter { $0 != id }
        }
        roots = roots.filter { $0 != id }
        if focusedNode == id { focusedNode = nil }
        selection = selection.filter { $0 != id }
    }

    /// Forget a node's children so they're re-fetched on next access.
    public func _invalidateChildren(of id: NodeID) { childrenByParent[id] = nil }
}

/// Implemented by the host's graph store. Everything the plugin API can trigger
/// funnels through here, which is the seam that would later back onto XPC if any
/// plugin ever needed to run out-of-process.
@MainActor
public protocol GraphBackend: AnyObject {
    func open(_ id: NodeID)
    func select(_ ids: [NodeID])
    func mount(_ uri: String)
    func openURI(_ uri: String)
    func apply(_ mutation: GraphMutation)
    func canApply(_ mutation: GraphMutation) -> Bool
    func requestChildren(of id: NodeID)
    func requestRelated(of id: NodeID)
}
