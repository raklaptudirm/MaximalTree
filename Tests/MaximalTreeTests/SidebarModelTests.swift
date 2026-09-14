import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// The sidebar's row computation and selection semantics — the logic that used
/// to live implicitly inside List/DisclosureGroup state, where the overlap and
/// stutter bugs also lived. Now it's pure and provable.
@Suite struct SidebarRowsTests {
    private func id(_ path: String) -> NodeID { NodeID("stub://\(path)")! }

    /// stub://a has children a/1 (expandable) and a/2; a/1 has child a/1/x.
    private var graph: SidebarGraph {
        SidebarGraph(
            children: { parent in
                switch parent.uri {
                case "stub://a": return [self.id("a/1"), self.id("a/2")]
                case "stub://a/1": return [self.id("a/1/x")]
                default: return []
                }
            },
            isExpandable: { ["stub://a", "stub://a/1"].contains($0.uri) },
            hasMore: { $0.uri == "stub://a" })
    }

    // MARK: Membership

    /// One node, two collections: two rows, and two identities.
    ///
    /// A row keyed by its node gave both copies the same id — which a
    /// `ForEach` does not survive, and which scrolled to whichever it found
    /// first.
    @Test func aNodeUnderTwoParentsGetsTwoDistinctRows() {
        let shared = SidebarGraph(
            children: { parent in
                ["stub://left", "stub://right"].contains(parent.uri) ? [self.id("x")] : []
            },
            isExpandable: { ["stub://left", "stub://right"].contains($0.uri) },
            hasMore: { _ in false })
        let rows = SidebarRows.flatten(entries: [.root("stub://left"), .root("stub://right")],
                                       expandedNodes: [id("left"), id("right")], graph: shared)

        let copies = rows.filter { $0.nodeID == id("x") }
        #expect(copies.count == 2, "a membership went missing")
        #expect(Set(rows.map(\.id)).count == rows.count, "two rows share an id: \(rows.map(\.id))")
    }

    /// A node inside itself draws once and stops, rather than never returning.
    @Test func aCycleFlattensAndStops() {
        // a holds b, and b holds a.
        let looping = SidebarGraph(
            children: { parent in
                switch parent.uri {
                case "stub://a": return [self.id("b")]
                case "stub://b": return [self.id("a")]
                default: return []
                }
            },
            isExpandable: { _ in true },
            hasMore: { _ in false })
        let rows = SidebarRows.flatten(entries: [.root("stub://a")],
                                       expandedNodes: [id("a"), id("b")], graph: looping)

        #expect(rows.map(\.nodeID) == [id("a"), id("b"), id("a")])
        guard case .node(_, _, let expandable, _, _, _, _) = rows[2] else {
            Issue.record("expected the repeated node as a row"); return
        }
        #expect(!expandable, "a node that is its own ancestor was offered for expansion")
    }

    /// Its own ancestors, not every node seen before. The same node under two
    /// unrelated parents is two memberships, and each can be opened.
    @Test func theSameNodeInTwoPlacesIsNotACycle() {
        let shared = SidebarGraph(
            children: { parent in
                switch parent.uri {
                case "stub://left", "stub://right": return [self.id("x")]
                case "stub://x": return [self.id("x/child")]
                default: return []
                }
            },
            isExpandable: { !$0.uri.hasSuffix("child") },
            hasMore: { _ in false })
        let rows = SidebarRows.flatten(
            entries: [.root("stub://left"), .root("stub://right")],
            expandedNodes: [id("left"), id("right"), id("x")], graph: shared)

        #expect(rows.filter { $0.nodeID == id("x/child") }.count == 2,
                "the second membership was treated as a loop and not opened")
    }

    // MARK: Drops

    /// A target that keeps members adopts; one that only contains, moves.
    @Test func dropsOntoACollectionAdopt() {
        let mutation = SidebarDrop.mutation(dropping: [id("x")], onto: id("coll"), accepts: .any)
        guard case .adopt(let ids, let into, let at) = mutation else {
            Issue.record("expected an adoption, got \(mutation)"); return
        }
        #expect(ids == [id("x")] && into == id("coll") && at == nil)
    }

    @Test func dropsOntoAContainerStillMove() {
        let mutation = SidebarDrop.mutation(dropping: [id("x")], onto: id("dir"), accepts: nil)
        guard case .move(let ids, let into) = mutation else {
            Issue.record("expected a move, got \(mutation)"); return
        }
        #expect(ids == [id("x")] && into == id("dir"))
    }

    @Test func collapsedRootIsOneRow() {
        let rows = SidebarRows.flatten(entries: [.root("stub://a")],
                                       expandedNodes: [], graph: graph)
        #expect(rows.count == 1)
        #expect(rows[0].nodeID == id("a"))
        #expect(rows[0].depth == 0)
    }

    @Test func expansionRecursesAndAppendsPagination() {
        let rows = SidebarRows.flatten(entries: [.root("stub://a")],
                                       expandedNodes: [id("a"), id("a/1")],
                                       graph: graph)
        // Rows are identified by their path: the same node can now be reached
        // two ways, and a top-level row keeps the spelling it always had.
        #expect(rows.map(\.id) == [
            "n:stub://a",
            "n:stub://a>stub://a/1",
            "n:stub://a>stub://a/1>stub://a/1/x",
            "n:stub://a>stub://a/2",
            "n:stub://a>more",
        ])
        #expect(rows[1].depth == 1)
        #expect(rows[2].depth == 2)
        // The pagination row belongs to a's listing: one level under a.
        #expect(rows[4].depth == 1)
    }

    @Test func collapsedSubtreesAreNeverAskedForChildren() {
        // The children closure must not fire for collapsed nodes — that's what
        // keeps flatten from triggering loads for invisible subtrees.
        let touched = LockedBox()
        let counting = SidebarGraph(
            children: { touched.append($0.uri); return [] },
            isExpandable: { _ in true },
            hasMore: { _ in false })
        _ = SidebarRows.flatten(entries: [.root("stub://a"), .root("stub://b")],
                                expandedNodes: [id("b")], graph: counting)
        #expect(touched.values == ["stub://b"])
    }

    private func groupNode(_ folder: RootFolder) -> NodeID {
        NodeID(canonical: CollectionRef.uri(for: folder.id))
    }

    /// A group is a node row like any other, and carries where it sits so the
    /// strips around it can drop into the right place.
    @Test func groupsAreNodeRowsAndCarryTheirPositions() {
        let inner = RootFolder(id: UUID(), name: "Inner", entries: [.root("stub://a")])
        let outer = RootFolder(id: UUID(), name: "Outer", entries: [.folder(inner)])
        let rows = SidebarRows.flatten(entries: [.folder(outer), .root("stub://b")],
                                       expandedNodes: [groupNode(outer), groupNode(inner)],
                                       graph: graph)

        guard case .node(let o, 0, true, true, let oPos, _, let oParent) = rows[0],
              case .node(let i, 1, true, true, let iPos, _, let iParent) = rows[1],
              case .node(let a, 2, _, _, let aPos, _, let aParent) = rows[2],
              case .node(let b, 0, _, _, let bPos, _, let bParent) = rows[3]
        else { Issue.record("unexpected shape: \(rows.map(\.id))"); return }

        #expect(o == groupNode(outer) && i == groupNode(inner))
        #expect(a == id("a") && b == id("b"))
        #expect(oPos == .init(container: nil, index: 0))
        #expect(iPos == .init(container: outer.id, index: 0))
        #expect(aPos == .init(container: inner.id, index: 0))
        #expect(bPos == .init(container: nil, index: 1))
        // And each knows what it is in, which is what "remove" acts on.
        #expect(oParent == nil && iParent == groupNode(outer) && aParent == groupNode(inner))
        #expect(bParent == nil)
    }

    /// Open is the node expansion now, groups included — closed unless opened.
    @Test func aClosedGroupHidesWhatItHolds() {
        let folder = RootFolder(id: UUID(), name: "F", entries: [.root("stub://a")])
        let rows = SidebarRows.flatten(entries: [.folder(folder)],
                                       expandedNodes: [], graph: graph)
        #expect(rows.count == 1)
        #expect(rows.first?.nodeID == groupNode(folder))
    }

    /// An empty group has nothing to open, so no triangle — but it is still
    /// somewhere to drop things.
    @Test func anEmptyGroupIsNotExpandable() {
        let empty = RootFolder(id: UUID(), name: "Empty", entries: [])
        let rows = SidebarRows.flatten(entries: [.folder(empty)],
                                       expandedNodes: [groupNode(empty)], graph: graph)
        guard case .node(_, _, let expandable, _, _, _, _) = rows.first else {
            Issue.record("expected the group's row"); return
        }
        #expect(!expandable)
    }

    // MARK: Dropping into the group tree

    /// Dragging a row somewhere moves it, as it always has.
    @Test func aDropMovesByDefault() {
        let target = UUID(), source = UUID()
        #expect(SidebarDrop.plan(dropping: ["file:///x"], origin: .group(source),
                                 onto: target, at: nil, adding: false)
                == .move(["file:///x"], from: source, to: target, at: nil))
        #expect(SidebarDrop.plan(dropping: ["file:///x"], origin: .topLevel,
                                 onto: target, at: 2, adding: false)
                == .move(["file:///x"], from: nil, to: target, at: 2))
    }

    /// Option leaves it where it was as well.
    @Test func optionAdds() {
        let target = UUID()
        #expect(SidebarDrop.plan(dropping: ["file:///x"], origin: .group(UUID()),
                                 onto: target, at: nil, adding: true)
                == .add(["file:///x"], to: target, at: nil))
    }

    /// From inside a folder on disk, or from a drag the sidebar did not start,
    /// there is nothing of the sidebar's to move it out of.
    @Test func aDropFromElsewhereAdds() {
        let target = UUID()
        #expect(SidebarDrop.plan(dropping: ["file:///x"], origin: .elsewhere,
                                 onto: target, at: nil, adding: false)
                == .add(["file:///x"], to: target, at: nil))
        #expect(SidebarDrop.plan(dropping: ["file:///x"], origin: nil,
                                 onto: target, at: nil, adding: false)
                == .add(["file:///x"], to: target, at: nil))
    }

    private final class LockedBox: @unchecked Sendable {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }
}

@Suite struct SidebarSelectionTests {
    private func id(_ n: Int) -> NodeID { NodeID("stub://n\(n)")! }
    private var ordered: [NodeID] { (0..<6).map(id) }

    @Test func plainClickReplacesAndAnchors() {
        let (sel, anchor) = SidebarSelection.afterClick(
            on: id(3), ordered: ordered, selection: [id(0), id(1)],
            anchor: id(0), command: false, shift: false)
        #expect(sel == [id(3)] && anchor == id(3))
    }

    @Test func commandClickTogglesMembership() {
        var (sel, anchor) = SidebarSelection.afterClick(
            on: id(3), ordered: ordered, selection: [id(1)],
            anchor: id(1), command: true, shift: false)
        #expect(sel == [id(1), id(3)] && anchor == id(3))

        (sel, anchor) = SidebarSelection.afterClick(
            on: id(1), ordered: ordered, selection: sel,
            anchor: anchor, command: true, shift: false)
        #expect(sel == [id(3)])
        #expect(anchor == id(3))
    }

    @Test func shiftClickSelectsTheVisibleRange() {
        // Down from the anchor…
        var (sel, anchor) = SidebarSelection.afterClick(
            on: id(4), ordered: ordered, selection: [id(1)],
            anchor: id(1), command: false, shift: true)
        #expect(sel == Set([1, 2, 3, 4].map(id)))
        #expect(anchor == id(1), "the anchor survives so the range can pivot")

        // …then pivoting up around the same anchor replaces the range.
        (sel, anchor) = SidebarSelection.afterClick(
            on: id(0), ordered: ordered, selection: sel,
            anchor: anchor, command: false, shift: true)
        #expect(sel == Set([0, 1].map(id)))
    }

    @Test func arrowsMoveFromTheSelectionEdge() {
        #expect(SidebarSelection.afterArrow(down: true, ordered: ordered,
                                            selection: [id(1), id(3)]) == id(4))
        #expect(SidebarSelection.afterArrow(down: false, ordered: ordered,
                                            selection: [id(1), id(3)]) == id(0))
        // Edges clamp to nothing rather than wrapping.
        #expect(SidebarSelection.afterArrow(down: true, ordered: ordered,
                                            selection: [id(5)]) == nil)
        // No selection: an arrow lands somewhere sensible.
        #expect(SidebarSelection.afterArrow(down: true, ordered: ordered,
                                            selection: []) == id(0))
    }
}

/// Disclosure has to write through to the host the moment it changes — the app
/// can be quit at any point, and nothing else would have saved it.
@MainActor
@Suite struct SidebarPersistenceTests {
    private func node(_ path: String) throws -> NodeID {
        try #require(NodeID("file://\(path)"))
    }

    @Test func togglingReportsTheRevealedSet() throws {
        let state = SidebarState()
        var reported: [Set<NodeID>] = []
        state.onExpansionChanged = { reported.append($0) }

        let a = try node("/tmp/a")
        state.toggle(a)
        state.toggle(a)

        #expect(reported == [[a], []])
    }

    @Test func restoringDoesNotReportBack() throws {
        let state = SidebarState()
        var reports = 0
        state.onExpansionChanged = { _ in reports += 1 }

        state.restore(SidebarState.Snapshot(expandedNodes: [try node("/tmp/a")],
                                            anchor: nil))

        // Loading persisted state isn't an edit; echoing it back would let a
        // restore overwrite the workspace it was just read from.
        #expect(reports == 0)
        #expect(state.expandedNodes.count == 1)
    }

    @Test func renamingKeepsTheSubtreeOpenAndReportsIt() throws {
        let state = SidebarState()
        let old = try node("/tmp/old")
        let new = try node("/tmp/new")
        state.restore(SidebarState.Snapshot(expandedNodes: [old], anchor: old))

        var reported: Set<NodeID>?
        state.onExpansionChanged = { reported = $0 }
        state.remap(from: old, to: new)

        #expect(state.expandedNodes == [new])
        #expect(reported == [new])
    }
}
