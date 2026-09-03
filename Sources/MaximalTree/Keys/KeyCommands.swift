import AppKit
import MaximalTreeKit

/// What the keys actually do.
///
/// Every binding names a command id, and ids come from two places: the host's
/// own vocabulary (`explorer.down`, `pane.splitRight`) and the action registry,
/// where every plugin command already has one. That second half is what makes
/// this cheap — binding a key to a plugin's command needs nothing from the
/// plugin, and a plugin that adds an action can be bound the day it ships.
extension AppModel {
    func runCommand(_ id: String, count: Int = 1) {
        switch id {
        case "mode.insert":
            // Typing has to land somewhere: if the keyboard is still with the
            // app, hand it to the canvas first.
            if KeyFocus.focusedEditor() == nil, NSApp.keyWindow?.firstResponder is NSWindow {
                focusCanvas()
            }
            keys.setMode(.insert)
        case "editor.focus":
            focusEditor()
        case "explorer.focus":
            focus(.sidebar)
        case "inspector.focus":
            focus(.inspector)
        case "finder.all":
            finderVisible ? closeFinder() : openFinder()
        case "finder.actions":
            openFinder(scope: "actions")
        case "finder.nodes":
            openFinder(scope: "nodes")
        case "finder.files":
            openFinder(scope: "files")
        case "finder.buffers":
            openFinder(scope: "buffers")
        case "finder.workspaces":
            openFinder(scope: "workspaces")

        // Motions belong to the surface holding the keyboard. In a canvas they
        // never arrive here at all — it was offered them first and took them —
        // so reaching this means the sidebar has the keyboard, or nothing does
        // and the sidebar stands in.
        case "explorer.down":
            inSidebar { moveExplorerSelection(down: true, times: count) }
        case "explorer.up":
            inSidebar { moveExplorerSelection(down: false, times: count) }
        case "explorer.expand":
            inSidebar { expandSelectedNode(true) }
        case "explorer.collapse":
            inSidebar { expandSelectedNode(false) }
        case "explorer.open":
            inSidebar {
                guard let node = host.selection.first ?? host.focusedNode else { return }
                store?.open(node)
                // Opening something is going to it. Staying put left the
                // keyboard in the sidebar while the thing you just opened sat
                // there waiting, which was only ever confusing.
                focusActiveSurface()
            }
        case "explorer.first":
            inSidebar { selectExplorerEdge(last: false) }
        case "explorer.last":
            inSidebar { selectExplorerEdge(last: true) }

        case "nav.back":
            for _ in 0..<count { goBack() }
        case "nav.forward":
            for _ in 0..<count { goForward() }

        case "tab.next":
            cycleTab(by: count)
        case "tab.previous":
            cycleTab(by: -count)
        case "tab.close":
            closeActiveTab()

        case "pane.splitRight":
            splitPaneRight()
        case "pane.splitDown":
            splitPaneDown()
        case "pane.close":
            closeActivePane()

        case "surface.left":
            moveSurface(.left)
        case "surface.right":
            moveSurface(.right)
        case "surface.up":
            moveSurface(.up)
        case "surface.down":
            moveSurface(.down)
        case "surface.next":
            cyclePane(by: count)
            focusActiveSurface()
        case "surface.previous":
            cyclePane(by: -count)
            focusActiveSurface()

        case "tab.first":
            selectTab(0)
        case "tab.last":
            selectTab(max(navigation.tabs.count - 1, 0))

        case "node.nextSibling":
            inSidebar { moveToSibling(down: true, times: count) }
        case "node.previousSibling":
            inSidebar { moveToSibling(down: false, times: count) }
        case "node.parent":
            inSidebar { selectParentOfSelection() }

        case "workspace.next":
            cycleWorkspace(by: count)
        case "workspace.previous":
            cycleWorkspace(by: -count)

        case "toggle.sidebar":
            sidebarVisible.toggle()
        case "toggle.inspector":
            inspectorVisible.toggle()
        case "toggle.zen":
            toggleZenMode()

        case "workspace.addFolder":
            addFolder()
        case "file.save":
            // The editors own saving, and ⌘S is what they listen for.
            sendCommandKey("s")

        default:
            // Anything else is an action id. Applicable ones only, so a key
            // bound to something that doesn't apply here does nothing rather
            // than something surprising.
            guard let action = applicableActions().first(where: { $0.id == id })
            else { return }
            run(action)
        }
    }

    // MARK: Explorer motions

    /// Run `body` only when the sidebar is the surface with the keyboard.
    ///
    /// These keys used to move the explorer from wherever you were, which read
    /// as the app having one list and every other surface being scenery. The
    /// sidebar is a surface like the rest, so its motions are its own — and a
    /// terminal that declines `j` now does nothing with it rather than
    /// scrolling a tree you aren't looking at.
    private func inSidebar(_ body: () -> Void) {
        guard Surfaces.focused() == .sidebar else { return }
        body()
    }

    /// The nodes the sidebar is showing, top to bottom — the order `j` and `k`
    /// move through. Recomputed rather than remembered: the tree changes under
    /// the reader as folders load, and a stale order moves the wrong way.
    func orderedExplorerNodes() -> [NodeID] {
        SidebarRows.flatten(
            entries: rootLayout.entries,
            expandedNodes: sidebar.expandedNodes,
            graph: SidebarGraph(
                children: { [host] in host.children(of: $0) },
                isExpandable: { [host] in host.node($0)?.hasChildren ?? false },
                hasMore: { [host] in host.hasMoreChildren($0) }))
            .compactMap(\.nodeID)
    }

    private func moveExplorerSelection(down: Bool, times: Int) {
        let ordered = orderedExplorerNodes()
        guard !ordered.isEmpty else { return }
        var selection = Set(host.selection)
        var target: NodeID?
        for _ in 0..<max(times, 1) {
            guard let next = SidebarSelection.afterArrow(down: down, ordered: ordered,
                                                         selection: selection)
            else { break }
            target = next
            selection = [next]
        }
        guard let target else { return }
        host.select([target])
        sidebar.anchor = target
    }

    private func selectExplorerEdge(last: Bool) {
        let ordered = orderedExplorerNodes()
        guard let target = last ? ordered.last : ordered.first else { return }
        host.select([target])
        sidebar.anchor = target
    }

    private func expandSelectedNode(_ expand: Bool) {
        guard let node = host.selection.first ?? host.focusedNode else { return }
        let isExpanded = sidebar.expandedNodes.contains(node)
        guard expand != isExpanded else {
            // `h` on a closed node steps out to its parent, the way a file
            // tree in Vim does.
            if !expand, let parent = parentOfNode(node) {
                host.select([parent])
                sidebar.anchor = parent
            }
            return
        }
        sidebar.toggle(node)
    }

    private func parentOfNode(_ node: NodeID) -> NodeID? {
        orderedExplorerNodes().first { host.cachedChildren(of: $0)?.contains(node) == true }
    }

    // MARK: Surfaces

    /// Step to the neighbouring surface, whatever kind it is.
    ///
    /// One rule over the sidebar, the canvases, and the inspector alike. It
    /// used to carry two special cases — the sidebar reached by a branch that
    /// fired when nothing had the keyboard, and the inspector not reachable at
    /// all — and both are gone: the sidebar is simply the surface left of the
    /// leftmost pane, and the inspector the one right of the rightmost.
    private func moveSurface(_ direction: PaneDirection) {
        let from = Surfaces.focused()
        guard let target = Surfaces.neighbour(of: from, moving: direction) else { return }
        // A pane is also the thing navigation acts on, so stepping into one
        // makes it active. The sidebar and inspector have no such state.
        if case .pane(let id) = target { activatePane(id) }
        focus(target)
    }

    /// Put the keyboard in a surface.
    ///
    /// After the update the move set going, not during it: activating a pane
    /// re-lays out the panes, and the editor defers its first scroll a turn
    /// for the same reason.
    ///
    /// Never clears the responder on failure. Doing that handed the keyboard
    /// to the window, which used to read as "you are in the sidebar" — so one
    /// surface with nothing focusable in it and every later step became a
    /// no-op until you clicked back in.
    private func focus(_ surface: SurfaceID) {
        guard let window = NSApp.keyWindow else { return }
        DispatchQueue.main.async { [self] in
            guard let target = Surfaces.focusTarget(of: surface, in: window) else { return }
            window.makeFirstResponder(target)
            refreshFocusedSurface()
        }
    }

    private func focusActiveSurface() {
        guard let pane = navigation.activePane?.id else { return }
        focus(.pane(pane))
    }

    // MARK: Nodes

    /// The next node at the same depth, stepping over an expanded subtree
    /// rather than down into it — how you get through a big folder.
    ///
    /// Stops at the end of the parent: a sibling is only a sibling while the
    /// rows stay at least as deep, and the first shallower row is the parent's
    /// next sibling, which belongs to a different list.
    private func moveToSibling(down: Bool, times: Int) {
        let rows = SidebarRows.flatten(
            entries: rootLayout.entries,
            expandedNodes: sidebar.expandedNodes,
            graph: SidebarGraph(
                children: { [host] in host.children(of: $0) },
                isExpandable: { [host] in host.node($0)?.hasChildren ?? false },
                hasMore: { [host] in host.hasMoreChildren($0) }))
        guard let current = host.selection.first ?? host.focusedNode,
              var index = rows.firstIndex(where: { $0.nodeID == current }) else { return }
        let depth = rows[index].depth
        var target: NodeID?

        for _ in 0..<max(times, 1) {
            var step = index
            while true {
                step += down ? 1 : -1
                guard rows.indices.contains(step), rows[step].depth >= depth else { break }
                if rows[step].depth == depth, let node = rows[step].nodeID {
                    target = node
                    index = step
                    break
                }
            }
        }
        guard let target else { return }
        host.select([target])
        sidebar.anchor = target
    }

    private func selectParentOfSelection() {
        guard let node = host.selection.first ?? host.focusedNode,
              let parent = parentOfNode(node) else { return }
        host.select([parent])
        sidebar.anchor = parent
    }

    // MARK: Tabs

    private func cycleTab(by offset: Int) {
        let tabs = navigation.tabs
        guard tabs.count > 1 else { return }
        let index = (navigation.activeIndex + offset) % tabs.count
        selectTab(index < 0 ? index + tabs.count : index)
    }

    // MARK: Focus

    /// Hand the keyboard to the editor, leaving it in whichever mode it was
    /// in — normal, like stepping into another window in Vim. `i` there then
    /// starts inserting.
    private func focusEditor() {
        guard let window = NSApp.keyWindow,
              let editor = KeyFocus.firstEditor(in: window.contentView) else { return }
        window.makeFirstResponder(editor)
    }

    /// Give the keyboard to whatever the canvas is showing — an editor, a
    /// terminal, a page — so that insert mode has something to type into.
    private func focusCanvas() {
        guard let window = NSApp.keyWindow, let content = window.contentView else { return }
        if let editor = KeyFocus.firstEditor(in: content) {
            window.makeFirstResponder(editor)
            return
        }
        if let responder = KeyFocus.firstKeyTaker(in: content) {
            window.makeFirstResponder(responder)
        }
    }

    private func sendCommandKey(_ key: String) {
        guard let window = NSApp.keyWindow,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: .command, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: key, charactersIgnoringModifiers: key,
                                           isARepeat: false, keyCode: 1)
        else { return }
        window.sendEvent(event)
    }
}

extension NSView {
    /// The first text view under this one, which is what "start typing" means.
    var firstTextResponder: NSView? {
        if let text = self as? NSTextView, text.isEditable { return text }
        for subview in subviews {
            if let found = subview.firstTextResponder { return found }
        }
        return nil
    }
}
