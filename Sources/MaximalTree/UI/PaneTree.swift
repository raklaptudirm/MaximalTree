import SwiftUI
import AppKit
import MaximalTreeKit

// The arrangement layer: tabs, the split tree, panes, and the canvas each pane
// hosts. This is a window manager whose windows aren't OS windows — tiling,
// focus, and session state for views of nodes rather than for surfaces.
//
// Kept apart from Shell.swift deliberately. Everything here duplicates work a
// compositor already does, and does it only because the WM's unit is a surface
// while ours is a view of a typed object: no window manager can know that this
// preview belongs to that buffer. That makes this the one part of the UI with
// a real owner above us — if the platform ever grows fine-grained tiling, this
// is the file that gets deleted. The node/provider semantics next door never
// will be.
//
// The model behind it (NavigationModel: tabs, split tree, per-pane history) is
// likewise free of node semantics — it deals in NodeID and nothing else.

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
                                provisional: !tab.isPinned,
                                active: i == nav.activeIndex,
                                closable: nav.tabs.count > 1,
                                select: { model.selectTab(i) },
                                close: { model.closeTab(tab.id) })
                    }
                }
            }
            .frame(height: 22)

            Spacer(minLength: 0)

            // Status, not a control — so it sits ahead of the buttons, with a
            // rule between. In the strip rather than the toolbar because an
            // NSToolbar item wraps arbitrary content in a glass container it
            // won't size to, and the label spilled out of it.
            KeyModeIndicator()
            Divider().frame(height: 16)

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
    /// A preview tab — the next thing opened replaces it. Italic, as editors
    /// have spelled this for years.
    var provisional: Bool = false
    let active: Bool
    let closable: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1).font(.callout)
                .italic(provisional)
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
            // So `C-w l` can put the keyboard in the surface it moved to.
            .background(SurfaceAccessor(.pane(pane.id)))
            .overlay {
                if isMultiPane && isActive {
                    // Accent while this surface has the keyboard, grey when it
                    // doesn't — the same thing the sidebar's selection says.
                    // Its own view, so a focus change redraws the border and
                    // not the pane hosting the canvas.
                    SurfaceFocusRing(surface: .pane(pane.id), dimWhenUnfocused: true)
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
        if let id = model.displayedNode(in: pane) {
            if let node = host.node(id), let canvas = model.store?.canvas(for: node) {
                PreparedCanvas(node: id, canvas: canvas)
            } else if host.childStyle(of: id) == .contents {
                // A container whose whole job is to be gone into. It has no
                // canvas because there is nothing to draw *of* it — what you
                // came for is in the column beside this, and the pane shows
                // whichever row you land on. Saying "Loading…" here was the
                // pane waiting for something that was never coming.
                ContentUnavailableView("Nothing Picked", systemImage: "list.bullet",
                                       description: Text("Choose something from the list."))
            } else if host.node(id) != nil {
                // The record is here; nothing draws it. Saying "Loading…" left
                // the pane promising something that was never going to arrive
                // — which a collection, having no view of its own, hit on
                // every click.
                ContentUnavailableView("No View", systemImage: "square.dashed",
                                       description: Text("Nothing draws this here."))
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
