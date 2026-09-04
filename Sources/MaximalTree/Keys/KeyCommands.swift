import AppKit
import SwiftUI
import MaximalTreeKit

/// Everything the app can do.
///
/// One registry, one id space. The host's own operations — moving in the tree,
/// splitting a pane, switching workspace — are `Action`s exactly like a
/// plugin's, so all of it is listed in the finder, bindable to a key, and
/// callable by name from a plugin through `host.perform(_:)`. There is no
/// second vocabulary of things only the keyboard can reach.
///
/// It was two systems until recently: a switch of forty-odd command ids the
/// keys could run, and an action registry everything else used. The commands
/// were invisible to the finder and unreachable from a plugin, and the split
/// was invisible from outside — "why can I bind `git.open` but not
/// `pane.splitRight`" had no answer worth giving.
///
/// Most of these are offered in the palette only. They are real operations and
/// belong in a list you can search, but forty motions in the menu bar would
/// bury the handful of things that belong there.
extension AppModel {
    /// Run an operation by id, from a key or from a plugin.
    ///
    /// Applicable ones only, so a key bound to something that doesn't apply
    /// here does nothing rather than something surprising — which is also how
    /// the explorer motions stay the sidebar's own.
    func runCommand(_ id: String, count: Int = 1) {
        guard let action = applicableActions().first(where: { $0.id == id }) else { return }
        perform(action, count: count)
    }

    /// Actions the host contributes itself.
    ///
    /// Node manipulation that belongs to no plugin because it rides the generic
    /// mutation vocabulary — rename is the model case: any provider supporting
    /// `.rename` gets the inline-rename UI, the menu item, the shortcut and the
    /// palette entry without writing any UI — and the app's own operations,
    /// which belong to no plugin because they are the app.
    func registerCoreActions(with registry: Registry) {
        /// Registers one, weakly: the registry outlives no model, but nothing
        /// here should be what keeps the model alive either.
        func act(_ id: String, _ title: String, image: String? = nil,
                 when predicate: ActionPredicate = .always,
                 surfaces: ActionSurfaces = [.palette],
                 scope: ActionScope = .workspace,
                 _ body: @escaping @MainActor (AppModel, ActionContext) -> Void) {
            registry.register(action: Action(
                id: id, title: title, systemImage: image, appliesTo: predicate,
                scope: scope, surfaces: surfaces,
                handler: { [weak self] ctx in
                    guard let self else { return }
                    body(self, ctx)
                }))
        }

        // The explorer's motions are the explorer's own. As a predicate rather
        // than a guard inside each handler, so the finder stops offering them
        // when the sidebar hasn't got the keyboard — an action that would do
        // nothing shouldn't be in the list you are reading.
        let inSidebar = ActionPredicate.custom { _ in Surfaces.focused() == .sidebar }

        registry.register(action: Action(
            id: "core.rename",
            title: "Rename…",
            systemImage: "pencil",
            appliesTo: .custom { ctx in
                guard ctx.targets.count == 1, let target = ctx.targets.first else { return false }
                let label = ctx.host.node(target)?.label ?? target.uri
                return ctx.host.canApply(.rename(target, to: label))
            },
            shortcut: KeyboardShortcut("r", modifiers: [.command, .shift]),
            handler: { ctx in
                guard let target = ctx.targets.first else { return }
                ctx.host.beginRename(target)
            }
        ))

        // MARK: Mode and focus

        act("mode.insert", "Insert Mode", image: "cursorarrow") { model, _ in
            // Typing has to land somewhere: if the keyboard is still with the
            // app, hand it to the canvas first.
            if KeyFocus.focusedEditor() == nil, NSApp.keyWindow?.firstResponder is NSWindow {
                model.focusCanvas()
            }
            model.keys.setMode(.insert)
        }
        act("editor.focus", "Focus Editor") { model, _ in model.focusEditor() }
        act("explorer.focus", "Focus Explorer") { model, _ in model.focus(.sidebar) }
        act("inspector.focus", "Focus Inspector") { model, _ in model.focus(.inspector) }

        // MARK: The finder

        act("finder.all", "Find Anything…", image: "magnifyingglass") { model, _ in
            model.finderVisible ? model.closeFinder() : model.openFinder()
        }
        act("finder.actions", "Run Action…") { model, _ in model.openFinder(scope: "actions") }
        act("finder.nodes", "Find in Sidebar…") { model, _ in model.openFinder(scope: "nodes") }
        act("finder.files", "Find File…") { model, _ in model.openFinder(scope: "files") }
        act("finder.buffers", "Find Tab…") { model, _ in model.openFinder(scope: "buffers") }
        act("finder.workspaces", "Find Workspace…") { model, _ in
            model.openFinder(scope: "workspaces")
        }

        // MARK: Moving in the explorer

        act("explorer.down", "Move Down", when: inSidebar) { model, ctx in
            model.moveExplorerSelection(down: true, times: ctx.count)
        }
        act("explorer.up", "Move Up", when: inSidebar) { model, ctx in
            model.moveExplorerSelection(down: false, times: ctx.count)
        }
        act("explorer.expand", "Expand", when: inSidebar) { model, _ in
            model.expandSelectedNode(true)
        }
        act("explorer.collapse", "Collapse", when: inSidebar) { model, _ in
            model.expandSelectedNode(false)
        }
        act("explorer.open", "Open Selected", when: inSidebar) { model, _ in
            guard let node = model.host.selection.first ?? model.host.focusedNode else { return }
            model.store?.open(node)
            // Opening something is going to it. Staying put left the keyboard
            // in the sidebar while the thing you just opened sat there
            // waiting, which was only ever confusing.
            model.focusActiveSurface()
        }
        act("explorer.first", "Go to First", when: inSidebar) { model, _ in
            model.selectExplorerEdge(last: false)
        }
        act("explorer.last", "Go to Last", when: inSidebar) { model, _ in
            model.selectExplorerEdge(last: true)
        }
        act("node.nextSibling", "Next Sibling", when: inSidebar) { model, ctx in
            model.moveToSibling(down: true, times: ctx.count)
        }
        act("node.previousSibling", "Previous Sibling", when: inSidebar) { model, ctx in
            model.moveToSibling(down: false, times: ctx.count)
        }
        act("node.parent", "Go to Parent", when: inSidebar) { model, _ in
            model.selectParentOfSelection()
        }

        // MARK: History and tabs

        act("nav.back", "Back", image: "chevron.left") { model, ctx in
            for _ in 0..<ctx.count { model.goBack() }
        }
        act("nav.forward", "Forward", image: "chevron.right") { model, ctx in
            for _ in 0..<ctx.count { model.goForward() }
        }
        act("tab.next", "Next Tab") { model, ctx in model.cycleTab(by: ctx.count) }
        act("tab.previous", "Previous Tab") { model, ctx in model.cycleTab(by: -ctx.count) }
        act("tab.first", "First Tab") { model, _ in model.selectTab(0) }
        act("tab.last", "Last Tab") { model, _ in
            model.selectTab(max(model.navigation.tabs.count - 1, 0))
        }
        act("tab.close", "Close Tab", image: "xmark") { model, _ in model.closeActiveTab() }

        // MARK: Panes and surfaces

        act("pane.splitRight", "Split Right",
            image: "rectangle.split.2x1") { model, _ in model.splitPaneRight() }
        act("pane.splitDown", "Split Down",
            image: "rectangle.split.1x2") { model, _ in model.splitPaneDown() }
        act("pane.close", "Close Pane",
            image: "xmark.rectangle") { model, _ in model.closeActivePane() }

        act("surface.left", "Focus Surface Left") { model, _ in model.moveSurface(.left) }
        act("surface.right", "Focus Surface Right") { model, _ in model.moveSurface(.right) }
        act("surface.up", "Focus Surface Above") { model, _ in model.moveSurface(.up) }
        act("surface.down", "Focus Surface Below") { model, _ in model.moveSurface(.down) }
        act("surface.next", "Next Surface") { model, ctx in
            model.cyclePane(by: ctx.count)
            model.focusActiveSurface()
        }
        act("surface.previous", "Previous Surface") { model, ctx in
            model.cyclePane(by: -ctx.count)
            model.focusActiveSurface()
        }

        // MARK: Workspaces and chrome

        act("workspace.next", "Next Workspace") { model, ctx in
            model.cycleWorkspace(by: ctx.count)
        }
        act("workspace.previous", "Previous Workspace") { model, ctx in
            model.cycleWorkspace(by: -ctx.count)
        }
        act("workspace.addFolder", "Mount Root…",
            image: "externaldrive.badge.plus") { model, _ in model.addFolder() }

        act("toggle.sidebar", "Toggle Sidebar",
            image: "sidebar.leading") { model, _ in model.sidebarVisible.toggle() }
        act("toggle.inspector", "Toggle Inspector",
            image: "sidebar.trailing") { model, _ in model.inspectorVisible.toggle() }
        act("toggle.zen", "Toggle Zen Mode",
            image: "arrow.up.left.and.arrow.down.right") { model, _ in model.toggleZenMode() }

        act("file.save", "Save", image: "square.and.arrow.down") { model, _ in
            // The editors own saving, and ⌘S is what they listen for.
            model.sendCommandKey("s")
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
