import Foundation
import MaximalTreeKit

/// Host-owned navigation state: a set of tabs, each with its own back/forward
/// history. This is purely a host UI concern — plugins never see it; they only ever
/// call `HostContext.open(_:)`, which drives the active tab. `focusedNode` on the
/// context is kept in sync with the active tab's current node.
@MainActor
@Observable
final class NavigationModel {
    struct Tab: Identifiable {
        let id = UUID()
        var history: [NodeID]
        var index: Int

        var current: NodeID? { history.indices.contains(index) ? history[index] : nil }
        var canGoBack: Bool { index > 0 }
        var canGoForward: Bool { index >= 0 && index < history.count - 1 }
    }

    private(set) var tabs: [Tab] = [Tab(history: [], index: -1)]
    private(set) var activeIndex = 0

    var activeTab: Tab { tabs[activeIndex] }
    var current: NodeID? { activeTab.current }
    var canGoBack: Bool { activeTab.canGoBack }
    var canGoForward: Bool { activeTab.canGoForward }

    /// Navigate the active tab to `id`: truncate any forward history and push.
    func navigate(to id: NodeID) {
        var tab = tabs[activeIndex]
        guard tab.current != id else { return }
        if tab.index < tab.history.count - 1 {
            tab.history.removeSubrange((tab.index + 1)...)
        }
        tab.history.append(id)
        tab.index = tab.history.count - 1
        tabs[activeIndex] = tab
    }

    func back() { if tabs[activeIndex].canGoBack { tabs[activeIndex].index -= 1 } }
    func forward() { if tabs[activeIndex].canGoForward { tabs[activeIndex].index += 1 } }

    func newTab(with id: NodeID?) {
        tabs.append(Tab(history: id.map { [$0] } ?? [], index: id == nil ? -1 : 0))
        activeIndex = tabs.count - 1
    }

    func closeTab(_ tabID: Tab.ID) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs.remove(at: i)
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        else if activeIndex > i { activeIndex -= 1 }
    }

    func selectTab(_ i: Int) { if tabs.indices.contains(i) { activeIndex = i } }

    /// A node was renamed: rewrite it throughout every tab's history.
    func remap(from old: NodeID, to new: NodeID) {
        for i in tabs.indices where tabs[i].history.contains(old) {
            tabs[i].history = tabs[i].history.map { $0 == old ? new : $0 }
        }
    }

    /// A node was deleted: drop it from every tab's history, keeping each tab's
    /// current index valid (it shifts back for entries removed at or before it).
    func remove(_ id: NodeID) {
        for i in tabs.indices {
            var tab = tabs[i]
            guard tab.history.contains(id) else { continue }
            let removedUpToIndex = tab.history[...min(tab.index, tab.history.count - 1)]
                .filter { $0 == id }.count
            tab.history.removeAll { $0 == id }
            tab.index = min(tab.index - removedUpToIndex, tab.history.count - 1)
            tabs[i] = tab
        }
    }
}
