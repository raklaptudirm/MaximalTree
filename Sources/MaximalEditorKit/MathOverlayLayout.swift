import AppKit
import STTextKitPlus

/// Where a rendered equation's image belongs on screen.
///
/// Kept apart from the editor coordinator because it's pure geometry over a
/// layout manager — the part that has to be exactly right, and the part worth
/// testing against real TextKit layout.
///
/// Two rules earn their keep here, both learned from equations drifting out of
/// place in wrapped paragraphs:
///
/// 1. **Ensure layout before measuring.** TextKit 2 lays out lazily; reading
///    fragment frames without forcing layout returns the *previous* geometry,
///    so an image lands where its line used to be — visibly higher every time
///    the paragraph gains a wrapped line.
/// 2. **Find the line by character range, not by geometry.** A range's segment
///    frame is a *union* when the range straddles a line break (which the
///    equation's reserved width invites), and a union's top edge belongs to the
///    first line — placing the image above where the equation actually sits.
/// 3. **Lay out the whole prefix, not just the equation** (see
///    `ensureLayout(upTo:)`) — an absolute y is only as good as everything
///    above it.
@MainActor
enum MathOverlayLayout {
    /// The image's frame in layout coordinates, or nil when the equation isn't
    /// laid out (off-screen, or the range no longer exists).
    static func frame(forEquationAt range: NSRange,
                      image: CGSize,
                      imageBaseline: CGFloat,
                      block: Bool,
                      lineHeightMultiple: Double,
                      in layoutManager: NSTextLayoutManager) -> CGRect? {
        guard let contentManager = layoutManager.textContentManager,
              let textRange = NSTextRange(range, in: contentManager)
        else { return nil }
        layoutManager.ensureLayout(upTo: textRange.endLocation)

        guard let (fragment, line) = lineFragment(containing: textRange.location,
                                                  in: layoutManager),
              // A *zero-length* segment: one line's rect, never a union.
              let start = layoutManager.textSegmentFrame(at: textRange.location,
                                                         type: .standard)
        else { return nil }

        let lineTop = fragment.layoutFragmentFrame.minY + line.typographicBounds.minY
        let height = line.typographicBounds.height
        // The engine draws each line shifted by −(height × (multiple − 1) / 2) —
        // text centred inside the multiplied line height — so on-screen geometry
        // needs the same correction (see STTextLayoutFragment.draw).
        let centering = -(height * (max(lineHeightMultiple, 1) - 1) / 2)

        if block {
            // A display equation owns its paragraph, and its *source* may span
            // several collapsed lines — concealment can't remove the newlines.
            // The reserved box is then useless for x: the kern rides the last
            // line, leaving the first ~zero-wide, which centering parks at the
            // column's midpoint (the image drifted to the right margin from
            // there). Centre in the column instead, and centre y across the
            // whole span. For a one-line source the span is the line and this
            // reduces to the old formula.
            guard let endRange = NSTextRange(
                    NSRange(location: max(range.location, range.upperBound - 1), length: 0),
                    in: contentManager),
                  let (endFragment, endLine) = lineFragment(containing: endRange.location,
                                                            in: layoutManager)
            else { return nil }
            let bottom = endFragment.layoutFragmentFrame.minY + endLine.typographicBounds.maxY
            // No `centering` here: that term tracks where the engine draws
            // *glyphs* inside a line, and a block equation's glyphs are
            // invisible. The image centres in the reserved box itself.
            let y = lineTop + (bottom - lineTop - image.height) / 2

            let padding = layoutManager.textContainer?.lineFragmentPadding ?? 0
            let column = layoutManager.textContainer?.size.width
                ?? fragment.layoutFragmentFrame.width
            let x = max(padding, (column - image.width) / 2)
            return CGRect(origin: CGPoint(x: x, y: y), size: image)
        }

        // Inline: the image's own baseline sits on the text's drawn baseline.
        let y = lineTop + centering + line.glyphOrigin.y - imageBaseline
        return CGRect(origin: CGPoint(x: start.minX, y: y), size: image)
    }

    /// Follow a pending equation across an edit.
    ///
    /// Repaints are debounced, so during continuous typing the text reflows for
    /// as long as the typing lasts while the images stay where they were —
    /// which is what makes them creep away from their equations and end up over
    /// other text. Shifting the ranges lets the overlays be repositioned on
    /// every keystroke, cheaply, without waiting for the next highlight pass.
    ///
    /// Returns nil when the edit *touched* the equation: its image no longer
    /// describes the text, so it should disappear until the next repaint
    /// re-renders it.
    static func adjust(_ range: NSRange, forEditIn edited: NSRange,
                       delta: Int) -> NSRange? {
        // Wholly after the edit: slide by the length change.
        if range.location >= edited.upperBound {
            return NSRange(location: range.location + delta, length: range.length)
        }
        // Wholly before it: untouched.
        if range.upperBound <= edited.location { return range }
        return nil      // overlapping — including an insertion inside it
    }

    /// The laid-out line fragment holding `location` — matched on the line's
    /// character range, so wrapping can't confuse it.
    static func lineFragment(containing location: NSTextLocation,
                             in layoutManager: NSTextLayoutManager)
        -> (NSTextLayoutFragment, NSTextLineFragment)? {
        var result: (NSTextLayoutFragment, NSTextLineFragment)?
        layoutManager.enumerateTextLayoutFragments(from: location,
                                                   options: [.ensuresLayout]) { fragment in
            var fallback: NSTextLineFragment?
            for line in fragment.textLineFragments {
                fallback = line
                guard let lineRange = line.textRange(in: fragment) else { continue }
                if lineRange.contains(location) || lineRange.endLocation == location {
                    result = (fragment, line)
                    return false
                }
            }
            // The location can sit exactly at a fragment's end (a trailing
            // equation): use its last line rather than giving up.
            if let fallback { result = (fragment, fallback) }
            return false        // only the fragment the location belongs to
        }
        return result
    }
}

extension NSTextLayoutManager {
    /// Lay out everything up to `location` for real.
    ///
    /// TextKit 2 will hand back a fragment whose *origin* is an estimate:
    /// laying out a sub-range doesn't recompute the fragments above it, and a
    /// fragment already marked valid keeps its old origin no matter what
    /// changed height earlier. After a repaint that grew text further up, a
    /// measurement can be a hundred points out — an equation drawn over a
    /// paragraph it has nothing to do with. An absolute y is only as
    /// trustworthy as everything above it.
    func ensureLayout(upTo location: NSTextLocation) {
        guard let prefix = NSTextRange(location: documentRange.location, end: location)
        else { return }
        ensureLayout(for: prefix)
    }
}
