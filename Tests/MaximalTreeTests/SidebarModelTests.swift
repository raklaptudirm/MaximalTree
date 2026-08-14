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
        #expect(rows.map(\.id) == [
            "n:stub://a", "n:stub://a/1", "n:stub://a/1/x", "n:stub://a/2",
            "m:stub://a",
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

    @Test func foldersNestAndCarryEntryPositions() {
        let inner = RootFolder(id: UUID(), name: "Inner",
                               entries: [.root("stub://a")], isExpanded: true)
        let outer = RootFolder(id: UUID(), name: "Outer",
                               entries: [.folder(inner)], isExpanded: true)
        let rows = SidebarRows.flatten(entries: [.folder(outer), .root("stub://b")],
                                       expandedNodes: [], graph: graph)

        guard case .folder(let outerID, _, 0, true, let outerPos) = rows[0],
              case .folder(let innerID, _, 1, true, let innerPos) = rows[1],
              case .node(let a, 2, _, _, let aPos) = rows[2],
              case .node(let b, 0, _, _, let bPos) = rows[3]
        else { Issue.record("unexpected shape: \(rows.map(\.id))"); return }

        #expect(outerID == outer.id && innerID == inner.id)
        #expect(a == id("a") && b == id("b"))
        #expect(outerPos == .init(container: nil, index: 0))
        #expect(innerPos == .init(container: outer.id, index: 0))
        #expect(aPos == .init(container: inner.id, index: 0))
        #expect(bPos == .init(container: nil, index: 1))
    }

    @Test func collapsedFolderHidesItsEntries() {
        let folder = RootFolder(id: UUID(), name: "F",
                                entries: [.root("stub://a")], isExpanded: false)
        let rows = SidebarRows.flatten(entries: [.folder(folder)],
                                       expandedNodes: [], graph: graph)
        #expect(rows.count == 1)
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
