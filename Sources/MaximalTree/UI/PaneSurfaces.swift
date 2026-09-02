import AppKit
import SwiftUI
import MaximalEditorKit

/// Where each surface is on screen, so moving to one can put the keyboard in it.
///
/// The obvious approach — register the view containing a pane and search its
/// subtree — cannot work: SwiftUI flattens the whole window into a single
/// hosting view, so a pane's marker view is a *sibling* of its canvas rather
/// than an ancestor, and there is no per-pane container to search. Views can't
/// tell the panes apart. Their frames can.
///
/// So a pane is a rectangle, and the canvas to focus is whichever key-taking
/// view sits inside it. The rectangle is read from the marker view at the
/// moment it is needed rather than cached, which keeps it right across splits,
/// drags, and window resizes without anything having to be told about them.
@MainActor
enum PaneSurfaces {
    private final class Box {
        weak var marker: NSView?
        init(_ marker: NSView?) { self.marker = marker }
    }

    private static var markers: [UUID: Box] = [:]

    static func register(_ marker: NSView?, for pane: UUID) {
        markers[pane] = Box(marker)
        markers = markers.filter { $0.value.marker != nil }
    }

    /// The pane's rectangle in window coordinates, or nil when it isn't on
    /// screen. Read from the marker, which `.background` sizes to the pane.
    static func frame(of pane: UUID) -> CGRect? {
        guard let marker = markers[pane]?.marker, marker.window != nil else { return nil }
        return marker.convert(marker.bounds, to: nil)
    }

    /// What to hand the keyboard when moving into `pane`: the editor showing
    /// there, or failing that whatever else in it will take a key press.
    ///
    /// An editor first because that is the thing you are most often moving to
    /// in order to type; every other canvas — a terminal, a page — comes
    /// through the same key-taker rule the rest of the app uses.
    static func focusTarget(of pane: UUID, in window: NSWindow? = NSApp.keyWindow) -> NSView? {
        guard let window, let content = window.contentView,
              let rect = frame(of: pane) else { return nil }
        let inside = keyTakers(in: content, within: rect)
        return inside.first { $0.view is MaximalEditor.EditorTextView }?.view
            ?? inside.first?.view
    }

    /// Every view showing in `rect` that would accept the keyboard, the one
    /// filling most of the pane first.
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
                found.append((view, shared.width * shared.height))
            }
        }
        return found.sorted { $0.overlap > $1.overlap }
    }

    /// The part of a view actually on screen, in window coordinates.
    ///
    /// Deliberately not `visibleRect`. An NSView does not clip to its bounds
    /// by default, so for a view with no clipping ancestor that returns the
    /// whole visible region of the *window* mapped into the view's own space
    /// — bigger than the view, and identical for every pane, which made every
    /// pane resolve to the same canvas.
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

/// Marks out a pane's area for `PaneSurfaces`. A background, so it takes the
/// pane's own frame without affecting what is drawn in it.
struct PaneSurfaceAccessor: NSViewRepresentable {
    let pane: UUID

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        PaneSurfaces.register(view, for: pane)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        PaneSurfaces.register(view, for: pane)
    }
}
