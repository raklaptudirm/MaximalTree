import SwiftUI
import AppKit
@_spi(Host) import MaximalTreeKit

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

    /// The same rows the keyboard walks — asked of the model rather than
    /// flattened again here, so `j` and what is drawn cannot disagree.
    private var rows: [SidebarRow] { model.sidebarRows() }

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
                                   index: model.placements.children(of: model.sidebarRoot).count,
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
            // The tree, not the mounted roots: a workspace holding only
            // groups has no roots, and used to be told it was empty with the
            // groups drawn right there underneath the message.
            if model.placements.children(of: model.sidebarRoot).isEmpty {
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
            if let row = rows.first(where: { $0.nodeID == next }) { proxy.scrollTo(row.id) }
        case .left, .right:
            guard host.selection.count == 1, let id = host.selection.first,
                  case .node(_, _, let expandable, let expanded, _, _, _)? =
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
        case .node(let id, let depth, let expandable, let expanded, let entry, let rowID, let parent):
            NodeRow(nodeID: id, depth: depth, expandable: expandable,
                    expanded: expanded, entry: entry, ordered: ordered, rowID: rowID,
                    parent: parent)
        case .more(let parent, let depth, _):
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
    @Environment(AppModel.self) private var model

    /// A selection in the surface holding the keyboard is drawn in the accent
    /// colour; one in a surface that doesn't goes grey. Standard for every
    /// list on the platform, and here it is also the only thing that says
    /// where the keyboard is.
    private var emphasized: Bool { selected && model.focusedSurface == .sidebar }

    var body: some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 4 + CGFloat(depth) * 13)
            Group {
                if expandable {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(emphasized ? .white : Color.secondary)
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
        .background(selectionColor, in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(emphasized ? Color.white : Color.primary)
        .padding(.horizontal, 8)
    }

    private var selectionColor: Color {
        guard selected else { return .clear }
        return Color(nsColor: emphasized ? .selectedContentBackgroundColor
                                         : .unemphasizedSelectedContentBackgroundColor)
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
    /// Where this row is, which is more than which node it shows.
    let rowID: String
    /// What it was reached through, so it can be taken back out.
    let parent: NodeID?
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    private var selected: Bool { host.selection.contains(nodeID) }

    /// The collection this row is, if it is a group.
    private var group: UUID? { CollectionRef.id(from: nodeID.uri) }

    /// A group's name, for the moment before its node arrives — otherwise a
    /// new group is drawn as its raw URI until it is fetched. It is in the URI.
    private var groupName: String? { CollectionRef.name(from: nodeID.uri) }

    var body: some View {
        let node = host.node(nodeID)
        RowChrome(depth: depth, expandable: expandable, expanded: expanded,
                  selected: selected,
                  toggle: {
                      withAnimation(.easeOut(duration: 0.15)) { model.sidebar.toggle(nodeID) }
                  }) {
            NodeIconView(node?.icon ?? (group == nil ? nil : NodeIcon("square.stack", tint: .secondary)))
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
                Text(node?.label ?? groupName ?? nodeID.uri)
                    .lineLimit(1)
            }
        }
        .onTapGesture { click() }
        // Not `.draggable`: that has no moment when the drag starts, and a drop
        // needs to know where the rows came from to move them rather than add.
        .onDrag {
            let payload = dragPayload
            model.sidebar.drag = (payload.split(separator: "\n").map(String.init), parent)
            return NSItemProvider(object: payload as NSString)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(.horizontal, 8)
            }
        }
        .modifier(DropTargetModifier(
            // A group takes anything; any other node takes a drop only if it
            // contains things, or accepts them as members.
            enabled: group != nil || expandable || node?.accepts != nil,
            isTargeted: $dropTargeted,
            perform: { uris in
                if let group { return model.drop(uris, onto: group) }
                let ids = uris
                    .flatMap { $0.split(separator: "\n") }
                    .compactMap { NodeID(String($0)) }
                guard !ids.isEmpty else { return false }
                let mutation = SidebarDrop.mutation(dropping: ids, onto: nodeID,
                                                    accepts: node?.accepts)
                guard host.canApply(mutation) else { return false }
                host.apply(mutation)
                return true
            }))
        .contextMenu { contextMenuItems }
        .overlay(alignment: .top) {
            if let entry {
                InsertionStrip(container: entry.container, index: entry.index)
            }
        }
        .id(rowID)
    }

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
        // multi-select only feeds actions. Except a group: it has nothing to
        // draw in a pane, and replacing the tab you were reading with "No View"
        // on every click is not what clicking a group has ever done. It opens
        // and closes, the way a folder did.
        guard next == [nodeID] else { return }
        if group != nil, expandable {
            withAnimation(.easeOut(duration: 0.15)) { model.sidebar.toggle(nodeID) }
        } else if group == nil {
            host.open(nodeID)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        // Right-click inside the selection targets the whole selection;
        // outside it, just this row — the platform's menu semantics.
        let targets = selected && host.selection.count > 1 ? host.selection : [nodeID]
        if targets.count == 1 {
            Button("Open in New Tab") { model.openInNewTab(targets[0]) }
        }
        // Out of the collection this row is in — not every collection the
        // node belongs to, and never deleting it. The same channel can be in
        // three aggregators, and removing it from one leaves the other two.
        // Rows the sidebar arranges — at the top level, or in a group — can be
        // moved between places and taken out of the one they are in. A row
        // inside a folder on disk is the folder's, not the sidebar's.
        let inGroup = parent.flatMap { CollectionRef.id(from: $0.uri) } != nil
        if parent == nil || inGroup {
            MoveToCollectionMenu(targets: targets, parent: parent)
            AddToCollectionMenu(targets: targets)
        }
        if inGroup {
            Button("Remove from Collection") { model.remove(targets, from: parent) }
        } else if parent == nil {
            // For a collection that lives only here this deletes it, which is
            // what removing something that exists only in the sidebar means.
            Button("Remove from Sidebar") { model.remove(targets, from: nil) }
        }
        if let group {
            Button("New Collection Inside") { model.newCollection(in: group) }
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

/// "Add to Collection ▸ …" — every group, and a new one.
///
/// Adding rather than moving, for a row that is not the sidebar's to move: one
/// inside a channel's listing, a search result, a file in a folder. What you
/// were looking at stays where it is, and the collection gains a reference —
/// which is what a watch list is.
struct AddToCollectionMenu: View {
    let targets: [NodeID]
    @Environment(AppModel.self) private var model

    var body: some View {
        let moving = Set(targets.compactMap { CollectionRef.id(from: $0.uri) })
        Menu("Add to Collection") {
            ForEach(model.placements.collections(from: model.sidebarRoot, excluding: moving),
                    id: \.uri) { item in
                Button(String(repeating: "   ", count: item.depth)
                       + (CollectionRef.name(from: item.uri) ?? "")) {
                    model.addToCollection(targets, uri: item.uri)
                }
            }
            Divider()
            Button("New Collection…") { model.addToNewCollection(targets) }
        }
    }
}

/// "Move to Collection ▸ …" — every group, then the top level.
private struct MoveToCollectionMenu: View {
    let targets: [NodeID]
    let parent: NodeID?
    @Environment(AppModel.self) private var model

    var body: some View {
        let moving = Set(targets.compactMap { CollectionRef.id(from: $0.uri) })
        Menu("Move to Collection") {
            // Not the groups being moved, and nothing inside them — a group
            // cannot go into itself.
            ForEach(model.placements.collections(from: model.sidebarRoot, excluding: moving),
                    id: \.uri) { item in
                Button(String(repeating: "   ", count: item.depth)
                       + (CollectionRef.name(from: item.uri) ?? "")) {
                    model.move(targets, from: parent, to: CollectionRef.id(from: item.uri))
                }
            }
            Divider()
            Button("Top Level") { model.move(targets, from: parent, to: nil) }
            Button("New Collection…") { model.newCollection(movingIn: targets, from: parent) }
        }
    }
}

// MARK: - Drop helpers

/// A thin strip along a row's top edge, for any row the sidebar arranges:
/// dropping there puts the dragged rows before it, in the same place. Invisible
/// until hovered.
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
                model.drop(items, onto: container, at: index)
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
