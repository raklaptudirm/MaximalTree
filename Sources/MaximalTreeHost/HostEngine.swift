import Foundation
import Observation
@_spi(Host) import MaximalTreeKit

/// What the engine needs from the shell around it: the few things only a
/// window knows, and the moments it has to hear about.
///
/// Small on purpose. Everything else a shell shows it reads from the engine;
/// this is only what flows the other way.
@MainActor
protocol HostShell: KeyTargeting {
    /// The nodes opened out beneath the roots — what is on screen, and so
    /// what a refresh asks for again. The roots themselves the engine knows.
    var revealedNodes: [NodeID] { get }
    /// A node was renamed: whatever the shell keeps by id follows it.
    func nodeRenamed(from old: NodeID, to new: NodeID)
    /// The active workspace is about to change, so whatever the shell keeps
    /// per workspace can be put by for `id`.
    func leavingWorkspace(_ id: UUID)
    /// A workspace has become active, its roots already in place. On its first
    /// visit this run there is nothing put by, and what it saved on disk is
    /// what there is to go on.
    func enteredWorkspace(_ id: UUID, firstVisit: Bool)
    /// The mode a surface's command left behind.
    func setKeyMode(_ mode: KeyMode)
}

/// The host with no window: the workspace library, the graph, what is open,
/// and running what is asked for.
///
/// One per shell. The Mac app's `AppModel` holds one and adds what a window
/// has — the sidebar, the finder, the panes on screen; a headless host would
/// hold one and add nothing. Whatever has to stay true whichever shell is in
/// front of it lives here: that a rename reaches the placements, that a new
/// root joins the collection you were working in, that switching workspace
/// brings back what you left.
@MainActor
@Observable
final class HostEngine {
    let host: HostContext
    let registry: CoreContributions
    /// Where the workspace library lives — see `WorkspaceStore`.
    let workspaceStore: WorkspaceStore
    let navigation = NavigationModel()
    let dispatch: Dispatcher
    /// Built by `start()`, once every plugin has registered.
    private(set) var store: GraphStore?

    @ObservationIgnored weak var shell: HostShell? {
        didSet { dispatch.keyTargeting = shell }
    }

    init(host: HostContext, registry: CoreContributions, workspaceStore: WorkspaceStore) {
        self.host = host
        self.registry = registry
        self.workspaceStore = workspaceStore
        self.dispatch = Dispatcher(host: host, registry: registry)
        // Before any plugin registers, so the broker they share is installed
        // with it: a plugin can put a collection in its own listing, and a
        // plugin's node that takes drops reads what was placed in it through
        // the broker.
        let workspaces = workspaceStore
        registry.register(provider: CollectionProvider(
            exists: { uri in await MainActor.run { workspaces.members(of: uri) != nil } },
            change: { mutation in await MainActor.run { workspaces.applyToCollections(mutation) } }))
        registry.hostBroker.installPlacements { uri in
            await MainActor.run { workspaces.placedChildren(of: uri) }
        }
        // What the host's own views do to a node, so that whatever drives the
        // engine — a key, a script, a shell elsewhere — can do it too.
        registry.register(RenameNode())
        registry.register(DropNodes())
    }

    /// Build the graph and bring back the active workspace. Once, after every
    /// plugin has registered: the store routes by the providers it is given.
    func start() {
        guard store == nil else { return }
        hearFromTheLibrary()
        // And from the plugins, which have their own files of the reader's to
        // keep — whatever they said while loading is held until now.
        registry.notices.listen { [weak self] notice in self?.dispatch.notice(notice) }

        let store = GraphStore(context: host, registry: registry, nav: navigation)
        self.store = store
        store.onNodeRenamed = { [weak self] old, new in
            guard let self else { return }
            shell?.nodeRenamed(from: old, to: new)
            // Placements are written down, so a rename has to reach them —
            // descendants included, which only the placements do.
            workspaceStore.remap(from: old.uri, to: new.uri)
        }
        store.onNodeRemoved = { [weak self] id in
            self?.workspaceStore.removeEverywhere(id.uri)
        }
        // `host.perform(id)` from a plugin runs the same dispatch a key does,
        // so there is one answer to "what happens when this id is invoked".
        store.onPerformAction = { [weak self] id, count in
            self?.dispatch.runCommand(id, count: count)
        }
        store.onRunCommand = { [weak self] id, input in
            guard let self else { throw CommandError.noSuchCommand(command: id) }
            return try await dispatch.run(commandID: id, input: input)
        }
        store.onSetKeyMode = { [weak self] mode in self?.shell?.setKeyMode(mode) }
        // Persist on every root-set change, no matter who mounted (UI or
        // plugin). New roots join the collection of the current node's root —
        // creating a node respects where you already are.
        store.onRootsChanged = { [weak self] in
            guard let self else { return }
            workspaceStore.reconcileRoots(host.roots, placingNewInto: groupForNewRoot())
        }
        // One place for everything that follows a change to the sidebar's
        // tree, whichever way it changed — a drag, a delete, a rename
        // underneath a group.
        workspaceStore.onActiveTreeChanged = { [weak self] in self?.treeChanged($0) }
        store.placements = workspaceStore

        let providers = registry.providers
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
        store.ensureNodes(groupNodes)
        // After the roots exist, so the disclosed subtrees have something to
        // hang from.
        if let id = activeWorkspaceID { shell?.enteredWorkspace(id, firstVisit: true) }
    }

    /// What the workspace library has to say before anything else happens: that
    /// it couldn't be read and was kept aside, or that it can't be saved.
    private func hearFromTheLibrary() {
        let library = workspaceStore
        if let unreadable = library.unreadable {
            dispatch.notice(.unreadable("Workspaces", "workspaces", file: library.fileURL,
                                        keptAt: unreadable.keptAt, source: "workspace.load"))
        }
        library.onSaveFailed = { [weak self] error in self?.reportSaveFailure(error) }
        if let error = library.saveError { reportSaveFailure(error) }
    }

    private func reportSaveFailure(_ error: Error) {
        dispatch.notice(.notSaved("Workspaces", "workspaces", error: error, source: "workspace.save"))
    }

    // MARK: Workspaces

    var workspaces: [Workspace] { workspaceStore.library.workspaces }
    /// The same workspaces in last-use order — what cycling and the switcher
    /// walk, while the menu keeps the arranged one.
    var workspacesByRecency: [Workspace] { workspaceStore.byRecency }
    var activeWorkspaceID: UUID? { workspaceStore.library.activeID }
    var activeWorkspaceName: String { workspaceStore.active.name }
    /// Whether what you are looking at is a workspace that will not outlive
    /// the session — which is what offers you the chance to keep it.
    var activeWorkspaceIsEphemeral: Bool { workspaceStore.active.isEphemeral }

    /// What each workspace's tabs looked like when you left it, splits and
    /// history and all — in memory, so a switch restores exactly what you
    /// had. Tabs aren't written down: they would need their canvases
    /// serialized. What the shell keeps per workspace it puts by itself.
    private var tabsByWorkspace: [UUID: NavigationModel.Snapshot] = [:]

    func switchWorkspace(to id: UUID) {
        guard id != activeWorkspaceID else { return }
        if let leaving = activeWorkspaceID {
            tabsByWorkspace[leaving] = navigation.snapshot()
            shell?.leavingWorkspace(leaving)
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

    /// Step through the workspaces in last-use order, wrapping.
    ///
    /// Alt-tab, not a carousel: the active one is always the head of that
    /// order, so one step forward is the workspace you were just in — and
    /// taking it again brings you back, because arriving put this one at the
    /// head instead. Two workspaces you are working between stay one
    /// keystroke apart however many others exist.
    ///
    /// The menu keeps the arranged order and its ⌘⌥1…9, which have to mean
    /// the same workspace tomorrow as today.
    func cycleWorkspace(by offset: Int) {
        let recent = workspacesByRecency
        guard recent.count > 1 else { return }
        switchWorkspace(to: recent[offset.wrapped(around: recent.count)].id)
    }

    private func reloadActiveWorkspaceRoots() {
        let roots = workspaceStore.restoreRoots(using: registry.providers)
        // switchRoots resets the surface; put this workspace's own back if we
        // have seen it before. Order matters: the roots have to exist before
        // the tabs pointing into them are focused.
        store?.switchRoots(roots)
        store?.ensureNodes(groupNodes)
        // What was placed in a node is the workspace's, and the listings
        // cached are the last workspace's — for a plugin's node that takes
        // drops, the same node holds something else here.
        placementsChanged(Set(workspaces.flatMap { $0.placements.children.keys }))
        guard let id = activeWorkspaceID else { return }
        guard let tabs = tabsByWorkspace[id] else {
            // First visit this run: nothing is cached yet, so opening the tree
            // fetches it fresh — there is nothing here to bring up to date.
            shell?.enteredWorkspace(id, firstVisit: true)
            return
        }
        shell?.enteredWorkspace(id, firstVisit: false)
        store?.restoreNavigation(tabs)
        // Switched back to a workspace this session has seen before, so its
        // children are cached from whenever you last looked. Long enough ago
        // to be wrong.
        refreshVisibleNodes()
    }

    /// Ask again for what is on screen.
    ///
    /// Providers that stream their changes keep themselves current, and two of
    /// the six do; the rest answered once, when the node was first opened, and
    /// would go on showing that answer until something happened to invalidate
    /// it. Nothing did — so a directory changed by another program, a branch
    /// switched in a terminal, a note written by a script all stayed invisible
    /// until the node was collapsed and opened again.
    ///
    /// What is revealed can name nodes inside a collapsed parent, which are
    /// not strictly on screen — refreshing those is a listing nobody reads,
    /// but the set is small and bounded by what has been loaded at all.
    /// `refreshChildren` skips anything never loaded, so this can only ever
    /// re-ask questions the app has already asked once.
    func refreshVisibleNodes() {
        store?.refreshChildren(of: host.roots + (shell?.revealedNodes ?? []))
    }

    // MARK: Files opened from outside

    /// Open these files. A file inside a mounted root belongs to that root's
    /// workspace and opens there, with the project around it — switching
    /// workspace first if it isn't the one in front of you.
    ///
    /// A file no workspace mounts gets a workspace of its own, made on the
    /// spot and holding just that file: a workspace is the app's own answer to
    /// "a set of things to work on", and one file is a perfectly good set.
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

    /// Keep the workspace a stray file arrived in: from here on it is written
    /// down like any other.
    func keepActiveWorkspace() {
        guard let id = activeWorkspaceID else { return }
        workspaceStore.keep(id)
    }

    // MARK: Collections

    /// The active workspace's sidebar: what was placed in it, and where.
    var placements: Placements { workspaceStore.active.placements }
    /// The entry in `placements` the sidebar is drawn from.
    var sidebarRoot: String { workspaceStore.active.root }

    /// A new collection called "New Collection", in `parent` or at the top
    /// level, holding `ids` if any were moved in. The node it is, so the
    /// shell can put it in front of the reader.
    @discardableResult
    func newCollection(in parent: UUID? = nil, movingIn ids: [NodeID] = [],
                       from source: NodeID? = nil) -> NodeID? {
        let id = workspaceStore.createGroup(named: "New Collection", in: parent)
        guard let uri = workspaceStore.uri(of: id) else { return nil }
        let node = NodeID(canonical: uri)
        if !ids.isEmpty { move(ids, from: source, to: id) }
        store?.ensureNodes([node])
        return node
    }

    /// What "Add to Watch Later" means: a collection of that name, in this
    /// workspace.
    ///
    /// There is nothing else to it. A watch list is an ordered set of things
    /// you meant to come back to, which is what a collection already is — so
    /// it is drag-arrangeable, renameable, can hold anything, and is nobody
    /// else's list: not YouTube's, not synced, not a feature of one plugin.
    static let watchLaterName = "Watch Later"

    /// Put these in the collection called `name`, making it at the top level
    /// if this workspace has none — so the action works before the collection
    /// exists.
    ///
    /// Added, not moved: a video listed inside a channel stays there, and one
    /// already in the collection moves to the end rather than appearing twice.
    func addToCollection(_ ids: [NodeID], named name: String) {
        guard !ids.isEmpty else { return }
        let destination = placements.collections(from: sidebarRoot)
            .first { CollectionRef.name(from: $0.uri) == name }?.uri
            ?? workspaceStore.uri(of: workspaceStore.createGroup(named: name))
        guard let destination else { return }
        workspaceStore.place(ids.map(\.uri), into: destination, at: nil)
        store?.ensureNodes([NodeID(canonical: destination)])
    }

    /// Put these in a collection made for them. The node it is.
    @discardableResult
    func addToNewCollection(_ ids: [NodeID]) -> NodeID? {
        let id = workspaceStore.createGroup(named: "New Collection")
        guard let uri = workspaceStore.uri(of: id) else { return nil }
        workspaceStore.place(ids.map(\.uri), into: uri, at: nil)
        let node = NodeID(canonical: uri)
        store?.ensureNodes([node])
        return node
    }

    /// Put these in a collection that is already there.
    func addToCollection(_ ids: [NodeID], uri: String) {
        guard !ids.isEmpty else { return }
        workspaceStore.place(ids.map(\.uri), into: uri, at: nil)
    }

    /// Delete groups. Everything they held takes their place.
    func deleteGroups(_ ids: [NodeID]) {
        for id in ids { if let group = CollectionRef.id(from: id.uri) { workspaceStore.deleteGroup(group) } }
    }

    /// Take rows out of the place they are in — `parent`, or the top level.
    func remove(_ ids: [NodeID], from parent: NodeID?) {
        workspaceStore.remove(ids.map(\.uri), from: parent.flatMap { CollectionRef.id(from: $0.uri) })
    }

    /// Move rows from where they are to `destination` (nil: the top level).
    /// From inside something that is not a group, they are added instead.
    func move(_ ids: [NodeID], from parent: NodeID?, to destination: UUID?) {
        let uris = ids.map(\.uri)
        switch parent {
        case nil:
            workspaceStore.move(uris, from: nil, to: destination, at: nil)
        case let parent? where CollectionRef.id(from: parent.uri) != nil:
            workspaceStore.move(uris, from: CollectionRef.id(from: parent.uri), to: destination, at: nil)
        default:
            workspaceStore.add(uris, to: destination, at: nil)
        }
    }

    /// Put back the last change to the sidebar's arrangement, or put back the
    /// putting back.
    ///
    /// Both write through the same path any other change does, so the roots are
    /// recomputed and the tree relists exactly as if the change had been made
    /// by hand — which, going the other way, it has.
    func undo() { workspaceStore.undo() }
    func redo() { workspaceStore.redo() }

    /// Every group in the active workspace, as the nodes the sidebar draws.
    private var groupNodes: [NodeID] {
        placements.collections(from: sidebarRoot).map { NodeID(canonical: $0.uri) }
    }

    /// The sidebar's tree changed, however it changed: bring along what the
    /// rest of the app sees — the mounted roots the graph loads and watches,
    /// and the records the group rows are drawn from.
    private func treeChanged(_ parents: Set<String>) {
        guard let store else { return }
        let roots = workspaceStore.resolvedRoots(using: registry.providers)
        if roots != host.roots { store.setRoots(roots) }
        store.ensureNodes(groupNodes)
        placementsChanged(parents)
    }

    /// Tell the tree that what was placed in these changed: their listings,
    /// and whether they have anything to open.
    ///
    /// A turn later, because this can be reached from inside the store working
    /// through a batch of changes, and reporting more to it mid-batch would
    /// interleave the two.
    ///
    /// Fetched again at once rather than only marked stale — the way a refresh
    /// is, so a listing on screen swaps in place — and only those already
    /// loaded.
    ///
    /// Their other identities too: a feed is made of what was placed in its
    /// aggregator, so it changed as well.
    private func placementsChanged(_ parents: some Sequence<String>) {
        let placed = parents.compactMap(NodeID.init)
        let ids = placed + placed.flatMap { host.node($0)?.identities ?? [] }
        guard !ids.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.store?.notify(ids.map { .modified($0) })
            self?.store?.refreshChildren(of: ids)
        }
    }

    /// The group a newly mounted root should join: the one holding the current
    /// node's root, so "New X" lands beside what you were looking at. Nil when
    /// that root is at the top level.
    private func groupForNewRoot() -> UUID? {
        guard let focused = host.focusedNode,
              let root = rootContaining(focused) else { return nil }
        return workspaceStore.groupContaining(root.uri)
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
}
