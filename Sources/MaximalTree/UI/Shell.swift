import SwiftUI
import MaximalTreeKit

/// The three-pane shell. All three panes are generic and registry-driven: the
/// sidebar walks `children(of:)`, the canvas and inspector look up the focused
/// node's `TypeRenderer`. None of them know what a `file.directory` is.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            ExplorerSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
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
        } content: {
            CanvasPane()
                .navigationSplitViewColumnWidth(min: 340, ideal: 560)
        } detail: {
            InspectorPane()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
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

    var body: some View {
        List {
            ForEach(host.roots, id: \.self) { root in
                NodeRow(nodeID: root)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if host.roots.isEmpty {
                ContentUnavailableView("No Roots", systemImage: "tray",
                                       description: Text("Add a folder to get started."))
            }
        }
    }
}

/// One recursive sidebar entry. Containment only — walks `children(of:)`.
struct NodeRow: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    @State private var expanded = false

    var body: some View {
        let node = host.node(nodeID)
        if node?.hasChildren == true {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(host.children(of: nodeID), id: \.self) { child in
                    NodeRow(nodeID: child)
                }
            } label: {
                rowLabel(node)
            }
        } else {
            rowLabel(node)
        }
    }

    @ViewBuilder
    private func rowLabel(_ node: Node?) -> some View {
        let isFocused = host.focusedNode == nodeID
        HStack(spacing: 6) {
            Image(systemName: node?.type == TypeID("file.directory") ? "folder.fill" : "doc")
                .foregroundStyle(.tint)
            Text(node?.displayName ?? nodeID.uri)
                .lineLimit(1)
        }
        .fontWeight(isFocused ? .semibold : .regular)
        .contentShape(Rectangle())
        .onTapGesture { host.open(nodeID) }
    }
}

// MARK: - Center: canvas

struct CanvasPane: View {
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = host.focusedNode {
            if let node = host.node(id), let renderer = model.store?.renderer(for: node.type) {
                renderer.canvas(id, host)
            } else {
                ContentUnavailableView("Loading…", systemImage: "hourglass")
            }
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "square.dashed",
                                   description: Text("Pick something in the sidebar."))
        }
    }
}

// MARK: - Right: inspector

struct InspectorPane: View {
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = host.focusedNode,
           let node = host.node(id),
           let renderer = model.store?.renderer(for: node.type) {
            renderer.inspector(id, host)
        } else {
            ContentUnavailableView("No Inspector", systemImage: "sidebar.right")
        }
    }
}
