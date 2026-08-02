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
                    HStack(spacing: 0) {
                        Spacer(minLength: 24)
                        editor(style: .prose()).frame(maxWidth: 760)
                        Spacer(minLength: 24)
                    }
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

    @Test func switchingToWriteModeSettles() async throws {
        let mode = Mode()
        let hosting = NSHostingView(rootView: Shell(
            mode: mode, text: document,
            tokenizer: StubTokenizer(), math: StubMath()))
        // Sized so the write column sits at its maxWidth boundary — where the
        // editor's width is negotiable and a content-derived intrinsic size can
        // oscillate the constraint solver.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1310, height: 850),
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
