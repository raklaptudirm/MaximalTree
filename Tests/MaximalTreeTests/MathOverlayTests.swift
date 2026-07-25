import Testing
import AppKit
import Foundation
@testable import MaximalEditorKit

/// Placement of rendered equations, against real TextKit 2 layout.
///
/// Regression: in a long wrapping paragraph the image drifted *upward* as the
/// paragraph gained lines, eventually landing on top of earlier text. Two
/// causes — measuring before layout had caught up, and picking the line by
/// geometry from a range's segment frame, which is a multi-line *union* once
/// the equation's reserved width straddles a wrap (a union's top edge is the
/// first line's).
@MainActor
@Suite struct MathOverlayLayoutTests {
    /// A paragraph that wraps several times, with an "equation" collapsed the
    /// way the editor collapses one: a near-zero font plus kern reserving the
    /// image's width.
    private func layout(text: String, equation: NSRange, imageWidth: CGFloat,
                        width: CGFloat = 300, fontSize: CGFloat = 15,
                        lineHeightMultiple: CGFloat = 1.5)
        -> (NSTextLayoutManager, NSTextContainer) {
        let storage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width,
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        storage.addTextLayoutManager(layoutManager)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeightMultiple
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: fontSize),
                         .paragraphStyle: paragraph])
        // Collapse the equation source and reserve the image's width, exactly
        // as the editor does.
        attributed.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.1),
                                range: equation)
        attributed.addAttribute(.kern, value: imageWidth,
                                range: NSRange(location: equation.upperBound - 1, length: 1))
        storage.textStorage?.setAttributedString(attributed)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return (layoutManager, container)
    }

    /// The y range of the visual line holding `location`, for comparison.
    private func lineBounds(at offset: Int, in layoutManager: NSTextLayoutManager)
        -> (top: CGFloat, height: CGFloat)? {
        guard let contentManager = layoutManager.textContentManager,
              let range = NSTextRange(NSRange(location: offset, length: 0), in: contentManager),
              let (fragment, line) = MathOverlayLayout.lineFragment(
                containing: range.location, in: layoutManager)
        else { return nil }
        return (fragment.layoutFragmentFrame.minY + line.typographicBounds.minY,
                line.typographicBounds.height)
    }

    @Test func equationLandsOnItsOwnLineInAWrappedParagraph() throws {
        // Long enough to wrap many times at 300pt, with the equation far in.
        let prose = String(repeating: "the quick brown fox jumps over it ", count: 12)
        let text = prose + "$e^(i pi)$" + " and the sentence continues afterwards."
        let equation = NSRange(location: prose.utf16.count, length: 10)
        let (layoutManager, _) = layout(text: text, equation: equation, imageWidth: 60)

        let frame = try #require(MathOverlayLayout.frame(
            forEquationAt: equation, image: CGSize(width: 60, height: 18),
            imageBaseline: 14, block: false, lineHeightMultiple: 1.5,
            in: layoutManager))
        let line = try #require(lineBounds(at: equation.location, in: layoutManager))

        // The image must sit on the equation's own line — not hiked up to an
        // earlier one. Allow the ascent/descent slack a baseline-aligned image
        // legitimately needs.
        #expect(frame.midY > line.top - line.height,
                "image drifted above its line (top \\(line.top), image \\(frame.midY))")
        #expect(frame.midY < line.top + 2 * line.height,
                "image drifted below its line")
    }

    /// The heart of the bug: the deeper the equation sits in a wrapped
    /// paragraph, the further the old code placed it from the truth. Placement
    /// must track the line, however many wraps precede it.
    @Test func placementTracksTheLineAsTheParagraphGrows() throws {
        var offsets: [(imageY: CGFloat, lineTop: CGFloat)] = []
        for repeats in [2, 6, 12, 20] {
            let prose = String(repeating: "the quick brown fox jumps over it ", count: repeats)
            let text = prose + "$e^(i pi)$" + " and more text after the equation."
            let equation = NSRange(location: prose.utf16.count, length: 10)
            let (layoutManager, _) = layout(text: text, equation: equation, imageWidth: 60)

            let frame = try #require(MathOverlayLayout.frame(
                forEquationAt: equation, image: CGSize(width: 60, height: 18),
                imageBaseline: 14, block: false, lineHeightMultiple: 1.5,
                in: layoutManager))
            let line = try #require(lineBounds(at: equation.location, in: layoutManager))
            offsets.append((frame.minY, line.top))
        }

        // Deeper paragraphs put the equation further down; the image must move
        // with it, staying a *constant* distance from its line's top.
        let deltas = offsets.map { $0.imageY - $0.lineTop }
        let spread = (deltas.max() ?? 0) - (deltas.min() ?? 0)
        #expect(spread < 1,
                "image position drifts relative to its line as the paragraph wraps: \\(deltas)")
        #expect(offsets.last!.lineTop > offsets.first!.lineTop,
                "the test itself must actually push the equation onto later lines")
    }

    @Test func horizontalPositionFollowsTheEquationNotTheParagraph() throws {
        let prose = String(repeating: "alpha beta gamma delta ", count: 4)
        let text = prose + "$x$" + " tail"
        let equation = NSRange(location: prose.utf16.count, length: 3)
        let (layoutManager, _) = layout(text: text, equation: equation, imageWidth: 40)

        let frame = try #require(MathOverlayLayout.frame(
            forEquationAt: equation, image: CGSize(width: 40, height: 18),
            imageBaseline: 14, block: false, lineHeightMultiple: 1.5,
            in: layoutManager))
        // A union rect would report the paragraph's left edge; the real
        // position is wherever the equation starts on its line.
        #expect(frame.minX > 0, "x collapsed to the paragraph edge")
    }

    /// Repaints are debounced, so during continuous typing the document reflows
    /// while no highlight pass runs — the mechanism behind images creeping away
    /// from their equations. Tracking edits keeps the ranges honest so overlays
    /// can be repositioned every keystroke.
    @Test func equationsFollowTheTextAcrossEdits() {
        let equation = NSRange(location: 100, length: 10)

        // Typing before it slides it along.
        #expect(MathOverlayLayout.adjust(equation,
                                         forEditIn: NSRange(location: 5, length: 0),
                                         delta: 7)
                == NSRange(location: 107, length: 10))
        // Deleting before it slides it back.
        #expect(MathOverlayLayout.adjust(equation,
                                         forEditIn: NSRange(location: 5, length: 4),
                                         delta: -4)
                == NSRange(location: 96, length: 10))
        // Typing after it leaves it alone.
        #expect(MathOverlayLayout.adjust(equation,
                                         forEditIn: NSRange(location: 200, length: 0),
                                         delta: 3)
                == equation)
        // An edit that touches it invalidates the image until the next repaint.
        #expect(MathOverlayLayout.adjust(equation,
                                         forEditIn: NSRange(location: 104, length: 0),
                                         delta: 1) == nil)
        #expect(MathOverlayLayout.adjust(equation,
                                         forEditIn: NSRange(location: 95, length: 20),
                                         delta: 0) == nil)
    }

    /// Placement runs right after edits now, which is exactly when TextKit's
    /// layout is invalid — measuring without forcing it returns nothing at all.
    @Test func placementIsCorrectImmediatelyAfterAnEdit() throws {
        let prose = String(repeating: "the quick brown fox jumps over it ", count: 6)
        let text = prose + "$e^(i pi)$" + " tail text here."
        let equation = NSRange(location: prose.utf16.count, length: 10)
        let (layoutManager, _) = layout(text: text, equation: equation, imageWidth: 60)
        let storage = layoutManager.textContentManager as? NSTextContentStorage

        // Type a lot above it, then measure before anything re-lays out.
        let inserted = String(repeating: "typing more and more words here ", count: 6)
        storage?.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 0),
                                                with: inserted)
        let moved = try #require(MathOverlayLayout.adjust(
            equation, forEditIn: NSRange(location: 0, length: 0),
            delta: inserted.utf16.count))

        let immediate = try #require(MathOverlayLayout.frame(
            forEquationAt: moved, image: CGSize(width: 60, height: 18),
            imageBaseline: 14, block: false, lineHeightMultiple: 1.5,
            in: layoutManager))

        // Ground truth once everything is laid out.
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        let settled = try #require(MathOverlayLayout.frame(
            forEquationAt: moved, image: CGSize(width: 60, height: 18),
            imageBaseline: 14, block: false, lineHeightMultiple: 1.5,
            in: layoutManager))

        #expect(abs(immediate.minY - settled.minY) < 0.5, "measured stale geometry")
        #expect(abs(immediate.minX - settled.minX) < 0.5)
    }

    @Test func blockEquationsCentreInTheirLine() throws {
        let text = "before\n$ x + y $\nafter"
        let equation = NSRange(location: 7, length: 9)
        let (layoutManager, _) = layout(text: text, equation: equation, imageWidth: 80,
                                        width: 400)

        let frame = try #require(MathOverlayLayout.frame(
            forEquationAt: equation, image: CGSize(width: 80, height: 30),
            imageBaseline: 20, block: true, lineHeightMultiple: 1.5,
            in: layoutManager))
        let line = try #require(lineBounds(at: equation.location, in: layoutManager))
        let lineCentre = line.top + line.height / 2
        #expect(abs(frame.midY - lineCentre) < line.height,
                "a block equation should sit in its own line")
    }
}
