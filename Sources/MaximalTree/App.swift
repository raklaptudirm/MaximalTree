import SwiftUI
import AppKit
import MaximalTreeKit

@main
struct MaximalTreeApp: App {
    @State private var model = AppModel(host: HostContext())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model.host)
                .environment(model)
                .task {
                    model.start()
                    // Debug hook: MAXIMALTREE_ZEN=1 boots straight into zen so
                    // window-chrome issues can be inspected from the CLI.
                    if ProcessInfo.processInfo.environment["MAXIMALTREE_ZEN"] == "1" {
                        try? await Task.sleep(for: .seconds(1))
                        model.toggleZenMode()
                    }
                }
        }
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
    private let pluginHost = PluginHost()
    private let workspaceStore = WorkspaceStore()
    private(set) var store: GraphStore?

    /// Whether the command palette overlay is showing.
    var paletteVisible = false
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

    init(host: HostContext) { self.host = host }

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
            restoreRevealedNodesFromDisk()
            return
        }
        sidebar.restore(session.sidebar)
        store?.restoreNavigation(session.navigation)
    }

    /// Put the sidebar's disclosure back the way the active workspace last had
    /// it. Uris that no longer resolve are simply dropped — an expanded node
    /// that's gone has nothing to disclose.
    private func restoreRevealedNodesFromDisk() {
        let revealed = Set(workspaceStore.active.revealedNodes.compactMap(NodeID.init))
        sidebar.restore(SidebarState.Snapshot(expandedNodes: revealed, anchor: nil))
    }

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

    /// Actions (from any plugin) that apply to `targets`, defaulting to the current
    /// selection. One registry feeds the menu bar, the palette, the sidebar context
    /// menu, and the inspector.
    func applicableActions(for targets: [NodeID]? = nil) -> [Action] {
        guard let store else { return [] }
        let ctx = ActionContext(host: host, targets: targets)
        return store.actions.filter { $0.appliesTo.matches(ctx) }
    }

    func run(_ action: Action, targets: [NodeID]? = nil) {
        action.handler(ActionContext(host: host, targets: targets))
        paletteVisible = false
    }

    /// Actions the host contributes itself — node manipulation that belongs to no
    /// plugin because it rides the generic mutation vocabulary. Rename is the
    /// model case: any provider that supports `.rename` (filesystem today,
    /// bookmarks or branches tomorrow) gets the sidebar's inline-rename UI, the
    /// menu item, the shortcut, and the palette entry without writing any UI.
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
        // Under XCTest the test bundle compiles the plugin's sources directly; don't
        // also dlopen the .bundle into the same process, or the @objc principal class
        // collides. Tests exercise provider logic without the running host.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !underTest { pluginHost.loadAll() }
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
