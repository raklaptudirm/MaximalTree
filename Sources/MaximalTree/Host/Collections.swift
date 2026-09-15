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

/// Collections as nodes: a name, and whatever was put in them, in order.
///
/// Built into the host rather than shipped as a plugin, because the sidebar is
/// built out of them. Everything about a collection is in its workspace's
/// placements, so the provider holds nothing: it asks the workspaces what a
/// collection holds, and hands every change back to them.
final class CollectionProvider: NodeProvider, MutatingNodeProvider, Sendable {
    let schemes: Set<String> = [CollectionRef.scheme]
    /// What a collection holds, or nil if no workspace has it.
    private let members: @Sendable (String) async -> [String]?
    /// Make a change, and say what changed.
    private let change: @Sendable (GraphMutation) async -> [NodeChange]
    /// How a member URI becomes a node. The broker in the app; a closure in a
    /// test, which has no broker installed.
    private let resolveMember: @Sendable (String) async -> Node?

    init(members: @escaping @Sendable (String) async -> [String]?,
         change: @escaping @Sendable (GraphMutation) async -> [NodeChange],
         resolveMember: @escaping @Sendable (String) async -> Node?) {
        self.members = members
        self.change = change
        self.resolveMember = resolveMember
    }

    func resolve(_ uri: String) -> NodeID? {
        guard CollectionRef.id(from: uri) != nil else { return nil }
        return NodeID(uri)
    }

    func node(for id: NodeID) async -> Node? {
        guard let name = CollectionRef.name(from: id.uri),
              let members = await members(id.uri) else { return nil }
        return Node(id: id,
                    type: TypeID("collection"),
                    label: name,
                    icon: NodeIcon("square.stack", tint: .secondary),
                    hasChildren: !members.isEmpty,
                    accepts: .any)
    }

    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        var nodes: [Node] = []
        for member in await members(id.uri) ?? [] {
            if let node = await resolveMember(member) {
                nodes.append(node)
            } else if let placeholder = Self.inert(member) {
                nodes.append(placeholder)
            }
        }
        return Page(items: nodes)
    }

    /// A member that did not resolve, shown rather than dropped.
    ///
    /// Its own id, not a stand-in's: when the plugin that owns it loads, the
    /// same row becomes the real thing.
    static func inert(_ uri: String) -> Node? {
        guard let id = NodeID(uri) else { return nil }
        let name = uri.split(separator: "/").last.map(String.init) ?? uri
        return Node(id: id, type: TypeID("collection.unavailable"),
                    label: name.removingPercentEncoding ?? name,
                    icon: NodeIcon("questionmark.circle", tint: .gray))
    }

    // MARK: Mutations

    /// Decided from the URIs alone: a collection's name is in its URI, so
    /// whether something is one needs nobody to be asked.
    func supports(_ mutation: GraphMutation) -> Bool {
        switch mutation {
        case .rename(let id, _): return Placements.isCollection(id.uri)
        case .delete(let ids): return !ids.isEmpty && ids.allSatisfy { Placements.isCollection($0.uri) }
        case .create(let parent, _, let asContainer): return asContainer && Placements.isCollection(parent.uri)
        case .adopt(_, let into, _): return Placements.isCollection(into.uri)
        case .release(_, let from): return Placements.isCollection(from.uri)
        case .move: return false
        @unknown default: return false
        }
    }

    func apply(_ mutation: GraphMutation) async throws -> [NodeChange] {
        await change(mutation)
    }
}

// MARK: - Collections, changed

extension WorkspaceStore {
    /// A change to the active sidebar's collections, made through the graph —
    /// and what it changed, for the graph to follow.
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

        case .adopt(let ids, let into, let index):
            guard let uuid = group(into) else { return [] }
            add(ids.map(\.uri), to: uuid, at: index)
            return touched([into.uri])

        case .release(let ids, let from):
            guard let uuid = group(from) else { return [] }
            remove(ids.map(\.uri), from: uuid)
            return touched([from.uri])

        case .move:
            return []
        @unknown default:
            return []
        }
    }
}
