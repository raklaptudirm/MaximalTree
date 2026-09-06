import Testing
import AppKit
import SwiftUI
import STTextView
@testable import MaximalEditorKit

/// The editor inside a real `NSHostingView`, switched between the typst
/// canvas's Typeset and Write layouts — the crash the pure-AppKit harness in
/// EditorOverlayTests cannot see, because the constraint feedback loop lives in
/// the SwiftUI hosting machinery (`NSHostingView.SizeConstraints` ping-ponging
/// with `AppKitPlatformViewHost.invalidateLayout`).
///
/// Detection: after `layoutIfNeeded` a settled window has no view still
/// flagged `needsUpdateConstraints`. A feedback loop re-dirties some view on
/// every turn, forever — which is what AppKit's loop detector eventually
/// aborts on in the app.
@MainActor
@Suite struct EditorHostingTests {
    private final class StubMath: EditorMathRenderer {
        let image: NSImage = {
            let image = NSImage(size: CGSize(width: 120, height: 32))
            image.lockFocus()
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: 120, height: 32).fill()
            image.unlockFocus()
            return image
        }()

        /// Like the real compiler seam: a miss first, the completion later —
        /// so switching modes triggers the same repaint-per-landed-render storm
        /// the app sees, not one stable paint.
        private var ready = Set<String>()

        func renderedMath(for equation: String, fontSize: CGFloat, dark: Bool,
                          block: Bool,
                          completion: @escaping @MainActor () -> Void) -> RenderedEquation? {
            let key = "\(equation)|\(fontSize)|\(block)"
            if ready.contains(key) {
                return RenderedEquation(image: image, baseline: 24)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int.random(in: 10...80))) { [weak self] in
                self?.ready.insert(key)
                completion()
            }
            return nil
        }
    }

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
                let block = ns.substring(with: range).hasPrefix("$ ")
                tokens.append((range, .math(block: block)))
                search = NSRange(location: close.upperBound,
                                 length: ns.length - close.upperBound)
            }
            return tokens
        }
    }

    @Observable
    final class Mode {
        var write = false
    }

    /// The typst canvas's two layouts around one identity-stable editor.
    private struct Harness: View {
        @Bindable var mode: Mode
        @State var text: String
        let tokenizer: StubTokenizer
        let math: StubMath

        var body: some View {
            Group {
                if mode.write {
                    // Full width, as the canvas gives it: the editor centres
                    // its own column by inset so the scroller stays at the
                    // window edge.
                    editor(style: .prose())
                } else {
                    editor(style: .code(size: 12, wrapLines: true, indentSpaces: 2))
                }
            }
        }

        private func editor(style: EditorStyle) -> some View {
            MaximalEditor(text: $text, style: style,
                          tokenizer: tokenizer, mathRenderer: math)
                .id("node")
                .clipped()
        }
    }

    /// A typst-ish document with prose, inline math, and multi-line display math.
    private var document: String {
        var lines = ["= Heading", ""]
        for index in 0..<8 {
            lines.append("Paragraph \(index) has inline $x_\(index)$ math and runs "
                         + "long enough to wrap when the column narrows in write mode.")
            lines.append("")
            lines.append("$ sum_(k=1)^\(index + 2) k \\\n  = (n(n+1))/2 $")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Views still marked dirty after a full layout pass.
    private func unsettled(in root: NSView) -> Int {
        var count = root.needsUpdateConstraints ? 1 : 0
        for subview in root.subviews { count += unsettled(in: subview) }
        return count
    }

    /// The shell structure around the canvas, faithful to ContentView: the
    /// split view whose column controller appears in the crash stack, the
    /// tab strip's fixedSize, and the trailing inspector.
    private struct Shell: View {
        @Bindable var mode: Mode
        @State var text: String
        let tokenizer: StubTokenizer
        let math: StubMath

        var body: some View {
            NavigationSplitView {
                List { Text("root") }
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240)
            } detail: {
                VStack(spacing: 0) {
                    HStack { Text("tab") }
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Harness(mode: mode, text: text,
                            tokenizer: tokenizer, math: math)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .inspector(isPresented: .constant(true)) {
                    Form { Text("inspector") }
                        .inspectorColumnWidth(min: 200, ideal: 260, max: 420)
                }
            }
        }
    }

    /// The oscillator itself: STTextView reports the *document* size as its
    /// intrinsic size, which re-enters the constraint solver after every
    /// re-wrap. The editor's subclass must not report one at all.
    @Test func editorTextViewReportsNoIntrinsicSize() {
        let scrollView = MaximalEditor.EditorTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView
        textView.text = String(repeating: "words that wrap and change height ", count: 200)
        #expect(textView.intrinsicContentSize.width == NSView.noIntrinsicMetric)
        #expect(textView.intrinsicContentSize.height == NSView.noIntrinsicMetric)
    }

    /// The reported crash: switching a small/new document to prose mode threw
    /// out of a layout pass (EXC_BREAKPOINT via `_crashOnException`).
    /// `updateNSView` runs inside the window's layout, and a style change was
    /// the one update that reassigned the font, the wrap mode, and every
    /// attribute in the document from in there. The switch must leave the pass
    /// untouched and still land — the text view ends up carrying the new style.
    @Test(arguments: ["", "x", "= H\n\nsome words $x^2$ here"])
    func modeSwitchAppliesWithoutMutatingLayoutInPlace(_ text: String) async throws {
        let mode = Mode()
        let hosting = NSHostingView(rootView: Shell(
            mode: mode, text: text,
            tokenizer: StubTokenizer(), math: StubMath()))
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 1310, height: 850),
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        defer { window.orderOut(nil) }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(30))
            window.layoutIfNeeded()
        }

        func editorTextView(in view: NSView) -> STTextView? {
            if let found = view as? STTextView { return found }
            for sub in view.subviews {
                if let found = editorTextView(in: sub) { return found }
            }
            return nil
        }
        let before = try #require(editorTextView(in: hosting))
        #expect(before.font.fontName == EditorStyle.code(size: 12).font.fontName)

        mode.write = true
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(30))
            window.displayIfNeeded()
            window.layoutIfNeeded()
        }

        // Deferring must not mean dropping: prose is serif, code is monospaced.
        let after = try #require(editorTextView(in: hosting))
        #expect(after.font.fontName == EditorStyle.prose().font.fontName,
                "the deferred style change never landed for a \(text.count)-char document")
    }

    /// A newly created file is empty or nearly so — the reported hang-then-crash
    /// case. An empty text view has no content to size against, which is exactly
    /// where a size negotiation can fail to converge.
    @Test(arguments: ["", "x", "= H\n\nsome words $x^2$ here"])
    func switchingToWriteModeSettlesForSmallDocuments(_ text: String) async throws {
        let mode = Mode()
        let hosting = NSHostingView(rootView: Shell(
            mode: mode, text: text,
            tokenizer: StubTokenizer(), math: StubMath()))
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 1310, height: 850),
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        defer { window.orderOut(nil) }

        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(30))
            window.layoutIfNeeded()
        }

        mode.write = true

        var dirtyTurns = 0
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(30))
            window.displayIfNeeded()
            window.layoutIfNeeded()
            if unsettled(in: hosting) > 0 { dirtyTurns += 1 }
        }
        #expect(dirtyTurns < 20,
                "constraints never settle for a \(text.count)-char document: \(dirtyTurns)/25")
    }

    @Test func switchingToWriteModeSettles() async throws {
        let mode = Mode()
        let hosting = NSHostingView(rootView: Shell(
            mode: mode, text: document,
            tokenizer: StubTokenizer(), math: StubMath()))
        // Sized so the write column sits at its maxWidth boundary — where the
        // editor's width is negotiable and a content-derived intrinsic size can
        // oscillate the constraint solver.
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 1310, height: 850),
                              styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        // On screen: the display-cycle flush — where AppKit's feedback-loop
        // detector counts constraint passes — only runs for visible windows.
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        defer { window.orderOut(nil) }

        // Let the initial (Typeset-style) layout and overlay passes finish.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(30))
            window.layoutIfNeeded()
        }

        mode.write = true

        // Pump display turns. A healthy switch settles almost immediately; the
        // feedback loop re-dirties the hosting subtree on every turn (the app
        // aborts once AppKit's detector counts enough passes in one flush).
        var dirtyTurns = 0
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(30))
            window.displayIfNeeded()
            window.layoutIfNeeded()
            if unsettled(in: hosting) > 0 { dirtyTurns += 1 }
        }
        #expect(dirtyTurns < 20,
                "constraints never settle after the mode switch: \(dirtyTurns)/25 dirty turns")
    }
}

/// Editor styles and the geometry every consumer derives from them.
@MainActor
@Suite struct EditorStyleGeometryTests {
    /// The invariant behind the jittery caret: `lineHeightMultiple` is the one
    /// paragraph property STTextView compensates for at *draw* time — it shifts
    /// glyphs by `-(height × (multiple − 1) / 2)` in the two glyph renderers and
    /// the gutter, and nowhere else. The caret, selection rectangles, and hit
    /// testing read raw layout geometry, so any multiple ≠ 1 puts the drawn text
    /// somewhere the caret and mouse don't agree with. Our styles must never
    /// trigger it.
    @Test func stylesNeverTriggerTheDrawTimeGlyphShift() {
        for style in [EditorStyle.prose(), .prose(size: 18),
                      .code(), .code(size: 14, wrapLines: true)] {
            let paragraph = style.paragraphStyle
            // 0 is NSParagraphStyle's "natural"; the engine maps it to 1.0.
            let effective = paragraph.lineHeightMultiple == 0 ? 1 : paragraph.lineHeightMultiple
            #expect(effective == 1,
                    "a multiple of \(effective) shifts glyphs away from the caret")
            let shift = -(style.naturalLineHeight * (effective - 1) / 2)
            #expect(shift == 0)
        }
    }

    /// …and the roominess that motivated the multiple is preserved, now as
    /// spacing that lives inside the line fragment where every consumer sees it.
    @Test func proseStaysRoomierThanTheBareFont() throws {
        let style = EditorStyle.prose()
        #expect(style.lineSpacing > 0)
        #expect(style.paragraphStyle.lineSpacing == style.lineSpacing)

        // Measure a real line: the laid-out height must exceed the font's own,
        // by the spacing we asked for.
        let storage = NSTextContentStorage()
        let layoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 400,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        storage.addTextLayoutManager(layoutManager)
        storage.textStorage?.setAttributedString(NSAttributedString(
            string: "one line\nand another",
            attributes: [.font: style.font, .paragraphStyle: style.paragraphStyle]))
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        var heights: [CGFloat] = []
        layoutManager.enumerateTextLayoutFragments(from: layoutManager.documentRange.location,
                                                   options: [.ensuresLayout]) { fragment in
            heights += fragment.textLineFragments.map(\.typographicBounds.height)
            return true
        }
        let first = try #require(heights.first)
        #expect(first > style.font.ascender - style.font.descender,
                "prose lines lost their air: \(first)")
    }
}

/// Non-wrapping code needs somewhere to go sideways.
@MainActor
@Suite struct EditorHorizontalScrollTests {
    /// With wrapping off, a line longer than the viewport must make the
    /// document wider than the viewport — that width *is* the scrollable
    /// range. Without it the tail of every long line is simply unreachable.
    @Test func longLinesMakeTheDocumentWiderThanTheViewport() async throws {
        let scrollView = MaximalEditor.EditorTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView
        let style = EditorStyle.code()          // wrapLines: false
        textView.font = style.font
        textView.defaultParagraphStyle = style.paragraphStyle
        textView.widthTracksTextView = style.wrapLines
        textView.text = String(repeating: "let value = compute(everything) ; ", count: 40)

        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        scrollView.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        window.contentView = scrollView
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        defer { window.orderOut(nil) }
        for _ in 0..<6 {
            try? await Task.sleep(for: .milliseconds(30))
            window.displayIfNeeded()
            window.layoutIfNeeded()
        }

        let viewport = scrollView.contentView.bounds.width
        let width = textView.frame.width
        #expect(width > viewport + 1,
                "document \(width) fits inside viewport \(viewport) — nowhere to scroll")
        #expect(scrollView.hasHorizontalScroller)
    }

    /// A real file's long line is rarely its *last* line — and that is exactly
    /// what broke. STTextView sizes the document by enumerating fragments in
    /// reverse from the end and stopping at the first, so it measures the last
    /// line and clamps up to the viewport. Every earlier test here used a
    /// single long line, which is also the last line, and so passed while the
    /// app had no horizontal scroll at all.
    @Test func aLongLineAboveShorterOnesStillWidensTheDocument() async throws {
        let scrollView = MaximalEditor.EditorTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView
        let style = EditorStyle.code()
        textView.font = style.font
        textView.defaultParagraphStyle = style.paragraphStyle
        textView.widthTracksTextView = style.wrapLines
        textView.text = String(repeating: "let value = compute(everything) ; ", count: 40)
            + "\nshort\nalso short\n"

        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        scrollView.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        window.contentView = scrollView
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        defer { window.orderOut(nil) }
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(30))
            window.displayIfNeeded()
            window.layoutIfNeeded()
        }

        let viewport = scrollView.contentView.bounds.width
        let width = textView.frame.width
        #expect(width > viewport + 1,
                "document \(width) fits in viewport \(viewport) — long line unreachable")
    }

    /// The text editor canvas's own shape: a VStack with `.clipped()`. Without
    /// a flexible frame the editor's width is whatever size negotiation lands
    /// on rather than the pane's — and a scroll view that isn't the size of its
    /// viewport has no viewport to scroll within.
    @Test func editorFillsItsPaneInTheCanvasLayout() async throws {
        struct CanvasShape: View {
            @State var text: String
            var body: some View {
                VStack(spacing: 0) {
                    MaximalEditor(text: $text, style: .code())
                        .clipped()
                }
            }
        }
        let hosting = NSHostingView(rootView: CanvasShape(
            text: String(repeating: "let value = compute(everything) ; ", count: 40)))
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        defer { window.orderOut(nil) }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(40))
            window.displayIfNeeded()
            window.layoutIfNeeded()
        }

        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let found = view as? NSScrollView { return found }
            for sub in view.subviews {
                if let found = findScrollView(sub) { return found }
            }
            return nil
        }
        let scrollView = try #require(findScrollView(hosting))
        #expect(abs(scrollView.frame.width - hosting.bounds.width) < 1,
                "editor is \(scrollView.frame.width) wide in a \(hosting.bounds.width) pane")

        // …and the document inside it still has to overflow, or there is
        // nothing for the scroller (or the trackpad) to move.
        let textView = try #require(scrollView.documentView as? STTextView)
        let viewport = scrollView.contentView.bounds.width
        print("PROBE canvas doc=\(textView.frame.width) viewport=\(viewport) tracks=\(textView.widthTracksTextView) gutter=\(textView.showsLineNumbers)")
        #expect(textView.frame.width > viewport + 1,
                "document \(textView.frame.width) fits in viewport \(viewport) — nothing scrolls")
    }

    /// The same invariant through SwiftUI, which is how the app actually
    /// mounts the editor — and where its size is negotiated rather than set.
    @Test func longLinesStillScrollWhenHostedInSwiftUI() async throws {
        struct Host: View {
            @State var text: String
            var body: some View {
                MaximalEditor(text: $text, style: .code())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        let hosting = NSHostingView(rootView: Host(
            text: String(repeating: "let value = compute(everything) ; ", count: 40)))
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        defer { window.orderOut(nil) }
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(40))
            window.displayIfNeeded()
            window.layoutIfNeeded()
        }

        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let found = view as? NSScrollView { return found }
            for sub in view.subviews {
                if let found = findScrollView(sub) { return found }
            }
            return nil
        }
        let scrollView = try #require(findScrollView(hosting))
        let textView = try #require(scrollView.documentView as? STTextView)
        let viewport = scrollView.contentView.bounds.width
        let width = textView.frame.width
        #expect(viewport > 100, "the editor got a real width: \(viewport)")
        #expect(width > viewport + 1,
                "document \(width) fits inside viewport \(viewport) — nowhere to scroll")
    }
}

/// Being mounted is not the same as being scrollable.
@MainActor
@Suite struct EditorReadinessTests {
    /// The distinction a phony-node jump turns on. A jump that waits only for
    /// the editor to *exist* sets a selection and goes nowhere, because
    /// TextKit drops a scroll before the view is in a window with a laid-out
    /// scroll view — which is why opening a section used to take two clicks.
    @Test func anEditorIsNotScrollableUntilItIsOnScreen() async throws {
        let controller = EditorController()
        #expect(!controller.canScroll, "nothing attached at all")

        let scrollView = MaximalEditor.EditorTextView.scrollableTextView()
        let textView = try #require(scrollView.documentView as? MaximalEditor.EditorTextView)
        textView.text = String(repeating: "a line of text\n", count: 200)
        controller.textView = textView
        #expect(!controller.canScroll, "attached, but nowhere to scroll yet")

        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: false)
        scrollView.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        window.contentView = scrollView
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        defer { window.orderOut(nil) }
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(20))
            window.displayIfNeeded()
            window.layoutIfNeeded()
        }

        #expect(controller.canScroll, "on screen and laid out, and still refusing")
    }
}
