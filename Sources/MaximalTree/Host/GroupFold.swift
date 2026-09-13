import Foundation
import MaximalTreeKit

/// The sidebar's groups, as collections, and back.
///
/// Groups were a tree the host kept for itself: folders of roots, invisible to
/// the rest of the graph. They are collections now — a group is a collection
/// that takes anything — and this is the exact correspondence between the two
/// shapes, as pure functions, so that it can be checked in both directions.
///
/// Both directions exist on purpose. Collections are the truth, but the sidebar
/// still draws a layout for now, and the layout is still written beside them:
/// a build from before this change reads it and shows the same sidebar, and if
/// the collections were ever lost the layout rebuilds them.
enum GroupFold {
    // MARK: Layout → collections

    /// A workspace's layout as collections.
    ///
    /// No identities are invented. The top level becomes the collection whose
    /// id is the workspace's own, and each folder becomes the collection whose
    /// id is the folder's — so migrating the same layout twice gives the same
    /// collections, and nothing that already pointed at a folder has to move.
    static func collections(from entries: [RootEntry], workspace: UUID,
                            named name: String) -> [CollectionRecord] {
        var records: [CollectionRecord] = []
        func members(of entries: [RootEntry]) -> [String] {
            entries.map { entry in
                switch entry {
                case .root(let uri):
                    return uri
                case .folder(let folder):
                    records.append(CollectionRecord(id: folder.id, name: folder.name,
                                                    members: members(of: folder.entries)))
                    return CollectionRef.uri(for: folder.id)
                }
            }
        }
        let top = CollectionRecord(id: workspace, name: name, members: members(of: entries))
        return [top] + records
    }

    /// The folders that were closed, as the collections they became.
    ///
    /// Closed rather than open, because a group is open unless someone closed
    /// it — so what needs writing down is the exception.
    static func collapsed(in entries: [RootEntry]) -> [String] {
        entries.flatMap { entry -> [String] in
            guard case .folder(let folder) = entry else { return [] }
            return (folder.isExpanded ? [] : [CollectionRef.uri(for: folder.id)])
                + collapsed(in: folder.entries)
        }
    }

    // MARK: Collections → layout

    /// What the sidebar draws, from the collections.
    ///
    /// A member that is a collection becomes a folder; anything else is a root.
    /// A collection that appears inside itself is left out rather than drawn
    /// for ever — the host refuses to form one, but a file edited by hand can
    /// still describe one.
    static func layout(workspace: UUID, records: [UUID: CollectionRecord],
                       collapsed: Set<String>) -> [RootEntry] {
        func entries(of id: UUID, lineage: Set<UUID>) -> [RootEntry] {
            guard let record = records[id] else { return [] }
            return record.members.compactMap { member in
                guard let child = CollectionRef.id(from: member), let nested = records[child] else {
                    return .root(member)
                }
                guard !lineage.contains(child) else { return nil }
                return .folder(RootFolder(id: child, name: nested.name,
                                          entries: entries(of: child, lineage: lineage.union([child])),
                                          isExpanded: !collapsed.contains(member)))
            }
        }
        return entries(of: workspace, lineage: [workspace])
    }

    /// Everything mounted in a workspace: the members that are not groups,
    /// reachable from its top level, in the order the sidebar shows them, each
    /// once.
    ///
    /// This is `context.roots` — the set the rest of the graph sees. Groups
    /// stay out of it for the same reason folders always did: they organise
    /// the sidebar, they are not something you mounted.
    static func roots(workspace: UUID, records: [UUID: CollectionRecord]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for entry in layout(workspace: workspace, records: records, collapsed: []) {
            for uri in entry.rootURIs where seen.insert(uri).inserted {
                result.append(uri)
            }
        }
        return result
    }
}
