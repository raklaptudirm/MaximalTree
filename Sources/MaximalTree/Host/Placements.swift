import Foundation

/// What was put inside what, in one workspace.
///
/// A node's children are either its own — a folder's files, a server's
/// libraries, whatever its provider says — or placed: put there by the reader,
/// and remembered here because nothing else would. This is the second kind,
/// and only that. A collection is nothing more than an entry in this table,
/// under a URI that carries its name; an aggregator is a plugin's node with one.
///
/// Per workspace on purpose. The table is how a workspace's sidebar is
/// arranged, and the same aggregator mounted in two workspaces holds whatever
/// each was given.
///
/// Everything here is a value and every operation a pure mutation, so the parts
/// with judgement in them — where a deleted collection's children go, which
/// references a rename reaches, what is left over after a removal — can be
/// checked without a file on disk.
struct Placements: Codable, Equatable {
    /// The placed children of every node something was put into, in order,
    /// by URI. A node with none has no entry: an empty list is never stored.
    private(set) var children: [String: [String]] = [:]

    init() {}

    /// The entry the sidebar is drawn from.
    ///
    /// The workspace's own id as a collection, which is what it has been since
    /// groups became collections — so nothing keyed by it has to move.
    static func root(of workspace: UUID) -> String { CollectionRef.uri(for: workspace) }

    func children(of parent: String) -> [String] { children[parent] ?? [] }

    // MARK: Placing

    /// Put these inside `parent`, at `index` or at the end. Whether it was done.
    ///
    /// Refused if it would make something its own ancestor. Exact for placed
    /// edges, since every one of them is in this table; a node's own children
    /// are not, and are the graph's to check.
    @discardableResult
    mutating func adopt(_ uris: [String], into parent: String, at index: Int? = nil) -> Bool {
        guard !uris.isEmpty, !formsCycle(adopting: uris, into: parent) else { return false }
        set(CollectionRules.adopt(uris, into: children(of: parent), at: index), for: parent)
        return true
    }

    mutating func release(_ uris: [String], from parent: String) {
        set(CollectionRules.release(uris, from: children(of: parent)), for: parent)
    }

    func formsCycle(adopting uris: [String], into parent: String) -> Bool {
        uris.contains { $0 == parent || reachable(from: [$0]).contains(parent) }
    }

    // MARK: Collections

    /// A new, empty collection placed inside `parent`. Its URI.
    ///
    /// Empty means no entry, so until something is put in it the collection
    /// is only the reference in `parent`.
    @discardableResult
    mutating func createCollection(named name: String, in parent: String,
                                   at index: Int? = nil) -> String {
        let uri = CollectionRef.uri(for: UUID(), named: name)
        adopt([uri], into: parent, at: index)
        return uri
    }

    /// Rename a collection. Its new URI, which every reference here now uses.
    ///
    /// The name is part of the URI, so this is a rename in the graph's sense
    /// too — the same change a file makes, and followed the same way.
    /// Nil for anything without a name to change: a plugin's node, or the
    /// sidebar, which is named by its workspace.
    @discardableResult
    mutating func rename(_ collection: String, to name: String) -> String? {
        guard let id = CollectionRef.id(from: collection),
              CollectionRef.name(from: collection) != nil else { return nil }
        let renamed = CollectionRef.uri(for: id, named: name)
        if renamed != collection { remap(from: collection, to: renamed) }
        return renamed
    }

    /// Delete a collection, putting what it held into everything that held it,
    /// where it sat — skipping what a holder already has, and never a holder
    /// into itself.
    ///
    /// Only a named collection: never the sidebar, whose entry is the
    /// workspace's whole arrangement.
    mutating func delete(_ collection: String) {
        guard CollectionRef.name(from: collection) != nil else { return }
        let spilled = children(of: collection)
        for (parent, list) in children {
            guard let slot = list.firstIndex(of: collection) else { continue }
            var updated = list
            updated.remove(at: slot)
            let fresh = spilled.filter { !updated.contains($0) && $0 != parent }
            updated.insert(contentsOf: fresh, at: slot)
            set(updated, for: parent)
        }
        children[collection] = nil
    }

    // MARK: What happened elsewhere

    /// Follow a rename — as a child, and as a parent — including everything
    /// under a renamed folder, whose URIs change with it though only the folder
    /// is reported.
    mutating func remap(from old: String, to new: String) {
        func moved(_ uri: String) -> String {
            if uri == old { return new }
            if uri.hasPrefix(old + "/") { return new + uri.dropFirst(old.count) }
            return uri
        }
        // A node renamed onto one that already had placements keeps both.
        children = Dictionary(children.map { (moved($0.key), $0.value.map(moved)) },
                              uniquingKeysWith: { a, b in a + b.filter { !a.contains($0) } })
    }

    /// Something reported gone — deleted, not merely unreachable. It leaves
    /// every list, and whatever was placed inside it goes with it.
    ///
    /// Only this drops a reference. One that fails to resolve is kept: its
    /// plugin may not be loaded, or its server asleep.
    mutating func remove(_ uri: String) {
        func gone(_ candidate: String) -> Bool { candidate == uri || candidate.hasPrefix(uri + "/") }
        for key in children.keys where gone(key) { children[key] = nil }
        for (parent, list) in children { set(list.filter { !gone($0) }, for: parent) }
    }

    /// Drop the collections nothing shows any more.
    ///
    /// A collection exists only here, so one that cannot be reached is gone for
    /// good. Reached from the sidebar, or from any node that is not a
    /// collection: an aggregator can live inside a plugin's own tree, where
    /// this table cannot see it, and what was put inside it is kept until the
    /// node itself is reported gone.
    mutating func collectGarbage(root: String) {
        let anchors = [root] + children.keys.filter { CollectionRef.id(from: $0) == nil }
        let live = reachable(from: anchors)
        for uri in children.keys where CollectionRef.id(from: uri) != nil && !live.contains(uri) {
            children[uri] = nil
        }
    }

    // MARK: Migration

    /// A workspace's placements from the collections it was stored as.
    ///
    /// Whatever its sidebar reaches, and nothing else: another workspace's
    /// groups stay with that workspace. A collection that two workspaces both
    /// reached becomes a copy in each, which is what per-workspace means.
    ///
    /// Every collection takes its name into its URI, wherever it is referred
    /// to. The sidebar keeps the bare one: its name is the workspace's.
    static func migrating(_ records: [UUID: CollectionRecord], workspace: UUID) -> Placements {
        var reached: [CollectionRecord] = []
        var pending = [workspace], seen: Set<UUID> = []
        while let id = pending.popLast() {
            guard seen.insert(id).inserted, let record = records[id] else { continue }
            reached.append(record)
            pending += record.members.compactMap(CollectionRef.id(from:))
        }
        let named = Dictionary(uniqueKeysWithValues: reached.map { record in
            (record.id, record.id == workspace ? root(of: workspace)
                                               : CollectionRef.uri(for: record.id, named: record.name))
        })
        var placements = Placements()
        for record in reached {
            let members = record.members.map { member in
                CollectionRef.id(from: member).flatMap { named[$0] } ?? member
            }
            placements.set(members, for: named[record.id]!)
        }
        return placements
    }

    // MARK: -

    private mutating func set(_ list: [String], for parent: String) {
        children[parent] = list.isEmpty ? nil : list
    }

    /// Everything reachable from these through placed edges, them included.
    private func reachable(from start: [String]) -> Set<String> {
        var seen: Set<String> = [], pending = start
        while let uri = pending.popLast() {
            guard seen.insert(uri).inserted else { continue }
            pending += children(of: uri)
        }
        return seen
    }
}
