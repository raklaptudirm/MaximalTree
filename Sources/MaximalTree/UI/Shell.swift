import SwiftUI
import AppKit
import MaximalTreeKit

/// The three-pane shell. All three panes are generic and registry-driven: the
/// sidebar walks `children(of:)`, the canvas and inspector look up the focused
/// node's `TypeRenderer`. None of them know what a `file.directory` is.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(HostContext.self) private var host
    @State private var inspectorVisible = true
    @State private var workspaceNameDraft = ""
    @State private var folderNameDraft = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// The inspector state to restore when zen mode ends.
    @State private var inspectorVisibleBeforeZen = true
    /// The hosting window, for zen title-bar styling.
    @State private var window: NSWindow?

    var body: some View {
        @Bindable var model = model
        // Two columns + a real trailing inspector. (A three-column split view makes
        // the *detail* column the flexible one, which handed the inspector all the
        // slack; `.inspector` keeps the canvas flexible and the inspector sized.)
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ExplorerSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
                .toolbar {
                    ToolbarItem {
                        Menu {
                            WorkspaceMenuItems(model: model, showShortcuts: false)
                        } label: {
                            Label(model.activeWorkspaceName, systemImage: "square.stack.3d.up")
                        }
                        .help("Switch workspace")
                    }
                    ToolbarItem {
                        Menu {
                            Button {
                                model.addFolder()
                            } label: {
                                Label("Add Root…", systemImage: "externaldrive.badge.plus")
                            }
                            Button {
                                model.beginCreateFolder()
                            } label: {
                                Label("New Folder", systemImage: "folder.badge.plus")
                            }
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                        .help("Mount a root, or add an organizing folder")
                    }
                }
        } detail: {
            VStack(spacing: 0) {
                if !host.isZenMode {
                    TabStrip()
                    Divider()
                }
                CanvasPane()
            }
            // Zen: without this the hidden title bar leaves a 52pt dead strip —
            // SwiftUI keeps laying the canvas out below the top safe area.
            .ignoresSafeArea(.container, edges: host.isZenMode ? .top : [])
            .inspector(isPresented: $inspectorVisible) {
                InspectorPane()
                    .inspectorColumnWidth(min: 200, ideal: 260, max: 420)
            }
            .toolbar {
                ToolbarItem {
                    Button { inspectorVisible.toggle() } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    .help("Toggle inspector")
                }
            }
        }
        // The window title belongs to the workspace; the focused node rides in the
        // subtitle. Plugin canvases must not set navigationTitle (see HACKING.md).
        .navigationTitle(model.activeWorkspaceName)
        .navigationSubtitle(host.focusedNode.flatMap { host.node($0)?.label } ?? "")
        // Zen: the canvas, alone. Collapse both side panes and the toolbar;
        // restore the inspector to how the user had it on the way out.
        .toolbar(host.isZenMode ? .hidden : .automatic, for: .windowToolbar)
        .background(WindowAccessor { window = $0 })
        .onChange(of: host.isZenMode) { _, zen in
            if zen {
                inspectorVisibleBeforeZen = inspectorVisible
                inspectorVisible = false
                columnVisibility = .detailOnly
            } else {
                inspectorVisible = inspectorVisibleBeforeZen
                columnVisibility = .all
            }
            // The empty title bar would linger as a dead strip. Extending
            // content beneath it invites this OS's scroll-edge glass instead
            // (a blurred band) — so don't: keep content below, and make the
            // title-bar area *blend* — transparent, no separator, no toolbar,
            // window background matching the canvas. It reads as padding.
            if let window {
                window.titleVisibility = zen ? .hidden : .visible
                window.titlebarAppearsTransparent = zen
                window.titlebarSeparatorStyle = zen ? .none : .automatic
                window.toolbar?.isVisible = !zen
                window.backgroundColor = zen ? .textBackgroundColor : .windowBackgroundColor
            }
        }
        .alert("New Workspace", isPresented: $model.showingCreateWorkspace) {
            TextField("Name", text: $workspaceNameDraft)
            Button("Create") { model.createWorkspace(named: workspaceNameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Workspace", isPresented: $model.showingRenameWorkspace) {
            TextField("Name", text: $workspaceNameDraft)
            Button("Rename") { model.renameActiveWorkspace(to: workspaceNameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(model.pendingFolderRename == nil ? "New Folder" : "Rename Folder",
               isPresented: $model.showingFolderPrompt) {
            TextField("Name", text: $folderNameDraft)
            Button(model.pendingFolderRename == nil ? "Create" : "Rename") {
                model.commitFolderPrompt(name: folderNameDraft)
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: model.showingFolderPrompt) { _, showing in
            if showing { folderNameDraft = model.pendingFolderRename?.name ?? "" }
        }
        .onChange(of: model.showingCreateWorkspace) { _, showing in
            if showing { workspaceNameDraft = "" }
        }
        .onChange(of: model.showingRenameWorkspace) { _, showing in
            if showing { workspaceNameDraft = model.activeWorkspaceName }
        }
        .overlay {
            if model.paletteVisible {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .onTapGesture { model.paletteVisible = false }
                    CommandPalette()
                        .padding(.top, 90)
                }
            }
        }
    }
}

// MARK: - Left: explorer

struct ExplorerSidebar: View {
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model
    @State private var selection: Set<NodeID> = []

    var body: some View {
        // Native list selection rather than a hand-rolled highlight: it brings the
        // real macOS look, full-row hit testing, keyboard arrow navigation, and
        // multi-select (which the Action predicates already support).
        List(selection: $selection) {
            // Native disclosure nesting (auto-indent, dense rows); each row carries
            // a thin top-edge insertion strip for position-aware drops, and folder
            // rows accept drops to nest.
            ForEach(Array(model.rootLayout.entries.enumerated()), id: \.element.id) { index, entry in
                RootEntryRow(entry: entry, container: nil, index: index)
            }
            // The one insertion point the strips can't express: the very end of
            // the top level.
            InsertionStrip(container: nil, index: model.rootLayout.entries.count, minHeight: 8)
        }
        // .sidebar enforces roomy source-list row metrics that neither
        // defaultMinListRowHeight (only a floor) nor row insets can shrink — the row
        // height simply isn't content-driven. .plain lets rows size to their content,
        // which is what actually closes the gaps.
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 18)
        // …but .plain also paints an opaque content background, so the sidebar stopped
        // reading as a sidebar. Drop that and put the real vibrant material back, which
        // buys the density of .plain and the look of .sidebar.
        .scrollContentBackground(.hidden)
        // ignoresSafeArea so the material runs *under* the toolbar. Without it the
        // background stops at the safe area and the toolbar strip reads as a bare
        // transparent bar behind the buttons; the scroll-edge gradient needs material
        // beneath it to fade into.
        .background(SidebarMaterial().ignoresSafeArea())
        // List-level rather than per-row: SwiftUI hands us exactly the rows the menu
        // applies to, and gives the native semantics for free (right-clicking outside
        // the selection targets just that row; inside it targets the whole selection).
        .contextMenu(forSelectionType: NodeID.self) { items in
            let targets = Array(items)
            if targets.count == 1 {
                Button("Open in New Tab") { model.openInNewTab(targets[0]) }
            }
            // Roots can be organized into folders. (Only whole roots — a folder
            // groups roots, not their descendants.)
            let rootTargets = targets.filter(host.roots.contains)
            if !rootTargets.isEmpty {
                moveToFolderMenu(for: rootTargets)
                if rootTargets.count == 1 {
                    Button("Remove from Sidebar") { model.removeRoot(rootTargets[0]) }
                }
            }
            Divider()
            let actions = model.applicableActions(for: targets)
            if actions.isEmpty {
                Button("No Actions") {}.disabled(true)
            } else {
                ForEach(actions) { action in
                    Button { model.run(action, targets: targets) } label: {
                        if let image = action.systemImage {
                            Label(action.title, systemImage: image)
                        } else {
                            Text(action.title)
                        }
                    }
                }
            }
        }
        .onChange(of: selection) { _, newValue in
            host.select(Array(newValue))
            // A lone selection also drives the canvas, Finder-style. Multi-select
            // only feeds actions — it deliberately leaves the canvas alone.
            if newValue.count == 1, let id = newValue.first, id != host.focusedNode {
                host.open(id)
            }
            // `open` resolves phony nodes to their real ancestor synchronously
            // when cached. If the ancestor was already selected, host.selection
            // ends where it started — no net change, so the observation below
            // never fires. Reconcile directly.
            let resolved = Set(host.selection)
            if !resolved.isEmpty, resolved != newValue, selection != resolved {
                selection = resolved
            }
        }
        .onChange(of: host.selection) { _, newValue in
            // The host is authoritative: every focus move (tab switch,
            // back/forward, Related links) rewrites the selection, and opening
            // a phony node resolves it to the real ancestor — even when focus
            // didn't change because that ancestor was already open. Mirror it.
            if selection != Set(newValue) { selection = Set(newValue) }
        }
        .overlay {
            if host.roots.isEmpty {
                ContentUnavailableView("No Roots", systemImage: "tray",
                                       description: Text("Add a root to get started."))
            }
        }
    }

    /// "Move to Folder ▸ {nested folders} / Top Level / New Folder…" for roots.
    @ViewBuilder
    private func moveToFolderMenu(for roots: [NodeID]) -> some View {
        let refs = roots.map { EntryRef.root($0.uri) }
        Menu("Move to Folder") {
            ForEach(RootLayout.folderList(model.rootLayout.entries), id: \.folder.id) { item in
                Button(String(repeating: "   ", count: item.depth) + item.folder.name) {
                    model.moveEntries(refs, toFolder: item.folder.id)
                }
            }
            Divider()
            Button("Top Level") { model.moveEntries(refs, toFolder: nil) }
            Button("New Folder…") { model.beginCreateFolder(movingIn: roots.map(\.uri)) }
        }
    }
}

// MARK: - Root organization rows

/// One entry in the sidebar's folder tree: a root (a `NodeRow`) or a folder
/// (a nesting `DisclosureGroup`). `container`/`index` locate it for the
/// insertion strip that overlays its top edge — dropping there reorders.
private struct RootEntryRow: View {
    let entry: RootEntry
    let container: UUID?
    let index: Int

    var body: some View {
        switch entry {
        case .root(let uri):
            if let id = NodeID(uri) {
                NodeRow(nodeID: id)
                    .overlay(alignment: .top) { InsertionStrip(container: container, index: index) }
            }
        case .folder(let folder):
            RootFolderRow(folder: folder, container: container, index: index)
        }
    }
}

/// A folder as a native `DisclosureGroup` (auto-indent, matches node rows).
/// Draggable (to nest/reorder) and a drop target — dropping *onto* the label
/// nests the payload inside. Host-side organization; no node, no provider.
struct RootFolderRow: View {
    let folder: RootFolder
    let container: UUID?
    let index: Int
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { folder.isExpanded },
            set: { model.setRootFolderExpanded(folder.id, $0) }
        )) {
            ForEach(Array(folder.entries.enumerated()), id: \.element.id) { childIndex, child in
                RootEntryRow(entry: child, container: folder.id, index: childIndex)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").foregroundStyle(.tint)
                Text(folder.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(dropTargeted ? Color.accentColor.opacity(0.25) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .top) { InsertionStrip(container: container, index: index) }
            .draggable(EntryRef.folder(folder.id).token)
            .contextMenu {
                Button("Rename Folder…") { model.beginRenameFolder(folder) }
                Button("New Folder Inside") { model.beginCreateFolder(in: folder.id) }
                Button("Delete Folder", role: .destructive) { model.deleteRootFolder(folder.id) }
            }
            // Dropping onto the label nests the payload inside (at the end).
            .dropDestination(for: String.self) { items, _ in
                let refs = model.entryRefs(from: items, roots: host.roots)
                guard !refs.isEmpty else { return false }
                model.moveEntries(refs, toFolder: folder.id, at: nil)
                return true
            } isTargeted: { dropTargeted = $0 }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
    }
}

/// A thin drop strip along a row's top edge: dropping here inserts the dragged
/// entries *before* that row (position-aware reorder). Invisible until hovered;
/// overlaid so it wins the top few points without adding a row.
private struct InsertionStrip: View {
    let container: UUID?
    let index: Int
    var minHeight: CGFloat = 4
    @Environment(AppModel.self) private var model
    @Environment(HostContext.self) private var host
    @State private var targeted = false

    var body: some View {
        Rectangle()
            .fill(targeted ? Color.accentColor : Color.clear)
            .frame(height: targeted ? max(minHeight, 3) : minHeight)
            .dropDestination(for: String.self) { items, _ in
                let refs = model.entryRefs(from: items, roots: host.roots)
                guard !refs.isEmpty else { return false }
                model.moveEntries(refs, toFolder: container, at: index)
                return true
            } isTargeted: { targeted = $0 }
            // No-ops when overlaid; matter when the strip is a standalone row
            // (the top-level trailing drop zone).
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .listRowSeparator(.hidden)
    }
}

/// Hands the hosting `NSWindow` to SwiftUI once it exists — for window-level
/// styling SwiftUI doesn't expose (zen's title-bar dissolve).
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The genuine macOS sidebar vibrancy. `.listStyle(.sidebar)` supplies this for free
/// but forces roomy rows with it; since we need `.plain` for density, we paint the
/// material ourselves.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// One recursive sidebar entry. Containment only — walks `children(of:)`.
struct NodeRow: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @State private var dropTargeted = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        let node = host.node(nodeID)
        Group {
            if node?.hasChildren == true {
                // Known beta-OS glitch: animated row insertion in this customized
                // List occasionally composites a row at a stale offset, overlapping
                // a neighbour. Disabling the disclosure animation fixes it, but the
                // animation is worth more than the rare artifact — revisit when the
                // OS stabilizes (or if the sidebar ever moves off List).
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(host.children(of: nodeID), id: \.self) { child in
                        NodeRow(nodeID: child)
                    }
                    if host.hasMoreChildren(nodeID) {
                        Button {
                            host.loadMoreChildren(of: nodeID)
                        } label: {
                            Label("More…", systemImage: "ellipsis")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } label: {
                    rowLabel(node)
                }
            } else {
                rowLabel(node)
            }
        }
        .tag(nodeID)                      // what List(selection:) selects
        // Vertical insets zeroed for density; horizontal kept so the root disclosure
        // triangle isn't jammed against the edge. (DisclosureGroup adds the hierarchy
        // indent on top of this, so nesting still reads.)
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)        // .plain draws separators; a tree wants none
    }

    @ViewBuilder
    private func rowLabel(_ node: Node?) -> some View {
        // Items stay their normal size — it's the row gap we're closing, not the
        // content. No manual highlight or tap handling either: List(selection:)
        // draws the selection and hit-tests the whole row.
        HStack(spacing: 5) {
            // Icon and label come from the owning plugin — the host knows nothing
            // about what kind of thing this node is.
            NodeIconView(node?.icon)
            if host.pendingRename == nodeID {
                // The host-owned inline rename. Any provider supporting `.rename`
                // lands here — the row swaps its label for a text field, and the
                // committed name goes through the same mutation funnel as
                // drag-and-drop moves. Esc cancels; focus loss commits (the
                // platform's text-field convention, and Finder's).
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onAppear {
                        renameDraft = node?.label ?? ""
                        renameFocused = true
                    }
                    .onSubmit { commitRename(of: node) }
                    .onExitCommand { host._setPendingRename(nil) }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused, host.pendingRename == nodeID { commitRename(of: node) }
                    }
            } else {
                Text(node?.label ?? nodeID.uri)
                    .lineLimit(1)
            }
        }
        // Tree drag-and-drop → the generic `.move` mutation. Dragging a row in
        // the current multi-selection drags the whole selection (newline-joined
        // URIs); container-ish rows (hasChildren — the host's only generic
        // containment signal) accept drops, and the owning provider validates
        // the actual move via `canApply`.
        .draggable(dragPayload)
        .background(dropTargeted ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .modifier(DropTargetModifier(
            enabled: node?.hasChildren == true,
            isTargeted: $dropTargeted,
            perform: { uris in
                let ids = uris
                    .flatMap { $0.split(separator: "\n") }
                    .compactMap { NodeID(String($0)) }
                let mutation = GraphMutation.move(ids, into: nodeID)
                guard !ids.isEmpty, host.canApply(mutation) else { return false }
                host.apply(mutation)
                return true
            }))
    }

    private var dragPayload: String {
        let selection = host.selection
        let ids = selection.contains(nodeID) && selection.count > 1 ? selection : [nodeID]
        return ids.map(\.uri).joined(separator: "\n")
    }

    /// End the inline edit and apply the result. Clearing `pendingRename` first
    /// makes this idempotent: submit resigns focus, and the focus-loss observer
    /// must find nothing left to commit.
    private func commitRename(of node: Node?) {
        host._setPendingRename(nil)
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != node?.label else { return }
        host.apply(.rename(nodeID, to: name))
    }
}

/// Attaches a String drop target only when `enabled` — files shouldn't light up
/// as drop zones, and SwiftUI has no conditional-modifier form of
/// `dropDestination` short of this.
private struct DropTargetModifier: ViewModifier {
    let enabled: Bool
    @Binding var isTargeted: Bool
    let perform: ([String]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: String.self) { items, _ in
                perform(items)
            } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
    }
}

// MARK: - Tab strip (top of the canvas column)

struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(HostContext.self) private var host

    var body: some View {
        let nav = model.navigation
        HStack(spacing: 6) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!nav.canGoBack)
                .help("Back")
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!nav.canGoForward)
                .help("Forward")

            Divider().frame(height: 16)

            // A horizontal ScrollView will happily take every point of vertical space
            // it's offered — pin it, or the strip eats the canvas.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(nav.tabs.enumerated()), id: \.element.id) { i, tab in
                        TabChip(title: title(of: tab),
                                active: i == nav.activeIndex,
                                closable: nav.tabs.count > 1,
                                select: { model.selectTab(i) },
                                close: { model.closeTab(tab.id) })
                    }
                }
            }
            .frame(height: 22)

            Spacer(minLength: 0)

            Button { model.splitPaneRight() } label: { Image(systemName: "rectangle.split.2x1") }
                .help("Split Right")
            Button { model.splitPaneDown() } label: { Image(systemName: "rectangle.split.1x2") }
                .help("Split Down")
            if model.navigation.canClosePane {
                Button { model.closeActivePane() } label: { Image(systemName: "xmark.rectangle") }
                    .help("Close Pane")
            }

            Divider().frame(height: 16)

            Button { model.newTab() } label: { Image(systemName: "plus") }
                .help("New Tab")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .fixedSize(horizontal: false, vertical: true)   // never grow vertically
    }

    private func title(of tab: NavigationModel.Tab) -> String {
        tab.current.flatMap { host.node($0)?.label } ?? "New Tab"
    }
}

private struct TabChip: View {
    let title: String
    let active: Bool
    let closable: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1).font(.callout)
            if closable {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: 170)
        .background(active ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

// MARK: - Center: canvas

/// The canvas area: the active tab's split tree, rendered recursively. Each leaf is
/// an independent pane with its own history; the active pane is what the sidebar,
/// inspector, and window subtitle follow.
struct CanvasPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SplitTreeView(node: model.navigation.activeTab.root)
            // The canvas must be the flexible one: without this the VStack has no
            // child that expands, so it sizes to content and centres everything —
            // which looks like the tab strip claiming half the pane.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A canvas is arbitrary plugin SwiftUI, and AppKit-backed ones don't
            // respect the SwiftUI frame on their own (a plugin's scroll view happily
            // painted its line-number gutter up over the tab strip). Containment is
            // the host's job: no plugin gets to draw on host chrome.
            .clipped()
    }
}

/// Recursive renderer for the split tree.
struct SplitTreeView: View {
    let node: SplitNode

    var body: some View {
        switch node {
        case .pane(let pane):
            PaneView(pane: pane)
        case .split(let id, let horizontal, let fraction, let first, let second):
            SplitContainer(id: id, horizontal: horizontal, fraction: fraction,
                           first: first, second: second)
        }
    }
}

/// A hand-rolled splitter instead of HSplitView/VSplitView: those legacy containers
/// ignore the column's bounds/safe areas on current macOS and slid panes underneath
/// the floating sidebar and inspector. Sizing each side as a fraction of the
/// *measured* container makes overflow structurally impossible.
private struct SplitContainer: View {
    let id: UUID
    let horizontal: Bool
    let fraction: Double
    let first: SplitNode
    let second: SplitNode
    @Environment(AppModel.self) private var model

    private let handleThickness: CGFloat = 7
    private let minPane: CGFloat = 100

    var body: some View {
        GeometryReader { geo in
            let total = horizontal ? geo.size.width : geo.size.height
            let available = max(total - handleThickness, 1)
            let firstLength = min(max(available * CGFloat(fraction), minPane),
                                  max(available - minPane, minPane))

            Group {
                if horizontal {
                    HStack(spacing: 0) {
                        SplitTreeView(node: first).frame(width: firstLength)
                        handle(available: available)
                        SplitTreeView(node: second).frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        SplitTreeView(node: first).frame(height: firstLength)
                        handle(available: available)
                        SplitTreeView(node: second).frame(maxHeight: .infinity)
                    }
                }
            }
            .coordinateSpace(name: id)      // drag locations resolve against this split
        }
    }

    /// The divider: a 1pt line inside a wider invisible grab area.
    private func handle(available: CGFloat) -> some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
        }
        .frame(width: horizontal ? handleThickness : nil,
               height: horizontal ? nil : handleThickness)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(id))
                .onChanged { value in
                    let position = horizontal ? value.location.x : value.location.y
                    let fraction = Double((position - handleThickness / 2) / available)
                    model.navigation.setSplitFraction(id, to: fraction)
                }
        )
        .onTapGesture(count: 2) { model.navigation.setSplitFraction(id, to: 0.5) }
    }
}

/// One leaf of the split tree: the canvas for this pane's current node, plus the
/// active-pane affordances.
struct PaneView: View {
    let pane: Pane
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model

    private var isActive: Bool { model.navigation.activePane?.id == pane.id }
    private var isMultiPane: Bool { model.navigation.canClosePane }

    var body: some View {
        // No minWidth/minHeight here: a hard minimum would let panes overflow the
        // column again in tight layouts. Minimum sizes are enforced by the divider
        // clamp in SplitContainer instead.
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()                       // same containment guarantee, per pane
            .overlay {
                if isMultiPane && isActive {
                    Rectangle()
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // Click-to-activate for inactive panes. An overlay (which consumes
                // that first click) rather than a pass-through gesture, because
                // AppKit-backed canvases (editor, Quick Look) swallow SwiftUI
                // gestures — a simultaneous gesture would never fire over them.
                if isMultiPane && !isActive {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.activatePane(pane.id) }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let id = pane.current {
            if let node = host.node(id), let canvas = model.store?.canvas(for: node) {
                PreparedCanvas(node: id, canvas: canvas)
            } else {
                ContentUnavailableView("Loading…", systemImage: "hourglass")
            }
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "square.dashed",
                                   description: Text("Pick something in the sidebar."))
        }
    }
}

/// Runs a canvas's async `prepare` (off the main actor) before building its view,
/// so slow openings — first-use warmups, big file reads — never stall the app.
/// The progress indicator only appears when preparation actually takes a moment;
/// warm switches render without a flash.
private struct PreparedCanvas: View {
    let node: NodeID
    let canvas: CanvasContribution
    @Environment(HostContext.self) private var host

    @State private var readyNode: NodeID?
    @State private var showsProgress = false

    var body: some View {
        Group {
            if canvas.prepare == nil || readyNode == node {
                canvas.make(node, host)
            } else if showsProgress {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Opening…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .task(id: node) {
            guard let prepare = canvas.prepare, readyNode != node else { return }
            let delayedSpinner = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                showsProgress = true
            }
            await prepare(node)   // @Sendable nonisolated: runs off the main actor
            delayedSpinner.cancel()
            showsProgress = false
            readyNode = node
        }
    }
}

// MARK: - Right: inspector

struct InspectorPane: View {
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model

    /// A single selected node wins over the focused one — selecting an item inside a
    /// canvas (Finder-style click) should inspect that item, not its container.
    private var subject: NodeID? {
        host.selection.count == 1 ? host.selection[0] : host.focusedNode
    }

    var body: some View {
        if let id = subject, let node = host.node(id) {
            let sections = model.store?.inspectors(for: node) ?? []
            let actions = model.applicableActions()
            if sections.isEmpty && actions.isEmpty {
                ContentUnavailableView("No Inspector", systemImage: "sidebar.right")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            section.make(id, host)
                        }
                        // Host-provided: what you can *do* with this node belongs next
                        // to what it *is*.
                        if !actions.isEmpty {
                            Form {
                                Section("Actions") {
                                    ForEach(actions) { action in
                                        Button { model.run(action) } label: {
                                            if let image = action.systemImage {
                                                Label(action.title, systemImage: image)
                                            } else {
                                                Text(action.title)
                                            }
                                        }
                                    }
                                }
                            }
                            .formStyle(.grouped)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("No Inspector", systemImage: "sidebar.right")
        }
    }
}
