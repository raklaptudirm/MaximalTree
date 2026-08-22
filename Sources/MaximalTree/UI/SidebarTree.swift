import SwiftUI
import AppKit
import MaximalTreeKit

// The sidebar's pixels. Deliberately NOT a List: the old implementation fought
// List for density (plain style + inset surgery), painted its own material over
// the native one (killing the column's collapse animation — AppKit-backed
// backgrounds snap instead of animating), mirrored the selection into local
// state with reconciliation in both directions (stutter), and still hit the
// engine's row-compositing bug (overlapping rows on animated insertion). This
// tree renders the flattened rows from SidebarModel in a LazyVStack: every
// behavior is explicit, selection has one source of truth (host.selection), and
// the native sidebar material — and its animations — are simply left alone.

struct SidebarTree: View {
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model

    private var rows: [SidebarRow] {
        SidebarRows.flatten(
            entries: model.rootLayout.entries,
            expandedNodes: model.sidebar.expandedNodes,
            graph: SidebarGraph(
                children: { host.children(of: $0) },
                isExpandable: { host.node($0)?.hasChildren ?? false },
                hasMore: { host.hasMoreChildren($0) }))
    }

    var body: some View {
        let rows = self.rows
        let ordered = rows.compactMap(\.nodeID)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        SidebarRowView(row: row, ordered: ordered)
                    }
                    // The one insertion point the row strips can't express: the
                    // very end of the top level.
                    InsertionStrip(container: nil,
                                   index: model.rootLayout.entries.count,
                                   minHeight: 8)
                }
                .padding(.vertical, 4)
            }
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                moveSelection(direction, ordered: ordered, rows: rows, proxy: proxy)
            }
        }
        .overlay {
            if host.roots.isEmpty {
                ContentUnavailableView("No Roots", systemImage: "tray",
                                       description: Text("Add a root to get started."))
            }
        }
    }

    /// Keyboard: ↑/↓ move the selection along the visible rows; ← collapses the
    /// selected node (or nothing); → expands it.
    private func moveSelection(_ direction: MoveCommandDirection,
                               ordered: [NodeID], rows: [SidebarRow],
                               proxy: ScrollViewProxy) {
        switch direction {
        case .up, .down:
            guard let next = SidebarSelection.afterArrow(
                down: direction == .down, ordered: ordered,
                selection: Set(host.selection)) else { return }
            model.sidebar.anchor = next
            host.select([next])
            host.open(next)
            proxy.scrollTo("n:\(next.uri)")
        case .left, .right:
            guard host.selection.count == 1, let id = host.selection.first,
                  case .node(_, _, let expandable, let expanded, _)? =
                    rows.first(where: { $0.nodeID == id }), expandable
            else { return }
            let wantOpen = direction == .right
            if expanded != wantOpen {
                withAnimation(.easeOut(duration: 0.15)) { model.sidebar.toggle(id) }
            }
        @unknown default:
            break
        }
    }
}

// MARK: - Rows

private struct SidebarRowView: View {
    let row: SidebarRow
    let ordered: [NodeID]

    var body: some View {
        switch row {
        case .node(let id, let depth, let expandable, let expanded, let entry):
            NodeRow(nodeID: id, depth: depth, expandable: expandable,
                    expanded: expanded, entry: entry, ordered: ordered)
        case .folder(let id, let name, let depth, let expanded, let entry):
            FolderRow(folderID: id, name: name, depth: depth,
                      expanded: expanded, entry: entry)
        case .more(let parent, let depth):
            MoreRow(parent: parent, depth: depth)
        }
    }
}

/// Shared row chrome: indentation, chevron, fixed height, selection background.
private struct RowChrome<Content: View>: View {
    let depth: Int
    let expandable: Bool
    let expanded: Bool
    let selected: Bool
    let toggle: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 4 + CGFloat(depth) * 13)
            Group {
                if expandable {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(selected ? .white : Color.secondary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                }
            }
            .frame(width: 12)
            content
            Spacer(minLength: 0)
        }
        .padding(.trailing, 8)
        .frame(height: 24)
        .contentShape(Rectangle())
        .background(selected ? Color(nsColor: .selectedContentBackgroundColor) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
    }
}

/// A node (root or descendant): selection, open-on-click, rename field, context
/// menu, drag out, drop in, and — for top-level roots — the reorder strip.
private struct NodeRow: View {
    let nodeID: NodeID
    let depth: Int
    let expandable: Bool
    let expanded: Bool
    let entry: SidebarRow.EntryPosition?
    let ordered: [NodeID]
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    private var selected: Bool { host.selection.contains(nodeID) }

    var body: some View {
        let node = host.node(nodeID)
        RowChrome(depth: depth, expandable: expandable, expanded: expanded,
                  selected: selected,
                  toggle: {
                      withAnimation(.easeOut(duration: 0.15)) { model.sidebar.toggle(nodeID) }
                  }) {
            NodeIconView(node?.icon)
            if host.pendingRename == nodeID {
                // The host-owned inline rename (see HostContext.beginRename):
                // Esc cancels, Return and focus loss commit.
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
        .onTapGesture { click() }
        .draggable(dragPayload)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(.horizontal, 8)
            }
        }
        .modifier(DropTargetModifier(
            enabled: expandable,
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
        .contextMenu { contextMenuItems }
        .overlay(alignment: .top) {
            if let entry {
                InsertionStrip(container: entry.container, index: entry.index)
            }
        }
        .id(row_id)
    }

    private var row_id: String { "n:\(nodeID.uri)" }

    /// One selection source of truth: compute the click's result, hand it to
    /// the host, and let rendering follow `host.selection`. Opening resolves
    /// phony nodes to their real ancestor; whatever the host settles on is
    /// what every row renders — no local mirror, no reconciliation.
    private func click() {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let (next, anchor) = SidebarSelection.afterClick(
            on: nodeID, ordered: ordered,
            selection: Set(host.selection),
            anchor: model.sidebar.anchor,
            command: flags.contains(.command),
            shift: flags.contains(.shift))
        model.sidebar.anchor = anchor
        host.select(Array(next))
        // A lone plain selection also drives the canvas, Finder-style;
        // multi-select only feeds actions.
        if next == [nodeID] { host.open(nodeID) }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        // Right-click inside the selection targets the whole selection;
        // outside it, just this row — the platform's menu semantics.
        let targets = selected && host.selection.count > 1 ? host.selection : [nodeID]
        if targets.count == 1 {
            Button("Open in New Tab") { model.openInNewTab(targets[0]) }
        }
        let rootTargets = targets.filter(host.roots.contains)
        if !rootTargets.isEmpty {
            MoveToFolderMenu(roots: rootTargets)
            if rootTargets.count == 1 {
                Button("Remove from Sidebar") { model.removeRoot(rootTargets[0]) }
            }
        }
        Divider()
        // Grouped by contributing plugin and ordered by how close each action
        // sits to this node; commands that act on the app or on some other
        // document don't belong on a node's menu at all.
        let groups = model.actionGroups(for: .contextMenu, targets: targets)
        if groups.isEmpty {
            Button("No Actions") {}.disabled(true)
        } else {
            ForEach(groups) { group in
                Section {
                    ForEach(group.actions) { action in
                        Button { model.run(action, targets: targets) } label: {
                            if let image = action.systemImage {
                                Label(action.title, systemImage: image)
                            } else {
                                Text(action.title)
                            }
                        }
                    }
                } header: {
                    if let title = group.title { Text(title) }
                }
            }
        }
    }

    private var dragPayload: String {
        let selection = host.selection
        let ids = selection.contains(nodeID) && selection.count > 1 ? selection : [nodeID]
        return ids.map(\.uri).joined(separator: "\n")
    }

    private func commitRename(of node: Node?) {
        host._setPendingRename(nil)
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != node?.label else { return }
        host.apply(.rename(nodeID, to: name))
    }
}

/// A workspace folder: expansion, rename/delete menu, drag (as an entry ref),
/// and dropping onto it nests the payload inside.
private struct FolderRow: View {
    let folderID: UUID
    let name: String
    let depth: Int
    let expanded: Bool
    let entry: SidebarRow.EntryPosition
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        RowChrome(depth: depth, expandable: true, expanded: expanded,
                  selected: false,
                  toggle: {
                      withAnimation(.easeOut(duration: 0.15)) {
                          model.setRootFolderExpanded(folderID, !expanded)
                      }
                  }) {
            Image(systemName: "folder.fill").foregroundStyle(.tint)
            Text(name).lineLimit(1)
        }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                model.setRootFolderExpanded(folderID, !expanded)
            }
        }
        .draggable(EntryRef.folder(folderID).token)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(.horizontal, 8)
            }
        }
        .dropDestination(for: String.self) { items, _ in
            let refs = model.entryRefs(from: items, roots: host.roots)
            guard !refs.isEmpty else { return false }
            model.moveEntries(refs, toFolder: folderID, at: nil)
            return true
        } isTargeted: { dropTargeted = $0 }
        .contextMenu {
            Button("Rename Folder…") { model.beginRenameFolder(folder) }
            Button("New Folder Inside") { model.beginCreateFolder(in: folderID) }
            Button("Delete Folder", role: .destructive) { model.deleteRootFolder(folderID) }
        }
        .overlay(alignment: .top) {
            InsertionStrip(container: entry.container, index: entry.index)
        }
    }

    private var folder: RootFolder {
        RootLayout.folderList(model.rootLayout.entries)
            .first { $0.folder.id == folderID }?.folder
            ?? RootFolder(id: folderID, name: name, entries: [], isExpanded: expanded)
    }
}

private struct MoreRow: View {
    let parent: NodeID
    let depth: Int
    @Environment(HostContext.self) private var host

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 4 + CGFloat(depth) * 13 + 16)
            Button {
                host.loadMoreChildren(of: parent)
            } label: {
                Label("More…", systemImage: "ellipsis")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .frame(height: 20)
        .padding(.horizontal, 8)
    }
}

/// "Move to Folder ▸ …" for root targets (shared by row context menus).
private struct MoveToFolderMenu: View {
    let roots: [NodeID]
    @Environment(AppModel.self) private var model

    var body: some View {
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

// MARK: - Drop helpers

/// A thin strip along a top-level row's top edge: dropping there inserts the
/// dragged entries before it (position-aware reorder). Invisible until hovered.
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
            .padding(.horizontal, 8)
            .dropDestination(for: String.self) { items, _ in
                let refs = model.entryRefs(from: items, roots: host.roots)
                guard !refs.isEmpty else { return false }
                model.moveEntries(refs, toFolder: container, at: index)
                return true
            } isTargeted: { targeted = $0 }
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
