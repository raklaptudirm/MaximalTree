import SwiftUI
import AppKit
import MaximalTreeKit

/// The middle column: what is *inside* the thing selected in the sidebar.
///
/// A tree can show a folder of six. It cannot show a library of six thousand,
/// and the sidebar admitted as much by growing a "More…" row — a tree paging
/// itself in two at a time through a button. `ChildStyle` says which a node is;
/// this is where the ones that are contents go.
///
/// One column, not one per pane. What it lists is decided by the sidebar, and
/// there is one sidebar — a list per pane would be several answers to a
/// question with one asker, and would cost the width twice in a split.
@MainActor
@Observable
final class ContentsModel {
    /// Where the highlight is in each container.
    ///
    /// Per container rather than one row overall, so stepping out to another
    /// library and back puts you where you were. Cheap to keep and the thing
    /// you would otherwise miss immediately.
    var rowByContainer: [NodeID: NodeID] = [:]
    /// What `/` is narrowing the list to. Cleared when the container changes.
    var filter = ""
    /// Whether the filter field has the keyboard.
    var filtering = false
    /// Forced off with `SPC s B`. Off by choice, as opposed to absent because
    /// nothing selected has contents.
    var isHidden = false
}

/// The column itself.
struct ContentsList: View {
    let container: NodeID
    @Environment(HostContext.self) private var host
    @Environment(AppModel.self) private var model

    private var rows: [NodeID] {
        let children = host.children(of: container)
        let needle = model.contents.filter
        guard !needle.isEmpty else { return children }
        return children.filter {
            (host.node($0)?.label ?? $0.uri).localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.contents.filtering || !model.contents.filter.isEmpty {
                FilterField()
                Divider()
            }
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.self) { row(for: $0) }
                        if host.hasMoreChildren(container) {
                            // Scroll-driven paging is the next phase; until
                            // then a listing that has more says so rather than
                            // pretending it ends here.
                            Button { host.loadMoreChildren(of: container) } label: {
                                Label("More…", systemImage: "ellipsis")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 6)
                        }
                    }
                }
                .onChange(of: model.contentsRow) { _, row in
                    guard let row else { return }
                    withAnimation(.easeOut(duration: 0.12)) { scroller.scrollTo(row) }
                }
            }
            .background(ContentsFocus())
        }
        .background(SurfaceAccessor(.contents))
        .overlay { SurfaceFocusRing(surface: .contents) }
    }

    private func row(for id: NodeID) -> some View {
        let node = host.node(id)
        let selected = model.contentsRow == id
        let emphasized = selected && model.focusedSurface == .contents
        return HStack(spacing: 6) {
            NodeIconView(node?.icon)
            Text(node?.label ?? id.uri)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .contentShape(Rectangle())
        .background(selected ? (emphasized ? Color.accentColor : Color.secondary.opacity(0.2))
                             : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .foregroundStyle(emphasized ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .id(id)
        // A click highlights, which shows it in the pane; opening it for real
        // is the second click, the same bargain as everywhere else.
        .onTapGesture(count: 2) { model.openContentsRow(id) }
        .onTapGesture { model.highlightContentsRow(id) }
    }
}

/// The `/` field. Narrowing rather than searching: it filters what is listed,
/// which is what you want when the list is the thing you are looking at.
private struct FilterField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var contents = model.contents
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
            TextField("Filter", text: $contents.filter)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { model.runCommand("contents.open") }
            if !contents.filter.isEmpty {
                Button {
                    contents.filter = ""
                    contents.filtering = false
                } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .onAppear { focused = model.contents.filtering }
        .onChange(of: model.contents.filtering) { _, on in focused = on }
        .onChange(of: focused) { _, on in model.contents.filtering = on }
    }
}

/// Something in the column that will take the keyboard.
///
/// The same problem the inspector had: a surface made of labels and rows has
/// nothing focusable in it, and a surface nothing can focus cannot be moved to
/// — `SPC s b` would find nothing and the keyboard would stay where it was.
private struct ContentsFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> Accessor { Accessor() }
    func updateNSView(_ view: Accessor, context: Context) {}

    final class Accessor: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
}
