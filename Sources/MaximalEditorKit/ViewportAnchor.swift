import AppKit
import STTextKitPlus

/// Keeps the view still while the text under it changes shape.
///
/// Repaints move things: markup conceals and reveals, equation images arrive
/// and change line heights. Without compensation the document slides under the
/// reader. The fix is to pin one thing across the change — and *which* thing
/// matters:
///
/// - Pinning the **caret** was wrong. Clicking into a paragraph reveals its
///   markup, which moves the caret's own line, so every click scrolled the
///   whole document to keep the caret fixed — a lurch right before the
///   insertion point appeared.
/// - Pinning the **topmost visible line** is what readers expect: whatever you
///   were looking at stays where it is, and clicking never scrolls.
@MainActor
enum ViewportAnchor {
    struct Anchor {
        let location: NSTextLocation
        /// The anchored line's offset from the top of the viewport (usually
        /// slightly negative — the top line is normally partly scrolled off).
        let offset: CGFloat
    }

    /// The line at the top of `visible`, and where it sits relative to it.
    static func capture(in layoutManager: NSTextLayoutManager,
                        visible: CGRect) -> Anchor? {
        guard let fragment = layoutManager.textLayoutFragment(
            for: CGPoint(x: visible.minX, y: visible.minY))
        else { return nil }
        return Anchor(location: fragment.rangeInElement.location,
                      offset: fragment.layoutFragmentFrame.minY - visible.minY)
    }

    /// Where to scroll so the anchored line sits at the same offset again, or
    /// nil when it no longer exists. Lays out the prefix first: right after a
    /// repaint the anchored line's origin is still an estimate, and scrolling
    /// to an estimate is itself a jump.
    static func targetY(for anchor: Anchor,
                        in layoutManager: NSTextLayoutManager) -> CGFloat? {
        layoutManager.ensureLayout(upTo: anchor.location)
        var top: CGFloat?
        layoutManager.enumerateTextLayoutFragments(from: anchor.location,
                                                   options: [.ensuresLayout]) { fragment in
            top = fragment.layoutFragmentFrame.minY
            return false
        }
        return top.map { $0 - anchor.offset }
    }
}
