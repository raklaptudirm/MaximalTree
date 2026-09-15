import Foundation
import MaximalTreeKit

/// A collection as the builds before placements kept it, in
/// `collections.json`: read once, to migrate, and never written.
struct CollectionRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var members: [String]

    var uri: String { CollectionRef.uri(for: id) }
}

enum CollectionRef {
    static let scheme = "collection"
    static func uri(for id: UUID) -> String { "collection://\(id.uuidString.lowercased())" }

    /// A collection that carries its name: `collection://<id>?name=<name>`.
    ///
    /// Encoded strictly — `&`, `=`, `+`, `#`, `?` and `/` included — so any
    /// name reads back exactly, and the string is already canonical.
    static func uri(for id: UUID, named name: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/")
        return uri(for: id) + "?name=" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }

    static func id(from uri: String) -> UUID? {
        guard uri.hasPrefix("collection://") else { return nil }
        let rest = uri.dropFirst("collection://".count)
        return UUID(uuidString: String(rest.prefix { $0 != "?" }))
    }

    static func name(from uri: String) -> String? {
        guard id(from: uri) != nil else { return nil }
        return URLComponents(string: uri)?.queryItems?.first { $0.name == "name" }?.value
    }
}

// MARK: - The provider

/// Collections as nodes: a name, and whatever was put in them.
///
/// Built into the host rather than shipped as a plugin, because the sidebar is
/// built out of them. What a collection holds is placed, so the host lists it
/// like any node that takes drops; all that is left here is what a collection
/// is — its name, which is in its URI — and the changes only a collection has:
/// being renamed, deleted, and made.
final class CollectionProvider: NodeProvider, MutatingNodeProvider, Sendable {
    let schemes: Set<String> = [CollectionRef.scheme]
    /// Whether any workspace has this collection.
    private let exists: @Sendable (String) async -> Bool
    /// Make a change, and say what changed.
    private let change: @Sendable (GraphMutation) async -> [NodeChange]

    init(exists: @escaping @Sendable (String) async -> Bool,
         change: @escaping @Sendable (GraphMutation) async -> [NodeChange]) {
        self.exists = exists
        self.change = change
    }

    func resolve(_ uri: String) -> NodeID? {
        guard CollectionRef.id(from: uri) != nil else { return nil }
        return NodeID(uri)
    }

    func node(for id: NodeID) async -> Node? {
        guard let name = CollectionRef.name(from: id.uri), await exists(id.uri) else { return nil }
        return Node(id: id,
                    type: TypeID("collection"),
                    label: name,
                    icon: NodeIcon("square.stack", tint: .secondary),
                    accepts: .any)
    }

    /// Nothing of its own: everything in a collection was put there, and the
    /// host lists that.
    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        Page(items: [])
    }

    // MARK: Mutations

    /// Decided from the URI alone: a collection's name is in its URI, so
    /// whether something is one needs nobody to be asked. Placing is not here
    /// — that is the host's, for every node.
    func supports(_ mutation: GraphMutation) -> Bool {
        switch mutation {
        case .rename(let id, _): return Placements.isCollection(id.uri)
        case .delete(let ids): return !ids.isEmpty && ids.allSatisfy { Placements.isCollection($0.uri) }
        case .create(let parent, _, let asContainer): return asContainer && Placements.isCollection(parent.uri)
        default: return false
        }
    }

    func apply(_ mutation: GraphMutation) async throws -> [NodeChange] {
        await change(mutation)
    }
}

// MARK: - Collections, changed

extension WorkspaceStore {
    /// A change to the active sidebar's collections, made through the graph —
    /// and what it changed, for the graph to follow. Not placing, which the
    /// graph does itself.
    func applyToCollections(_ mutation: GraphMutation) -> [NodeChange] {
        func group(_ id: NodeID) -> UUID? { CollectionRef.id(from: id.uri) }
        func touched(_ uris: [String]) -> [NodeChange] {
            uris.map { NodeID(canonical: $0) }.flatMap { [.childrenChanged($0), .modified($0)] }
        }
        switch mutation {
        case .rename(let id, let name):
            guard let uuid = group(id), let (old, new) = renameGroup(uuid, to: name) else { return [] }
            // The name is in the URI, so this is a rename in the graph's sense:
            // a new identity, followed wherever the old one was held.
            return [.renamed(from: NodeID(canonical: old), to: NodeID(canonical: new))]
                + touched(active.placements.holders(of: new))

        case .delete(let ids):
            var changes: [NodeChange] = []
            for id in ids {
                guard let uuid = group(id) else { continue }
                let holders = active.placements.holders(of: id.uri)
                deleteGroup(uuid)
                changes += [.removed(id)] + touched(holders)
            }
            return changes

        case .create(let parent, let name, _):
            guard let uuid = group(parent) else { return [] }
            createGroup(named: name, in: uuid)
            return touched([parent.uri])

        default:
            return []
        }
    }
}
