import SwiftUI
import AppKit
@_spi(Host) import MaximalTreeKit
import MaximalEditorKit

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
        MainActor.assumeIsolated {
            WindowFloor.watch()
            Self.stayOutOfTheWayUnderTest()
        }
        claimOpenDocuments()
    }

    /// Under XCTest, be an app nobody has to look at.
    ///
    /// The suite runs *inside* this app — it is the test host — so a plain run
    /// launched a full window over whatever the reader was working on and took
    /// the keyboard with it. `.accessory` keeps it out of the Dock and out of
    /// the way; its own windows are ordered off as they appear, since the
    /// scene still builds one and nothing in the tests wants it.
    ///
    /// Not `.prohibited`, which forbids windows outright: several suites need
    /// a real window to get TextKit to lay anything out.
    @MainActor
    private static func stayOutOfTheWayUnderTest() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        else { return }
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue.contains("AppWindow") == true else { return }
            MainActor.assumeIsolated { window.orderOut(nil) }
        }
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
    /// one per file, and they never go away. Neither `handlesExternalEvents`
    /// nor closing the window afterwards helps: the first is ignored and the
    /// second is undone — SwiftUI keeps the window open through every
    /// `close()`. Claiming the event is the only thing that worked.
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
        .commands { AppCommands(model: model) }


    }
}

/// The window around the engine: loads the plugins, and keeps what only a
/// window has — the sidebar's disclosure, the finder, which chrome is showing,
/// the keyboard. Everything that would be true with no window at all is the
/// engine's (`HostEngine`), and what the views ask of it is forwarded from here.
@MainActor
@Observable
final class AppModel: HostShell {
    let host: HostContext
    /// The host with no window — see `HostEngine`.
    let engine: HostEngine
    var navigation: NavigationModel { engine.navigation }
    /// Sidebar UI state (expansion, selection anchor) — session-scoped, owned
    /// here so the tree survives sidebar view recreation.
    let sidebar = SidebarState()
    /// The middle column's state — see `ContentsModel`.
    let contents = ContentsModel()
    // Not private: under XCTest the plugin bundles aren't dlopened (their
    // sources are compiled into the test target instead), so a test that wants
    // the real registry has to populate it itself.
    let pluginHost: PluginHost
    /// Where the workspace library lives. Injectable so a test drives the
    /// real model without writing into the user's own workspaces.
    var workspaceStore: WorkspaceStore { engine.workspaceStore }
    var store: GraphStore? { engine.store }

    /// Running what is asked for, and saying when it didn't work — the
    /// engine's; this window only says what a key press is pointing at.
    var dispatch: Dispatcher { engine.dispatch }
    /// The failure or notice in front of the reader — see `Dispatcher.failure`.
    var commandFailure: CommandFailure? { dispatch.failure }
    var commandsRunning: Int { dispatch.running }

    /// The finder: fuzzy search over everything the app knows about.
    var finderVisible = false
    let finder = FinderModel()
    /// Chrome visibility lives here rather than in the view, because the
    /// keyboard layer has to be able to toggle it (see KeyCommands).
    var sidebarVisible = true
    var inspectorVisible = true

    // MARK: The contents column

    /// What the middle column is listing: the sidebar's selection, when what
    /// is selected is something you go *into* rather than open in place.
    ///
    /// Or what it produces. An aggregator is its channels in the sidebar and
    /// its feed in the column: one thing, whose second identity declares
    /// itself contents. Declared, not inferred from a paged listing — a
    /// project whose directory happens to be large is not asking for a column.
    ///
    /// Derived rather than stored, and derived from the sidebar's selection
    /// specifically — which is why the column never writes that selection
    /// itself. A row publishing itself there would re-derive this to the row,
    /// find a file has no contents, and close the column that was showing it.
    var contentsContainer: NodeID? {
        guard host.selection.count == 1, let id = host.selection.first else { return nil }
        if host.childStyle(of: id) == .contents { return id }
        return host.node(id)?.identities.first { host.node($0)?.childStyle == .contents }
    }

    /// The highlighted row, if the column is on screen.
    ///
    /// Gated on visibility because the highlight is what the active pane
    /// draws: a list you have put away must not go on deciding what you are
    /// looking at. Hiding it hands the pane back to its own history, and the
    /// row is still there when the column comes back.
    var contentsRow: NodeID? {
        guard contentsVisible, let container = contentsContainer else { return nil }
        return contents.rowByContainer[container]
    }

    /// Whether the column is on screen: something to list, not turned off, and
    /// not zen — which hides everything that isn't the work.
    var contentsVisible: Bool {
        contentsContainer != nil && !contents.isHidden && !host.isZenMode
    }

    /// What a pane draws.
    ///
    /// The highlighted row stands in front of the active pane's own history
    /// without touching it: arrowing down a list of two hundred should not
    /// push two hundred entries you then have to walk back out of. Enter is
    /// what commits — see `openContentsRow`.
    ///
    /// The active pane only. A split exists to hold two things still; a list
    /// that redrew every pane at once would take that away.
    func displayedNode(in pane: Pane) -> NodeID? {
        if pane.id == navigation.activePane?.id, let row = contentsRow { return row }
        return pane.current
    }

    /// Highlight a row: shown in the active pane, nothing navigated.
    func highlightContentsRow(_ id: NodeID) {
        guard let container = contentsContainer else { return }
        contents.rowByContainer[container] = id
        if contentsNeedsMore(after: id) { host.loadMoreChildren(of: container) }
    }

    /// How close to the end of the loaded rows the highlight has to come
    /// before the next page is worth asking for. A few rows of warning, so the
    /// page is usually there by the time it is needed.
    static let contentsPrefetchMargin = 5

    /// Whether landing on this row should ask for the next page.
    ///
    /// The spinner at the foot of the list asks when it is *drawn*, which the
    /// keyboard never causes: the motions clamp at the last loaded row, so `j`
    /// stops exactly one short of the thing that would have asked, and the
    /// list looks like it ends there. The highlight coming within sight of the
    /// end is the same signal read from the keyboard's side.
    func contentsNeedsMore(after id: NodeID) -> Bool {
        guard let container = contentsContainer, host.hasMoreChildren(container) else {
            return false
        }
        let rows = contentsRows()
        guard let index = rows.firstIndex(of: id) else { return false }
        return rows.count - index <= Self.contentsPrefetchMargin
    }

    /// Commit to a row — the pane navigates, and the preview stops standing in
    /// front of it because it is now what the pane is showing anyway.
    func openContentsRow(_ id: NodeID) {
        highlightContentsRow(id)
        host.open(id)
    }

    /// Move the highlight `delta` rows, clamped at both ends.
    ///
    /// Nothing highlighted yet counts as standing just outside the list, on
    /// the side the move is coming from: the first `j` lands on the first row
    /// and the first `k` on the last, and a count carries from there rather
    /// than being swallowed by a special case for the first press.
    func moveContentsRow(by delta: Int) {
        let rows = contentsRows()
        guard !rows.isEmpty, delta != 0 else { return }
        let from = contentsRow.flatMap { rows.firstIndex(of: $0) }
            ?? (delta > 0 ? -1 : rows.count)
        highlightContentsRow(rows[min(max(from + delta, 0), rows.count - 1)])
    }

    func moveContentsRowToEdge(last: Bool) {
        let rows = contentsRows()
        guard let target = last ? rows.last : rows.first else { return }
        highlightContentsRow(target)
    }

    /// What the column is listing, filter and all — the motions have to walk
    /// the rows on screen, not the ones a cleared filter would show.
    func contentsRows() -> [NodeID] {
        guard let container = contentsContainer else { return [] }
        let children = host.children(of: container)
        let needle = contents.filter
        guard !needle.isEmpty else { return children }
        return children.filter {
            (host.node($0)?.label ?? $0.uri).localizedCaseInsensitiveContains(needle)
        }
    }

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
    func open(files urls: [URL]) { engine.open(files: urls) }

    var activeWorkspaceIsEphemeral: Bool { engine.activeWorkspaceIsEphemeral }

    /// Keep the workspace a stray file arrived in.
    ///
    /// The way out of being ephemeral: from here on it is written down like
    /// any other. Renaming it is the next thing most people want, since it is
    /// still named after a file, so that prompt follows.
    func keepActiveWorkspace() {
        guard activeWorkspaceID != nil else { return }
        engine.keepActiveWorkspace()
        showingRenameWorkspace = true
    }

    /// Recompute after anything that could have moved the keyboard: a key, a
    /// click, a focus this app asked for. Deferred a turn because AppKit sets
    /// the first responder while handling the event, after the monitor has
    /// already seen it.
    func refreshFocusedSurface() {
        DispatchQueue.main.async { [self] in
            let now = keyboardSurface()
            if now != focusedSurface { focusedSurface = now }
        }
    }
    /// The surface keymap last built, and what it was built for.
    ///
    /// Stored here because an extension cannot hold one; the reasoning lives
    /// with `surfaceKeymap(for:showing:)`, which is the only thing that reads
    /// or writes it.
    @ObservationIgnored
    var cachedSurfaceKeys: (surface: SurfaceID, node: NodeID?, map: Keymap)?
    /// How many times that map has actually been built, for a test to check
    /// the answer is remembered rather than recomputed.
    @ObservationIgnored private(set) var surfaceKeymapBuilds = 0
    func bumpSurfaceKeymapBuilds() { surfaceKeymapBuilds += 1 }

    /// The modal keyboard layer. Built here so every surface shares one mode.
    @ObservationIgnored lazy var keys: KeyEngine = {
        let engine = KeyEngine(keymap: DefaultKeymap.make())
        engine.perform = { [weak self] id, count in
            self?.runCommand(id, count: count)
        }
        // The mode is app-wide, and a surface reads it through the host — so
        // the one that changes it tells the other.
        engine.onModeChange = { [weak self] mode in
            self?.host._setKeyMode(mode)
            // Escape is the app's, and leaving insert is when an editor has to
            // put a selection back. It cannot see the key, so it is told.
            EditorKeys.appModeChanged(to: mode)
        }
        return engine
    }()
    /// Canvas-only view; see `HostContext.isZenMode` for the canvas contract.
    var isZenMode: Bool { host.isZenMode }
    /// Prompt state for the workspace name alerts, settable from any surface
    /// (toolbar menu, menu bar); ContentView presents the alerts.
    var showingCreateWorkspace = false
    var showingRenameWorkspace = false

    init(host: HostContext, workspaceFile: URL? = nil) {
        self.host = host
        let plugins = PluginHost()
        self.pluginHost = plugins
        self.engine = HostEngine(
            host: host, registry: plugins.registry,
            workspaceStore: WorkspaceStore(fileURL: workspaceFile ?? Self.isolatedLibraryUnderTest()))
        engine.shell = self
    }

    /// Somewhere to keep the library while the test runner is using the app.
    ///
    /// The tests run inside the app itself, which launches like any launch
    /// and builds its model on the default library — the reader's own. So
    /// every test run loaded it, saved it back, and, once groups became
    /// collections, migrated it. Nothing a test asserts depends on that
    /// model, and none of it should ever touch real data.
    private static func isolatedLibraryUnderTest() -> URL? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        else { return nil }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maximaltree-test-host-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspaces.json")
    }

    // MARK: Workspaces

    var workspaces: [Workspace] { engine.workspaces }
    var workspacesByRecency: [Workspace] { engine.workspacesByRecency }
    var activeWorkspaceID: UUID? { engine.activeWorkspaceID }
    var activeWorkspaceName: String { engine.activeWorkspaceName }
    func switchWorkspace(to id: UUID) { engine.switchWorkspace(to: id) }
    func createWorkspace(named name: String) { engine.createWorkspace(named: name) }
    func renameActiveWorkspace(to name: String) { engine.renameActiveWorkspace(to: name) }
    func deleteActiveWorkspace() { engine.deleteActiveWorkspace() }
    func cycleWorkspace(by offset: Int) { engine.cycleWorkspace(by: offset) }

    /// The sidebar's disclosure in each workspace you have left this run, so
    /// coming back finds it opened out as you left it. The tabs are the
    /// engine's to keep; this is the window's half.
    private var sidebarByWorkspace: [UUID: SidebarState.Snapshot] = [:]

    func leavingWorkspace(_ id: UUID) { sidebarByWorkspace[id] = sidebar.snapshot() }

    func enteredWorkspace(_ id: UUID, firstVisit: Bool) {
        if !firstVisit, let snapshot = sidebarByWorkspace[id] {
            sidebar.restore(snapshot)
            return
        }
        // Put the sidebar's disclosure back the way the workspace last had it
        // on disk. Uris that no longer resolve are simply dropped — an
        // expanded node that's gone has nothing to disclose.
        let revealed = Set(workspaceStore.active.revealedNodes.compactMap(NodeID.init))
        sidebar.restore(SidebarState.Snapshot(expandedNodes: revealed, anchor: nil))
    }

    var revealedNodes: [NodeID] { Array(sidebar.expandedNodes) }

    func nodeRenamed(from old: NodeID, to new: NodeID) { sidebar.remap(from: old, to: new) }

    func setKeyMode(_ mode: KeyMode) { keys.setMode(mode) }

    // MARK: Keeping the tree current

    /// How often the tree is brought up to date while you are using the app.
    ///
    /// Long enough that it costs nothing to have running, short enough that a
    /// directory changed by something else doesn't stay wrong for a session.
    private static let refreshInterval: TimeInterval = 60

    func refreshVisibleNodes() { engine.refreshVisibleNodes() }

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

    // MARK: The sidebar's groups

    var placements: Placements { engine.placements }
    var sidebarRoot: String { engine.sidebarRoot }

    /// A new group called "New Collection", in `parent` or at the top level,
    /// selected with its name ready to type.
    ///
    /// Marked open before it holds anything, so the first things dropped into
    /// it are seen arriving — which is how a new folder always behaved.
    func newCollection(in parent: UUID? = nil, movingIn ids: [NodeID] = [],
                       from source: NodeID? = nil) {
        guard let node = engine.newCollection(in: parent, movingIn: ids, from: source) else { return }
        sidebar.expandedNodes.insert(node)
        if let parent, let holder = workspaceStore.uri(of: parent) {
            sidebar.expandedNodes.insert(NodeID(canonical: holder))
        }
        present(node)
    }

    static let watchLaterName = HostEngine.watchLaterName

    func addToCollection(_ ids: [NodeID], named name: String) {
        engine.addToCollection(ids, named: name)
    }

    /// Put these in a collection made for them, named and ready to rename.
    func addToNewCollection(_ ids: [NodeID]) {
        guard let node = engine.addToNewCollection(ids) else { return }
        sidebar.expandedNodes.insert(node)
        present(node)
    }

    /// A collection just made: selected, with its name ready to type.
    private func present(_ node: NodeID) {
        host.select([node])
        store?.beginRename(node)
    }

    func addToCollection(_ ids: [NodeID], uri: String) { engine.addToCollection(ids, uri: uri) }

    /// Dragged rows let go over a place in the group tree — a group, or a strip
    /// between rows (`destination` nil is the top level).
    @discardableResult
    func drop(_ payloads: [String], onto destination: UUID?, at index: Int? = nil) -> Bool {
        let uris = payloads.flatMap { $0.split(separator: "\n").map(String.init) }
            .filter { NodeID($0) != nil }
        guard !uris.isEmpty else { return false }
        let plan = SidebarDrop.plan(dropping: uris, origin: dragOrigin(of: uris),
                                    onto: destination, at: index,
                                    adding: NSEvent.modifierFlags.contains(.option))
        sidebar.drag = nil
        switch plan {
        case .move(let uris, let from, let to, let at):
            workspaceStore.move(uris, from: from, to: to, at: at)
        case .add(let uris, let to, let at):
            workspaceStore.add(uris, to: to, at: at)
        }
        return true
    }

    /// Where a drag of these rows started, if this is the drag the sidebar
    /// recorded — a drag from another app, or one abandoned earlier, is not.
    ///
    /// A move needs every row to actually be in the place it is moving from;
    /// a selection spanning two groups is added rather than half-moved.
    private func dragOrigin(of uris: [String]) -> SidebarDrop.Origin? {
        guard let drag = sidebar.drag, Set(drag.uris) == Set(uris) else { return nil }
        let holder = drag.parent.map(\.uri) ?? sidebarRoot
        guard drag.parent == nil || Placements.isCollection(holder),
              Set(uris).isSubset(of: placements.children(of: holder)) else { return .elsewhere }
        return drag.parent.flatMap { CollectionRef.id(from: $0.uri) }.map { .group($0) } ?? .topLevel
    }

    func deleteGroups(_ ids: [NodeID]) { engine.deleteGroups(ids) }
    func remove(_ ids: [NodeID], from parent: NodeID?) { engine.remove(ids, from: parent) }
    func move(_ ids: [NodeID], from parent: NodeID?, to destination: UUID?) {
        engine.move(ids, from: parent, to: destination)
    }
    func undo() { engine.undo() }
    func redo() { engine.redo() }

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

    // What applies and running it are the dispatcher's; these say it from here.
    func applicableActions(for targets: [NodeID]? = nil) -> [Action] {
        dispatch.applicableActions(for: targets)
    }
    func actionGroups(for surface: ActionSurfaces, targets: [NodeID]? = nil) -> [ActionGroup] {
        dispatch.actionGroups(for: surface, targets: targets)
    }
    func action(_ id: String) -> Action? { dispatch.action(id) }
    func canRun(_ action: Action, targets: [NodeID]? = nil) -> Bool {
        dispatch.canRun(action, targets: targets)
    }

    /// Run an action from a surface that lists them — a menu, the finder.
    ///
    /// Puts the finder away, which running one *by id* must not: the finder is
    /// itself opened by an action, and closing it on the way in would mean the
    /// key that opens it also shuts it.
    func run(_ action: Action, targets: [NodeID]? = nil) {
        perform(action, targets: targets)
        closeFinder()
    }

    func perform(_ action: Action, targets: [NodeID]? = nil, count: Int = 1) {
        dispatch.perform(action, targets: targets, count: count)
    }
    func invoke(_ command: AnyCommand, in context: ActionContext) {
        dispatch.invoke(command, in: context)
    }
    func runCommand(_ id: String, count: Int = 1) { dispatch.runCommand(id, count: count) }
    func runCommand(_ id: String, with argument: CommandValue) {
        dispatch.runCommand(id, with: argument)
    }
    func run(commandID id: String, input: Any) async throws -> Any {
        try await dispatch.run(commandID: id, input: input)
    }
    func report(_ error: Error, from command: String) { dispatch.report(error, from: command) }
    func notice(_ notice: Notice) { dispatch.notice(notice) }
    func dismissCommandFailure() { dispatch.dismissFailure() }

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
        // Every disclosure writes through to the active workspace, so quitting
        // at any moment leaves the tree the way it looks right now.
        sidebar.onExpansionChanged = { [weak self] revealed in
            self?.workspaceStore.setRevealedNodes(revealed.map(\.uri))
        }
        engine.start()
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

}
