import Foundation
import Observation
import MaximalTreeKit

extension Int {
    /// Modulo that brings negatives round the other side, which `%` doesn't:
    /// stepping back from the first tab belongs on the last.
    func wrapped(around count: Int) -> Int {
        guard count > 0 else { return 0 }
        let remainder = self % count
        return remainder < 0 ? remainder + count : remainder
    }
}

/// One navigation surface: a linear back/forward history shown in a single canvas
/// pane. (Before splits existed this state lived directly on `Tab`.)
struct Pane: Identifiable, Equatable {
    let id: UUID
    var history: [NodeID]
    var index: Int

    init(with nodeID: NodeID? = nil) {
        self.id = UUID()
        self.history = nodeID.map { [$0] } ?? []
        self.index = history.isEmpty ? -1 : 0
    }

    var current: NodeID? { history.indices.contains(index) ? history[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < history.count - 1 }

    /// Navigate: truncate any forward history and push.
    mutating func navigate(to id: NodeID) {
        guard current != id else { return }
        if index < history.count - 1 { history.removeSubrange((index + 1)...) }
        history.append(id)
        index = history.count - 1
    }

    mutating func back() { if canGoBack { index -= 1 } }
    mutating func forward() { if canGoForward { index += 1 } }

    /// A node was renamed: rewrite it throughout this pane's history.
    mutating func remap(from old: NodeID, to new: NodeID) {
        history = history.map { $0 == old ? new : $0 }
    }

    /// A node was deleted: drop it from history, keeping the index valid (it shifts
    /// back for entries removed at or before it).
    mutating func remove(_ id: NodeID) {
        guard history.contains(id) else { return }
        let removedUpToIndex = history[...min(index, history.count - 1)]
            .filter { $0 == id }.count
        history.removeAll { $0 == id }
        index = min(index - removedUpToIndex, history.count - 1)
    }
}

/// Which way to step between surfaces.
enum PaneDirection: Equatable {
    case left, right, up, down

    /// Left and right cross a side-by-side split; up and down a stacked one.
    var isHorizontal: Bool { self == .left || self == .right }
    /// `first` is the leading child — left in a side-by-side split, top in a
    /// stacked one — so these two are the ones that move towards `second`.
    var towardsSecond: Bool { self == .right || self == .down }
}

/// A binary tree of panes. "Arbitrary splits" come from nesting: splitting a pane
/// replaces its leaf with a split holding it and a new pane, on either axis.
indirect enum SplitNode: Equatable {
    case pane(Pane)
    /// `fraction` is the first child's share of the container (0…1), settable by
    /// dragging the divider. It lives in the model so the layout is deterministic —
    /// the view sizes panes as fractions of its measured bounds, which is what makes
    /// overflowing the canvas column structurally impossible.
    case split(id: UUID, horizontal: Bool, fraction: Double, first: SplitNode, second: SplitNode)

    var panes: [Pane] {
        switch self {
        case .pane(let pane): return [pane]
        case .split(_, _, _, let first, let second): return first.panes + second.panes
        }
    }

    func pane(_ id: UUID) -> Pane? { panes.first { $0.id == id } }

    /// The pane you reach by stepping `direction` out of `id`, or nil when
    /// that edge of the window is the edge of the tree.
    ///
    /// The tree is what says where things are — panes have no coordinates —
    /// so this walks up from the pane looking for the first split that both
    /// runs the right way and has something on the far side, then comes back
    /// down the sibling hugging the boundary it just crossed. That last part
    /// is what makes stepping right out of a tall pane land on the neighbour
    /// beside it rather than in some pane three splits away.
    func pane(from id: UUID, moving direction: PaneDirection) -> UUID? {
        guard var route = route(to: id) else { return nil }
        while let step = route.popLast() {
            guard case .split(_, let horizontal, _, let first, let second) = step.split,
                  horizontal == direction.isHorizontal,
                  step.tookSecond != direction.towardsSecond
            else { continue }
            return (direction.towardsSecond ? second : first).edgePane(facing: direction)
        }
        return nil
    }

    /// Descending into a neighbour, the pane against the edge you came
    /// through. Across the other axis there is no nearer or further, so the
    /// leading child stands in — top for a stacked split, left for a
    /// side-by-side one.
    private func edgePane(facing direction: PaneDirection) -> UUID {
        switch self {
        case .pane(let pane):
            return pane.id
        case .split(_, let horizontal, _, let first, let second):
            guard horizontal == direction.isHorizontal else {
                return first.edgePane(facing: direction)
            }
            return (direction.towardsSecond ? first : second).edgePane(facing: direction)
        }
    }

    /// The splits between the root and `id`, each with the branch taken.
    private func route(to id: UUID) -> [(split: SplitNode, tookSecond: Bool)]? {
        switch self {
        case .pane(let pane):
            return pane.id == id ? [] : nil
        case .split(_, _, _, let first, let second):
            if let rest = first.route(to: id) { return [(self, false)] + rest }
            if let rest = second.route(to: id) { return [(self, true)] + rest }
            return nil
        }
    }

    /// Mutate one pane in place. Returns false when the pane isn't in this subtree.
    @discardableResult
    mutating func withPane(_ id: UUID, _ transform: (inout Pane) -> Void) -> Bool {
        switch self {
        case .pane(var pane):
            guard pane.id == id else { return false }
            transform(&pane)
            self = .pane(pane)
            return true
        case .split(let sid, let horizontal, let fraction, var first, var second):
            var done = first.withPane(id, transform)
            if !done { done = second.withPane(id, transform) }
            self = .split(id: sid, horizontal: horizontal, fraction: fraction,
                          first: first, second: second)
            return done
        }
    }

    /// Replace pane `id` with an even split of it and `new` (existing pane keeps the
    /// first/leading position).
    @discardableResult
    mutating func split(_ id: UUID, horizontal: Bool, adding new: Pane) -> Bool {
        switch self {
        case .pane(let pane):
            guard pane.id == id else { return false }
            self = .split(id: UUID(), horizontal: horizontal, fraction: 0.5,
                          first: .pane(pane), second: .pane(new))
            return true
        case .split(let sid, let h, let fraction, var first, var second):
            var done = first.split(id, horizontal: horizontal, adding: new)
            if !done { done = second.split(id, horizontal: horizontal, adding: new) }
            self = .split(id: sid, horizontal: h, fraction: fraction,
                          first: first, second: second)
            return done
        }
    }

    /// Remove pane `id`, collapsing its parent split into the sibling. Removing the
    /// root pane is refused here — callers enforce the ≥1-pane invariant.
    @discardableResult
    mutating func removePane(_ id: UUID) -> Bool {
        switch self {
        case .pane:
            return false
        case .split(let sid, let horizontal, let fraction, var first, var second):
            if case .pane(let pane) = first, pane.id == id { self = second; return true }
            if case .pane(let pane) = second, pane.id == id { self = first; return true }
            var done = first.removePane(id)
            if !done { done = second.removePane(id) }
            self = .split(id: sid, horizontal: horizontal, fraction: fraction,
                          first: first, second: second)
            return done
        }
    }

    /// Set the divider position of split `id`.
    @discardableResult
    mutating func setFraction(_ id: UUID, to fraction: Double) -> Bool {
        switch self {
        case .pane:
            return false
        case .split(let sid, let horizontal, let old, var first, var second):
            if sid == id {
                self = .split(id: sid, horizontal: horizontal, fraction: fraction,
                              first: first, second: second)
                return true
            }
            var done = first.setFraction(id, to: fraction)
            if !done { done = second.setFraction(id, to: fraction) }
            self = .split(id: sid, horizontal: horizontal, fraction: old,
                          first: first, second: second)
            return done
        }
    }

    mutating func forEachPane(_ transform: (inout Pane) -> Void) {
        switch self {
        case .pane(var pane):
            transform(&pane)
            self = .pane(pane)
        case .split(let sid, let horizontal, let fraction, var first, var second):
            first.forEachPane(transform)
            second.forEachPane(transform)
            self = .split(id: sid, horizontal: horizontal, fraction: fraction,
                          first: first, second: second)
        }
    }
}

/// Host-owned navigation state: tabs, each holding a split tree of panes with one
/// active. Purely a host UI concern — plugins only ever call `HostContext.open(_:)`,
/// which drives the active pane of the active tab. `focusedNode` on the context is
/// kept in sync with that pane's current node.
@MainActor
@Observable
final class NavigationModel {
    struct Tab: Identifiable {
        let id = UUID()
        var root: SplitNode
        var activePaneID: UUID
        /// A pinned tab keeps its document; an unpinned one is a *preview* and
        /// gets reused by the next thing you open. Editing pins it, which is
        /// what stops a glance at one file from throwing away the file you're
        /// working in. At most one preview tab exists at a time.
        var isPinned: Bool

        init(with nodeID: NodeID? = nil, pinned: Bool = false) {
            let pane = Pane(with: nodeID)
            self.root = .pane(pane)
            self.activePaneID = pane.id
            self.isPinned = pinned
        }

        /// Falls back to the first pane if the active id ever dangles.
        var activePane: Pane? { root.pane(activePaneID) ?? root.panes.first }
        var current: NodeID? { activePane?.current }
    }

    private(set) var tabs: [Tab] = [Tab()]
    private(set) var activeIndex = 0

    var activeTab: Tab { tabs[activeIndex] }
    var activePane: Pane? { activeTab.activePane }
    var current: NodeID? { activePane?.current }
    var canGoBack: Bool { activePane?.canGoBack ?? false }
    var canGoForward: Bool { activePane?.canGoForward ?? false }
    var canClosePane: Bool { activeTab.root.panes.count > 1 }

    // MARK: Navigation (active pane)

    func navigate(to id: NodeID) { withActivePane { $0.navigate(to: id) } }
    func back() { withActivePane { $0.back() } }
    func forward() { withActivePane { $0.forward() } }

    private func withActivePane(_ transform: (inout Pane) -> Void) {
        guard let paneID = activePane?.id else { return }
        tabs[activeIndex].root.withPane(paneID, transform)
    }

    // MARK: Panes

    /// Put a node in a neighbouring pane, and leave the keyboard where it is.
    ///
    /// The call a plugin needs to show two views of one thing side by side —
    /// a typst document's source and its pages — without knowing anything
    /// about splits. Reuse before creation: a pane already showing it is the
    /// answer, then any neighbour, and only then a new split. Sequencing
    /// "split" and "open" as two actions could not do that, and split again
    /// every time the key was pressed.
    ///
    /// Focus deliberately stays put: you asked to *see* the other thing, not
    /// to go to it, and typing should carry on where it was.
    @discardableResult
    func openBeside(_ id: NodeID) -> UUID? {
        guard let source = activePane else { return nil }
        let panes = tabs[activeIndex].root.panes
        if let showing = panes.first(where: { $0.id != source.id && $0.current == id }) {
            return showing.id
        }
        if let neighbour = tabs[activeIndex].root.pane(from: source.id, moving: .right)
            ?? panes.first(where: { $0.id != source.id })?.id {
            tabs[activeIndex].root.withPane(neighbour) { $0.navigate(to: id) }
            return neighbour
        }
        splitActivePane(horizontal: true)
        guard let created = activePane?.id, created != source.id else { return nil }
        tabs[activeIndex].root.withPane(created) { $0.navigate(to: id) }
        tabs[activeIndex].activePaneID = source.id
        return created
    }

    /// Split the active pane; the new pane starts on the same node (fresh history)
    /// and becomes active.
    func splitActivePane(horizontal: Bool) {
        guard let source = activePane else { return }
        let newPane = Pane(with: source.current)
        if tabs[activeIndex].root.split(source.id, horizontal: horizontal, adding: newPane) {
            tabs[activeIndex].activePaneID = newPane.id
        }
    }

    /// Close the active pane and activate the first remaining. Refused for the last
    /// pane — closing the whole surface is what Close Tab is for.
    func closeActivePane() {
        guard canClosePane, let paneID = activePane?.id else { return }
        if tabs[activeIndex].root.removePane(paneID) {
            tabs[activeIndex].activePaneID = tabs[activeIndex].root.panes[0].id
        }
    }

    func activatePane(_ id: UUID) {
        guard tabs[activeIndex].root.pane(id) != nil else { return }
        tabs[activeIndex].activePaneID = id
    }

    /// Step to the neighbouring surface. Returns the pane now active, or nil
    /// when there is nothing that way — which is the caller's cue to leave the
    /// canvas entirely and hand the keyboard to the sidebar.
    @discardableResult
    func movePane(_ direction: PaneDirection) -> UUID? {
        guard let from = activePane?.id,
              let target = activeTab.root.pane(from: from, moving: direction)
        else { return nil }
        tabs[activeIndex].activePaneID = target
        return target
    }

    /// The panes in layout order, for stepping through them regardless of
    /// arrangement — `C-w w`, when you don't want to think about geometry.
    func cyclePane(by offset: Int) {
        let panes = activeTab.root.panes
        guard panes.count > 1, let from = activePane?.id,
              let index = panes.firstIndex(where: { $0.id == from }) else { return }
        let next = (index + offset).wrapped(around: panes.count)
        tabs[activeIndex].activePaneID = panes[next].id
    }

    /// Move a divider. Clamped so neither side can be dragged away entirely.
    func setSplitFraction(_ id: UUID, to fraction: Double) {
        tabs[activeIndex].root.setFraction(id, to: min(max(fraction, 0.1), 0.9))
    }

    // MARK: Tabs

    /// Explicitly asking for a new tab means you intend to keep it.
    func newTab(with id: NodeID?) {
        tabs.append(Tab(with: id, pinned: true))
        activeIndex = tabs.count - 1
    }

    /// Open the way clicking a file in an explorer does: go to the document if
    /// it's already open, otherwise reuse the preview tab when the active one
    /// still is one, and failing that start a new preview beside it rather
    /// than displacing work.
    func openInPreview(_ id: NodeID) {
        if focusTab(showing: id) { return }
        if tabs[activeIndex].isPinned {
            tabs.append(Tab(with: id))
            activeIndex = tabs.count - 1
        } else {
            navigate(to: id)
        }
    }

    /// Switch to a tab already showing `id`, and to the pane showing it — a
    /// document open in the other half of a split is still open as far as the
    /// reader is concerned, and duplicating it into a third view is not what
    /// clicking it asks for.
    ///
    /// The active tab is checked first, so clicking the document you are
    /// already in never moves you somewhere else that happens to show it too.
    private func focusTab(showing id: NodeID) -> Bool {
        let searchOrder = [activeIndex] + tabs.indices.filter { $0 != activeIndex }
        for index in searchOrder {
            guard let pane = tabs[index].root.panes.first(where: { $0.current == id })
            else { continue }
            activeIndex = index
            tabs[index].activePaneID = pane.id
            return true
        }
        return false
    }

    /// Pin every tab currently showing `id`, so the next thing opened can't
    /// take its place. Editing a document asks for this; so does anything
    /// else that is work rather than a glance — a terminal, from the moment
    /// it opens.
    func pinTabs(showing id: NodeID) {
        for index in tabs.indices where tabs[index].current == id {
            tabs[index].isPinned = true
        }
    }

    func closeTab(_ tabID: Tab.ID) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs.remove(at: i)
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
        else if activeIndex > i { activeIndex -= 1 }
    }

    func selectTab(_ i: Int) { if tabs.indices.contains(i) { activeIndex = i } }

    // MARK: Graph changes

    /// A node was renamed: rewrite it in every pane of every tab.
    func remap(from old: NodeID, to new: NodeID) {
        for i in tabs.indices {
            tabs[i].root.forEachPane { $0.remap(from: old, to: new) }
        }
    }

    /// A node was deleted: drop it from every pane of every tab.
    func remove(_ id: NodeID) {
        for i in tabs.indices {
            tabs[i].root.forEachPane { $0.remove(id) }
        }
    }

    /// Back to the launch state: one tab, one empty pane. Used when the workspace
    /// switches — history references nodes from the previous workspace's context.
    func reset() {
        tabs = [Tab()]
        activeIndex = 0
    }

    // MARK: Session snapshots

    /// The whole surface — tabs, their splits, each pane's history, and which
    /// is active. Switching workspaces swaps one of these for another, so a
    /// workspace you come back to is where you left it.
    struct Snapshot {
        var tabs: [Tab]
        var activeIndex: Int
    }

    func snapshot() -> Snapshot { Snapshot(tabs: tabs, activeIndex: activeIndex) }

    func restore(_ snapshot: Snapshot) {
        guard !snapshot.tabs.isEmpty else { reset(); return }
        tabs = snapshot.tabs
        activeIndex = min(max(snapshot.activeIndex, 0), tabs.count - 1)
    }
}
