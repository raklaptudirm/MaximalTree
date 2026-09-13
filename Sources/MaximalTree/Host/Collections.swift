import Foundation
import MaximalTreeKit

// MARK: - The rules

/// A collection: a name, and an ordered list of the things put in it.
///
/// Members are URIs rather than nodes, because a collection holds references.
/// The channel in an aggregator is still the channel, owned by whoever owns
/// channels, and can be in any number of other collections at once.
struct CollectionRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var members: [String]

    var uri: String { CollectionRef.uri(for: id) }
}

enum CollectionRef {
    static let scheme = "collection"
    static func uri(for id: UUID) -> String { "collection://\(id.uuidString.lowercased())" }
    static func id(from uri: String) -> UUID? {
        guard uri.hasPrefix("collection://") else { return nil }
        return UUID(uuidString: String(uri.dropFirst("collection://".count)))
    }
}

/// What every operation on a set of collections does, as pure functions.
///
/// Separate from the store so the parts with judgement in them — where a
/// deleted collection's members go, what reordering means, which references a
/// rename touches — can be checked without a file on disk.
enum CollectionRules {
    /// Put members in at `index`, or at the end.
    ///
    /// Something already a member moves to the new position rather than
    /// appearing twice: membership is a set with an order, and dragging an
    /// existing member is how you reorder.
    static func adopt(_ uris: [String], into members: [String], at index: Int?) -> [String] {
        let incoming = uris.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        // Count what was ahead of the insertion point before removing it, so
        // moving something downward lands where it was aimed.
        let target = index ?? members.count
        let shift = members.prefix(max(0, min(target, members.count)))
            .filter(incoming.contains).count
        var remaining = members.filter { !incoming.contains($0) }
        let position = max(0, min(target - shift, remaining.count))
        remaining.insert(contentsOf: incoming, at: position)
        return remaining
    }

    static func release(_ uris: [String], from members: [String]) -> [String] {
        members.filter { !uris.contains($0) }
    }

    /// Delete a collection, spilling what it held into everything that held
    /// *it*, in its place.
    ///
    /// Deleting a group has always done this rather than discard the contents,
    /// and a collection keeps the promise. With membership there can be
    /// several holders, and each gets the members where the collection sat —
    /// skipping any it already has, since a collection is not a list of
    /// duplicates.
    static func delete(_ id: UUID, from records: [CollectionRecord]) -> [CollectionRecord] {
        guard let doomed = records.first(where: { $0.id == id }) else { return records }
        return records.compactMap { record in
            guard record.id != id else { return nil }
            guard let slot = record.members.firstIndex(of: doomed.uri) else { return record }
            var members = record.members
            members.remove(at: slot)
            let fresh = doomed.members.filter { !members.contains($0) && $0 != record.uri }
            members.insert(contentsOf: fresh, at: slot)
            var updated = record
            updated.members = members
            return updated
        }
    }

    /// Follow a rename into every collection that refers to it.
    ///
    /// Descendants too: a folder renamed on disk changes the URI of everything
    /// inside it, and the provider reports only the folder. The rest of the
    /// host remaps exact matches, which is fine for state that lasts as long as
    /// a window — history, selection. A collection's references are written to
    /// disk and last for ever, so a file inside a renamed folder cannot be left
    /// pointing at a path that no longer exists.
    static func remap(from old: String, to new: String,
                      in records: [CollectionRecord]) -> [CollectionRecord] {
        records.map { record in
            var updated = record
            updated.members = record.members.map { member in
                if member == old { return new }
                if member.hasPrefix(old + "/") { return new + member.dropFirst(old.count) }
                return member
            }
            return updated
        }
    }

    /// A member reported gone — deleted, not merely unreachable.
    ///
    /// Only this drops a member. A reference that fails to resolve is kept:
    /// the plugin that owns it may not be loaded, or the server behind it may
    /// be asleep, and neither is evidence that it has gone. Silently deleting
    /// something the reader put there is far worse than showing it inert.
    static func remove(_ uri: String, from records: [CollectionRecord]) -> [CollectionRecord] {
        records.map { record in
            var updated = record
            updated.members = record.members.filter { $0 != uri && !$0.hasPrefix(uri + "/") }
            return updated
        }
    }
}

// MARK: - The store

/// Collections on disk.
///
/// One set for the app rather than one per workspace. A collection is a node,
/// and a node exists independently of where it is mounted — an aggregator can
/// sit in two workspaces and be the same aggregator in both.
final class CollectionStore: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var records: [CollectionRecord]

    init(url: URL = CollectionStore.defaultURL) {
        self.url = url
        self.records = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([CollectionRecord].self, from: $0) } ?? []
    }

    static let defaultURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MaximalTree/collections.json")

    var all: [CollectionRecord] { lock.withLock { records } }

    func record(_ id: UUID) -> CollectionRecord? {
        lock.withLock { records.first { $0.id == id } }
    }

    /// The collections that hold `uri` directly.
    func holders(of uri: String) -> [CollectionRecord] {
        lock.withLock { records.filter { $0.members.contains(uri) } }
    }

    @discardableResult
    func create(named name: String, in parent: UUID? = nil) -> CollectionRecord {
        let record = CollectionRecord(id: UUID(), name: name, members: [])
        update { records in
            records.append(record)
            if let parent, let index = records.firstIndex(where: { $0.id == parent }) {
                records[index].members.append(record.uri)
            }
        }
        return record
    }

    func rename(_ id: UUID, to name: String) {
        update { records in
            guard let index = records.firstIndex(where: { $0.id == id }) else { return }
            records[index].name = name
        }
    }

    func delete(_ id: UUID) { update { $0 = CollectionRules.delete(id, from: $0) } }

    func adopt(_ uris: [String], into id: UUID, at index: Int?) {
        update { records in
            guard let slot = records.firstIndex(where: { $0.id == id }) else { return }
            records[slot].members = CollectionRules.adopt(uris, into: records[slot].members, at: index)
        }
    }

    func release(_ uris: [String], from id: UUID) {
        update { records in
            guard let slot = records.firstIndex(where: { $0.id == id }) else { return }
            records[slot].members = CollectionRules.release(uris, from: records[slot].members)
        }
    }

    func remap(from old: String, to new: String) {
        update { $0 = CollectionRules.remap(from: old, to: new, in: $0) }
    }

    func remove(_ uri: String) {
        update { $0 = CollectionRules.remove(uri, from: $0) }
    }

    private func update(_ change: (inout [CollectionRecord]) -> Void) {
        let snapshot: [CollectionRecord] = lock.withLock {
            change(&records)
            return records
        }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - The provider

/// Collections as nodes: a name, and whatever was put in them, in order.
///
/// Built into the host rather than shipped as a plugin, because the host is
/// going to be built out of them — the sidebar's groups are collections that
/// take anything, and that fold happens next.
final class CollectionProvider: NodeProvider, MutatingNodeProvider, @unchecked Sendable {
    let schemes: Set<String> = [CollectionRef.scheme]
    let store: CollectionStore
    /// How a member URI becomes a node. The broker in the app; a closure in a
    /// test, which has no broker installed.
    private let resolveMember: @Sendable (String) async -> Node?

    init(store: CollectionStore, resolveMember: @escaping @Sendable (String) async -> Node?) {
        self.store = store
        self.resolveMember = resolveMember
    }

    func resolve(_ uri: String) -> NodeID? {
        guard CollectionRef.id(from: uri) != nil else { return nil }
        return NodeID(uri)
    }

    func node(for id: NodeID) async -> Node? {
        guard let uuid = CollectionRef.id(from: id.uri), let record = store.record(uuid) else {
            return nil
        }
        return Self.node(for: record)
    }

    static func node(for record: CollectionRecord) -> Node {
        Node(id: NodeID(canonical: record.uri),
             type: TypeID("collection"),
             label: record.name,
             icon: NodeIcon("square.stack", tint: .secondary),
             hasChildren: !record.members.isEmpty,
             accepts: .any)
    }

    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        guard let uuid = CollectionRef.id(from: id.uri), let record = store.record(uuid) else {
            return Page(items: [])
        }
        var nodes: [Node] = []
        for member in record.members {
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

    func supports(_ mutation: GraphMutation) -> Bool {
        switch mutation {
        case .rename(let id, _): return collection(id) != nil
        case .delete(let ids): return !ids.isEmpty && ids.allSatisfy { collection($0) != nil }
        case .create(let parent, _, let asContainer): return asContainer && collection(parent) != nil
        case .adopt(_, let into, _): return collection(into) != nil
        case .release(_, let from): return collection(from) != nil
        case .move: return false
        @unknown default: return false
        }
    }

    func apply(_ mutation: GraphMutation) async throws -> [NodeChange] {
        switch mutation {
        case .rename(let id, let name):
            guard let uuid = collection(id) else { return [] }
            store.rename(uuid, to: name)
            // The URI is the collection's id, not its name, so a rename keeps
            // its identity: modified, not renamed.
            return [.modified(id)]

        case .delete(let ids):
            var changes: [NodeChange] = []
            for id in ids {
                guard let uuid = collection(id) else { continue }
                let holders = store.holders(of: id.uri)
                store.delete(uuid)
                changes.append(.removed(id))
                for holder in holders {
                    let holderID = NodeID(canonical: holder.uri)
                    changes += [.childrenChanged(holderID), .modified(holderID)]
                }
            }
            return changes

        case .create(let parent, let name, _):
            guard let uuid = collection(parent) else { return [] }
            store.create(named: name, in: uuid)
            return [.childrenChanged(parent), .modified(parent)]

        case .adopt(let ids, let into, let index):
            guard let uuid = collection(into) else { return [] }
            store.adopt(ids.map(\.uri), into: uuid, at: index)
            // Modified as well: an empty collection has no triangle until it
            // is told it now has something to open.
            return [.childrenChanged(into), .modified(into)]

        case .release(let ids, let from):
            guard let uuid = collection(from) else { return [] }
            store.release(ids.map(\.uri), from: uuid)
            return [.childrenChanged(from), .modified(from)]

        case .move:
            return []
        @unknown default:
            return []
        }
    }

    private func collection(_ id: NodeID) -> UUID? {
        guard let uuid = CollectionRef.id(from: id.uri), store.record(uuid) != nil else { return nil }
        return uuid
    }
}
