import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

@MainActor
@Suite struct NavigationModelTests {
    private func id(_ s: String) -> NodeID { NodeID(s)! }

    @Test func startsEmpty() {
        let nav = NavigationModel()
        #expect(nav.current == nil)
        #expect(nav.tabs.count == 1)
        #expect(!nav.canGoBack)
        #expect(!nav.canGoForward)
    }

    @Test func navigatePushesHistory() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        #expect(nav.current == id("file:///a"))
        nav.navigate(to: id("file:///b"))
        #expect(nav.current == id("file:///b"))
        #expect(nav.canGoBack)
        #expect(!nav.canGoForward)
    }

    @Test func navigateSameIsNoop() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.navigate(to: id("file:///a"))
        #expect(nav.activePane?.history.count == 1)
    }

    @Test func backAndForward() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.navigate(to: id("file:///b"))
        nav.back()
        #expect(nav.current == id("file:///a"))
        #expect(nav.canGoForward)
        nav.forward()
        #expect(nav.current == id("file:///b"))
    }

    @Test func navigateTruncatesForwardHistory() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.navigate(to: id("file:///b"))
        nav.back()                        // at a; forward would be b
        nav.navigate(to: id("file:///c")) // should drop b
        #expect(nav.current == id("file:///c"))
        #expect(!nav.canGoForward)
        #expect(nav.activePane?.history == [id("file:///a"), id("file:///c")])
    }

    @Test func newTabActivatesAndIsIndependent() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.newTab(with: id("file:///b"))
        #expect(nav.tabs.count == 2)
        #expect(nav.activeIndex == 1)
        #expect(nav.current == id("file:///b"))
        #expect(!nav.canGoBack)           // fresh tab has no back history
    }

    @Test func closeTabClampsActiveIndex() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.newTab(with: id("file:///b"))
        nav.newTab(with: id("file:///c"))   // tabs a,b,c; active = 2
        nav.closeTab(nav.activeTab.id)       // close c; active clamps to 1
        #expect(nav.tabs.count == 2)
        #expect(nav.current == id("file:///b"))
    }

    @Test func cannotCloseLastTab() {
        let nav = NavigationModel()
        nav.closeTab(nav.activeTab.id)
        #expect(nav.tabs.count == 1)
    }

    @Test func remapRewritesHistory() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.navigate(to: id("file:///b"))
        nav.remap(from: id("file:///b"), to: id("file:///c"))
        #expect(nav.current == id("file:///c"))
        nav.back()
        #expect(nav.current == id("file:///a"))   // rest of history intact
    }

    @Test func removeDropsFromHistoryAndKeepsIndexValid() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.navigate(to: id("file:///b"))
        nav.navigate(to: id("file:///c"))    // index 2
        nav.remove(id("file:///b"))          // remove the middle entry
        #expect(nav.activePane?.history == [id("file:///a"), id("file:///c")])
        #expect(nav.current == id("file:///c"))
    }

    @Test func resetReturnsToSingleEmptyTab() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.newTab(with: id("file:///b"))
        nav.reset()
        #expect(nav.tabs.count == 1)
        #expect(nav.current == nil)
        #expect(!nav.canGoBack && !nav.canGoForward)
    }

    @Test func removeCurrentFallsBack() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.navigate(to: id("file:///b"))    // current = b
        nav.remove(id("file:///b"))
        #expect(nav.current == id("file:///a"))
    }
}

@MainActor
@Suite struct SplitPaneTests {
    private func id(_ s: String) -> NodeID { NodeID(s)! }

    @Test func splitDuplicatesCurrentIntoNewActivePane() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        let original = nav.activePane?.id

        nav.splitActivePane(horizontal: true)

        #expect(nav.activeTab.root.panes.count == 2)
        #expect(nav.activePane?.id != original, "the new pane becomes active")
        #expect(nav.current == id("file:///a"), "new pane starts on the same node")
        #expect(!nav.canGoBack, "…but with fresh history")
    }

    @Test func panesNavigateIndependently() throws {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        let first = try #require(nav.activePane?.id)
        nav.splitActivePane(horizontal: true)

        nav.navigate(to: id("file:///b"))          // in the new (active) pane

        #expect(nav.current == id("file:///b"))
        #expect(nav.activeTab.root.pane(first)?.current == id("file:///a"))
    }

    @Test func closePaneActivatesRemaining() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.splitActivePane(horizontal: false)
        nav.navigate(to: id("file:///b"))

        nav.closeActivePane()                      // closes the pane showing b

        #expect(nav.activeTab.root.panes.count == 1)
        #expect(nav.current == id("file:///a"))
    }

    @Test func cannotCloseLastPane() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.closeActivePane()
        #expect(nav.activeTab.root.panes.count == 1)
        #expect(nav.current == id("file:///a"))
    }

    @Test func nestedSplitsCollapseCorrectly() throws {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.splitActivePane(horizontal: true)      // [a | a']
        nav.splitActivePane(horizontal: false)     // [a | (a' / a'')]
        #expect(nav.activeTab.root.panes.count == 3)

        nav.closeActivePane()                      // collapse innermost split
        #expect(nav.activeTab.root.panes.count == 2)
        nav.closeActivePane()
        #expect(nav.activeTab.root.panes.count == 1)
    }

    @Test func activatePaneSwitchesCurrent() throws {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        let first = try #require(nav.activePane?.id)
        nav.splitActivePane(horizontal: true)
        nav.navigate(to: id("file:///b"))

        nav.activatePane(first)
        #expect(nav.current == id("file:///a"))
    }

    @Test func remapAndRemoveReachAllPanes() throws {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///x"))
        let first = try #require(nav.activePane?.id)
        nav.splitActivePane(horizontal: true)      // both panes show x

        nav.remap(from: id("file:///x"), to: id("file:///y"))
        #expect(nav.current == id("file:///y"))
        #expect(nav.activeTab.root.pane(first)?.current == id("file:///y"))

        nav.remove(id("file:///y"))
        #expect(nav.current == nil)
        #expect(nav.activeTab.root.pane(first)?.current == nil)
    }

    @Test func splitStartsEvenAndFractionClampsWhenDragged() throws {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.splitActivePane(horizontal: true)

        guard case .split(let sid, _, let fraction, _, _) = nav.activeTab.root else {
            Issue.record("root should be a split"); return
        }
        #expect(fraction == 0.5)

        nav.setSplitFraction(sid, to: 0.02)     // dragged nearly off the edge
        guard case .split(_, _, let clamped, _, _) = nav.activeTab.root else {
            Issue.record("root should still be a split"); return
        }
        #expect(clamped == 0.1, "divider clamps so neither side vanishes")
    }

    @Test func resetCollapsesToSinglePane() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.splitActivePane(horizontal: true)
        nav.reset()
        #expect(nav.activeTab.root.panes.count == 1)
        #expect(nav.current == nil)
    }
}

/// Preview tabs and session snapshots — the two behaviours that make tabs feel
/// like an editor's rather than a browser's.
@MainActor
@Suite struct TabLifecycleTests {
    private func id(_ s: String) -> NodeID { NodeID("stub://\(s)")! }

    /// Clicking around reuses one provisional tab; editing claims it, so the
    /// next thing opened arrives beside your work instead of on top of it.
    @Test func previewTabIsReusedUntilTheDocumentIsEdited() {
        let nav = NavigationModel()

        nav.openInPreview(id("a"))
        #expect(nav.tabs.count == 1)
        #expect(nav.current == id("a"))
        #expect(!nav.activeTab.isPinned)

        // Still a preview: b replaces a rather than stacking up.
        nav.openInPreview(id("b"))
        #expect(nav.tabs.count == 1)
        #expect(nav.current == id("b"))

        // Typing in b claims the tab.
        nav.pinTabs(showing: id("b"))
        #expect(nav.activeTab.isPinned)

        // So c can't displace it.
        nav.openInPreview(id("c"))
        #expect(nav.tabs.count == 2)
        #expect(nav.current == id("c"))
        #expect(!nav.activeTab.isPinned, "the new tab is itself a preview")
        #expect(nav.tabs[0].current == id("b"), "the edited document survived")

        // And c, still a preview, is the one that gets reused next.
        nav.openInPreview(id("d"))
        #expect(nav.tabs.count == 2)
        #expect(nav.tabs[1].current == id("d"))
    }

    /// Asking for a new tab explicitly means keeping it.
    @Test func explicitNewTabsArePinned() {
        let nav = NavigationModel()
        nav.newTab(with: id("a"))
        #expect(nav.activeTab.isPinned)

        nav.openInPreview(id("b"))
        #expect(nav.tabs.count == 3, "a pinned tab is never reused")
    }

    /// Pinning targets the document, not the active tab: an edit in a
    /// background tab still protects it.
    @Test func editingPinsWhicheverTabShowsTheDocument() {
        let nav = NavigationModel()
        nav.newTab(with: id("a"))
        nav.newTab(with: id("b"))

        nav.pinTabs(showing: id("a"))
        #expect(nav.tabs.first { $0.current == id("a") }?.isPinned == true)
    }

    /// A workspace switch swaps whole surfaces: tabs, their splits, each
    /// pane's history, and which tab was active all come back.
    @Test func snapshotRestoresTheWholeSurface() {
        let nav = NavigationModel()
        nav.openInPreview(id("a"))
        nav.pinTabs(showing: id("a"))
        nav.newTab(with: id("b"))
        // Split first: a new pane starts fresh at the same document, so the
        // history has to be built in the pane that will carry it.
        nav.splitActivePane(horizontal: true)
        nav.navigate(to: id("b2"))
        nav.selectTab(0)
        let saved = nav.snapshot()

        // Go somewhere else entirely, as switching workspaces does.
        nav.reset()
        #expect(nav.tabs.count == 1)
        #expect(nav.current == nil)

        nav.restore(saved)
        #expect(nav.tabs.count == 2)
        #expect(nav.activeIndex == 0)
        #expect(nav.current == id("a"))
        #expect(nav.tabs[0].isPinned)
        #expect(nav.tabs[1].current == id("b2"))
        #expect(nav.tabs[1].root.panes.count == 2, "the split came back")

        // History survived, not just the current node.
        nav.selectTab(1)
        #expect(nav.canGoBack)
        nav.back()
        #expect(nav.current == id("b"))
    }

    @Test func restoringAnEmptySnapshotFallsBackToAFreshTab() {
        let nav = NavigationModel()
        nav.openInPreview(id("a"))
        nav.restore(NavigationModel.Snapshot(tabs: [], activeIndex: 5))
        #expect(nav.tabs.count == 1)
        #expect(nav.current == nil)
    }
}

@MainActor
@Suite struct SidebarSessionTests {
    @Test func expansionRoundTripsThroughASnapshot() throws {
        let state = SidebarState()
        let a = try #require(NodeID("stub://a"))
        let b = try #require(NodeID("stub://b"))
        state.toggle(a)
        state.toggle(b)
        state.anchor = a
        let saved = state.snapshot()

        // Switching away collapses the tree…
        state.restore(SidebarState.Snapshot(expandedNodes: [], anchor: nil))
        #expect(state.expandedNodes.isEmpty)

        // …and switching back reveals exactly what was revealed before.
        state.restore(saved)
        #expect(state.expandedNodes == [a, b])
        #expect(state.anchor == a)
    }
}
