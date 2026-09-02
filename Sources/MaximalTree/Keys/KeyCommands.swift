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
            // Letting the editor go is enough: with no text taking the
            // keyboard, the modal layer has it again.
            NSApp.keyWindow?.makeFirstResponder(nil)
        case "palette.toggle":
            paletteVisible.toggle()

        case "explorer.down":
            moveExplorerSelection(down: true, times: count)
        case "explorer.up":
            moveExplorerSelection(down: false, times: count)
        case "explorer.expand":
            expandSelectedNode(true)
        case "explorer.collapse":
            expandSelectedNode(false)
        case "explorer.open":
            if let node = host.selection.first ?? host.focusedNode { store?.open(node) }
        case "explorer.first":
            selectExplorerEdge(last: false)
        case "explorer.last":
            selectExplorerEdge(last: true)

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
            moveToSibling(down: true, times: count)
        case "node.previousSibling":
            moveToSibling(down: false, times: count)
        case "node.parent":
            selectParentOfSelection()

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

    /// Step between surfaces, with the sidebar standing in as the one off the
    /// left edge.
    ///
    /// That is what makes `C-w h` mean one thing rather than two: from any
    /// canvas it walks left through the splits, and from the leftmost one it
    /// keeps going and lands in the explorer — which is where "further left"
    /// visibly is. `C-w l` comes back the same way.
    private func moveSurface(_ direction: PaneDirection) {
        // "With the app rather than a canvas" is the window holding the
        // keyboard itself, which is what `explorer.focus` leaves behind and
        // what `mode.insert` already tests for. Asking instead whether an
        // *editor* had focus — as this did — made the whole feature dead
        // over a terminal, a web page, or anything else that isn't one.
        if NSApp.keyWindow?.firstResponder is NSWindow {
            // Only rightward means anything from here: back into the canvas.
            if direction == .right { focusActiveSurface() }
            return
        }
        if movePane(direction) != nil {
            focusActiveSurface()
        } else if direction == .left {
            // Out of the panes entirely.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    /// Put the keyboard in whatever the active surface is showing, so that
    /// having moved there is the same thing as being there.
    /// Put the keyboard in whatever the active surface is showing.
    ///
    /// After the update the move itself set going, not during it: activating a
    /// pane re-lays out both panes, and a responder installed first was being
    /// undone by that pass — the border moved and the keyboard didn't. The
    /// editor defers its first scroll a turn for the same reason.
    ///
    /// Never clears the responder on failure. Doing that used to hand the
    /// keyboard to the window, which `moveSurface` reads as "you are in the
    /// sidebar" — so one surface with nothing focusable in it, or one focus
    /// that didn't take, and every later step became a no-op until you
    /// clicked back in. Leaving the keyboard where it was keeps moving
    /// working regardless.
    private func focusActiveSurface() {
        guard let window = NSApp.keyWindow, let pane = navigation.activePane?.id else { return }
        DispatchQueue.main.async {
            guard let target = PaneSurfaces.focusTarget(of: pane, in: window) else { return }
            window.makeFirstResponder(target)
        }
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
