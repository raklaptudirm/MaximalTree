import SwiftUI
import AppKit
import MaximalTreeKit

/// The three-pane shell: window, columns, and the chrome around them. All three
/// panes are generic and registry-driven — the sidebar walks `children(of:)`,
/// the canvas and inspector look up the focused node's renderer. None of them
/// know what a `file.directory` is.
///
/// The sidebar lives in SidebarTree.swift (computed rows, SidebarModel.swift),
/// and the tabs/splits/panes in PaneTree.swift (the arrangement layer).
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
            SidebarTree()
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
            if sections.isEmpty {
                ContentUnavailableView("No Inspector", systemImage: "sidebar.right")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            section.contribution.make(section.id, host)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("No Inspector", systemImage: "sidebar.right")
        }
    }
}
