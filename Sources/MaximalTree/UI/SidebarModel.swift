import Foundation
import MaximalTreeKit

// The sidebar's brain, kept apart from its pixels. The old sidebar was a
// recursive stack of DisclosureGroups inside a heavily customized List — row
// positions, expansion, and selection all lived implicitly inside SwiftUI
// containers, which is exactly where they couldn't be tested, and where the
// engine's compositing bugs (overlapping rows) and reconciliation loops
// (selection mirrored in two places) lived. Now the visible tree is *computed*:
// one pure function flattens the workspace layout + expansion state into an
// ordered row list, and one pure function answers what a click does to the
// selection. The view renders the result and nothing else.

/// One visible sidebar row, in display order.
enum SidebarRow: Identifiable, Equatable {
    /// Where a row sits in the workspace organization (folder + index) — only
    /// top-level entries (roots and folders) have one; it's what the
    /// position-aware insertion strips target.
    struct EntryPosition: Equatable {
        let container: UUID?
        let index: Int
    }

    /// A mounted root or one of its descendants.
    ///
    /// `rowID` is the path to it, not the node. Once a node can belong to more
    /// than one collection it appears in more than one place, and a row keyed
    /// by the node alone gave two rows one identity — which `ForEach` does not
    /// survive, and which sent a scroll to whichever copy it found first.
    ///
    /// `parent` is the node it was reached through, if any — needed to take it
    /// out of a collection, since with membership the same node can be in
    /// several and "remove" has to know which one it means.
    case node(NodeID, depth: Int, expandable: Bool, expanded: Bool, entry: EntryPosition?,
              rowID: String, parent: NodeID?)
    /// A workspace organization folder (host-side; no node behind it).
    case folder(id: UUID, name: String, depth: Int, expanded: Bool, entry: EntryPosition)
    /// The pagination affordance under a partially loaded parent — keyed by
    /// the parent's row for the same reason.
    case more(parent: NodeID, depth: Int, rowID: String)

    var id: String {
        switch self {
        case .node(_, _, _, _, _, let rowID, _): return rowID
        case .folder(let id, _, _, _, _): return "f:\(id.uuidString)"
        case .more(_, _, let rowID): return rowID
        }
    }

    var nodeID: NodeID? {
        if case .node(let id, _, _, _, _, _, _) = self { return id }
        return nil
    }

    var depth: Int {
        switch self {
        case .node(_, let d, _, _, _, _, _), .folder(_, _, let d, _, _), .more(_, let d, _): return d
        }
    }
}

/// Everything the flattener needs to ask about the graph, as closures so the
/// logic stays pure and the tests stay tiny.
struct SidebarGraph {
    let children: (NodeID) -> [NodeID]
    let isExpandable: (NodeID) -> Bool
    let hasMore: (NodeID) -> Bool
}

enum SidebarRows {
    /// The visible tree, in order. Expanded folders recurse into their entries;
    /// expanded nodes recurse into their children (asking `children` lazily, so
    /// collapsed subtrees cost nothing and trigger no loads).
    static func flatten(entries: [RootEntry],
                        expandedNodes: Set<NodeID>,
                        graph: SidebarGraph) -> [SidebarRow] {
        var rows: [SidebarRow] = []

        func walkNode(_ id: NodeID, depth: Int, entry: SidebarRow.EntryPosition?,
                      parentRow: String? = nil, parent: NodeID? = nil,
                      ancestors: Set<NodeID> = []) {
            // A top-level row keeps the identity it always had; below that the
            // path is spelled out, since the same node can be reached two ways.
            let rowID = parentRow.map { "\($0)>\(id.uri)" } ?? "n:\(id.uri)"
            // A node that is its own ancestor — possible now that membership is
            // by reference — is drawn once and not walked into, or this would
            // not return. Its ancestors, not every node seen: the same node
            // under two different parents is not a cycle, and hiding the second
            // copy would hide a real membership.
            let isOwnAncestor = ancestors.contains(id)
            let expandable = !isOwnAncestor && graph.isExpandable(id)
            let expanded = expandable && expandedNodes.contains(id)
            rows.append(.node(id, depth: depth, expandable: expandable,
                              expanded: expanded, entry: entry, rowID: rowID, parent: parent))
            guard expanded else { return }
            let lineage = ancestors.union([id])
            for child in graph.children(id) {
                walkNode(child, depth: depth + 1, entry: nil,
                         parentRow: rowID, parent: id, ancestors: lineage)
            }
            if graph.hasMore(id) {
                rows.append(.more(parent: id, depth: depth + 1, rowID: "\(rowID)>more"))
            }
        }

        func walkEntries(_ entries: [RootEntry], container: UUID?, depth: Int) {
            for (index, entry) in entries.enumerated() {
                let position = SidebarRow.EntryPosition(container: container, index: index)
                switch entry {
                case .root(let uri):
                    guard let id = NodeID(uri) else { continue }
                    walkNode(id, depth: depth, entry: position)
                case .folder(let folder):
                    rows.append(.folder(id: folder.id, name: folder.name, depth: depth,
                                        expanded: folder.isExpanded, entry: position))
                    if folder.isExpanded {
                        walkEntries(folder.entries, container: folder.id, depth: depth + 1)
                    }
                }
            }
        }

        walkEntries(entries, container: nil, depth: 0)
        return rows
    }
}

enum SidebarSelection {
    /// What a click on `id` does to the selection — Finder's vocabulary:
    /// plain replaces, ⌘ toggles, ⇧ selects the visible range from the anchor.
    /// `ordered` is the flattened row order (only node rows participate).
    static func afterClick(on id: NodeID,
                           ordered: [NodeID],
                           selection: Set<NodeID>,
                           anchor: NodeID?,
                           command: Bool,
                           shift: Bool) -> (selection: Set<NodeID>, anchor: NodeID?) {
        if shift {
            let from = anchor ?? id
            guard let a = ordered.firstIndex(of: from), let b = ordered.firstIndex(of: id)
            else { return ([id], id) }
            let range = ordered[min(a, b)...max(a, b)]
            return (Set(range), from)
        }
        if command {
            var next = selection
            if next.contains(id) {
                next.remove(id)
                return (next, next.isEmpty ? nil : anchor)
            }
            next.insert(id)
            return (next, id)
        }
        return ([id], id)
    }

    /// The row selection moves to for an up/down arrow, or nil at the edges.
    static func afterArrow(down: Bool,
                           ordered: [NodeID],
                           selection: Set<NodeID>) -> NodeID? {
        guard !ordered.isEmpty else { return nil }
        // Move relative to the selection's edge in the arrow's direction.
        let indices = selection.compactMap { ordered.firstIndex(of: $0) }
        guard let edge = down ? indices.max() : indices.min() else {
            return down ? ordered.first : ordered.last
        }
        let next = down ? edge + 1 : edge - 1
        guard ordered.indices.contains(next) else { return nil }
        return ordered[next]
    }
}

/// Sidebar UI state for the active workspace. Expansion outlives the process:
/// the host persists it per workspace (see `onExpansionChanged`), next to the
/// folder expansion that always lived in the workspace layout.
@MainActor
@Observable
final class SidebarState {
    var expandedNodes: Set<NodeID> = [] {
        didSet {
            guard !isRestoring, expandedNodes != oldValue else { return }
            onExpansionChanged?(expandedNodes)
        }
    }
    /// The last plainly-clicked row — where a ⇧-range starts.
    var anchor: NodeID?

    /// Called whenever the revealed set changes, so the host can persist it.
    /// Not called while restoring — that direction is a load, not an edit.
    var onExpansionChanged: ((Set<NodeID>) -> Void)?
    private var isRestoring = false

    func toggle(_ id: NodeID) {
        if expandedNodes.contains(id) {
            expandedNodes.remove(id)
        } else {
            expandedNodes.insert(id)
        }
    }

    /// Follow a rename so the renamed subtree stays open.
    func remap(from old: NodeID, to new: NodeID) {
        if expandedNodes.remove(old) != nil { expandedNodes.insert(new) }
        if anchor == old { anchor = new }
    }

    /// Which nodes are revealed, so a workspace switch can put the tree back
    /// the way it was rather than collapsing everything.
    struct Snapshot {
        var expandedNodes: Set<NodeID>
        var anchor: NodeID?
    }

    func snapshot() -> Snapshot {
        Snapshot(expandedNodes: expandedNodes, anchor: anchor)
    }

    func restore(_ snapshot: Snapshot) {
        isRestoring = true
        expandedNodes = snapshot.expandedNodes
        anchor = snapshot.anchor
        isRestoring = false
    }
}

/// What letting go of dragged nodes over another node asks for.
enum SidebarDrop {
    /// Adoption when the target keeps members, a move when it only contains.
    ///
    /// The target decides, because the target is the one that means something
    /// by the drop. A folder on disk takes a file by moving it there; an
    /// aggregator takes a channel by remembering it, and the channel stays
    /// wherever else it already was. Dropped onto the end of the collection:
    /// a row is "into this", and where among the members is the collection's
    /// own view to offer.
    static func mutation(dropping ids: [NodeID], onto target: NodeID,
                         accepts: AcceptedChildren?) -> GraphMutation {
        accepts == nil ? .move(ids, into: target) : .adopt(ids, into: target, at: nil)
    }
}
