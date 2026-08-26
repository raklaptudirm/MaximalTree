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
            KeyFocus.focusedEditor()?.vim.setMode(.insert)
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
