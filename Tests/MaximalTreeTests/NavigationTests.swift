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
