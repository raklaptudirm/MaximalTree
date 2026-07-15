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

    // MARK: Backend-facing mutation (host only)

    public func _ingest(_ node: Node) { nodes[node.id] = node }
    public func _setChildren(_ ids: [NodeID], of parent: NodeID) { childrenByParent[parent] = ids }
    public func _setRelated(_ r: [Related], of id: NodeID) { relatedByNode[id] = r }
    public func _setRoots(_ ids: [NodeID]) { roots = ids }
    public func _setFocus(_ id: NodeID?) { focusedNode = id }
    public func _setSelection(_ ids: [NodeID]) { selection = ids }
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
    func requestChildren(of id: NodeID)
    func requestRelated(of id: NodeID)
}
