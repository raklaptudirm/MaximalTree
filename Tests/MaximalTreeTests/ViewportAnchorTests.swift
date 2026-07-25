import Testing
import AppKit
import Foundation
@testable import MaximalEditorKit

/// Scroll stability across a repaint, against real TextKit 2 layout.
///
/// Regression: clicking anywhere in the editor lurched the view before the
/// insertion point appeared. Clicking reveals the clicked paragraph's markup,
/// which makes it taller; the repaint anchored the *caret*, so the view scrolled
/// to keep the caret's (now moved) line fixed. Anchoring the topmost visible
/// line instead means a click never scrolls.
@MainActor
@Suite struct ViewportAnchorTests {
    /// Paragraphs long enough to wrap, so the document is many lines tall.
    private func document(paragraphs: Int, width: CGFloat = 300)
        -> (NSTextContentStorage, NSTextLayoutManager) {
        let storage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width,
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        storage.addTextLayoutManager(layoutManager)

        let text = (0..<paragraphs)
            .map { "Paragraph \($0): " + String(repeating: "some words to wrap ", count: 4) }
            .joined(separator: "\n")
        storage.textStorage?.setAttributedString(
            NSAttributedString(string: text,
                               attributes: [.font: NSFont.systemFont(ofSize: 15)]))
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return (storage, layoutManager)
    }

    /// Reveal a paragraph the way the editor does: same characters, bigger —
    /// concealment is font size, never deletion, so offsets stay valid.
    private func reveal(_ range: NSRange, in storage: NSTextContentStorage,
                        for layoutManager: NSTextLayoutManager) {
        storage.textStorage?.beginEditing()
        storage.textStorage?.addAttribute(.font, value: NSFont.systemFont(ofSize: 34),
                                          range: range)
        storage.textStorage?.endEditing()
        // Invalidating only the edited range leaves every fragment below it
        // holding its old origin — a repaint invalidates the document.
        layoutManager.invalidateLayout(for: layoutManager.documentRange)
    }

    /// The top of the *visual line* holding `location` — a paragraph growing
    /// taller moves the lines inside it, not the paragraph's own origin.
    private func top(of location: NSTextLocation,
                     in layoutManager: NSTextLayoutManager) -> CGFloat? {
        layoutManager.ensureLayout(upTo: location)
        return MathOverlayLayout.lineFragment(containing: location, in: layoutManager)
            .map { $0.0.layoutFragmentFrame.minY + $0.1.typographicBounds.minY }
    }

    private func location(_ offset: Int, in storage: NSTextContentStorage) -> NSTextLocation? {
        NSTextRange(NSRange(location: offset, length: 0), in: storage)?.location
    }

    /// The user's complaint, reproduced: a click reveals the clicked paragraph
    /// and the view must stay put.
    @Test func clickingIntoAParagraphDoesNotScrollTheView() throws {
        let (storage, layoutManager) = document(paragraphs: 40)
        let visible = CGRect(x: 0, y: 600, width: 300, height: 400)
        let anchor = try #require(ViewportAnchor.capture(in: layoutManager, visible: visible))

        // Click into a paragraph inside the viewport, below the top line.
        let text = storage.textStorage?.string as NSString? ?? ""
        let caret = text.paragraphRange(
            for: NSRange(location: text.length / 2, length: 0))
        let caretLocation = try #require(location(caret.location + caret.length / 2,
                                                  in: storage))
        let caretTopBefore = try #require(top(of: caretLocation, in: layoutManager))

        reveal(caret, in: storage, for: layoutManager)

        // The line the reader is looking at hasn't moved, so neither should the view.
        let target = try #require(ViewportAnchor.targetY(for: anchor, in: layoutManager))
        #expect(abs(target - visible.minY) < 0.5,
                "a click scrolled the view to \(target) from \(visible.minY)")

        // …and the test isn't vacuous: the caret's own line *did* move, which is
        // exactly what the old caret anchoring would have chased.
        let caretTopAfter = try #require(top(of: caretLocation, in: layoutManager))
        let caretTarget = caretTopAfter - (caretTopBefore - visible.minY)
        #expect(abs(caretTarget - visible.minY) > 2,
                "the reveal must actually move the caret's line for this to prove anything")
    }

    /// The case anchoring exists for: when a repaint changes heights *above* the
    /// viewport, the reader's line must keep its place on screen.
    @Test func growthAboveTheViewportKeepsTheReadingPositionStill() throws {
        let (storage, layoutManager) = document(paragraphs: 40)
        let visible = CGRect(x: 0, y: 600, width: 300, height: 400)
        let anchor = try #require(ViewportAnchor.capture(in: layoutManager, visible: visible))
        let before = try #require(top(of: anchor.location, in: layoutManager))

        let text = storage.textStorage?.string as NSString? ?? ""
        reveal(text.paragraphRange(for: NSRange(location: 0, length: 0)),
               in: storage, for: layoutManager)

        let target = try #require(ViewportAnchor.targetY(for: anchor, in: layoutManager))
        let after = try #require(top(of: anchor.location, in: layoutManager))

        #expect(after > before, "the growth above must actually push the line down")
        // Scrolling to `target` leaves the anchored line at the offset it had.
        #expect(abs((after - target) - (before - visible.minY)) < 0.5)
        #expect(abs(target - visible.minY) > 2, "no compensation happened")
    }

    @Test func anEmptyDocumentHasNothingToAnchor() {
        let storage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        layoutManager.textContainer = NSTextContainer(
            size: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        storage.addTextLayoutManager(layoutManager)
        // Nothing laid out below the viewport top: nothing to pin, and the
        // caller must leave the scroll position alone.
        #expect(ViewportAnchor.capture(
            in: layoutManager,
            visible: CGRect(x: 0, y: 5000, width: 300, height: 400)) == nil)
    }
}
