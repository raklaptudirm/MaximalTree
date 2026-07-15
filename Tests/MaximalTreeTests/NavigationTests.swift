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
        #expect(nav.activeTab.history.count == 1)
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
        #expect(nav.activeTab.history == [id("file:///a"), id("file:///c")])
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
        #expect(nav.activeTab.history == [id("file:///a"), id("file:///c")])
        #expect(nav.current == id("file:///c"))
    }

    @Test func removeCurrentFallsBack() {
        let nav = NavigationModel()
        nav.navigate(to: id("file:///a"))
        nav.navigate(to: id("file:///b"))    // current = b
        nav.remove(id("file:///b"))
        #expect(nav.current == id("file:///a"))
    }
}
