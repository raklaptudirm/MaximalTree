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

    // MARK: Beside

    /// Nowhere to put it: split, fill the new pane, and leave the keyboard
    /// where the typing was. Asking to *see* a thing is not asking to go to it.
    @Test func besideSplitsWhenThereIsNoNeighbour() {
        let nav = NavigationModel()
        let source = id("file:///doc.typ")
        let pages = id("typst://preview?file=/doc.typ")
        nav.navigate(to: source)
        let editorPane = nav.activePane?.id

        let landed = nav.openBeside(pages)
        #expect(nav.activeTab.root.panes.count == 2)
        #expect(nav.activeTab.root.pane(landed!)?.current == pages)
        #expect(nav.activePane?.id == editorPane, "the keyboard followed the pages")
        #expect(nav.current == source)
    }

    /// A neighbour already exists: use it rather than splitting again. This is
    /// the whole reason it is one call and not "split" then "open" — pressing
    /// the key twice must not carve the window into quarters.
    @Test func besideReusesANeighbourInsteadOfSplittingAgain() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///doc.typ"))
        nav.openBeside(id("typst://preview?file=/doc.typ"))
        #expect(nav.activeTab.root.panes.count == 2)

        nav.openBeside(id("typst://preview?file=/other.typ"))
        #expect(nav.activeTab.root.panes.count == 2, "split a second time")
        #expect(nav.activeTab.root.panes.contains { $0.current?.uri.contains("other") == true })
    }

    /// Already showing it: nothing to do, and nothing moves.
    @Test func besideLeavesAPaneThatAlreadyShowsItAlone() {
        let nav = NavigationModel()
        let pages = id("typst://preview?file=/doc.typ")
        nav.navigate(to: id("file:///doc.typ"))
        let created = nav.openBeside(pages)

        let again = nav.openBeside(pages)
        #expect(again == created)
        #expect(nav.activeTab.root.panes.count == 2)
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

/// Stepping between surfaces. The tree is the only thing that knows where
/// anything is, so these check the geometry it implies.
@MainActor
@Suite struct SurfaceMovementTests {
    private func id(_ s: String) -> NodeID { NodeID(s)! }

    /// Two side by side: right lands on the other, left comes back, and up
    /// and down cross nothing.
    @Test func stepsAcrossASideBySideSplit() throws {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        let left = try #require(nav.activePane?.id)
        nav.splitActivePane(horizontal: true)
        let right = try #require(nav.activePane?.id)

        #expect(nav.movePane(.left) == left)
        #expect(nav.activePane?.id == left)
        #expect(nav.movePane(.right) == right)
        #expect(nav.movePane(.up) == nil, "nothing is stacked here")
        #expect(nav.movePane(.down) == nil)
    }

    @Test func stepsAcrossAStackedSplit() throws {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        let top = try #require(nav.activePane?.id)
        nav.splitActivePane(horizontal: false)
        let bottom = try #require(nav.activePane?.id)

        #expect(nav.movePane(.up) == top)
        #expect(nav.movePane(.down) == bottom)
        #expect(nav.movePane(.left) == nil, "nothing is beside it")
    }

    /// The edge of the tree is the edge of the window: there is nothing
    /// further that way, and saying so is what lets the caller fall through
    /// to the sidebar.
    @Test func theOutermostSurfaceHasNothingBeyondIt() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        for direction in [PaneDirection.left, .right, .up, .down] {
            #expect(nav.movePane(direction) == nil, "a lone surface has no neighbours")
        }
    }

    /// Left out of a pane stacked inside the right-hand column lands on the
    /// column beside it, not on some pane further away — this is the part a
    /// flat list of panes gets wrong.
    @Test func stepsToTheNeighbourItActuallyTouches() throws {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        let left = try #require(nav.activePane?.id)
        nav.splitActivePane(horizontal: true)      // left | right
        nav.splitActivePane(horizontal: false)     // right becomes top / bottom
        let bottomRight = try #require(nav.activePane?.id)

        #expect(nav.movePane(.left) == left, "left out of the lower right pane")
        #expect(nav.activePane?.id == left)
        // And back in: from the left column, right hugs the boundary it
        // crossed, so it lands on the top of the two rather than the bottom.
        let backIn = try #require(nav.movePane(.right))
        #expect(backIn != bottomRight, "right should land on the pane against the divider")
    }

    /// Cycling ignores geometry, which is the point of having it as well.
    @Test func cyclingVisitsEverySurfaceAndWrapsRound() throws {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.splitActivePane(horizontal: true)
        nav.splitActivePane(horizontal: false)

        let seen = (0..<3).map { _ -> UUID in
            nav.cyclePane(by: 1)
            return nav.activePane!.id
        }
        #expect(Set(seen).count == 3, "cycling should reach all three")
        nav.cyclePane(by: 1)
        #expect(nav.activePane?.id == seen[0], "and come back round")
    }

    @Test func cyclingBackwardsWrapsTheOtherWay() throws {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        let first = try #require(nav.activePane?.id)
        nav.splitActivePane(horizontal: true)
        nav.activatePane(first)

        nav.cyclePane(by: -1)
        #expect(nav.activePane?.id != first, "stepping back from the first wraps to the last")
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

    /// A document that's already open is *gone to*, not opened again — the
    /// same click that opens a file should return you to it once it's open.
    @Test func openingADocumentAlreadyInATabSwitchesToIt() {
        let nav = NavigationModel()
        nav.newTab(with: id("a"))
        nav.newTab(with: id("b"))
        #expect(nav.tabs.count == 3)

        nav.openInPreview(id("a"))

        #expect(nav.tabs.count == 3, "a second tab for the same document")
        #expect(nav.current == id("a"))
        #expect(nav.tabs[nav.activeIndex].current == id("a"))
    }

    /// Going back to an open document mustn't spend the preview tab: whatever
    /// was being glanced at is still there when you return to it.
    @Test func switchingToAnOpenDocumentLeavesThePreviewTabAlone() {
        let nav = NavigationModel()
        nav.newTab(with: id("a"))       // pinned work
        nav.openInPreview(id("b"))      // a preview beside it
        #expect(nav.tabs.count == 3)

        nav.openInPreview(id("a"))
        #expect(nav.current == id("a"))

        nav.openInPreview(id("b"))
        #expect(nav.tabs.count == 3, "the preview showing b was replaced or duplicated")
        #expect(nav.current == id("b"))
        #expect(!nav.activeTab.isPinned, "switching to a preview must not pin it")
    }

    /// Clicking the document you're already looking at does nothing at all.
    @Test func openingTheCurrentDocumentStaysPut() {
        let nav = NavigationModel()
        nav.newTab(with: id("a"))
        let tab = nav.activeTab.id

        nav.openInPreview(id("a"))

        #expect(nav.tabs.count == 2)
        #expect(nav.activeTab.id == tab)
        #expect(nav.current == id("a"))
    }

    /// Open in the *other half of a split* still counts as open: go to that
    /// pane rather than opening a third view of the same document.
    @Test func aDocumentInASplitPaneIsFocusedInPlace() {
        let nav = NavigationModel()
        nav.newTab(with: id("a"))
        nav.splitActivePane(horizontal: true)
        nav.navigate(to: id("b"))       // the new pane moves to b
        let bPane = nav.activePane?.id
        nav.activatePane(nav.activeTab.root.panes.first { $0.id != bPane }!.id)
        #expect(nav.current == id("a"))

        nav.openInPreview(id("b"))

        #expect(nav.tabs.count == 2, "opened a new tab for a document already on screen")
        #expect(nav.activePane?.id == bPane, "focus didn't move to the pane showing it")
        #expect(nav.current == id("b"))
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
