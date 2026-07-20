import Foundation

/// The host's minimal, universal mutation vocabulary for a forest of nodes. Kept
/// deliberately small — only operations the shell wants to drive generically across
/// providers. Anything richer or provider-specific stays a plugin `Action`.
public enum GraphMutation: Sendable {
    case rename(NodeID, to: String)
    case delete([NodeID])
    /// Reparent nodes under a new container (the tree's drag-and-drop). Identity
    /// is location, so a move IS a rename: the provider reports
    /// `.renamed(from:to:)` per item and the host remaps open state.
    case move([NodeID], into: NodeID)
    /// Create an empty child (a container — directory-like — or a leaf) under a
    /// parent. Providers should unique the name Finder-style rather than fail
    /// on collision. Content-bearing creation (templated notes) stays an Action.
    case create(in: NodeID, name: String, asContainer: Bool)
}

/// What a mutation actually changed, returned by `apply` so the host can update its
/// cache and remap navigation/selection without guessing. (Renames change identity,
/// so only the provider can report the resulting `NodeID`.) The same event type will
/// carry external-change notifications when a provider change-feed is added later.
public enum NodeChange: Sendable, Equatable {
    /// A node's identity changed (rename/move). Host remaps open state old → new.
    case renamed(from: NodeID, to: NodeID)
    /// A node no longer exists. Host drops it from caches and open state.
    case removed(NodeID)
    /// A node's child list changed; host should re-fetch its children.
    case childrenChanged(NodeID)
    /// A node changed in place (content/attributes) without changing identity —
    /// e.g. an editor saved its bytes. Host re-fetches the node record.
    case modified(NodeID)
}

/// A provider that can be written to. Separate from `NodeProvider` so read-only
/// providers stay trivial and the host can feature-detect via `is MutatingNodeProvider`.
public protocol MutatingNodeProvider: NodeProvider {
    /// Whether this provider can perform the given mutation right now.
    func supports(_ mutation: GraphMutation) -> Bool

    /// Perform the mutation and report its effects. Throws on failure; the host
    /// applies the returned changes to its cache and open state on success.
    func apply(_ mutation: GraphMutation) async throws -> [NodeChange]
}
