import Foundation

/// The lazy, virtual source of nodes for one or more URI schemes.
///
/// Providers are `Sendable` and their data methods are `async` and expected to run
/// off the main actor — they hit filesystems, APIs, and databases. The host caches
/// results; the provider is the source of truth.
public protocol NodeProvider: Sendable {
    /// Schemes this provider owns, used by the host for routing (`["file"]`).
    var schemes: Set<String> { get }

    /// Default roots to seed an empty workspace with. May be empty.
    func roots() -> [NodeID]

    /// Resolve a raw URI to a canonical node identity this provider owns, or nil
    /// if it doesn't exist / isn't ownable. Used on mount and to follow `Related`.
    func resolve(_ uri: String) -> NodeID?

    /// Fetch the node record for an id (type, attributes, hasChildren).
    func node(for id: NodeID) async -> Node?

    /// Children under `id` (the containment tree), paginated.
    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node>

    /// Fresh attributes for `id` (may be heavier than what `node(for:)` carries).
    func attributes(of id: NodeID) async -> Attributes

    /// Named forward links from `id`. Default: none.
    func related(to id: NodeID) async -> [Related]
}

/// Lets a provider ask the host for nodes owned by **other** providers, so plugins can
/// compose instead of duplicating each other. E.g. the git plugin lists a repo's
/// working tree by asking whoever owns `file://`, rather than re-implementing
/// directory listing (and losing that provider's labels, icons, and metadata).
///
/// Obtained from `PluginRegistry.broker` at registration and stored by the provider.
/// Callable from any isolation — providers use it inside their `async` methods.
public protocol NodeBroker: Sendable {
    /// The node for a URI, resolved by whichever provider owns its scheme.
    func node(for uri: String) async -> Node?
    /// The children of a URI, from whichever provider owns its scheme.
    func children(of uri: String, page: Cursor?) async -> Page<Node>
}

// Sensible defaults so simple providers stay small.
public extension NodeProvider {
    func roots() -> [NodeID] { [] }
    func related(to id: NodeID) async -> [Related] { [] }
    func attributes(of id: NodeID) async -> Attributes {
        await node(for: id)?.attributes ?? .init()
    }
}
