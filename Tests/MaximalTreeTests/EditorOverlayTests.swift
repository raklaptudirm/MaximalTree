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
    private final class StubMath: EditorMathRenderer {
        let image: NSImage = {
            let image = NSImage(size: CGSize(width: 48, height: 22))
            image.lockFocus()
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: 48, height: 22).fill()
            image.unlockFocus()
            return image
        }()

        func renderedMath(for equation: String, fontSize: CGFloat, dark: Bool,
                          block: Bool,
                          completion: @escaping @MainActor () -> Void) -> RenderedEquation? {
            RenderedEquation(image: image, baseline: 16)
        }
    }

    /// Marks every `$…$` as inline math and every heading line as a heading, so
    /// a repaint has real concealment work to do.
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
            return tokens
        }
    }

    private struct Editor {
        let scrollView: NSScrollView
        let textView: STTextView
        let coordinator: MaximalEditor.Coordinator
        let window: NSWindow
    }

    /// A live editor in a window, wired the way `makeNSView` wires one.
    private func makeEditor(text: String) -> Editor {
        let scrollView = STTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView
        var storage = text
        let binding = Binding(get: { storage }, set: { storage = $0 })
        let coordinator = MaximalEditor.Coordinator(
            text: binding, tokenizer: StubTokenizer(), mathRenderer: StubMath(),
            completionProvider: nil)
        let style = EditorStyle.prose()
        textView.textDelegate = coordinator
        coordinator.textView = textView
        coordinator.lastStyle = style
        textView.font = style.font
        textView.defaultParagraphStyle = style.paragraphStyle
        textView.text = text
        // The app installs these; they re-place overlays on scroll and resize,
        // so they're part of the behaviour under test.
        coordinator.installObservers(for: textView, in: scrollView)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
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
            forEquationAt: range, image: CGSize(width: 48, height: 22),
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
