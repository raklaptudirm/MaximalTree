import AppKit
import SwiftUI
import MaximalEditorKit

/// One of the areas the window is divided into.
///
/// The sidebar and the inspector are surfaces like any canvas — they hold the
/// keyboard, they answer to keys, and you step between them the same way. They
/// were special cases here once: the sidebar was "off the left edge", reached
/// by a rule written into the movement itself, and the inspector could not be
/// reached at all.
enum SurfaceID: Hashable {
    case sidebar
    /// What is inside the thing the sidebar has selected — see `ContentsList`.
    case contents
    case pane(UUID)
    case inspector
}

/// Where each surface is, so movement and focus can treat them alike.
///
/// Geometry rather than view ancestry, and not by choice: SwiftUI flattens the
/// window into a single hosting view, so a surface's marker is a *sibling* of
/// its content and no ancestor distinguishes one surface from another. What
/// separates them on screen is where they are, so that is what is recorded —
/// read from the marker when asked, which keeps it right across splits,
/// divider drags, and a sidebar or inspector being hidden.
@MainActor
enum Surfaces {
    /// Where a surface was last seen, as a value.
    ///
    /// Not a live view. Holding the marker weakly and reading its frame on
    /// demand meant a surface existed only while SwiftUI kept that particular
    /// NSView alive — and SwiftUI rebuilds subtrees whenever it likes, so a
    /// pane would vanish from the registry between one keystroke and the next.
    /// The rectangle is what anyone actually wants; keep that.
    private struct Placement {
        weak var marker: NSView?
        var frame: CGRect
        var windowNumber: Int
    }

    private static var placements: [SurfaceID: Placement] = [:]

    /// Report where a surface is. Called on every layout pass, so the frame
    /// tracks splits, drags, and resizes without anything else being told.
    static func report(_ marker: NSView, for surface: SurfaceID) {
        guard let window = marker.window else { return }
        let frame = marker.convert(marker.bounds, to: nil)
        guard frame.width > 1, frame.height > 1 else { return }
        placements[surface] = Placement(marker: marker, frame: frame,
                                        windowNumber: window.windowNumber)
    }

    /// A surface is gone — its sidebar hidden, its pane closed.
    ///
    /// Only when the view being dismantled is the one on record: SwiftUI often
    /// builds the replacement before tearing down the original, and clearing
    /// blindly would drop the entry that had just replaced this one.
    static func forget(_ marker: NSView, for surface: SurfaceID) {
        guard let known = placements[surface]?.marker, known === marker else { return }
        placements[surface] = nil
    }

    /// Forget the panes that are no longer part of `window`'s layout.
    ///
    /// A placement outliving its view is deliberate — SwiftUI rebuilds
    /// subtrees whenever it likes, and a pane that vanished from the registry
    /// between two keystrokes is the bug that outliving fixed. But a pane that
    /// has actually gone — a split closed, a tab switched away from — leaves
    /// its rectangle behind for good, and the rectangle goes on competing to
    /// be the surface holding the keyboard.
    ///
    /// Which is not a theoretical loss. The next tab lays its panes out in the
    /// same place, so the dead rectangle covers the caret exactly as well as
    /// the live one does, and `focused` breaks the tie out of a dictionary —
    /// arbitrarily. Naming a pane that no longer exists means no node, so no
    /// canvas, so no keys, and every key the canvas declares falls through
    /// unbound. That is the editor "randomly" going deaf, and it stays deaf
    /// until something happens to rebuild the layout.
    ///
    /// Only this window's, because the registry is shared and another
    /// window's panes are not this one's to forget.
    static func prunePanes(keeping live: Set<UUID>, in window: NSWindow?) {
        guard let window else { return }
        placements = placements.filter { id, placement in
            guard case .pane(let pane) = id,
                  placement.windowNumber == window.windowNumber else { return true }
            return live.contains(pane)
        }
    }

    /// Every surface showing in `window`, with its rectangle in that window's
    /// coordinates. A hidden sidebar or a closed inspector simply isn't one.
    ///
    /// Scoped to the window because the registry is not: surfaces from another
    /// window are neither neighbours nor candidates for focus.
    static func onScreen(in window: NSWindow?) -> [(id: SurfaceID, frame: CGRect)] {
        guard let window else { return [] }
        return placements.compactMap { id, placement in
            guard placement.windowNumber == window.windowNumber else { return nil }
            // A marker still in the window knows better than the last report.
            if let marker = placement.marker, marker.window === window {
                let now = marker.convert(marker.bounds, to: nil)
                if now.width > 1, now.height > 1 { return (id, now) }
            }
            return (id, placement.frame)
        }
    }

    static func frame(of surface: SurfaceID,
                      in window: NSWindow? = NSApp.keyWindow) -> CGRect? {
        onScreen(in: window).first { $0.id == surface }?.frame
    }

    /// The surface holding the keyboard, found by where the first responder
    /// is rather than by what contains it. Nothing focused means the sidebar:
    /// it is what the keyboard belongs to before anywhere else claims it.
    ///
    /// Matched by the part of the responder actually showing, and by how much
    /// of each surface it covers — not by where the middle of the view is. A
    /// document is far taller than the pane it scrolls in, so its centre lands
    /// outside every surface and often outside the window: judged that way the
    /// editor belonged to nothing, the answer fell back to the sidebar, and
    /// the sidebar stayed lit while you typed in the editor.
    static func focused(in window: NSWindow? = NSApp.keyWindow) -> SurfaceID {
        guard let view = window?.firstResponder as? NSView else { return .sidebar }
        let shown = onScreen(view)
        return onScreen(in: window)
            .map { (id: $0.id, overlap: $0.frame.intersection(shown).area) }
            .filter { $0.overlap > 0 }
            .max { $0.overlap < $1.overlap }?.id ?? .sidebar
    }

    /// The surface next to `surface` in `direction`.
    ///
    /// Purely geometric, which is what lets the sidebar, the canvases, and the
    /// inspector take part in one rule: whatever lies that way, overlapping on
    /// the other axis so that stepping right from a tall pane finds what is
    /// actually beside it, nearest edge first.
    static func neighbour(of surface: SurfaceID, moving direction: PaneDirection,
                          in window: NSWindow? = NSApp.keyWindow) -> SurfaceID? {
        let all = onScreen(in: window)
        guard let from = all.first(where: { $0.id == surface })?.frame else { return nil }

        return all
            .filter { $0.id != surface }
            .filter { direction.reaches($0.frame, from: from) }
            .filter { direction.isHorizontal ? $0.frame.overlapsVertically(from)
                                             : $0.frame.overlapsHorizontally(from) }
            .min { direction.distance(to: $0.frame, from: from)
                 < direction.distance(to: $1.frame, from: from) }?
            .id
    }

    /// What to hand the keyboard when moving into a surface: the editor there,
    /// or failing that whatever else in it will take a key press.
    static func focusTarget(of surface: SurfaceID,
                            in window: NSWindow? = NSApp.keyWindow) -> NSView? {
        guard let window, let content = window.contentView,
              let rect = frame(of: surface, in: window) else { return nil }
        let inside = keyTakers(in: content, within: rect)
        return inside.first { $0.view is MaximalEditor.EditorTextView }?.view
            ?? inside.first?.view
    }

    /// Every view showing in `rect` that would accept the keyboard, the one
    /// covering most of the surface first.
    private static func keyTakers(in view: NSView, within rect: CGRect)
        -> [(view: NSView, overlap: CGFloat)] {
        guard view.window != nil else { return [] }
        let shown = onScreen(view)
        // Only prune whole subtrees, never a leaf: a container can be smaller
        // than what it lays out.
        guard shown.intersects(rect) || !view.subviews.isEmpty else { return [] }

        var found = view.subviews.flatMap { keyTakers(in: $0, within: rect) }
        if KeyFocus.isKeyTaker(view) {
            let shared = shown.intersection(rect)
            if !shared.isNull, shared.width > 0, shared.height > 0 {
                found.append((view, shared.area))
            }
        }
        return found.sorted { $0.overlap > $1.overlap }
    }

    /// The part of a view actually on screen, in window coordinates.
    ///
    /// Deliberately not `visibleRect`. An NSView does not clip to its bounds
    /// by default, so for a view with no clipping ancestor that returns the
    /// whole visible region of the *window* mapped into the view's own space
    /// — bigger than the view, and identical for every surface, which made
    /// every one of them resolve to the same canvas.
    ///
    /// A document scrolling in a pane does have a clipping ancestor, and that
    /// is exactly what trims it to the part showing here.
    private static func onScreen(_ view: NSView) -> CGRect {
        var rect = view.convert(view.bounds, to: nil)
        var ancestor = view.superview
        while let current = ancestor {
            if current.clipsToBounds || current is NSClipView {
                rect = rect.intersection(current.convert(current.bounds, to: nil))
            }
            ancestor = current.superview
        }
        return rect
    }
}

private extension PaneDirection {
    /// Whether `other` lies this way from `from`, by the edge that faces it.
    func reaches(_ other: CGRect, from: CGRect) -> Bool {
        switch self {
        case .left: return other.midX < from.midX
        case .right: return other.midX > from.midX
        // Window coordinates put the origin at the bottom, so "up" is more y.
        case .up: return other.midY > from.midY
        case .down: return other.midY < from.midY
        }
    }

    func distance(to other: CGRect, from: CGRect) -> CGFloat {
        isHorizontal ? abs(other.midX - from.midX) : abs(other.midY - from.midY)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }

    func overlapsVertically(_ other: CGRect) -> Bool {
        minY < other.maxY && other.minY < maxY
    }

    func overlapsHorizontally(_ other: CGRect) -> Bool {
        minX < other.maxX && other.minX < maxX
    }
}

/// Marks out a surface's area for `Surfaces`. A background, so it takes the
/// surface's own frame without affecting what is drawn in it.
struct SurfaceAccessor: NSViewRepresentable {
    let surface: SurfaceID

    init(_ surface: SurfaceID) { self.surface = surface }

    func makeNSView(context: Context) -> Marker {
        let marker = Marker()
        marker.surface = surface
        return marker
    }

    func updateNSView(_ view: Marker, context: Context) {
        view.surface = surface
        Surfaces.report(view, for: surface)
    }

    static func dismantleNSView(_ view: Marker, coordinator: ()) {
        // The surface this view stood for is only gone if nothing has taken
        // its place; `forget` checks that.
        guard let surface = view.surface else { return }
        MainActor.assumeIsolated { Surfaces.forget(view, for: surface) }
    }

    /// Carries which surface it marks, and reports its own geometry.
    ///
    /// Reporting from `updateNSView` alone was not enough: SwiftUI runs that
    /// before the view is in a window — when there is no frame to report — and
    /// then may never run it again, so the surface was never recorded at all.
    /// AppKit says exactly when a view lands in a window and when it moves.
    final class Marker: NSView {
        var surface: SurfaceID?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            report()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            report()
        }

        private func report() {
            MainActor.assumeIsolated {
                guard let surface else { return }
                Surfaces.report(self, for: surface)
            }
        }
    }
}

/// Draws the "this surface has the keyboard" outline.
///
/// Deliberately its own view. Reading `focusedSurface` inside the pane's or
/// the shell's body made every focus change rebuild that subtree — which
/// deallocated the very markers the focused surface is worked out from, so
/// the pane dropped out of the registry and focus fell back to the sidebar.
/// Kept here, only the outline redraws.
struct SurfaceFocusRing: View {
    let surface: SurfaceID
    /// Panes stay outlined when unfocused (they are still the active pane),
    /// just without the colour. The inspector's ring only means focus.
    var dimWhenUnfocused = false
    @Environment(AppModel.self) private var model

    var body: some View {
        let focused = model.focusedSurface == surface
        if focused || dimWhenUnfocused {
            Rectangle()
                .strokeBorder(focused ? Color.accentColor.opacity(0.7)
                                      : Color.secondary.opacity(0.35),
                              lineWidth: 2)
                .allowsHitTesting(false)
        }
    }
}

/// Keeps a window at least as big as the shell inside it can lay out in.
///
/// The three columns give a shell window a minimum width of 975pt, and a
/// window narrower than that does not clip or clamp: the split view re-reports
/// its minimum on every constraints pass, the window is marked as needing
/// another, and AppKit's feedback detector aborts the process ("more Update
/// Constraints in Window passes than there are views in the window").
///
/// Nothing above us prevents that. `defaultSize` is ignored once SwiftUI has a
/// remembered frame, AppKit's own clamp lands a point *below* `minSize` —
/// still too narrow — and opening a file makes SwiftUI order a window front at
/// whatever frame it last saved. The crash then saves the frame it died at, so
/// one bad window poisons every launch after it: this app reached a state
/// where every file opened from the Finder killed it, from a 940x450 frame
/// left behind by an earlier session.
///
/// So the floor is stated rather than inferred, and applied as windows appear
/// rather than from the view — by the time a SwiftUI view has a window to
/// reach, the pass that aborts has already run.
@MainActor
enum WindowFloor {
    /// Enough for the sidebar, the canvas and the inspector at their
    /// minimums, with room to spare: the point is to be clear of the cliff
    /// rather than balanced on it.
    static let size = NSSize(width: 1040, height: 400)

    /// Watch every window this app puts on screen.
    ///
    /// `didUpdate` rather than a delegate: SwiftUI owns the delegate of its
    /// own windows, and this has to run while the window is being ordered in,
    /// which is the last moment before the layout that would abort.
    /// A window showing the shell, as opposed to a panel the system opened.
    /// Identified by the scene name SwiftUI stamps on its own windows, which
    /// a save panel does not carry.
    private static func isShell(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.contains("AppWindow") ?? false
    }

    static func watch() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { enforce(on: window) }
        }
    }

    static func enforce(on window: NSWindow) {
        guard isShell(window) else { return }
        window.minSize = NSSize(width: max(window.minSize.width, size.width),
                                height: max(window.minSize.height, size.height))
        guard window.frame.width < size.width || window.frame.height < size.height else { return }
        var frame = window.frame
        frame.size.width = max(frame.width, size.width)
        frame.size.height = max(frame.height, size.height)
        window.setFrame(frame, display: false)
    }

}

