import Testing
import AppKit
import SwiftUI
import STTextView
@testable import MaximalEditorKit

/// Equation overlays driven through the *real* coordinator and a real
/// STTextView in a window: placement end to end, across a paint, a click, a
/// scroll, and display math.
///
/// Worth knowing what this suite does *not* cover. The bug where every image
/// sat a uniform 36pt below its text never reproduced here — an offscreen
/// window's layout resolves early enough that the deferred placement pass
/// measures settled geometry either way. In the app a display pass is still
/// pending at that moment, and STTextView's attribute setters don't invalidate
/// the layout manager (only `needsLayout` on the view), so the measurement
/// described a document about to be replaced. That one was caught by
/// instrumenting the running app, not by these tests; they guard the placement
/// contract, not that specific race.
@MainActor
@Suite struct EditorOverlayTests {
    /// One fixed image for every equation, so expected geometry is knowable.
    /// A rendered equation, 40pt tall on purpose.
    ///
    /// Taller than a line of prose, which is what a real display equation is —
    /// a fraction or an integral is not the height of a sentence. That matters
    /// because the reserved box takes `max(image + 2, natural line height)`,
    /// and only the image branch of that max exercises the case where TextKit's
    /// *estimate* for an un-laid-out fragment (which assumes an ordinary line)
    /// is wrong. A 22pt image sat under the natural height, took the other
    /// branch, and let a real placement bug through.
    private final class StubMath: EditorMathRenderer {
        let image: NSImage = {
            let image = NSImage(size: CGSize(width: 48, height: 40))
            image.lockFocus()
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: 48, height: 40).fill()
            image.unlockFocus()
            return image
        }()

        func renderedMath(for equation: String, fontSize: CGFloat, dark: Bool,
                          block: Bool,
                          completion: @escaping @MainActor () -> Void) -> RenderedEquation? {
            RenderedEquation(image: image, baseline: 16)
        }
    }

    /// Marks every `$…$` as inline math, every `*…*` as strong, and every
    /// heading line as a heading — so a repaint has real concealment work to
    /// do.
    ///
    /// The strong runs matter more than they look. Concealment is what makes a
    /// paragraph change *height* when it gains or loses its reveal: delimiters
    /// collapse to a near-zero font off the caret's line and come back on it.
    /// A tokenizer that emits only math conceals almost nothing, so the
    /// document barely reflows and a test built on it cannot show a lurch it
    /// never causes.
    private final class StubTokenizer: EditorTokenizer {
        func tokens(in text: String) -> [(range: NSRange, kind: EditorTokenKind)] {
            let ns = text as NSString
            var tokens: [(range: NSRange, kind: EditorTokenKind)] = []
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let open = ns.range(of: "$", options: [], range: search)
                guard open.location != NSNotFound else { break }
                let rest = NSRange(location: open.upperBound,
                                   length: ns.length - open.upperBound)
                let close = ns.range(of: "$", options: [], range: rest)
                guard close.location != NSNotFound else { break }
                let range = NSRange(location: open.location,
                                    length: close.upperBound - open.location)
                // A display equation is one that owns its line, the way typst
                // writes them — a different placement branch entirely.
                let line = ns.lineRange(for: NSRange(location: open.location, length: 0))
                let trimmed = ns.substring(with: line)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                tokens.append((range, .math(block: trimmed == ns.substring(with: range))))
                search = NSRange(location: close.upperBound,
                                 length: ns.length - close.upperBound)
            }
            // `*…*` as strong, whose delimiters conceal off the caret's line.
            var stars = NSRange(location: 0, length: ns.length)
            while stars.length > 0 {
                let open = ns.range(of: "*", options: [], range: stars)
                guard open.location != NSNotFound else { break }
                let rest = NSRange(location: open.upperBound,
                                   length: ns.length - open.upperBound)
                let close = ns.range(of: "*", options: [], range: rest)
                guard close.location != NSNotFound else { break }
                tokens.append((NSRange(location: open.location,
                                       length: close.upperBound - open.location), .strong))
                stars = NSRange(location: close.upperBound,
                                length: ns.length - close.upperBound)
            }
            return tokens
        }
    }

    private struct Editor {
        let scrollView: NSScrollView
        let textView: MaximalEditor.EditorTextView
        let coordinator: MaximalEditor.Coordinator
        let window: NSWindow
    }

    /// A live editor in a window, wired the way `makeNSView` wires one.
    private func makeEditor(text: String) -> Editor {
        // The app's own subclass, with modal editing live: a motion has to be
        // able to run, and the view a motion runs against has to be the one
        // that ships.
        let scrollView = MaximalEditor.EditorTextView.scrollableTextView()
        let textView = scrollView.documentView as! MaximalEditor.EditorTextView
        textView.modalEditing = true
        var storage = text
        let binding = Binding(get: { storage }, set: { storage = $0 })
        let coordinator = MaximalEditor.Coordinator(
            text: binding, tokenizer: StubTokenizer(), mathRenderer: StubMath(),
            completionProvider: nil)
        let style = EditorStyle.prose()
        textView.textDelegate = coordinator
        coordinator.textView = textView
        coordinator.lastStyle = style
        // The app's own setup rather than a hand-copied subset of it.
        MaximalEditor.apply(style: style, to: textView)
        MaximalEditor.applyColumnInsets(style: style, in: scrollView)
        textView.text = text
        // The app installs these; they re-place overlays on scroll and resize,
        // so they're part of the behaviour under test.
        coordinator.installObservers(for: textView, in: scrollView)

        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        window.contentView = scrollView
        // A real first layout pass, as a displayed window gets: without one the
        // engine has no geometry at all and placement has nothing to measure.
        window.layoutIfNeeded()
        textView.layoutSubtreeIfNeeded()
        scrollView.displayIfNeeded()
        return Editor(scrollView: scrollView, textView: textView,
                      coordinator: coordinator, window: window)
    }

    /// Let the coordinator's deferred overlay pass (and AppKit's display cycle)
    /// run, the way they would in the app. Awaiting frees the main actor so its
    /// queued work actually drains — a nested RunLoop.run does not.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    private func overlays(in textView: STTextView) -> [NSImageView] {
        textView.subviews.compactMap { $0 as? NSImageView }
    }

    /// Where the equation's image belongs once every pending layout has been
    /// resolved — the position the reader ends up seeing the text at.
    private func settledFrame(for range: NSRange, in editor: Editor,
                              block: Bool = false) -> CGRect? {
        editor.textView.layoutSubtreeIfNeeded()
        editor.textView.textLayoutManager.ensureLayout(
            for: editor.textView.textLayoutManager.documentRange)
        guard var frame = MathOverlayLayout.frame(
            forEquationAt: range, image: CGSize(width: 48, height: 40),
            imageBaseline: 16, block: block,
            lineHeightMultiple: editor.coordinator.lastStyle?.lineHeightMultiple ?? 1,
            in: editor.textView.textLayoutManager)
        else { return nil }
        frame.origin.x += editor.textView.gutterView?.frame.width ?? 0
        return frame
    }

    /// A document whose equations stand on their own lines: display math.
    private var blockDocument: String {
        var lines = ["= Display equations", ""]
        for index in 0..<8 {
            lines.append("Paragraph \(index) introduces the next equation and "
                         + "runs long enough to wrap onto a second line.")
            lines.append("")
            lines.append("$ x^\(index) + y = z $")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    @Test func displayEquationsFollowTheirLinesAcrossAClick() async throws {
        let editor = makeEditor(text: blockDocument)
        editor.coordinator.highlightNow()
        await settle()

        let ns = blockDocument as NSString
        let clicked = ns.range(of: "Paragraph 2")
        editor.textView.textSelection = NSRange(location: clicked.location + 3, length: 0)
        editor.coordinator.textViewDidChangeSelection(
            Notification(name: STTextView.didChangeSelectionNotification,
                         object: editor.textView))
        await settle()

        let equation = lastEquation(in: blockDocument)
        let expected = try #require(settledFrame(for: equation, in: editor, block: true))
        let placed = try #require(overlays(in: editor.textView).min {
            abs($0.frame.minY - expected.minY) < abs($1.frame.minY - expected.minY)
        })
        #expect(abs(placed.frame.minY - expected.minY) < 1,
                "display equation drifted: image at \(placed.frame.minY), line at \(expected.minY)")
    }

    private var document: String {
        var lines = ["= A document with equations", ""]
        for index in 0..<12 {
            lines.append("Paragraph \(index) says $x^\(index)$ and then continues "
                         + "with enough words to wrap onto another line or two.")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The equation range the placement is checked against: the last one, far
    /// enough down that anything shifting above it shows up.
    private func lastEquation(in text: String) -> NSRange {
        let ns = text as NSString
        var result = NSRange(location: NSNotFound, length: 0)
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let open = ns.range(of: "$", options: [], range: search)
            guard open.location != NSNotFound else { break }
            let rest = NSRange(location: open.upperBound,
                               length: ns.length - open.upperBound)
            let close = ns.range(of: "$", options: [], range: rest)
            guard close.location != NSNotFound else { break }
            result = NSRange(location: open.location,
                             length: close.upperBound - open.location)
            search = NSRange(location: close.upperBound,
                             length: ns.length - close.upperBound)
        }
        return result
    }

    @Test func imagesLandOnTheirEquationsAfterTheFirstPaint() async throws {
        let editor = makeEditor(text: document)
        editor.coordinator.highlightNow()
        await settle()

        let equation = lastEquation(in: document)
        let expected = try #require(settledFrame(for: equation, in: editor))
        let placed = try #require(overlays(in: editor.textView).min {
            abs($0.frame.minY - expected.minY) < abs($1.frame.minY - expected.minY)
        })
        #expect(abs(placed.frame.minY - expected.minY) < 1,
                "image at \(placed.frame.minY), text at \(expected.minY)")
    }

    /// Repositioning must reuse the overlay views, not rebuild them. Every
    /// subview add/remove invalidates the text view's layout; the observers
    /// fire on every layout pass; rebuilding on each firing re-dirtied every
    /// pass until AppKit's feedback-loop detector aborted the app — the prose
    /// mode crash. Identity equality across a reposition is the whole fix.
    @Test func repositioningReusesOverlayViewsInsteadOfRebuilding() async throws {
        let editor = makeEditor(text: document)
        editor.coordinator.highlightNow()
        await settle()

        let before = overlays(in: editor.textView)
        #expect(!before.isEmpty)

        // The path the layout pass takes: the frame-change notification the
        // coordinator observes. Must reposition without any churn.
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification,
                                        object: editor.textView)
        await settle()

        let after = overlays(in: editor.textView)
        #expect(after.count == before.count)
        #expect(zip(before, after).allSatisfy { $0 === $1 },
                "reposition created fresh views — the churn that fed the constraint loop")
    }

    /// Scrolled down, the prefix above the viewport has never been laid out for
    /// real — TextKit is carrying estimates for it. That's the state the editor
    /// is actually in when a reader clicks mid-document.
    @Test func imagesFollowTheirEquationsWhenScrolledAway() async throws {
        let editor = makeEditor(text: document)
        editor.coordinator.highlightNow()
        await settle()

        editor.textView.scroll(CGPoint(x: 0, y: 500))
        editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
        await settle()

        let ns = document as NSString
        let clicked = ns.range(of: "Paragraph 8")
        editor.textView.textSelection = NSRange(location: clicked.location + 3, length: 0)
        editor.coordinator.textViewDidChangeSelection(
            Notification(name: STTextView.didChangeSelectionNotification,
                         object: editor.textView))
        await settle()

        let equation = lastEquation(in: document)
        let expected = try #require(settledFrame(for: equation, in: editor))
        let placed = try #require(overlays(in: editor.textView).min {
            abs($0.frame.minY - expected.minY) < abs($1.frame.minY - expected.minY)
        })
        #expect(abs(placed.frame.minY - expected.minY) < 1,
                "image drifted while scrolled: image at \(placed.frame.minY), text at \(expected.minY)")
    }

    /// A click must leave the document's geometry alone.
    ///
    /// Moving the caret across a paragraph boundary used to repaint the whole
    /// document — every attribute rewritten, the entire layout invalidated — so
    /// TextKit re-derived heights the reader never asked about and the text
    /// below the click reflowed on every click. Only the two paragraphs that
    /// change reveal state may move now; everything else holds still.
    @Test func clickingDoesNotReflowTheRestOfTheDocument() async throws {
        // Long enough that the viewport sits mid-document: scrolled to the very
        // bottom, the height change clamps the scroll and the test would be
        // measuring that instead.
        var long = document
        for index in 12..<40 {
            long += "\n\nParagraph \(index) says $x^\(index)$ and then continues "
                + "with enough words to wrap onto another line or two."
        }
        let editor = makeEditor(text: long)
        editor.coordinator.highlightNow()
        await settle()

        let ns = long as NSString
        let low = ns.range(of: "Paragraph 9")
        let high = ns.range(of: "Paragraph 6")
        try #require(low.location != NSNotFound && high.location != NSNotFound)

        /// Document y of a paragraph's first line, against settled layout.
        func documentY(of offset: Int) -> CGFloat? {
            let lm = editor.textView.textLayoutManager
            editor.textView.layoutSubtreeIfNeeded()
            lm.ensureLayout(for: lm.documentRange)
            guard let cm = lm.textContentManager,
                  let range = NSTextRange(NSRange(location: offset, length: 0), in: cm),
                  let (fragment, _) = MathOverlayLayout.lineFragment(
                    containing: range.location, in: lm)
            else { return nil }
            return fragment.layoutFragmentFrame.minY
        }

        let highY = try #require(documentY(of: high.location))
        editor.textView.scroll(CGPoint(x: 0, y: max(0, highY - 60)))
        editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
        await settle()

        func click(at offset: Int) async {
            editor.textView.textSelection = NSRange(location: offset, length: 0)
            editor.coordinator.textViewDidChangeSelection(
                Notification(name: STTextView.didChangeSelectionNotification,
                             object: editor.textView))
            await settle()
        }

        // Everything from the top of the document down to the paragraph being
        // clicked — none of it changes reveal state, so none of it may move.
        func untouched() -> [CGFloat] {
            (0...5).compactMap { documentY(of: ns.range(of: "Paragraph \($0)").location) }
        }

        // Caret low in the viewport, then click a paragraph above it.
        await click(at: low.location + 3)
        let before = untouched()
        let clickedBefore = try #require(documentY(of: high.location))
        let scrollBefore = editor.textView.visibleRect.minY

        await click(at: high.location + 3)
        let after = untouched()
        let clickedAfter = try #require(documentY(of: high.location))

        #expect(before.count == 6 && after == before,
                "content above the click moved: \(before) -> \(after)")
        #expect(clickedAfter == clickedBefore,
                "the clicked paragraph itself moved: \(clickedBefore) -> \(clickedAfter)")
        #expect(editor.textView.visibleRect.minY == scrollBefore, "the click scrolled")
    }

    /// A repaint that changes nothing must not move the view.
    ///
    /// The isolating case, with no click and no reveal in it: scroll far down,
    /// repaint the document exactly as it already looks, and see whether the
    /// line you were reading is still where it was. If this moves, the cause
    /// is the *whole-document* repaint itself — setting attributes across the
    /// file invalidates its layout, and TextKit re-estimates the prefix above
    /// the viewport it has not laid out — and no amount of compensating for a
    /// paragraph's reveal can help, because no reveal changed.
    @Test func aRepaintThatChangesNothingDoesNotMoveTheView() async throws {
        var long = document
        for index in 12..<90 {
            long += "\n\nParagraph \(index) says $x^\(index)$ and *emphasis* here too, "
                + "continuing with enough words to wrap onto another line or two."
        }
        let editor = makeEditor(text: long)
        editor.coordinator.highlightNow()
        await settle()

        // Measured the way the reader sees it, and *without* forcing layout:
        // which line is at the top of the viewport, and how far into it. Asking
        // for a document-wide layout to measure would lay out the prefix whose
        // re-estimation is the thing under test, and the test would pass by
        // having destroyed its own subject.
        let lm = editor.textView.textLayoutManager
        func topOfViewport() -> (offset: Int, into: CGFloat)? {
            guard let anchor = ViewportAnchor.capture(
                in: lm, visible: editor.textView.visibleRect),
                  let cm = lm.textContentManager else { return nil }
            return (cm.offset(from: cm.documentRange.location, to: anchor.location),
                    anchor.offset)
        }

        editor.textView.scroll(CGPoint(x: 0, y: 4000))
        editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
        await settle()

        let before = try #require(topOfViewport())

        // The same paint, over the same text, with the same caret: nothing
        // about what is on screen should differ afterwards.
        editor.coordinator.invalidateHighlight()
        editor.coordinator.highlightNow()
        await settle()

        let after = try #require(topOfViewport())
        #expect(before.offset == after.offset && abs(before.into - after.into) < 1,
                "a no-op repaint changed the top of the viewport: \(before) -> \(after)")
    }

    /// `j` moves down a line on screen, not down a paragraph.
    ///
    /// The reported bug: with wrapping on, a paragraph is many lines to the
    /// reader and one line to the file, so a motion computed from the text
    /// skipped the whole paragraph every time.
    @Test func downMovesByWrappedLineNotByParagraph() async throws {
        let paragraph = String(repeating: "words that wrap and keep going ", count: 12)
        let editor = makeEditor(text: paragraph + "\n\nA second paragraph.")
        editor.coordinator.highlightNow()
        await settle()

        editor.textView.textSelection = NSRange(location: 0, length: 0)
        editor.textView.run(.down, count: 1, mode: .normal)
        await settle()

        let landed = editor.textView.textSelection.location
        #expect(landed > 0, "did not move")
        #expect(landed < (paragraph as NSString).length,
                "left the paragraph entirely — moved by source line, not by wrapped line")
    }

    /// Down goes onto the next line, not to the end of this one.
    ///
    /// The granularity bug, and the reason it hid: with a *soft* wrap the end
    /// of one segment and the start of the next are the same offset, so a
    /// document without hard line breaks cannot tell the two apart. Put a real
    /// newline in and the caret stops at the end of the line it started on.
    @Test func downCrossesALineBreakInsteadOfStoppingAtItsEnd() async throws {
        let editor = makeEditor(text: "Intro line.\n\nA paragraph after it.")
        editor.coordinator.highlightNow()
        await settle()

        editor.textView.textSelection = NSRange(location: 0, length: 1)
        editor.textView.run(.down, count: 1, mode: .normal)
        await settle()

        #expect(editor.textView.textSelection.location == 12,
                "landed at \(editor.textView.textSelection.location); 11 is the end of the line it started on")
    }

    /// Revealing something puts it in the middle, not against the edge.
    ///
    /// `scrollRangeToVisible` moves the minimum distance, so a line reached by
    /// a find or by opening a section landed on the boundary — where the next
    /// few points of reflow pushed it back out again.
    @Test func revealingSomethingFarAwayCentresIt() async throws {
        var long = document
        for index in 12..<200 {
            long += "\n\nParagraph \(index) says something and continues with "
                + "enough words to wrap onto another line or two."
        }
        let editor = makeEditor(text: long)
        editor.coordinator.highlightNow()
        await settle()

        let ns = long as NSString
        let target = ns.range(of: "Paragraph 120")
        try #require(target.location != NSNotFound)

        editor.textView.reveal(target)
        await settle()

        let lm = editor.textView.textLayoutManager
        let cm = try #require(lm.textContentManager)
        let range = try #require(NSTextRange(NSRange(location: target.location, length: 0),
                                             in: cm))
        let frame = try #require(lm.textSegmentFrame(at: range.location, type: .standard))
        let visible = editor.textView.visibleRect
        let offCentre = abs(frame.midY - visible.midY)
        #expect(offCentre < visible.height / 4,
                "landed \(offCentre)pt from the middle of \(visible.height)")
    }

    /// And something already on screen is left exactly where it is — which is
    /// what made leaving insert mode shift the page.
    @Test func revealingSomethingAlreadyVisibleDoesNotMove() async throws {
        let editor = makeEditor(text: document)
        editor.coordinator.highlightNow()
        await settle()

        let before = editor.textView.visibleRect.minY
        editor.textView.reveal(NSRange(location: 5, length: 0))
        await settle()

        #expect(editor.textView.visibleRect.minY == before,
                "the view moved for something already in front of the reader")
    }

    // MARK: What an edit repaints
    //
    // The region, which is checkable. Not the thing it is for: a headless
    // window never runs the viewport layout pass, so a full repaint discards
    // nothing here and the collapse this avoids cannot be reproduced. That
    // half is measured in the running app or not at all.

    /// The repaint still has to reach what the edit actually changed, or the
    /// saving is just a document that stops being coloured.
    @Test func anEditRepaintsTheParagraphItTouched() async throws {
        let editor = makeEditor(text: document)
        editor.coordinator.highlightNow()
        await settle()

        let ns = (editor.textView.text ?? "") as NSString
        let region = MaximalEditor.Coordinator.repaintRegion(
            for: [NSRange(location: 5, length: 1)], in: ns,
            content: editor.textView.text ?? "", tokenizer: StubTokenizer())
        let paragraph = ns.paragraphRange(for: NSRange(location: 5, length: 1))
        #expect(NSIntersectionRange(region, paragraph).length == paragraph.length,
                "the edited paragraph was not covered")
    }

    /// A token spanning paragraphs is repainted whole: editing one line of a
    /// display equation restyles all of it, and half a repaint leaves the rest
    /// wearing the markup it had before.
    @Test func aRepaintGrowsToCoverTheTokensItTouches() async throws {
        // The stub's tokens are `$…$` runs, and this one crosses a paragraph
        // break — the shape a display equation has.
        let text = "Intro paragraph here.\n\n$x = 1\n\ny = 2$\n\nAfter."
        let ns = text as NSString
        let equation = ns.range(of: "$x = 1\n\ny = 2$")
        try #require(equation.location != NSNotFound)

        // An edit on the equation's last line only.
        let region = MaximalEditor.Coordinator.repaintRegion(
            for: [ns.range(of: "y = 2")], in: ns, content: text,
            tokenizer: StubTokenizer())

        #expect(region.location <= equation.location
                && NSMaxRange(region) >= NSMaxRange(equation),
                "region \(region) does not cover the equation at \(equation)")
        #expect(region.length < ns.length, "it repainted the whole document anyway")
    }

    // MARK: What a click leaves behind

    /// Normal mode always has a character selected. A click does not know
    /// that, and AppKit's mouse handling has never heard of the grammar.
    @Test func aClickDoesNotLeaveNormalModeWithoutASelection() async throws {
        let editor = makeEditor(text: document)
        editor.coordinator.highlightNow()
        await settle()

        // What a click does: a collapsed selection, set outside the engine.
        editor.textView.textSelection = NSRange(location: 5, length: 0)
        editor.coordinator.textViewDidChangeSelection(
            Notification(name: STTextView.didChangeSelectionNotification,
                         object: editor.textView))
        await settle()

        #expect(editor.textView.textSelection == NSRange(location: 5, length: 1),
                "left at \(editor.textView.textSelection), which no verb can act on")
    }

    /// Which is what `d` after a click was actually hitting: nothing selected,
    /// so nothing deleted — and an empty edit announced anyway.
    @Test func deletingAfterAClickDeletesTheCharacterUnderIt() async throws {
        let editor = makeEditor(text: document)
        editor.coordinator.highlightNow()
        await settle()
        let before = editor.textView.text ?? ""

        editor.textView.textSelection = NSRange(location: 5, length: 0)
        editor.coordinator.textViewDidChangeSelection(
            Notification(name: STTextView.didChangeSelectionNotification,
                         object: editor.textView))
        await settle()

        editor.textView.run(.delete, count: 1, mode: .normal)
        await settle()

        #expect((editor.textView.text ?? "").count == before.count - 1,
                "d after a click changed nothing")
    }

    /// And the guard behind it: replacing nothing with nothing is not an edit,
    /// so it must not be announced as one. A text change repaints the whole
    /// document, which invalidates its layout and slides the page.
    @Test func anEmptyEditIsNotAnnouncedAsAChange() async throws {
        let editor = makeEditor(text: document)
        editor.coordinator.highlightNow()
        await settle()
        editor.textView.undoManager?.removeAllActions()

        editor.textView.apply(EditOutcome(edit: (NSRange(location: 5, length: 0), ""),
                                          selection: NSRange(location: 5, length: 1),
                                          mode: .normal))
        await settle()

        #expect(editor.textView.undoManager?.canUndo != true,
                "an edit that changes nothing reached the document")
    }

    /// The commands that mean a collapsed selection still get one: entering
    /// insert mode is not a click.
    @Test func enteringInsertModeKeepsItsCollapsedSelection() async throws {
        let editor = makeEditor(text: document)
        editor.coordinator.highlightNow()
        await settle()

        editor.textView.run(.insertBefore, count: 1, mode: .normal)
        await settle()

        #expect(editor.textView.textSelection.length == 0,
                "insert mode was handed a selection it did not ask for")
    }

    // MARK: Keeping the caret in view

    /// A motion whose caret is already on screen leaves the view alone.
    ///
    /// Not merely "does not scroll" — does not *ask TextKit to lay anything
    /// out*. `apply` used to force `ensureLayout` up to the caret on every
    /// command, which replaces estimated heights with measured ones and moves
    /// every line below the point it reaches. Escape runs a command and goes
    /// nowhere, and so does typing after a delete.
    @Test func aMotionWithTheCaretInViewLeavesTheViewAlone() async throws {
        let editor = makeEditor(text: document)
        editor.coordinator.highlightNow()
        await settle()

        editor.textView.textSelection = NSRange(location: 5, length: 0)
        let before = editor.textView.visibleRect.minY

        editor.textView.keepVisible(NSRange(location: 5, length: 0))
        await settle()

        #expect(editor.textView.visibleRect.minY == before,
                "the view moved for a caret already in front of the reader")
    }

    /// And one whose caret is not still goes and gets it — the half the rule
    /// above must not cost.
    @Test func aMotionWithTheCaretOffScreenStillFollowsIt() async throws {
        var long = document
        for index in 12..<200 {
            long += "\n\nParagraph \(index) says something and continues with "
                + "enough words to wrap onto another line or two."
        }
        let editor = makeEditor(text: long)
        editor.coordinator.highlightNow()
        await settle()
        #expect(editor.textView.visibleRect.minY < 1, "should start at the top")

        let ns = long as NSString
        let target = ns.range(of: "Paragraph 120")
        try #require(target.location != NSNotFound)

        editor.textView.keepVisible(NSRange(location: target.location, length: 0))
        await settle()

        #expect(editor.textView.visibleRect.minY > 100,
                "the view stayed at \(editor.textView.visibleRect.minY) with the caret far below")
    }

    /// Unlike a reveal, it moves the least it can: a motion that stepped one
    /// line and re-centred the page would be its own kind of lurch.
    @Test func keepingTheCaretInViewDoesNotCentreIt() async throws {
        var long = document
        for index in 12..<200 {
            long += "\n\nParagraph \(index) says something and continues with "
                + "enough words to wrap onto another line or two."
        }
        let editor = makeEditor(text: long)
        editor.coordinator.highlightNow()
        await settle()

        let ns = long as NSString
        let target = ns.range(of: "Paragraph 120")
        try #require(target.location != NSNotFound)
        editor.textView.keepVisible(NSRange(location: target.location, length: 0))
        await settle()

        let lm = editor.textView.textLayoutManager
        let cm = try #require(lm.textContentManager)
        let range = try #require(NSTextRange(NSRange(location: target.location, length: 0),
                                             in: cm))
        let frame = try #require(lm.textSegmentFrame(at: range.location, type: .standard))
        let visible = editor.textView.visibleRect
        // Scrolled down to reach it, so it lands against the bottom edge, not
        // in the middle the way `reveal` puts it.
        #expect(frame.midY > visible.midY,
                "a minimum scroll should leave the caret at the near edge, not centred")
    }

    /// A motion takes the view with it.
    ///
    /// The counterpart to pinning the viewport across a click, and the reason
    /// the two cannot share a rule. Assigning the selection notifies
    /// synchronously, *before* the motion scrolls, so a repaint that anchors on
    /// what it sees at that moment captures the old viewport and then restores
    /// it — putting the view back and leaving the caret wherever it went. The
    /// cursor moves and nothing follows it.
    @Test func aMotionScrollsTheViewToTheCaret() async throws {
        var long = document
        for index in 12..<200 {
            long += "\n\nParagraph \(index) says $x^\(index)$ and *emphasis* here too, "
                + "continuing with enough words to wrap onto another line or two."
        }
        let editor = makeEditor(text: long)
        editor.coordinator.highlightNow()
        await settle()

        editor.textView.textSelection = NSRange(location: 0, length: 0)
        editor.coordinator.textViewDidChangeSelection(
            Notification(name: STTextView.didChangeSelectionNotification,
                         object: editor.textView))
        await settle()
        #expect(editor.textView.visibleRect.minY < 1, "should start at the top")

        editor.textView.run(.lastLine, count: 1, mode: .normal)
        await settle()

        #expect(editor.textView.visibleRect.minY > 100,
                "G moved the caret and left the view behind at \(editor.textView.visibleRect.minY)")
    }

    /// A click through the engine's own mouse handling, rather than a
    /// selection assigned by hand.
    ///
    /// Worth having — every other test here skips that path — but be clear
    /// about what it does *not* cover: the reported viewport lurch does not
    /// reproduce in a window that never draws. Measured in the running app, a
    /// click collapses TextKit's laid-out extent (9435pt to 2879pt) and the
    /// line at a stationary scroll offset moves forward by a thousand
    /// characters. Headless, the layout survives the repaint and nothing
    /// moves, so this asserts the click path works, not that the lurch is
    /// gone.
    ///
    /// Every other test here assigns `textSelection` and calls the delegate by
    /// hand, which skips the engine's own mouse handling — and that handling is
    /// where a selection change can route into the engine's scroll-to-visible,
    /// which corrects the content size and, for a target outside the viewport,
    /// re-anchors TextKit's own viewport. Both move content under a fixed
    /// scroll offset with no reveal involved, which is what the report says.
    @Test func clickingWhileScrolledDownDoesNotMoveTheView() async throws {
        var long = document
        for index in 12..<200 {
            long += "\n\nParagraph \(index) says $x^\(index)$ and *emphasis* here too, "
                + "continuing with enough words to wrap onto another line or two."
        }
        let editor = makeEditor(text: long)
        editor.coordinator.highlightNow()
        await settle()

        let lm = editor.textView.textLayoutManager
        func topOfViewport() -> (offset: Int, into: CGFloat)? {
            guard let anchor = ViewportAnchor.capture(
                in: lm, visible: editor.textView.visibleRect),
                  let cm = lm.textContentManager else { return nil }
            return (cm.offset(from: cm.documentRange.location, to: anchor.location),
                    anchor.offset)
        }

        editor.textView.scroll(CGPoint(x: 0, y: 3000))
        editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
        await settle()

        let before = try #require(topOfViewport())

        // A click a third of the way down whatever is on screen.
        let visible = editor.textView.visibleRect
        let point = CGPoint(x: visible.midX, y: visible.minY + visible.height / 3)
        let inWindow = editor.textView.convert(point, to: nil)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: editor.window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        editor.textView.mouseDown(with: down)
        await settle()

        let after = try #require(topOfViewport())
        #expect(before.offset == after.offset && abs(before.into - after.into) < 1,
                "the click moved the viewport: \(before) -> \(after)")
    }

    /// Clicking with the caret far above the viewport must not shift the view.
    ///
    /// This is the one case anchoring exists for: the paragraph losing its
    /// reveal is off-screen *above*, so its height change moves every line the
    /// reader is looking at. Absolute-position anchoring can't do this job —
    /// TextKit re-estimates the prefix above the viewport, which is what threw
    /// the view hundreds of points per click — so the compensation has to come
    /// from that one paragraph's own height delta.
    @Test func clickingWithTheCaretScrolledOffScreenDoesNotShiftTheView() async throws {
        // Long enough that the target sits mid-document — clamped at the bottom
        // the scroll can't move and the test measures clamping, not the fix.
        var long = document
        for index in 12..<90 {
            long += "\n\nParagraph \(index) says $x^\(index)$ and *emphasis* here too, "
                + "continuing with enough words to wrap onto another line or two."
        }
        let editor = makeEditor(text: long)
        editor.coordinator.highlightNow()
        await settle()

        let ns = long as NSString
        func offset(_ name: String) throws -> Int {
            let r = ns.range(of: name)
            try #require(r.location != NSNotFound)
            return r.location
        }
        func documentY(of offset: Int) -> CGFloat? {
            let lm = editor.textView.textLayoutManager
            editor.textView.layoutSubtreeIfNeeded()
            lm.ensureLayout(for: lm.documentRange)
            guard let cm = lm.textContentManager,
                  let range = NSTextRange(NSRange(location: offset, length: 0), in: cm),
                  let (fragment, _) = MathOverlayLayout.lineFragment(
                    containing: range.location, in: lm)
            else { return nil }
            return fragment.layoutFragmentFrame.minY
        }
        func click(at offset: Int) async {
            editor.textView.textSelection = NSRange(location: offset, length: 0)
            editor.coordinator.textViewDidChangeSelection(
                Notification(name: STTextView.didChangeSelectionNotification,
                             object: editor.textView))
            await settle()
        }

        // Caret near the top, then scroll far down — the caret's paragraph ends
        // up well above the viewport.
        let near = try offset("Paragraph 2 ")
        await click(at: near + 3)

        let target = try offset("Paragraph 25")
        let targetY = try #require(documentY(of: target))
        editor.textView.scroll(CGPoint(x: 0, y: targetY - 80))
        editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
        await settle()

        // Where a visible line sits on screen, before and after clicking it.
        let screenBefore = try #require(documentY(of: target)) - editor.textView.visibleRect.minY

        await click(at: target + 3)

        let screenAfter = try #require(documentY(of: target)) - editor.textView.visibleRect.minY
        #expect(abs(screenAfter - screenBefore) < 1,
                "the view jerked: the clicked line moved \(screenAfter - screenBefore)pt on screen")
    }

    /// The user's report: clicking into a paragraph reveals its markup, which
    /// changes heights — and every image has to move with its text, not stay
    /// behind at the geometry the repaint was measured against.
    @Test func imagesFollowTheirEquationsAcrossAClick() async throws {
        let editor = makeEditor(text: document)
        editor.coordinator.highlightNow()
        await settle()

        // Click into the first paragraph: caret moves, markup there reveals.
        let ns = document as NSString
        let clicked = ns.range(of: "Paragraph 0")
        editor.textView.textSelection = NSRange(location: clicked.location + 3, length: 0)
        editor.coordinator.textViewDidChangeSelection(
            Notification(name: STTextView.didChangeSelectionNotification,
                         object: editor.textView))
        await settle()

        let equation = lastEquation(in: document)
        let expected = try #require(settledFrame(for: equation, in: editor))
        let placed = try #require(overlays(in: editor.textView).min {
            abs($0.frame.minY - expected.minY) < abs($1.frame.minY - expected.minY)
        })
        #expect(abs(placed.frame.minY - expected.minY) < 1,
                "image drifted from its text on click: image at \(placed.frame.minY), text at \(expected.minY)")
    }
}
