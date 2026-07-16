import SwiftUI
import AppKit
import MaximalTreeKit

/// The three-pane shell. All three panes are generic and registry-driven: the
/// sidebar walks `children(of:)`, the canvas and inspector look up the focused
/// node's `TypeRenderer`. None of them know what a `file.directory` is.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var inspectorVisible = true

    var body: some View {
        // Two columns + a real trailing inspector. (A three-column split view makes
        // the *detail* column the flexible one, which handed the inspector all the
        // slack; `.inspector` keeps the canvas flexible and the inspector sized.)
        NavigationSplitView {
            ExplorerSidebar()
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
                .toolbar {
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
        .navigationTitle("MaximalTree")
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
        }
        .onChange(of: host.focusedNode) { _, newValue in
            // Keep the list in step when focus moves from somewhere else: a tab
            // switch, back/forward, or following a Related link.
            if let newValue, selection != [newValue] { selection = [newValue] }
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

struct CanvasPane: View {
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let id = host.focusedNode {
                if let node = host.node(id), let canvas = model.store?.canvas(for: node) {
                    canvas.make(id, host)
                } else {
                    ContentUnavailableView("Loading…", systemImage: "hourglass")
                }
            } else {
                ContentUnavailableView("Nothing Selected", systemImage: "square.dashed",
                                       description: Text("Pick something in the sidebar."))
            }
        }
        // The canvas must be the flexible one: without this the VStack has no child
        // that expands, so it sizes to content and centres everything — which looks
        // like the tab strip claiming half the pane.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A canvas is arbitrary plugin SwiftUI, and AppKit-backed ones don't respect
        // the SwiftUI frame on their own (a plugin's scroll view happily painted its
        // line-number gutter up over the tab strip). Containment is the host's job:
        // no plugin gets to draw on host chrome.
        .clipped()
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
