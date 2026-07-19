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

    var body: some View {
        @Bindable var model = model
        // Two columns + a real trailing inspector. (A three-column split view makes
        // the *detail* column the flexible one, which handed the inspector all the
        // slack; `.inspector` keeps the canvas flexible and the inspector sized.)
        NavigationSplitView {
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
                        Button {
                            model.addFolder()
                        } label: {
                            Label("Add Folder", systemImage: "plus")
                        }
                        .help("Mount a folder as a root")
                    }
                }
        } detail: {
            VStack(spacing: 0) {
                TabStrip()
                Divider()
                CanvasPane()
            }
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
            ForEach(host.roots, id: \.self) { root in
                NodeRow(nodeID: root)
            }
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
                if host.roots.contains(targets[0]) {
                    // Inverse of mounting — removes the sidebar entry, not the node.
                    Button("Remove from Sidebar") { model.removeRoot(targets[0]) }
                }
                Divider()
            }
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
                                       description: Text("Add a folder to get started."))
            }
        }
    }
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
            Text(node?.label ?? nodeID.uri)
                .lineLimit(1)
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
