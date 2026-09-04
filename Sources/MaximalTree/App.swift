import SwiftUI
import AppKit
import MaximalTreeKit

/// Takes files the system hands the app — a double-click in the Finder, a drop
/// on the icon, `open -a`.
///
/// A delegate rather than `onOpenURL`, which is for url *schemes*: a file open
/// arrives as `application(_:open:)` and never reaches a scene's handler.
final class OpenFilesDelegate: NSObject, NSApplicationDelegate {
    /// Before any window is on screen, because the first one can already be
    /// too small — SwiftUI orders a remembered frame front when a file
    /// arrives, and a shell that can't fit in it aborts the process.
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { WindowFloor.watch() }
        claimOpenDocuments()
    }

    /// Set once the model exists. Static because AppKit builds the delegate
    /// itself and hands it no context.
    @MainActor static var handler: (([URL]) -> Void)?
    /// Anything that arrived before the app had finished starting.
    @MainActor static var pending: [URL] = []

    /// Claimed a second time, in case AppKit's own install landed in between.
    func applicationDidFinishLaunching(_ notification: Notification) {
        claimOpenDocuments()
    }

    /// Take the open-documents event ourselves.
    ///
    /// The handler AppKit installs for this is SwiftUI's, and it answers a
    /// file from the Finder by making *another* window of the main scene —
    /// one per file, and they never go away. `handlesExternalEvents` does not
    /// dissuade it, and closing the window afterwards does not work either:
    /// SwiftUI keeps it open through every `close()`.
    ///
    /// So the event is claimed before it can reach SwiftUI. Where a file goes
    /// is this app's decision anyway; making a window was never part of it.
    ///
    /// Claimed in *both* launch phases on purpose. A file double-clicked while
    /// the app is closed arrives during launch, before `didFinishLaunching` —
    /// claiming it only there was one launch too late, and a cold start from
    /// the Finder still opened the shell twice.
    private func claimOpenDocuments() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleOpenDocuments(_:withReply:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments))
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor,
                                           withReply reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        var urls: [URL] = []
        for index in 1...max(list.numberOfItems, 1) {
            guard let item = list.atIndex(index),
                  let data = item.coerce(toDescriptorType: typeFileURL)?.data,
                  let text = String(data: data, encoding: .utf8),
                  let url = URL(string: text.trimmingCharacters(in: .controlCharacters))
            else { continue }
            urls.append(url)
        }
        guard !urls.isEmpty else { return }
        MainActor.assumeIsolated { OpenFilesDelegate.deliver(urls) }
    }

    /// Also the delegate's own way in, for whatever reaches it that way.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { OpenFilesDelegate.deliver(urls) }
    }

    @MainActor
    private static func deliver(_ urls: [URL]) {
        guard let handler = Self.handler else {
            Self.pending += urls
            return
        }
        // Off this turn: this arrives from inside AppKit's Apple event
        // dispatch, and switching workspace from there mutates the model
        // while the shell is mid-update.
        DispatchQueue.main.async { handler(urls) }
    }
}

@main
struct MaximalTreeApp: App {
    @State private var model = AppModel(host: HostContext())
    @NSApplicationDelegateAdaptor(OpenFilesDelegate.self) private var openFiles

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model.host)
                .environment(model)
                // The view half of the same statement: this is what SwiftUI
                // matches an *existing* window against when an external event
                // arrives. Without it the scene declares it can handle them
                // and SwiftUI still makes a new window every time.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .task {
                    model.start()
                    // Now that there is somewhere to put them.
                    OpenFilesDelegate.handler = { [model] in model.open(files: $0) }
                    if !OpenFilesDelegate.pending.isEmpty {
                        model.open(files: OpenFilesDelegate.pending)
                        OpenFilesDelegate.pending = []
                    }
                    // Debug hook: MAXIMALTREE_ZEN=1 boots straight into zen so
                    // window-chrome issues can be inspected from the CLI.
                    if ProcessInfo.processInfo.environment["MAXIMALTREE_ZEN"] == "1" {
                        try? await Task.sleep(for: .seconds(1))
                        model.toggleZenMode()
                    }
                }
        }
        // Not decoration. The shell's three columns give the window a minimum
        // width of 975pt, and SwiftUI's default for a new window is 940 —
        // narrower than the layout it is about to be given. AppKit does not
        // clamp its way out of that: the split view re-reports its minimum on
        // every constraints pass, the window is marked as needing another, and
        // the feedback detector aborts the process ("more Update Constraints
        // in Window passes than there are views in the window"). That is what
        // killed the app on every File > New Window and every file opened from
        // the Finder. Opening wide enough to lay out is the whole fix.
        .defaultSize(width: 1200, height: 800)
        // Take external events in the window that is already open. Without
        // this SwiftUI answers every file opened from the Finder by making
        // *another* shell window: eight of them after a morning's work, and
        // since each one drains the loose-file list, eight windows for the one
        // stray file too.
        .handlesExternalEvents(matching: ["*"])
        .commands { AppCommands(model: model) }


    }
}

/// Wires the host together: loads plugins, builds the store, restores the workspace.
/// Owns the objects the shell reaches for; `host` is the observable one plugins see.
@MainActor
@Observable
final class AppModel {
    let host: HostContext
    let navigation = NavigationModel()
    /// Sidebar UI state (expansion, selection anchor) — session-scoped, owned
    /// here so the tree survives sidebar view recreation.
    let sidebar = SidebarState()
    // Not private: under XCTest the plugin bundles aren't dlopened (their
    // sources are compiled into the test target instead), so a test that wants
    // the real registry has to populate it itself.
    let pluginHost = PluginHost()
    /// Where the workspace library lives. Injectable so a test drives the
    /// real model without writing into the user's own workspaces.
    private let workspaceStore: WorkspaceStore
    private(set) var store: GraphStore?

    /// The finder: fuzzy search over everything the app knows about.
    var finderVisible = false
    let finder = FinderModel()
    /// Chrome visibility lives here rather than in the view, because the
    /// keyboard layer has to be able to toggle it (see KeyCommands).
    var sidebarVisible = true
    var inspectorVisible = true

    /// The surface holding the keyboard.
    ///
    /// Derived from the first responder, but kept here because the answer has
    /// to be *observed*: a surface showing whether it is focused — the
    /// sidebar's selection, the inspector's ring — has to redraw when focus
    /// moves, and asking AppKit at draw time never redraws anything.
    private(set) var focusedSurface: SurfaceID = .sidebar

    /// Open the finder over one list, or over everything when `scope` is nil.
    ///
    /// Insert mode, because the finder is a text field and in this app that is
    /// what a text field means: keys are text, not commands. Without it the
    /// keymap ate the query — `g`, `o`, `w`, `d` and the digits are all bound,
    /// so typing "git" fired the goto prefix and then insert mode instead of
    /// narrowing anything.
    func openFinder(scope: String? = nil) {
        finder.open(scope: scope, sources: store?.finders ?? [])
        finderVisible = true
        keys.setMode(.insert)
    }

    /// The picker's own keys.
    ///
    /// Handled here rather than in the view: the first responder while the
    /// finder is open is the text field's *field editor*, so a SwiftUI key
    /// handler on the field never runs — the arrows moved the insertion point
    /// and the selection sat on the first row, which meant the only result you
    /// could ever reach was whichever one happened to be top.
    ///
    /// The monitor sees every key before the field editor does, so this is the
    /// one place that reliably can.
    func handleFinderKey(_ chord: KeyChord) -> Bool {
        guard finderVisible else { return false }
        switch (chord.key, chord.control) {
        case ("ESC", _):
            closeFinder()
        case ("RET", _):
            acceptFinderSelection()
        case ("down", _), ("n", true), ("j", true):
            finder.move(1)
        case ("up", _), ("p", true), ("k", true):
            finder.move(-1)
        default:
            return false
        }
        return true
    }

    /// Open what is picked out, and put the finder away.
    func acceptFinderSelection() {
        guard let item = finder.selected else { return }
        closeFinder()
        perform(item)
    }

    func closeFinder() {
        guard finderVisible else { return }
        finderVisible = false
        finder.close()
        keys.setMode(.normal)
    }

    // MARK: Files opened from outside

    /// Open what the Finder (or `open`, or a drop on the icon) gave us.
    ///
    /// A file inside a mounted root belongs to that root's workspace and opens
    /// there, with the project around it — switching workspace first if it
    /// isn't the one in front of you.
    ///
    /// A file no workspace mounts gets a workspace of its own, made on the
    /// spot and holding just that file. It was a window of its own once, with
    /// no sidebar and nothing but the canvas, which meant rebuilding the shell
    /// badly: focus, the mode indicator, the finder and the which-key overlay
    /// all had to be taught about a second kind of window. A workspace is the
    /// app's own answer to "a set of things to work on", and one file is a
    /// perfectly good set — so the whole shell comes with it, and keeping the
    /// file is `keepActiveWorkspace` rather than a menu built for the purpose.
    func open(files urls: [URL]) {
        for url in urls {
            if let owner = FileOpening.owner(of: url, in: workspaces) {
                if owner.id != activeWorkspaceID { switchWorkspace(to: owner.id) }
            } else {
                openInNewWorkspace(url)
            }
            store?.openURI(url.absoluteString)
        }
    }

    /// A workspace made for one file, and not written down.
    ///
    /// Named after the file, because that is the whole of it. Reuses the one
    /// already made for this file if it is still around, so opening the same
    /// stray twice returns to it rather than stacking up namesakes.
    private func openInNewWorkspace(_ url: URL) {
        let uri = url.absoluteString
        if let existing = workspaces.first(where: { $0.isEphemeral && $0.rootURIs == [uri] }) {
            if existing.id != activeWorkspaceID { switchWorkspace(to: existing.id) }
            return
        }
        let workspace = workspaceStore.createEphemeral(named: url.lastPathComponent,
                                                       rootURIs: [uri])
        switchWorkspace(to: workspace.id)
    }

    /// Whether what you are looking at is a workspace that will not outlive
    /// the session — which is what offers you the chance to keep it.
    var activeWorkspaceIsEphemeral: Bool { workspaceStore.active.isEphemeral }

    /// Keep the workspace a stray file arrived in.
    ///
    /// The way out of being ephemeral: from here on it is written down like
    /// any other. Renaming it is the next thing most people want, since it is
    /// still named after a file, so that prompt follows.
    func keepActiveWorkspace() {
        guard let id = activeWorkspaceID else { return }
        workspaceStore.keep(id)
        showingRenameWorkspace = true
    }

    /// Recompute after anything that could have moved the keyboard: a key, a
    /// click, a focus this app asked for. Deferred a turn because AppKit sets
    /// the first responder while handling the event, after the monitor has
    /// already seen it.
    func refreshFocusedSurface() {
        DispatchQueue.main.async { [self] in
            let now = Surfaces.focused()
            if now != focusedSurface { focusedSurface = now }
        }
    }
    /// The modal keyboard layer. Built here so every surface shares one mode.
    @ObservationIgnored lazy var keys: KeyEngine = {
        let engine = KeyEngine(keymap: DefaultKeymap.make())
        engine.perform = { [weak self] id, count in
            self?.runCommand(id, count: count)
        }
        return engine
    }()
    /// Canvas-only view; see `HostContext.isZenMode` for the canvas contract.
    var isZenMode: Bool { host.isZenMode }
    /// Prompt state for the workspace name alerts, settable from any surface
    /// (toolbar menu, menu bar); ContentView presents the alerts.
    var showingCreateWorkspace = false
    var showingRenameWorkspace = false
    /// Folder-name prompt state. Creating: `pendingFolderRename == nil`.
    /// Renaming: it carries the folder being renamed.
    var showingFolderPrompt = false
    var pendingFolderRename: RootFolder?

    init(host: HostContext, workspaceFile: URL? = nil) {
        self.host = host
        self.workspaceStore = WorkspaceStore(fileURL: workspaceFile)
    }

    // MARK: Workspaces

    var workspaces: [Workspace] { workspaceStore.library.workspaces }
    var activeWorkspaceID: UUID? { workspaceStore.library.activeID }
    var activeWorkspaceName: String { workspaceStore.active.name }

    /// What each workspace looked like when you left it: its tabs (with their
    /// splits and history) and which nodes were revealed in the sidebar.
    /// In memory, so a switch restores exactly what you had. The revealed set
    /// is *also* written to the workspace file, so it survives a relaunch too;
    /// tabs still don't (they'd need their canvases serialized).
    private struct WorkspaceSession {
        var navigation: NavigationModel.Snapshot
        var sidebar: SidebarState.Snapshot
    }
    private var sessions: [UUID: WorkspaceSession] = [:]

    func switchWorkspace(to id: UUID) {
        guard id != activeWorkspaceID else { return }
        if let leaving = activeWorkspaceID {
            sessions[leaving] = WorkspaceSession(navigation: navigation.snapshot(),
                                                 sidebar: sidebar.snapshot())
        }
        workspaceStore.setActive(id)
        reloadActiveWorkspaceRoots()
    }

    func createWorkspace(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = workspaceStore.create(named: trimmed.isEmpty ? "Untitled" : trimmed)
        workspaceStore.setActive(workspace.id)
        store?.switchRoots([])              // a new workspace starts empty
    }

    func renameActiveWorkspace(to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = activeWorkspaceID else { return }
        workspaceStore.rename(id, to: trimmed)
    }

    func deleteActiveWorkspace() {
        guard let id = activeWorkspaceID, workspaces.count > 1 else { return }
        workspaceStore.delete(id)           // store activates the first remaining
        reloadActiveWorkspaceRoots()
    }

    private func reloadActiveWorkspaceRoots() {
        let roots = workspaceStore.restoreRoots(using: pluginHost.registry.providers)
        // switchRoots resets the surface; put this workspace's own back if we
        // have seen it before. Order matters: the roots have to exist before
        // the tabs pointing into them are focused.
        store?.switchRoots(roots)
        guard let id = activeWorkspaceID, let session = sessions[id] else {
            // First visit this run: fall back to what the workspace persisted.
            // Nothing is cached yet, so opening the tree fetches it fresh —
            // there is nothing here to bring up to date.
            restoreRevealedNodesFromDisk()
            return
        }
        sidebar.restore(session.sidebar)
        store?.restoreNavigation(session.navigation)
        // Switched back to a workspace this session has seen before, so its
        // children are cached from whenever you last looked. Long enough ago
        // to be wrong.
        refreshVisibleNodes()
    }

    /// Put the sidebar's disclosure back the way the active workspace last had
    /// it. Uris that no longer resolve are simply dropped — an expanded node
    /// that's gone has nothing to disclose.
    private func restoreRevealedNodesFromDisk() {
        let revealed = Set(workspaceStore.active.revealedNodes.compactMap(NodeID.init))
        sidebar.restore(SidebarState.Snapshot(expandedNodes: revealed, anchor: nil))
    }

    // MARK: Keeping the tree current

    /// How often the tree is brought up to date while you are using the app.
    ///
    /// Long enough that it costs nothing to have running, short enough that a
    /// directory changed by something else doesn't stay wrong for a session.
    private static let refreshInterval: TimeInterval = 60

    /// The nodes whose contents are actually on display: the roots, and
    /// whatever has been opened out beneath them.
    ///
    /// The expanded set can name nodes inside a collapsed parent, which are
    /// not strictly on screen — refreshing those is a listing nobody reads,
    /// but the set is small and bounded by what has been loaded at all, and
    /// working out true visibility means walking the tree the sidebar just
    /// walked. `refreshChildren` skips anything never loaded, so this can only
    /// ever re-ask questions the app has already asked once.
    private var visibleNodes: [NodeID] { host.roots + sidebar.expandedNodes }

    /// Ask again for what is on screen.
    ///
    /// Providers that stream their changes keep themselves current, and two of
    /// the six do; the rest answered once, when the node was first opened, and
    /// would go on showing that answer until something happened to invalidate
    /// it. Nothing did — so a directory changed by another program, a branch
    /// switched in a terminal, a note written by a script all stayed invisible
    /// until the node was collapsed and opened again.
    func refreshVisibleNodes() {
        store?.refreshChildren(of: visibleNodes)
    }

    /// Refresh on the occasions when what is on screen is most likely to be
    /// out of date: coming back to the app after being away in another one,
    /// and on a slow tick while it is in front of you.
    ///
    /// Only while the app is active. A refresh in the background is work
    /// nobody is waiting for, and coming back triggers one anyway.
    private func startRefreshing() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleNodes() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval,
                                            repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSApp.isActive else { return }
                self?.refreshVisibleNodes()
            }
        }
    }

    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    // MARK: Root folders

    /// The sidebar's organization for the active workspace.
    var rootLayout: RootLayout { workspaceStore.active.layout }

    func createRootFolder(named name: String, in parent: UUID? = nil,
                          movingInto uris: [String] = []) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = workspaceStore.createFolder(named: trimmed.isEmpty ? "New Folder" : trimmed,
                                             in: parent)
        if !uris.isEmpty { workspaceStore.moveRoots(uris, toFolder: id) }
    }

    /// Reparent/reorder sidebar entries (roots and folders) — the drag-and-drop
    /// backing. `at` is the insertion index within the destination (nil = end).
    func moveEntries(_ refs: [EntryRef], toFolder id: UUID?, at index: Int? = nil) {
        workspaceStore.moveEntries(refs, toFolder: id, at: index)
    }

    /// Parse dropped drag payloads into entry refs. Folder rows drag a
    /// `folder:<id>` token; node rows drag raw node URIs (the same payload the
    /// filesystem `.move` uses) — only those that are actually roots become
    /// `.root` refs, so dragging a mere descendant into a sidebar folder is a
    /// no-op.
    func entryRefs(from payloads: [String], roots: [NodeID]) -> [EntryRef] {
        let rootURIs = Set(roots.map(\.uri))
        return payloads
            .flatMap { $0.split(separator: "\n").map(String.init) }
            .compactMap { token in
                if let ref = EntryRef(token: token), case .folder = ref { return ref }
                return rootURIs.contains(token) ? .root(token) : nil
            }
    }

    func renameRootFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspaceStore.renameFolder(id, to: trimmed)
    }

    func deleteRootFolder(_ id: UUID) { workspaceStore.deleteFolder(id) }

    /// Roots to drop into a folder created via the prompt (empty for a bare
    /// "New Folder…"), and the parent folder to create it inside (nil = top).
    private(set) var pendingFolderRoots: [String] = []
    private(set) var pendingFolderParent: UUID?

    func beginCreateFolder(in parent: UUID? = nil, movingIn uris: [String] = []) {
        pendingFolderRename = nil
        pendingFolderRoots = uris
        pendingFolderParent = parent
        showingFolderPrompt = true
    }

    func beginRenameFolder(_ folder: RootFolder) {
        pendingFolderRename = folder
        pendingFolderRoots = []
        pendingFolderParent = nil
        showingFolderPrompt = true
    }

    /// Commit the folder-name prompt — create (optionally inside a parent /
    /// moving roots in) or rename, depending on `pendingFolderRename`.
    func commitFolderPrompt(name: String) {
        if let folder = pendingFolderRename {
            renameRootFolder(folder.id, to: name)
        } else {
            createRootFolder(named: name, in: pendingFolderParent, movingInto: pendingFolderRoots)
        }
        pendingFolderRename = nil
        pendingFolderRoots = []
        pendingFolderParent = nil
    }

    func moveRoots(_ uris: [String], toFolder id: UUID?) {
        workspaceStore.moveRoots(uris, toFolder: id)
    }

    func setRootFolderExpanded(_ id: UUID, _ expanded: Bool) {
        workspaceStore.setFolderExpanded(id, expanded)
    }

    /// The folder a newly mounted root should join: the one holding the current
    /// node's root (so "New X" lands beside what you were looking at). Nil when
    /// the focused node isn't under any folder-held root.
    private func folderForNewRoot() -> UUID? {
        guard let focused = host.focusedNode,
              let root = rootContaining(focused) else { return nil }
        return workspaceStore.folderID(containing: root.uri)
    }

    /// The mounted root that contains `node`: the node itself if it's a root,
    /// else the longest root whose URI is a path-prefix of the node's. Best
    /// effort — a miss just places a new root loose.
    private func rootContaining(_ node: NodeID) -> NodeID? {
        let roots = host.roots
        if roots.contains(node) { return node }
        return roots
            .filter { root in
                node.uri == root.uri || node.uri.hasPrefix(root.uri + "/")
            }
            .max { $0.uri.count < $1.uri.count }
    }

    // Navigation commands surfaced to the toolbar, tab strip, and menu bar.
    func goBack() { store?.back() }
    func goForward() { store?.forward() }
    func newTab() { store?.newTab(with: host.focusedNode) }   // duplicate current node
    func openInNewTab(_ id: NodeID) { store?.newTab(with: id) }
    func closeActiveTab() { store?.closeTab(navigation.activeTab.id) }
    func closeTab(_ id: NavigationModel.Tab.ID) { store?.closeTab(id) }
    func selectTab(_ i: Int) { store?.selectTab(i) }

    // Canvas splits. "Right" = side by side, "down" = stacked.
    func toggleZenMode() { host._setZenMode(!host.isZenMode) }

    func splitPaneRight() { store?.splitActivePane(horizontal: true) }
    func splitPaneDown() { store?.splitActivePane(horizontal: false) }
    func closeActivePane() { store?.closeActivePane() }
    func activatePane(_ id: UUID) { store?.activatePane(id) }
    @discardableResult
    func movePane(_ direction: PaneDirection) -> UUID? { store?.movePane(direction) }
    func cyclePane(by offset: Int) { store?.cyclePane(by: offset) }

    /// Step to the next or previous workspace, wrapping. The workspace list is
    /// the order the switcher shows, so this and the menu agree.
    func cycleWorkspace(by offset: Int) {
        guard workspaces.count > 1, let active = activeWorkspaceID,
              let index = workspaces.firstIndex(where: { $0.id == active }) else { return }
        switchWorkspace(to: workspaces[(index + offset).wrapped(around: workspaces.count)].id)
    }

    /// The nth workspace, 1-based, as the switcher lists them.
    func selectWorkspace(number: Int) {
        let index = number - 1
        guard workspaces.indices.contains(index) else { return }
        switchWorkspace(to: workspaces[index].id)
    }

    /// Actions (from any plugin) that apply to `targets`, defaulting to the current
    /// selection. One registry feeds the menu bar, the palette, the sidebar context
    /// menu, and the inspector.
    func applicableActions(for targets: [NodeID]? = nil) -> [Action] {
        guard let store else { return [] }
        let variants = targetVariants(for: targets)
        return store.actions.filter { action in
            variants.contains { action.appliesTo.matches(ActionContext(host: host, targets: $0)) }
        }
    }

    /// The nodes as clicked, and as each identity they also are — so a git
    /// repository is offered to the file actions as the directory it is.
    private func targetVariants(for targets: [NodeID]?) -> [[NodeID]] {
        let resolved = targets ?? host.selection
        return ActionTargets.variants(for: resolved) { host.node($0)?.identities ?? [] }
    }

    /// The applicable actions a surface should show, in sections — see
    /// `ActionOrganizer` for what decides the order.
    func actionGroups(for surface: ActionSurfaces,
                      targets: [NodeID]? = nil) -> [ActionGroup] {
        let node = targets?.first ?? host.focusedNode
        return ActionOrganizer.groups(applicableActions(for: targets), for: surface,
                                      preferredOwner: store?.registry.owner(of: node))
    }

    /// Run an action against the identity that understands it — the same one
    /// that made it applicable in the first place.
    func run(_ action: Action, targets: [NodeID]? = nil) {
        let context = targetVariants(for: targets)
            .first { action.appliesTo.matches(ActionContext(host: host, targets: $0)) }
            .map { ActionContext(host: host, targets: $0) }
        action.handler(context ?? ActionContext(host: host, targets: targets))
        closeFinder()
    }

    /// Actions the host contributes itself — node manipulation that belongs to no
    /// plugin because it rides the generic mutation vocabulary. Rename is the
    /// model case: any provider that supports `.rename` (filesystem today,
    /// bookmarks or branches tomorrow) gets the sidebar's inline-rename UI, the
    /// menu item, the shortcut, and the palette entry without writing any UI.
    /// The host's own inspector section, shown for every node. High priority
    /// so it leads: what a thing *is* comes before what any one plugin has to
    /// say about it.
    private func registerCoreInspector(with registry: Registry) {
        registry.register(inspector: InspectorContribution(
            priority: 1000,
            matches: { _ in true }
        ) { id, host in
            AnyView(NodeInspector(nodeID: id).environment(host))
        })
    }

    private func registerCoreActions(with registry: Registry) {
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
    }

    func start() {
        guard store == nil else { return }
        // Host-owned actions register first so they lead every action list.
        registerCoreActions(with: pluginHost.registry)
        registerCoreInspector(with: pluginHost.registry)
        registerBuiltInFinders(into: pluginHost.registry)
        // Under XCTest the test bundle compiles the plugin's sources directly; don't
        // also dlopen the .bundle into the same process, or the @objc principal class
        // collides. Tests exercise provider logic without the running host.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !underTest {
            pluginHost.loadAll()
            // No timer under test: it would fire into a model the test has
            // finished with, and there is no app to become active anyway.
            startRefreshing()
        }
        let store = GraphStore(context: host, registry: pluginHost.registry, nav: navigation)
        self.store = store
        // Persist on every root-set change, no matter who mounted (UI or plugin).
        // New roots join the folder of the current node's root — creating a node
        // respects where you already are.
        store.onNodeRenamed = { [weak self] old, new in
            self?.sidebar.remap(from: old, to: new)
        }
        // Every disclosure writes through to the active workspace, so quitting
        // at any moment leaves the tree the way it looks right now.
        sidebar.onExpansionChanged = { [weak self] revealed in
            self?.workspaceStore.setRevealedNodes(revealed.map(\.uri))
        }
        store.onRootsChanged = { [weak self] in
            guard let self else { return }
            self.workspaceStore.reconcileRoots(self.host.roots,
                                               placingNewInto: self.folderForNewRoot())
        }

        let providers = pluginHost.registry.providers
        // Restore rewrites the layout in place (see `restoreRoots`) — roots keep
        // their position and folder across launches.
        var roots = workspaceStore.restoreRoots(using: providers)
        // Seed provider defaults (home directory) only on the very first launch —
        // a workspace the user deliberately emptied stays empty.
        if roots.isEmpty && workspaceStore.wasFreshlyCreated {
            roots = providers.flatMap { $0.roots() }
            workspaceStore.reconcileRoots(roots)
        }
        store.setRoots(roots)
        // After the roots exist, so the disclosed subtrees have something to
        // hang from; flattening them pulls their children in on its own.
        restoreRevealedNodesFromDisk()
    }

    /// Prompt for a folder and mount it as a new root. (Persistence happens in the
    /// store's onRootsChanged, same as any plugin-initiated mount.)
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Mount"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Pass the raw file URL; the FileSystem provider owns `file:` and canonicalizes
        // it on resolve. The host stays ignorant of what a path is.
        store?.mount(url.absoluteString)
    }

    /// Remove a root from the sidebar (the node itself is untouched).
    func removeRoot(_ id: NodeID) { store?.unmount(id) }
}
