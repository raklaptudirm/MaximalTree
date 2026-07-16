import SwiftUI
import AppKit
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
            VStack(spacing: 0) {
                TabStrip()
                Divider()
                CanvasPane()
            }
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
    @Environment(AppModel.self) private var model
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
            // Icon and label come from the owning plugin — the host knows nothing
            // about what kind of thing this node is.
            NodeIconView(node?.icon)
            Text(node?.label ?? nodeID.uri)
                .lineLimit(1)
        }
        .fontWeight(isFocused ? .semibold : .regular)
        .contentShape(Rectangle())
        .onTapGesture {
            // ⌘-click opens in a new tab, like a browser.
            if NSEvent.modifierFlags.contains(.command) {
                model.openInNewTab(nodeID)
            } else {
                host.open(nodeID)
            }
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

            Spacer(minLength: 0)

            Button { model.newTab() } label: { Image(systemName: "plus") }
                .help("New Tab")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
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
}

// MARK: - Right: inspector

struct InspectorPane: View {
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = host.focusedNode, let node = host.node(id) {
            let sections = model.store?.inspectors(for: node) ?? []
            if sections.isEmpty {
                ContentUnavailableView("No Inspector", systemImage: "sidebar.right")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                            section.make(id, host)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("No Inspector", systemImage: "sidebar.right")
        }
    }
}
