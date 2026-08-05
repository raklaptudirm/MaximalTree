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
            withAnimation {
                if zen {
                    inspectorVisibleBeforeZen = inspectorVisible
                    inspectorVisible = false
                    columnVisibility = .detailOnly
                } else {
                    inspectorVisible = inspectorVisibleBeforeZen
                    columnVisibility = .all
                }
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
    var body: some View {
        // The tree itself lives in SidebarTree.swift, computed from the pure
        // row model in SidebarModel.swift. No List: see those files for why.
        SidebarTree()
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
