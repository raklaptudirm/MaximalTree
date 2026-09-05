import AppKit
import SwiftUI

/// Moving the inspector from the keyboard.
///
/// The last surface with no keys of its own. Every other one declares some —
/// which is what made "any surface can" true rather than "any canvas can" —
/// and the inspector was the one place you could look at but not move.
///
/// Its sections come from plugins and are arbitrary SwiftUI, so there is no
/// selection to walk and nothing generic to activate. What there is, is a
/// scroll view, and being able to reach the bottom of a long inspector without
/// the mouse is the whole of what was missing.
@MainActor
enum InspectorScroll {
    /// Weak: the inspector is rebuilt whenever the focused node changes, and
    /// holding its scroll view would keep a dead view tree alive.
    private static weak var scrollView: NSScrollView?

    static func report(_ view: NSScrollView?) { scrollView = view }

    /// A line's worth, as the scroll wheel counts one.
    private static let line: CGFloat = 24

    static func by(lines: CGFloat) { scroll(by: lines * line) }

    static func byHalfPage(_ direction: CGFloat) {
        guard let height = scrollView?.contentView.bounds.height else { return }
        scroll(by: direction * height / 2)
    }

    static func toTop() { scroll(to: 0) }

    static func toBottom() {
        guard let scrollView, let document = scrollView.documentView else { return }
        scroll(to: document.bounds.height - scrollView.contentView.bounds.height)
    }

    private static func scroll(by delta: CGFloat) {
        guard let scrollView else { return }
        scroll(to: scrollView.contentView.bounds.origin.y + delta)
    }

    /// Clamped, so holding a key at either end does nothing rather than
    /// scrolling into blank space.
    private static func scroll(to offset: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let limit = max(document.bounds.height - scrollView.contentView.bounds.height, 0)
        let target = min(max(offset, 0), limit)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// Hands the inspector's scroll view to `InspectorScroll` once it exists.
///
/// The scroll view is SwiftUI's, made by the `ScrollView` in the pane, so the
/// only way to it is upwards from a view inside — which is what a background
/// placed in the content can do.
struct InspectorScrollAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> Accessor { Accessor() }
    func updateNSView(_ view: Accessor, context: Context) {}

    final class Accessor: NSView {
        /// Also what gives the inspector something to focus. Its sections are
        /// often a `Form` of labels with no control in them, and a surface
        /// with nothing focusable cannot be moved to — `SPC s i` would find
        /// nothing and the keyboard would stay where it was.
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            InspectorScroll.report(enclosingScrollView)
        }
    }
}
