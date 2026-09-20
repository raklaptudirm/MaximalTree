import AppKit
import SwiftUI
@_spi(Host) import MaximalTreeKit

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
    /// The keys the surface holding the keyboard claims.
    ///
    /// A canvas's keys come from the contribution that actually drew it, so
    /// the canvas on screen and the keys that work cannot disagree.
    func surfaceKeymap() -> Keymap {
        let surface = keyboardSurface()
        return surfaceKeymap(for: surface, showing: paneNode(of: surface))
    }

    /// Which surface has the keyboard, asked with the registry swept first.
    ///
    /// Every reading of it goes through here. `Surfaces` records where each
    /// surface was and cannot know when one stops existing, so the panes this
    /// window no longer lays out are cleared before the question is put — a
    /// dead pane's rectangle would otherwise answer it.
    func keyboardSurface() -> SurfaceID {
        Surfaces.prunePanes(keeping: Set(navigation.activeTab.root.panes.map(\.id)),
                            in: NSApp.keyWindow)
        return Surfaces.focused()
    }

    /// Remembered between keystrokes, because building it is not free.
    ///
    /// Resolving a canvas runs every registered matcher — twelve closures, and
    /// three of them test a file extension rather than a type — and then a
    /// trie is built from the winner's bindings, an allocation per chord. That
    /// happened on every key press. It only ever depends on two things: which
    /// surface has the keyboard, and which node its pane is showing, so those
    /// are the key and everything else is a hit.
    ///
    /// A node keeps its identity for as long as it is the same node — a rename
    /// makes a new one — so a file that becomes a `.typ` and changes which
    /// canvas draws it also changes this key, and the map is rebuilt.
    ///
    /// Split from the caller so a test can vary the surface and the node,
    /// which is otherwise impossible without a key window.
    func surfaceKeymap(for surface: SurfaceID, showing node: NodeID?) -> Keymap {
        if let cached = cachedSurfaceKeys, cached.surface == surface, cached.node == node {
            return cached.map
        }
        // Never mutated after building. `Keymap` is a struct around a class
        // trie, so a copy shares the nodes — binding into a copy of this would
        // reach back into the cache.
        // "No keys" and "cannot say yet" are different answers, and only one
        // of them is worth remembering. A canvas resolves through the node's
        // record, which arrives a moment after the canvas does — and caching
        // the gap meant every key that canvas declares stayed unbound for as
        // long as the pane showed that document, falling through to the view
        // and being typed as a character.
        guard let claimed = claimedKeys(surface: surface, showing: node) else {
            return Keymap()
        }
        var map = Keymap()
        for key in claimed {
            map.bind(key.sequence, to: key.action)
        }
        bumpSurfaceKeymapBuilds()
        cachedSurfaceKeys = (surface: surface, node: node, map: map)
        return map
    }

    /// The node the focused pane is showing, if a pane is focused at all.
    private func focusedPaneNode() -> NodeID? { paneNode(of: keyboardSurface()) }

    /// The same, for a surface already in hand — so the two halves of one
    /// answer cannot come from two different readings of where focus is.
    private func paneNode(of surface: SurfaceID) -> NodeID? {
        guard case .pane(let id) = surface,
              let pane = navigation.activeTab.root.pane(id) else { return nil }
        // What it is *showing*, which a highlighted row can stand in front of.
        // The canvas resolves from this too, so the keys that work are the
        // ones belonging to what is drawn.
        return displayedNode(in: pane)
    }

    /// What a surface claims, or nil when that cannot be answered yet.
    ///
    /// The distinction matters to the caller: an answer is worth remembering
    /// and a shrug is not.
    private func claimedKeys(surface: SurfaceID, showing node: NodeID?) -> [SurfaceKey]? {
        switch surface {
        case .sidebar, .contents, .inspector:
            // Registry data, not the store's: what a surface claims is
            // declared at registration and does not depend on a graph being
            // up. Reading it through the store made this unanswerable before
            // the app had started, which is also every test.
            let wanted: SurfaceKeys.Surface = switch surface {
            case .sidebar: .sidebar
            case .contents: .contents
            default: .inspector
            }
            return pluginHost.registry.surfaceKeys
                .filter { $0.surface == wanted }.flatMap(\.keys)
        case .pane:
            // A canvas's keys ride on the contribution that drew it, and
            // resolving which one that is needs the store.
            // No store yet, or no record for the node yet: not an empty set of
            // keys, an unanswerable question.
            guard let store, let record = node.flatMap({ host.node($0) }) else { return nil }
            return store.canvas(for: record)?.keys ?? []
        }
    }

    /// Run an operation by id, from a key or from a plugin.
    ///
    /// Applicable ones only, so a key bound to something that doesn't apply
    /// here does nothing rather than something surprising — which is also how
    /// the explorer motions stay the sidebar's own.
    func runCommand(_ id: String, count: Int = 1) {
        let targets = keyTargets()
        if let action = action(id) {
            guard canRun(action, targets: targets) else { return }
            perform(action, targets: targets, count: count)
            return
        }
        // A command registered without presentation: nothing lists it, so
        // there is no predicate to ask — being invoked by id is the whole of
        // how it is reached.
        guard let command = store?.registry.command(id) else { return }
        invoke(command, in: ActionContext(host: host, targets: targets, count: count))
    }

    /// What a key press acts on.
    ///
    /// The surface holding the keyboard says what "this" means. A pane means
    /// the node it is showing; the sidebar and the inspector mean the
    /// selection, which is what they are about.
    ///
    /// Without this a key pressed in a terminal acted on whatever happened to
    /// be selected in the tree — a different node, or none — which is why a
    /// canvas could only ever have implemented its own keys.
    private func keyTargets() -> [NodeID]? {
        switch keyboardSurface() {
        case .pane: return focusedPaneNode().map { [$0] }
        // The highlighted row, not the library holding it. Otherwise every
        // action run from the column would act on the container — which for
        // "Move to Trash" is the difference between one file and all of them.
        case .contents: return contentsRow.map { [$0] }
        case .sidebar, .inspector: return nil
        }
    }

    /// The keys the sidebar claims.
    ///
    /// Named rather than inline so a test can ask what they are — which is
    /// also how a settings screen would, when there is one.
    static let sidebarKeys: [SurfaceKey] = [
        SurfaceKey("j", "explorer.down"),
        SurfaceKey("k", "explorer.up"),
        SurfaceKey("h", "explorer.collapse"),
        SurfaceKey("l", "explorer.expand"),
        SurfaceKey("RET", "explorer.open"),
        SurfaceKey("o", "explorer.open"),
        SurfaceKey("g g", "explorer.first"),
        SurfaceKey("G", "explorer.last"),
        SurfaceKey("}", "node.nextSibling"),
        SurfaceKey("{", "node.previousSibling"),
        SurfaceKey("g p", "node.parent"),
    ]

    /// The keys the inspector claims.
    ///
    /// Reading, not acting. Its sections are arbitrary plugin SwiftUI, so
    /// there is no selection to walk and nothing generic to activate — but a
    /// long inspector you could not reach the bottom of without the mouse was
    /// the last hole in getting around by keyboard alone.
    static let inspectorKeys: [SurfaceKey] = [
        SurfaceKey("j", "inspector.scrollDown"),
        SurfaceKey("k", "inspector.scrollUp"),
        SurfaceKey("d", "inspector.halfPageDown"),
        SurfaceKey("u", "inspector.halfPageUp"),
        SurfaceKey("g g", "inspector.top"),
        SurfaceKey("G", "inspector.bottom"),
    ]

    /// The keys the contents column claims.
    ///
    /// The sidebar's motions by the same letters, because it is the same
    /// gesture on a different shape — a list rather than a tree, so there is
    /// nothing to expand or collapse and `h`/`l` are not among them.
    static let contentsKeys: [SurfaceKey] = [
        SurfaceKey("j", "contents.down"),
        SurfaceKey("k", "contents.up"),
        SurfaceKey("RET", "contents.open"),
        SurfaceKey("o", "contents.open"),
        SurfaceKey("g g", "contents.first"),
        SurfaceKey("G", "contents.last"),
        SurfaceKey("/", "contents.filter"),
    ]

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
                 shortcut: KeyboardShortcut? = nil,
                 when predicate: ActionPredicate = .always,
                 enabled: (@MainActor (AppModel) -> Bool)? = nil,
                 surfaces: ActionSurfaces = [.palette],
                 scope: ActionScope = .workspace,
                 _ body: @escaping @MainActor (AppModel, ActionContext) -> Void) {
            // An operation that can't be done right now says so once, here.
            // The menu greys out, the finder leaves it out, and a key bound to
            // it does nothing — all from the same answer.
            var applies = predicate
            if let enabled {
                applies = .custom { [weak self] _ in
                    guard let self else { return false }
                    return enabled(self)
                }
            }
            registry.register(action: Action(
                id: id, title: title, systemImage: image, appliesTo: applies,
                shortcut: shortcut, scope: scope, surfaces: surfaces,
                handler: { [weak self] ctx in
                    guard let self else { return }
                    body(self, ctx)
                }))
        }

        // The sidebar's keys, declared the way any surface declares them.
        //
        // They were ordinary app bindings narrowed by a predicate that asked
        // which surface had the keyboard: ten actions each carrying a rule
        // about where they applied, because the sidebar had no way to claim a
        // key of its own. Now it claims them, and the actions say nothing
        // about surfaces at all.
        registry.register(surfaceKeys: SurfaceKeys(.sidebar, Self.sidebarKeys))
        registry.register(surfaceKeys: SurfaceKeys(.contents, Self.contentsKeys))
        registry.register(surfaceKeys: SurfaceKeys(.inspector, Self.inspectorKeys))

        registry.register(action: Action(
            id: "core.rename",
            title: "Rename…",
            systemImage: "pencil",
            appliesTo: .custom { ctx in
                guard ctx.targets.count == 1, let target = ctx.targets.first else { return false }
                let label = ctx.host.node(target)?.label ?? target.uri
                return ctx.canApply(.rename(target, to: label))
            },
            shortcut: KeyboardShortcut("r", modifiers: [.command, .shift]),
            handler: { ctx in
                guard let target = ctx.targets.first else { return }
                ctx.beginRename(target)
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

        // MARK: Reading the inspector
        act("inspector.scrollDown", "Scroll Inspector Down") { _, ctx in
            InspectorScroll.by(lines: CGFloat(ctx.count))
        }
        act("inspector.scrollUp", "Scroll Inspector Up") { _, ctx in
            InspectorScroll.by(lines: -CGFloat(ctx.count))
        }
        act("inspector.halfPageDown", "Inspector Half Page Down") { _, _ in
            InspectorScroll.byHalfPage(1)
        }
        act("inspector.halfPageUp", "Inspector Half Page Up") { _, _ in
            InspectorScroll.byHalfPage(-1)
        }
        act("inspector.top", "Top of Inspector") { _, _ in InspectorScroll.toTop() }
        act("inspector.bottom", "Bottom of Inspector") { _, _ in InspectorScroll.toBottom() }
        act("explorer.focus", "Focus Explorer") { model, _ in model.focus(.sidebar) }
        act("inspector.focus", "Focus Inspector") { model, _ in model.focus(.inspector) }
        act("contents.focus", "Focus Contents") { model, _ in model.focus(.contents) }

        // MARK: The contents column

        act("contents.down", "Next Item") { model, ctx in
            model.moveContentsRow(by: max(ctx.count, 1))
        }
        act("contents.up", "Previous Item") { model, ctx in
            model.moveContentsRow(by: -max(ctx.count, 1))
        }
        act("contents.first", "First Item") { model, _ in model.moveContentsRowToEdge(last: false) }
        act("contents.last", "Last Item") { model, _ in model.moveContentsRowToEdge(last: true) }
        act("contents.open", "Open Item") { model, _ in
            guard let row = model.contentsRow else { return }
            model.openContentsRow(row)
        }
        act("contents.filter", "Filter Contents", image: "line.3.horizontal.decrease") { model, _ in
            model.contents.filtering = true
        }

        // MARK: Putting things back

        // Only the sidebar's own arrangement — see `UndoHistory`. Greyed out
        // when there is nothing to put back, which is the honest answer and
        // also the only one available: an Undo that appears to work on a
        // deleted file and doesn't would be worse than no Undo at all.
        act("edit.undo", "Undo", image: "arrow.uturn.backward",
            shortcut: KeyboardShortcut("z", modifiers: .command),
            enabled: { $0.workspaceStore.canUndo },
            surfaces: [.palette, .menuBar]) { model, _ in
            model.undo()
        }
        act("edit.redo", "Redo", image: "arrow.uturn.forward",
            shortcut: KeyboardShortcut("z", modifiers: [.command, .shift]),
            enabled: { $0.workspaceStore.canRedo },
            surfaces: [.palette, .menuBar]) { model, _ in
            model.redo()
        }

        // MARK: The finder

        act("finder.all", "Find Anything…", image: "magnifyingglass",
            shortcut: KeyboardShortcut("p", modifiers: [.command, .shift])) { model, _ in
            model.finderVisible ? model.closeFinder() : model.openFinder()
        }
        act("finder.actions", "Run Action…",
            shortcut: KeyboardShortcut("p", modifiers: [.command, .option])) { model, _ in
            model.openFinder(scope: "actions")
        }
        // Everything that can be done to what you are pointing at, as a list
        // you can search — the context menu, reachable from the keyboard.
        act("finder.nodeActions", "Act on Selection…", image: "hand.tap",
            shortcut: KeyboardShortcut(".", modifiers: .command)) { model, _ in
            model.openFinder(scope: "node-actions")
        }
        act("finder.nodes", "Find in Sidebar…") { model, _ in model.openFinder(scope: "nodes") }
        act("finder.files", "Find File…",
            shortcut: KeyboardShortcut("o", modifiers: [.command, .shift])) { model, _ in
            model.openFinder(scope: "files")
        }
        act("finder.buffers", "Find Tab…") { model, _ in model.openFinder(scope: "buffers") }
        act("finder.workspaces", "Find Workspace…") { model, _ in
            model.openFinder(scope: "workspaces")
        }

        // MARK: Moving in the explorer

        act("explorer.down", "Move Down") { model, ctx in
            model.moveExplorerSelection(down: true, times: ctx.count)
        }
        act("explorer.up", "Move Up") { model, ctx in
            model.moveExplorerSelection(down: false, times: ctx.count)
        }
        act("explorer.expand", "Expand") { model, _ in
            model.expandSelectedNode(true)
        }
        act("explorer.collapse", "Collapse") { model, _ in
            model.expandSelectedNode(false)
        }
        act("explorer.open", "Open Selected") { model, _ in
            guard let node = model.host.selection.first ?? model.host.focusedNode else { return }
            model.store?.open(node)
            // Opening something is going to it. Staying put left the keyboard
            // in the sidebar while the thing you just opened sat there
            // waiting, which was only ever confusing.
            model.focusActiveSurface()
        }
        act("explorer.first", "Go to First") { model, _ in
            model.selectExplorerEdge(last: false)
        }
        act("explorer.last", "Go to Last") { model, _ in
            model.selectExplorerEdge(last: true)
        }
        act("node.nextSibling", "Next Sibling") { model, ctx in
            model.moveToSibling(down: true, times: ctx.count)
        }
        act("node.previousSibling", "Previous Sibling") { model, ctx in
            model.moveToSibling(down: false, times: ctx.count)
        }
        act("node.parent", "Go to Parent") { model, _ in
            model.selectParentOfSelection()
        }

        // MARK: History and tabs

        act("nav.back", "Back", image: "chevron.left",
            shortcut: KeyboardShortcut("[", modifiers: .command),
            enabled: { $0.navigation.canGoBack }) { model, ctx in
            for _ in 0..<ctx.count { model.goBack() }
        }
        act("nav.forward", "Forward", image: "chevron.right",
            shortcut: KeyboardShortcut("]", modifiers: .command),
            enabled: { $0.navigation.canGoForward }) { model, ctx in
            for _ in 0..<ctx.count { model.goForward() }
        }
        act("tab.next", "Next Tab") { model, ctx in model.cycleTab(by: ctx.count) }
        act("tab.previous", "Previous Tab") { model, ctx in model.cycleTab(by: -ctx.count) }
        act("tab.first", "First Tab") { model, _ in model.selectTab(0) }
        act("tab.last", "Last Tab") { model, _ in
            model.selectTab(max(model.navigation.tabs.count - 1, 0))
        }
        act("tab.new", "New Tab", image: "plus",
            shortcut: KeyboardShortcut("t", modifiers: .command)) { model, _ in
            model.newTab()
        }
        act("tab.close", "Close Tab", image: "xmark",
            shortcut: KeyboardShortcut("w", modifiers: .command),
            enabled: { $0.navigation.tabs.count > 1 }) { model, _ in
            model.closeActiveTab()
        }

        // MARK: Panes and surfaces

        act("pane.splitRight", "Split Right", image: "rectangle.split.2x1",
            shortcut: KeyboardShortcut("d", modifiers: .command)) { model, _ in
            model.splitPaneRight()
        }
        act("pane.splitDown", "Split Down", image: "rectangle.split.1x2",
            shortcut: KeyboardShortcut("d", modifiers: [.command, .shift])) { model, _ in
            model.splitPaneDown()
        }
        act("pane.close", "Close Pane", image: "xmark.rectangle",
            shortcut: KeyboardShortcut("w", modifiers: [.command, .control]),
            enabled: { $0.navigation.canClosePane }) { model, _ in
            model.closeActivePane()
        }

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
        act("workspace.create", "New Workspace…", image: "plus.square.on.square") { model, _ in
            model.showingCreateWorkspace = true
        }
        act("workspace.rename", "Rename Workspace…", image: "pencil") { model, _ in
            model.showingRenameWorkspace = true
        }
        act("workspace.delete", "Delete Workspace", image: "trash",
            enabled: { $0.workspaces.count > 1 }) { model, _ in
            model.deleteActiveWorkspace()
        }
        act("workspace.keep", "Keep This Workspace…", image: "tray.and.arrow.down",
            enabled: { $0.activeWorkspaceIsEphemeral }) { model, _ in
            model.keepActiveWorkspace()
        }
        act("collection.new", "New Collection", image: "rectangle.stack.badge.plus") { model, _ in
            model.newCollection()
        }
        act("collection.watchLater", "Add to Watch Later", image: "clock.badge.checkmark",
            when: .custom { !$0.targets.isEmpty }) { model, ctx in
            model.addToCollection(ctx.targets, named: AppModel.watchLaterName)
        }
        act("collection.delete", "Delete Collection", image: "trash",
            when: .custom { ctx in
                !ctx.targets.isEmpty
                    && ctx.targets.allSatisfy { $0.scheme == CollectionRef.scheme }
            }) { model, ctx in
            // Its members are not deleted: they go where the collection was.
            // Through the workspace store rather than the provider, so the row
            // is gone when you click rather than a moment after.
            model.deleteGroups(ctx.targets)
        }
        act("workspace.addFolder", "Mount Root…",
            image: "externaldrive.badge.plus") { model, _ in model.addFolder() }

        act("toggle.sidebar", "Toggle Sidebar",
            image: "sidebar.leading") { model, _ in model.sidebarVisible.toggle() }
        act("toggle.inspector", "Toggle Inspector",
            image: "sidebar.trailing") { model, _ in model.inspectorVisible.toggle() }
        act("toggle.contents", "Toggle Contents",
            image: "list.bullet") { model, _ in model.contents.isHidden.toggle() }
        act("toggle.zen", "Toggle Zen Mode", image: "arrow.up.left.and.arrow.down.right",
            shortcut: KeyboardShortcut("z", modifiers: [.command, .control])) { model, _ in
            model.toggleZenMode()
        }

        act("file.save", "Save", image: "square.and.arrow.down") { model, _ in
            // The editors own saving, and ⌘S is what they listen for.
            model.sendCommandKey("s")
        }
    }

    // MARK: Explorer motions

    /// The nodes the sidebar is showing, top to bottom — the order `j` and `k`
    /// move through. Recomputed rather than remembered: the tree changes under
    /// the reader as folders load, and a stale order moves the wrong way.
    func orderedExplorerNodes() -> [NodeID] {
        sidebarRows().compactMap(\.nodeID)
    }

    /// The sidebar's rows, top to bottom.
    ///
    /// The one place that flattens the tree. It was written out three times —
    /// here, in the sibling motions, and in the view that draws it — with the
    /// same six lines of graph plumbing each time, which is three chances for
    /// the keyboard's idea of the row order to drift from the drawn one. They
    /// have to agree: `j` moving to a row the sidebar isn't showing is not a
    /// small bug.
    func sidebarRows() -> [SidebarRow] {
        SidebarRows.flatten(
            placements: placements, root: sidebarRoot,
            expandedNodes: sidebar.expandedNodes,
            graph: SidebarGraph(
                children: { [host] in host.children(of: $0) },
                isExpandable: { [host] in host.isExpandable($0) },
                hasMore: { [host] in host.hasMoreChildren($0) }))
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

    /// What a row was reached through — a group's members have no listing to
    /// look themselves up in, so the row's own record is the one that knows.
    private func parentOfNode(_ node: NodeID) -> NodeID? {
        guard case .node(_, _, _, _, _, _, let parent)? = sidebarRows().first(where: { $0.nodeID == node })
        else { return nil }
        return parent
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
        let from = keyboardSurface()
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
    func focus(_ surface: SurfaceID) {
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
        let rows = sidebarRows()
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
