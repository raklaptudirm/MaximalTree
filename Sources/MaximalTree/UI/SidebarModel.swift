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
    /// The pagination affordance under a partially loaded parent — keyed by
    /// the parent's row for the same reason.
    case more(parent: NodeID, depth: Int, rowID: String)

    var id: String {
        switch self {
        case .node(_, _, _, _, _, let rowID, _): return rowID
        case .more(_, _, let rowID): return rowID
        }
    }

    var nodeID: NodeID? {
        if case .node(let id, _, _, _, _, _, _) = self { return id }
        return nil
    }

    var depth: Int {
        switch self {
        case .node(_, let d, _, _, _, _, _), .more(_, let d, _): return d
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
    /// The visible tree, in order. Expanded groups recurse into what was
    /// placed in them; expanded nodes recurse into their children (asking
    /// `children` lazily, so collapsed subtrees cost nothing and trigger no
    /// loads).
    static func flatten(placements: Placements, root: String,
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

        func walkPlaced(in holder: String, container: UUID?, depth: Int,
                        parentRow: String? = nil, parent: NodeID? = nil,
                        ancestors: Set<NodeID> = []) {
            for (index, uri) in placements.children(of: holder).enumerated() {
                let position = SidebarRow.EntryPosition(container: container, index: index)
                guard let id = NodeID(uri) else { continue }
                guard Placements.isCollection(uri), let group = CollectionRef.id(from: uri) else {
                    walkNode(id, depth: depth, entry: position,
                             parentRow: parentRow, parent: parent, ancestors: ancestors)
                    continue
                }
                // A group is a node like any other: selected, opened, walked
                // to with the keyboard, taken out of its parent. What it holds
                // comes from the placements, not a listing — it is already
                // known, and asking for it would draw a tick late.
                let rowID = parentRow.map { "\($0)>\(uri)" } ?? "n:\(uri)"
                let expandable = !placements.children(of: uri).isEmpty && !ancestors.contains(id)
                let expanded = expandable && expandedNodes.contains(id)
                rows.append(.node(id, depth: depth, expandable: expandable,
                                  expanded: expanded, entry: position,
                                  rowID: rowID, parent: parent))
                if expanded {
                    walkPlaced(in: uri, container: group, depth: depth + 1,
                               parentRow: rowID, parent: id, ancestors: ancestors.union([id]))
                }
            }
        }

        walkPlaced(in: root, container: nil, depth: 0)
        return rows
    }

    /// A sidebar of nothing but these, at the top level.
    static func flatten(roots: [String], expandedNodes: Set<NodeID>,
                        graph: SidebarGraph) -> [SidebarRow] {
        let root = Placements.root(of: UUID())
        return flatten(placements: Placements(root: root, children: roots), root: root,
                       expandedNodes: expandedNodes, graph: graph)
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

    /// What is being dragged out of the sidebar, and what it was dragged out
    /// of. Recorded when the drag starts, because a drop is handed only the
    /// payload — and whether a drop moves or adds depends on where it came from.
    var drag: (uris: [String], parent: NodeID?)?

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
    /// Where dragged rows came from, as far as the sidebar's groups go.
    enum Origin: Equatable {
        case topLevel
        case group(UUID)
        /// Somewhere that is not the sidebar's to rearrange — inside a folder
        /// on disk, a repository.
        case elsewhere
    }

    enum GroupDrop: Equatable {
        case move([String], from: UUID?, to: UUID?, at: Int?)
        case add([String], to: UUID?, at: Int?)
    }

    /// Letting go over a place in the group tree: a group's row, or a strip
    /// between rows. `destination` nil is the top level.
    ///
    /// A move, by default — dragging a row somewhere has always meant moving
    /// it, and groups did exactly that before they were collections. Option
    /// adds instead, leaving it where it was too, which membership is what
    /// makes possible. Something dragged from inside a folder on disk was
    /// never the sidebar's to move, and is added.
    static func plan(dropping uris: [String], origin: Origin?, onto destination: UUID?,
                     at index: Int?, adding: Bool) -> GroupDrop {
        switch origin {
        case .topLevel? where !adding:
            return .move(uris, from: nil, to: destination, at: index)
        case .group(let source)? where !adding:
            return .move(uris, from: source, to: destination, at: index)
        default:
            return .add(uris, to: destination, at: index)
        }
    }
}
