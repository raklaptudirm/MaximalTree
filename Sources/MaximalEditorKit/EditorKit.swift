import SwiftUI
import MaximalTreeKit
import AppKit
import STTextView
import STTextKitPlus

// MaximalEditorKit: the one place MaximalTree touches its editor engine.
//
// Engine: STTextView (TextKit 2). Chosen for cross-platform reach — the same
// package ships AppKit and UIKit implementations, so the iOS version of this
// framework wraps the same engine — and for maintenance health. Plugins depend
// on this framework only; the seam has already survived one full engine swap
// (from CodeEditSourceEditor) with zero plugin-code changes.
//
// This file: the editor view, its style, the controller, and the coordinator
// (binding sync, markup rendering, concealment, math overlays, completion
// triggering, scroll anchoring). Companions: EditorHighlighting.swift (token
// vocabulary + syntax tokenizer), EditorCompletion.swift (completion
// seam), EditorMath.swift (rendered-math seam).
//
// Ground rules:
// - The text binding is live: external changes push into the view.
// - Highlighting is painted as *rendering attributes* — display-only, never
//   touching the text storage or the undo stack; markup rendering additionally
//   uses storage fonts/paragraphs (those ARE layout) with a full base reset.

// MARK: - Style

/// How an editor should look and behave. Presets cover the two personalities used
/// in MaximalTree: `.code` (monospaced IDE) and `.prose` (serif manuscript).
public struct EditorStyle: Equatable {
    public enum Design: Hashable {
        case monospaced, serif
        /// A named font family, for prose you want to read in something
        /// particular. Falls back to the system serif when the family isn't
        /// installed, so a style outlives the font it names.
        case family(String)
    }

    public var design: Design
    public var size: CGFloat
    /// Extra space *between* lines, in points.
    ///
    /// Deliberately not `lineHeightMultiple`. A multiple is the one paragraph
    /// property the engine compensates for at *draw* time: it shifts glyphs up
    /// by `height × (multiple − 1) / 2` in exactly three places (the two glyph
    /// renderers and the gutter). The caret, selection rectangles, and hit
    /// testing all read raw layout geometry instead, so with a 1.5 multiple in
    /// prose the text was drawn ~7pt above the line the engine thought it was
    /// on — a caret that sat below its own text, selections offset from what
    /// they highlighted, and drags that grabbed the neighbouring line.
    /// `lineSpacing` lands *inside* the line fragment, so every consumer —
    /// glyphs, caret, selection, hit testing — agrees.
    public var lineSpacing: CGFloat
    /// Line height as a multiple of the natural height. Kept at 1 by both
    /// presets (see `lineSpacing`); non-1 values still work, and
    /// `MathOverlayLayout` compensates for the engine's draw-time shift, but
    /// the caret and selection will disagree with the glyphs.
    public var lineHeightMultiple: Double
    public var wrapLines: Bool
    public var indentSpaces: Int
    public var showsLineNumbers: Bool
    /// When set, markup tokens render as live formatting — headings sized and
    /// bolded, `*strong*`/`_emphasis_` styled, `#align` bodies aligned, delimiters
    /// dimmed — instead of syntax colors. The WYSIWYG-ish prose experience.
    public var rendersMarkup: Bool

    public init(design: Design, size: CGFloat, lineSpacing: CGFloat = 0,
                lineHeightMultiple: Double = 1,
                wrapLines: Bool, indentSpaces: Int, showsLineNumbers: Bool = true,
                rendersMarkup: Bool = false) {
        self.design = design
        self.size = size
        self.lineSpacing = lineSpacing
        self.lineHeightMultiple = lineHeightMultiple
        self.wrapLines = wrapLines
        self.indentSpaces = indentSpaces
        self.showsLineNumbers = showsLineNumbers
        self.rendersMarkup = rendersMarkup
    }

    public static func code(size: CGFloat = 12, wrapLines: Bool = false,
                            indentSpaces: Int = 4) -> EditorStyle {
        EditorStyle(design: .monospaced, size: size, lineSpacing: (size * 0.2).rounded(),
                    wrapLines: wrapLines, indentSpaces: indentSpaces)
    }

    /// A plain box of text: monospaced and wrapped, with no gutter and no
    /// markup rendering.
    ///
    /// The third personality, for the places that want an editor rather than a
    /// document — a commit message, a description. `.code` would number its
    /// lines, which says "file" about something that is one paragraph and a
    /// list, and `.prose` would render its markup, which a message written in
    /// plain text does not have.
    public static func plain(size: CGFloat = 12) -> EditorStyle {
        EditorStyle(design: .monospaced, size: size, lineSpacing: (size * 0.2).rounded(),
                    wrapLines: true, indentSpaces: 2, showsLineNumbers: false)
    }

    /// Manuscript, not IDE: no line-number gutter, markup rendered as formatting.
    ///
    /// Leading is a quarter of the size on top of whatever the face asks for,
    /// which lands the system serif near 1.5× — the ratio a book is set at.
    /// It was 0.6 and read as a double-spaced draft: the faces already carry
    /// their own leading (Literata's is 4pt more than New York's at the same
    /// size), so adding two thirds of the point size on top of that pushed
    /// every one of them past 1.8×.
    ///
    /// - Parameter family: the typeface to set it in; the system serif when nil.
    public static func prose(size: CGFloat = 15, family: String? = nil) -> EditorStyle {
        EditorStyle(design: family.map(Design.family) ?? .serif,
                    size: size, lineSpacing: (size * 0.25).rounded(),
                    wrapLines: true, indentSpaces: 2, showsLineNumbers: false,
                    rendersMarkup: true)
    }

    var font: NSFont {
        switch design {
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .serif:
            return Self.systemSerif(size: size)
        case .family(let name):
            // Asking for a family rather than a face leaves the weight and the
            // italic to `fontVariant(of:)`, which derives them from symbolic
            // traits — the same path the system serif takes.
            let descriptor = NSFontDescriptor(fontAttributes: [.family: name])
            return NSFont(descriptor: descriptor, size: size)
                ?? Self.systemSerif(size: size)
        }
    }

    private static func systemSerif(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        if let descriptor = base.fontDescriptor.withDesign(.serif),
           let serif = NSFont(descriptor: descriptor, size: size) {
            return serif
        }
        return base
    }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        // Left at the default (0 — "natural") unless a caller asks for one, so
        // the engine's draw-time glyph shift stays out of the picture.
        if lineHeightMultiple != 1 { style.lineHeightMultiple = lineHeightMultiple }
        return style
    }

    /// How wide a column of this text wants to be.
    ///
    /// Two and a half lowercase alphabets, which is the old compositor's rule
    /// for a comfortable measure and lands around 73 characters a line. It is
    /// measured in the actual face rather than counted in characters, so a
    /// narrow one like EB Garamond gets a narrower column for the same measure
    /// instead of a longer line.
    ///
    /// Derived from the style rather than fixed, so the column tracks the text
    /// size: making the text bigger widens the column by the same proportion
    /// and the measure stays put, which is the thing a reader actually feels.
    ///
    /// Includes the text container's 5pt of padding a side — that is frame,
    /// not text, and a caller sizing a view wants the frame.
    public var idealColumnWidth: CGFloat {
        let alphabet = "abcdefghijklmnopqrstuvwxyz" as NSString
        let width = alphabet.size(withAttributes: [.font: font]).width
        return (width * 2.5 + 10).rounded()
    }

    /// A line's full height with this style's spacing — the floor a reserved
    /// math box must clear so an equation never shrinks its own line.
    var naturalLineHeight: CGFloat {
        let font = self.font
        return font.ascender - font.descender + font.leading + lineSpacing
    }
}

// MARK: - Controller

/// A handle for programmatic edits and cursor movement on a live editor. Pass one
/// to `MaximalEditor(controller:)` and keep it in view `@State`.
public final class EditorController {
    weak var textView: STTextView?

    public init() {}

    /// Replace `range` with `replacement`, then select `selection` (coordinates in
    /// the resulting text). Undo-registered by the engine.
    @MainActor
    public func applyEdit(range: NSRange, replacement: String, selection: NSRange) {
        guard let textView else { return }
        textView.replaceCharacters(in: range, with: replacement)
        textView.moveCaret(to: selection)
    }

    /// Put the keyboard in this editor.
    ///
    /// A canvas that holds an editor alongside other things needs to be able
    /// to hand focus to it, and taking the keyboard is the editor's business
    /// rather than the caller's — the view is not something a plugin can
    /// reach.
    @MainActor
    public func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// Whether this editor is the one holding the keyboard.
    @MainActor
    public var isFocused: Bool {
        guard let textView else { return false }
        return textView.window?.firstResponder === textView
    }

    /// Current text and primary selection, for computing edits.
    @MainActor
    public func textAndSelection() -> (text: String, selection: NSRange)? {
        guard let textView else { return nil }
        return (textView.text ?? "", textView.textSelection)
    }

    /// Move the caret to a 1-based line/column and scroll it into view.
    @MainActor
    public func moveCursor(toLine line: Int, column: Int) {
        guard let textView else { return }
        let offset = MaximalEditor.offset(ofLine: line, column: column,
                                          in: textView.text ?? "")
        let range = NSRange(location: offset, length: 0)
        textView.moveCaret(to: range)
    }
}

// MARK: - Scrolling somewhere far

extension STTextView {
    /// Scroll a range into view, having first laid out everything above it.
    ///
    /// TextKit 2 lays out lazily and *estimates* the height of everything it
    /// has not reached, so the y of a location far from the viewport is a
    /// guess. Scrolling to a guess puts the view roughly there, and the real
    /// layout that follows moves the text underneath — the lurch after a jump
    /// to a heading, a `G`, or a section node opening at its line. Laying the
    /// prefix out first costs the work the jump was going to force anyway; it
    /// just pays for it before choosing where to land rather than after.
    /// Put the caret here and take the view with it.
    ///
    /// Both halves together, because the order is load-bearing: assigning the
    /// selection notifies synchronously, so anything reacting to it needs to
    /// know a motion is in progress *before* the scroll rather than after.
    func moveCaret(to range: NSRange) {
        let editor = self as? MaximalEditor.EditorTextView
        editor?.isFollowingCaret = true
        defer { editor?.isFollowingCaret = false }
        textSelection = range
        scrollToVisible(range)
    }

    func scrollToVisible(_ range: NSRange, ensuringLayout: Bool = true) {
        if ensuringLayout, let contentManager = textLayoutManager.textContentManager,
           let textRange = NSTextRange(range, in: contentManager) {
            textLayoutManager.ensureLayout(upTo: textRange.endLocation)
        }
        scrollRangeToVisible(range)
    }
}

// MARK: - Editor view

/// MaximalTree's editor. Wraps the engine behind a stable surface.
///
/// The text binding is live in both directions: typing updates the binding, and
/// external binding changes replace the view's content. Still give each document
/// its own `.id(...)` so per-document state (undo stack, scroll) resets cleanly.
public struct MaximalEditor: NSViewRepresentable {
    @Binding private var text: String
    private let fileURL: URL?
    private let style: EditorStyle
    private let initialCursorLine: Int?
    private let tokenizer: EditorTokenizer?
    private let mathRenderer: EditorMathRenderer?
    private let completionProvider: EditorCompletionProvider?
    private let controller: EditorController?
    /// Modal editing (see `EditEngine`). The mode is reported back so the app
    /// can show which one is in force.
    private let modalEditing: Bool

    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - fileURL: Reserved for language detection/services; unused by the
    ///     current engine except through `editorLanguageName(for:)`.
    ///   - initialCursorLine: 1-based line the caret starts on.
    ///   - tokenizer: Custom highlighting, painted as rendering attributes.
    ///   - mathRenderer: When set (and the style renders markup), equations
    ///     display as rendered images off the caret's line.
    ///   - completionProvider: Feeds the completion window (Escape/F5).
    public init(text: Binding<String>, fileURL: URL? = nil,
                style: EditorStyle = .code(),
                initialCursorLine: Int? = nil,
                modalEditing: Bool = true,
                tokenizer: EditorTokenizer? = nil,
                mathRenderer: EditorMathRenderer? = nil,
                completionProvider: EditorCompletionProvider? = nil,
                controller: EditorController? = nil) {
        self._text = text
        self.fileURL = fileURL
        self.style = style
        self.initialCursorLine = initialCursorLine
        self.tokenizer = tokenizer
        self.mathRenderer = mathRenderer
        self.completionProvider = completionProvider
        self.controller = controller
        self.modalEditing = modalEditing
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, tokenizer: tokenizer, mathRenderer: mathRenderer,
                    completionProvider: completionProvider)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView

        textView.textDelegate = context.coordinator
        context.coordinator.textView = textView
        (textView as? EditorTextView)?.modalEditing = modalEditing
        context.coordinator.isDark = colorScheme == .dark
        context.coordinator.lastStyle = style
        controller?.textView = textView

        textView.highlightSelectedLine = true
        textView.allowsUndo = true
        // The shell owns editor placement (it never sits under window chrome in
        // normal mode, and zen deliberately extends it to the top edge) — don't
        // let AppKit re-inset it against the title bar, which would recreate
        // zen's dead strip inside the scroll view.
        scrollView.automaticallyAdjustsContentInsets = false
        Self.apply(style: style, to: textView)
        context.coordinator.installObservers(for: textView, in: scrollView)

        context.coordinator.push(text, into: textView)

        if let initialCursorLine {
            let offset = Self.offset(ofLine: initialCursorLine, column: 1, in: text)
            // Deferred one runloop turn: scrolling before the view is in the window
            // and laid out gets silently dropped by TextKit 2.
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.moveCaret(to: NSRange(location: offset, length: 0))
            }
        }
        return scrollView
    }

    /// Take the space offered; never derive a size from the content.
    ///
    /// Without this, SwiftUI sizes the representable from AppKit's
    /// `fittingSize`, which for a scroll view follows its document — so every
    /// text relayout changed the hosting view's min/max size,
    /// `SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)`
    /// invalidated layout, and that scheduled another constraint pass which
    /// re-laid out the text. AppKit's feedback-loop detector aborts once that
    /// circuit spins, and that call sits at the top of the crash's exception
    /// backtrace. A scroll view's content is unbounded by design: the right
    /// answer to "how big are you" is "as big as you like".
    public func sizeThatFits(_ proposal: ProposedViewSize,
                             nsView: NSScrollView,
                             context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(
            by: CGSize(width: 320, height: 240))
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView else { return }
        controller?.textView = textView
        let coordinator = context.coordinator
        coordinator.isDark = colorScheme == .dark

        let styleChanged = coordinator.lastStyle != style
        if styleChanged { coordinator.lastStyle = style }

        // Everything below this point mutates layout: assigning text, changing
        // the font and wrap mode, and repainting every attribute in the
        // document. `updateNSView` runs *inside* the window's layout pass, and
        // mutating layout from within one is what AppKit turns into a crash —
        // an exception escaping NSView.layout, reported through
        // `_crashOnException`. That was the mode switch: it's the one update
        // that changes the style, so it's the one that repaints synchronously
        // from inside layout. Hand the work to the next runloop turn instead,
        // where the engine owns its own layout again.
        let style = self.style
        DispatchQueue.main.async { [weak textView] in
            MainActor.assumeIsolated {
                guard let textView else { return }
                // Read at hop time, never captured. A keystroke can land in
                // this one runloop turn, and the text this update was handed
                // is then already a version behind — pushing it would take the
                // character back out from under the reader. Ask the binding
                // what it says *now*, which is the whole point of re-checking.
                let latest = coordinator.boundText
                if !coordinator.isEditing, textView.text != latest {
                    coordinator.push(latest, into: textView)
                }
                if styleChanged {
                    Self.apply(style: style, to: textView)
                    coordinator.invalidateHighlight()
                    coordinator.highlightNow()
                }
                coordinator.highlightIfAppearanceChanged()
            }
        }
    }

    /// The engine's text view, minus its intrinsic content size.
    ///
    /// STTextView reports the *document's* size (`usageBoundsForTextContainer`)
    /// as its intrinsic size. Inside a scroll view that's meaningless — overflow
    /// scrolls — and in a SwiftUI hosting hierarchy it's fatal: with
    /// width-tracking wrap, assigning a width re-wraps synchronously, the
    /// document height changes, the intrinsic size changes, and the window runs
    /// another constraint pass — all inside one display-cycle flush. The prose
    /// style closes that circuit (its layout leaves the editor's width
    /// negotiable, and math line heights land mid-flush), and AppKit's
    /// feedback-loop detector aborts the app. No intrinsic size, no circuit.
    /// Public so the app can ask the focused editor which mode it is in —
    /// while it has the keyboard, its mode is the one that matters.
    public final class EditorTextView: STTextView {
        /// Modal editing. Present but idle until `modalEditing` is set, so a
        /// plain text field stays a plain text field.
        public let editing = EditEngine()
        public var modalEditing = false
        /// True while a command is moving the caret.
        ///
        /// A click and a motion both change the selection, and the repaint
        /// that follows must treat them oppositely: a click pins the view —
        /// the reader is looking at something and clicking must not move it —
        /// while `j` or `G` has to take the view *with* the caret. Setting the
        /// selection notifies synchronously, before this method scrolls, so
        /// without this the anchor captures the old viewport and the restore
        /// puts it back, undoing the scroll the motion just asked for.
        var isFollowingCaret = false

        /// Insert mode is plain typing; in a commanding mode the app never
        /// sends keys here at all (see `handleKey`).
        public override func keyDown(with event: NSEvent) {
            super.keyDown(with: event)
        }

        func apply(_ outcome: EditOutcome) {
            isFollowingCaret = true
            defer { isFollowingCaret = false }
            if let edit = outcome.edit {
                // Through the text view, so undo and the highlighter see it.
                insertText(edit.replacement, replacementRange: edit.range)
            }
            let length = (text as NSString?)?.length ?? 0
            let start = min(max(outcome.selection.location, 0), length)
            textSelection = NSRange(location: start,
                                    length: min(outcome.selection.length, length - start))
            scrollToVisible(NSRange(location: start, length: 0))
        }



        public override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        /// Never narrower than the text it holds.
        ///
        /// With wrapping off, the engine sizes the document by enumerating
        /// layout fragments *in reverse from the end and stopping at the
        /// first* — so it measures the last line and then clamps up to the
        /// viewport. A file whose long line isn't its last (which is most
        /// files) therefore gets a document exactly as wide as the viewport:
        /// no overflow, so the caret walks off the right edge and neither the
        /// scroller nor the trackpad has anywhere to go.
        ///
        /// `usageBoundsForTextContainer` is TextKit's own union of what it has
        /// laid out, which is the number the engine's `intrinsicContentSize`
        /// reports and the right floor here. Growth only, and only when
        /// wrapping is off — a wrapping editor must stay the width it's given.
        public override func setFrameSize(_ newSize: NSSize) {
            var size = newSize
            if isHorizontallyResizable {
                let content = textLayoutManager.usageBoundsForTextContainer.maxX
                    + (gutterView?.frame.width ?? 0)
                size.width = max(size.width, content.rounded(.up))
            }
            super.setFrameSize(size)
        }
    }

    private static func apply(style: EditorStyle, to textView: STTextView) {
        textView.font = style.font
        textView.defaultParagraphStyle = style.paragraphStyle
        textView.widthTracksTextView = style.wrapLines
        textView.showsLineNumbers = style.showsLineNumbers
        // Wrapped text has nowhere to go sideways, so it must not offer a
        // scroller for going there. It can still *overflow*: the reserved box
        // for an equation is a kern on its last character, which no line
        // breaker can wrap, so one line ends up wider than the column and a
        // horizontal scroller appears under a manuscript.
        textView.enclosingScrollView?.hasHorizontalScroller = !style.wrapLines
    }

    /// Byte offset of a 1-based line/column in `text` (clamped to valid range).
    static func offset(ofLine line: Int, column: Int, in text: String) -> Int {
        let ns = text as NSString
        var currentLine = 1
        var index = 0
        while currentLine < line && index < ns.length {
            if ns.character(at: index) == UInt8(ascii: "\n") { currentLine += 1 }
            index += 1
        }
        return min(index + max(column - 1, 0), ns.length)
    }

    // MARK: Coordinator

    @MainActor
    public final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        private let text: Binding<String>
        /// What the binding says right now — for the deferred half of
        /// `updateNSView`, which must not act on a value it captured.
        var boundText: String { text.wrappedValue }
        private let tokenizer: EditorTokenizer?
        private let mathRenderer: EditorMathRenderer?
        private let completionProvider: EditorCompletionProvider?
        weak var textView: STTextView?
        var isEditing = false
        var lastStyle: EditorStyle?
        var isDark = false

        private var highlightTask: Task<Void, Never>?
        private var autoCompleteTask: Task<Void, Never>?
        private var lastHighlightedText: String?
        private var lastHighlightedDark: Bool?
        private var lastHighlightedRevealStart: Int?

        /// The paragraph (line) holding the caret. Markup on this line shows its
        /// delimiters (dimmed) for editing; elsewhere they're concealed — the
        /// live-preview reveal-on-caret behavior.
        private var revealedParagraph: NSRange?

        /// Paragraph styles are one attribute: composing effects (alignment,
        /// list indent, math line height) on the same paragraph means mutating
        /// one shared instance per paragraph per paint, not last-write-wins.
        private var paragraphStyles: [Int: NSMutableParagraphStyle] = [:]

        /// Equations rendered this paint (range → rendering), placed as overlay
        /// views once layout settles.
        private var pendingMath: [(range: NSRange, equation: RenderedEquation, block: Bool)] = []
        private var mathOverlays: [NSImageView] = []
        private var isPlacingOverlays = false

        /// The caret's viewport position captured before a repaint, restored
        /// after layout settles. Lazily arriving math images change line
        /// heights; without anchoring, a fragment jump (or plain reading
        /// position) drifts as the document reflows above the caret.
        private var pendingScrollAnchor: (anchor: ViewportAnchor.Anchor,
                                          caretWasVisible: Bool)?
        /// Whether the pending repaint was caused by the reader's own typing —
        /// those must not pin the viewport (see `highlightNow`).
        private var repaintFollowsEdit = false
        /// Whether the pending repaint was caused by the caret moving to another
        /// paragraph — a click or an arrow key. Those must not anchor either
        /// (see `highlightNow`).
        private var repaintFollowsCaret = false
        /// The paragraph about to lose its reveal, when it sits above the
        /// viewport: its height change moves everything the reader can see.
        private var pendingRevealLoss: NSRange?
        /// That paragraph's height before the repaint, to compare against after.
        private var pendingHeightCompensation: (location: NSTextLocation, height: CGFloat)?
        // nonisolated(unsafe): only written once from installObservers (main)
        // and read in deinit; NotificationCenter removal is thread-safe.
        private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

        init(text: Binding<String>, tokenizer: EditorTokenizer?,
             mathRenderer: EditorMathRenderer?,
             completionProvider: EditorCompletionProvider?) {
            self.text = text
            self.tokenizer = tokenizer
            self.mathRenderer = mathRenderer
            self.completionProvider = completionProvider
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// Overlay positions derive from text layout, which shifts on scroll
        /// (viewport re-layout), resize (re-wrap), and external frame changes —
        /// none of which repaint. Track them and reposition.
        ///
        /// Deferred, never inline: these notifications deliver *synchronously*
        /// when posted on the main thread — i.e. in the middle of the layout
        /// pass that moved the view. Placing overlays right there (forcing
        /// layout, touching subviews) re-dirties the layout the pass is trying
        /// to settle; AppKit's feedback-loop detector eventually aborts with
        /// "_postWindowNeedsUpdateConstraints". One hop coalesces the storm a
        /// single pass emits and lands after the pass has finished.
        func installObservers(for textView: STTextView, in scrollView: NSScrollView) {
            let reposition: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleOverlayReposition() }
            }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main, using: reposition))
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: textView, queue: .main, using: reposition))
        }

        private var repositionScheduled = false

        private func scheduleOverlayReposition() {
            guard !repositionScheduled, !pendingMath.isEmpty else { return }
            repositionScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.repositionScheduled = false
                    self.layoutMathOverlays()
                }
            }
        }

        private var isPushingText = false

        /// Assign external text to the view. STTextView fires its did-change
        /// delegate *synchronously* on assignment; the flag stops that echo from
        /// writing the binding back mid-view-update ("Modifying state during view
        /// update") — the binding is the source of this text anyway.
        func push(_ newText: String, into textView: STTextView) {
            isPushingText = true
            textView.text = newText
            isPushingText = false
            highlightNow()
        }

        /// Keep equation images glued to their text between repaints. Painting
        /// is debounced, so during continuous typing the document reflows while
        /// the images would otherwise sit at stale positions — drifting further
        /// from their equations with every wrapped line.
        public func textView(_ textView: STTextView, didChangeTextIn affectedCharRange: NSTextRange,
                             replacementString: String) {
            guard !pendingMath.isEmpty,
                  let contentManager = textView.textLayoutManager.textContentManager
            else { return }
            // Assigning the whole text is not an edit, and the engine reports
            // it as one: an insertion of the entire document at zero. Sliding
            // every equation forward by the length of the document is how the
            // ranges ended up past the end of the text they described, and the
            // only reason nothing showed it is that the next full repaint
            // rebuilt the list from scratch. Nothing here survives a wholesale
            // replacement anyway — every image describes text that is gone.
            let edited = NSRange(affectedCharRange, in: contentManager)
            let length = ((textView.text ?? "") as NSString).length
            if isPushingText || edited.location == 0 && edited.length == 0
                && (replacementString as NSString).length == length {
                // And repaint from scratch rather than leaving nothing: the
                // list is rebuilt from the document the engine has *finished*
                // announcing, which is the ordering the paint that ran from
                // the selection notification could not have seen.
                pendingMath.removeAll()
                invalidateHighlight()
                highlightNow()
                return
            }
            let delta = (replacementString as NSString).length - edited.length
            pendingMath = pendingMath.compactMap { entry in
                MathOverlayLayout.adjust(entry.range, forEditIn: edited, delta: delta)
                    .map { (range: $0, equation: entry.equation, block: entry.block) }
            }
            // A range that no longer fits the text cannot be placed and must
            // not be carried: whatever moved it was wrong about the document.
            pendingMath.removeAll { NSMaxRange($0.range) > length }
            // A tick later: the edit's layout has to settle before frames are real.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.layoutMathOverlays() }
            }
        }

        public func textViewDidChangeText(_ notification: Notification) {
            guard !isPushingText, let textView else { return }
            isEditing = true
            text.wrappedValue = textView.text ?? ""
            isEditing = false
            // Debounced: a full-document repaint per keystroke stutters; colors
            // catching up ~100ms after typing pauses is imperceptible.
            repaintFollowsEdit = true
            scheduleHighlight()
            scheduleAutoCompletion(in: textView)
        }

        /// Completions appear as you type — but only inside a `#…`/`@…` run
        /// (typst calls and references). Bare prose must never pop a window per
        /// word. Retriggers per keystroke (debounced) so the list live-filters;
        /// leaving the run dismisses it.
        private func scheduleAutoCompletion(in textView: STTextView) {
            guard completionProvider != nil else { return }
            autoCompleteTask?.cancel()
            let ns = (textView.text ?? "") as NSString
            let caret = min(textView.textSelection.location, ns.length)
            guard textView.textSelection.length == 0,
                  Self.isCompletableContext(at: caret, in: ns) else {
                textView.cancelComplete(nil)   // no-op when nothing is showing
                return
            }
            autoCompleteTask = Task { @MainActor [weak self, weak textView] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, self != nil, let textView else { return }
                textView.complete(nil)
            }
        }

        /// True when the caret sits in (or right after) a sigil-introduced run:
        /// identifier characters (plus `.` for field access) preceded by `#`/`@`.
        static func isCompletableContext(at offset: Int, in text: NSString) -> Bool {
            var i = offset
            while i > 0 {
                guard let scalar = Unicode.Scalar(text.character(at: i - 1)) else { return false }
                if CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "_" || scalar == "-" || scalar == "." {
                    i -= 1
                    continue
                }
                return scalar == "#" || scalar == "@"
            }
            return false
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !isPushingText, let textView,
                  (lastStyle ?? .code()).rendersMarkup else { return }
            let ns = (textView.text ?? "") as NSString
            let caret = min(textView.textSelection.location, ns.length)
            let paragraph = ns.paragraphRange(
                for: NSRange(location: caret,
                             length: min(textView.textSelection.length,
                                         ns.length - caret)))
            // Repaint only when the caret crosses onto a different line — typing
            // within a line rides the (debounced) text-change repaint, which reads
            // the updated range from here.
            let moved = paragraph.location != revealedParagraph?.location
            let previous = revealedParagraph
            revealedParagraph = paragraph
            guard moved else { return }
            // Two paragraphs change when the caret crosses a line: the one
            // losing its reveal and the one gaining it. Repainting the whole
            // document for that sets every font and paragraph style in the
            // file, which invalidates the file's layout — and TextKit answers
            // by throwing away what it had laid out and laying out the
            // viewport alone. Measured in the app: the laid-out extent
            // collapsed from 9435pt to 2879pt on one click, and with the
            // prefix above the reader an estimate again, the line sitting at
            // an unchanged scroll offset moved forward by a thousand
            // characters. Nothing scrolled; the document slid underneath.
            //
            // So paint the two paragraphs and leave the rest of the layout
            // alone. Only when the text is exactly what the last full paint
            // saw — typing a newline also moves the caret to a new paragraph,
            // and there the tokens have changed everywhere, so that case falls
            // through to the debounced full repaint as before.
            if textView.text == lastHighlightedText {
                repaintReveal(from: previous, to: paragraph, on: textView)
            } else {
                repaintFollowsCaret = true
                pendingRevealLoss = previous
                highlightNow()
            }
        }

        /// Repaint just the paragraphs a caret move changed.
        ///
        /// The incremental half of `highlightNow`, built from the same `paint`
        /// — which was written for it, and had lost its only caller. It keeps
        /// the same bookkeeping: the reveal position the next full paint
        /// compares against, the height compensation for a paragraph above the
        /// viewport, and the overlay pass a tick later once TextKit has laid
        /// the new attributes out.
        private func repaintReveal(from previous: NSRange?, to current: NSRange,
                                   on textView: STTextView) {
            guard let tokenizer else { return }
            let content = textView.text ?? ""
            let ns = content as NSString
            let style = lastStyle ?? .code()
            // Pin the top of the viewport, rather than compensating for the
            // one paragraph that lost its reveal. Compensation was the only
            // thing available while a caret repaint invalidated the whole
            // document — an absolute anchor is worthless when every position
            // above the reader is about to be re-estimated. Painting two
            // paragraphs leaves that layout alone, so the anchor is honest
            // again, and it covers what the single-paragraph delta could not:
            // any number of lines above changing height for any reason.
            // Unless the caret is what moved the view: then it is already
            // where the reader asked to be looking.
            if (textView as? MaximalEditor.EditorTextView)?.isFollowingCaret != true {
                captureScrollAnchor()
            }
            lastHighlightedRevealStart = current.location
            for range in [previous, current].compactMap({ $0 }) {
                let start = min(max(range.location, 0), ns.length)
                let clamped = NSRange(location: start,
                                      length: min(range.length, ns.length - start))
                paint(clamped, style: style, content: content, ns: ns,
                      tokenizer: tokenizer, on: textView)
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.layoutMathOverlays()
                    self?.restoreScrollAnchor()
                }
            }
        }

        private func scheduleHighlight() {
            highlightTask?.cancel()
            highlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                self?.highlightNow()
            }
        }

        func highlightIfAppearanceChanged() {
            if lastHighlightedDark != isDark { highlightNow() }
        }

        func invalidateHighlight() { lastHighlightedText = nil }

        /// Repaint the document. Colors go on as rendering attributes (display-only,
        /// undo-safe). In markup-rendering styles, fonts and paragraph alignment go
        /// on the storage — those *are* layout, there's no display-only channel for
        /// them — with a full base reset first so mode switches leave no residue.
        /// No-ops when nothing changed.
        func highlightNow() {
            guard let textView, let tokenizer else { return }
            // Taken before the no-op check, never after: these describe the
            // repaint that was *asked for*, and a repaint that turns out to
            // change nothing still answers for them. Left set, they would tell
            // the next repaint — an image landing, a theme switch — that the
            // reader had just typed or clicked, and it would skip the anchoring
            // that keeps the page still.
            let followsCaret = repaintFollowsCaret
            let followsReader = repaintFollowsEdit || followsCaret
            let revealLoss = pendingRevealLoss
            repaintFollowsEdit = false
            repaintFollowsCaret = false
            pendingRevealLoss = nil

            let content = textView.text ?? ""
            if content == lastHighlightedText && isDark == lastHighlightedDark
                && revealedParagraph?.location == lastHighlightedRevealStart { return }
            lastHighlightedText = content
            lastHighlightedDark = isDark
            lastHighlightedRevealStart = revealedParagraph?.location

            let style = lastStyle ?? .code()
            let ns = content as NSString
            let full = NSRange(location: 0, length: ns.length)
            paragraphStyles.removeAll()
            pendingMath.removeAll()
            // Pin the topmost visible line so a repaint that changes line
            // heights (math images landing, a concealment reveal, a theme
            // switch) doesn't shift the text under the reader.
            //
            // Only for repaints the reader didn't cause. Typing: the engine is
            // already scrolling to follow the caret and anchoring fights it. A
            // caret move (click, arrow): measured in the app, the restore threw
            // the view 200–600pt upward *every click*, scaling with scroll
            // depth — the signature of TextKit re-estimating the prefix above
            // the viewport after the repaint's layout pass, which makes the
            // anchored line look higher than it is. Both cases move only
            // paragraphs already in view, so there is nothing to compensate
            // for; anchoring is for images landing and theme switches, where
            // heights change under a passive reader.
            if followsCaret {
                captureHeightCompensation(of: revealLoss)
            } else if !followsReader {
                captureScrollAnchor()
            }
            // Every exit re-syncs overlays and the anchor — including removal
            // when the doc emptied or the style stopped rendering markup.
            // Deferred a tick: TextKit must lay out the new attributes first.
            defer {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.layoutMathOverlays()
                        self?.applyHeightCompensation()
                        self?.restoreScrollAnchor()
                    }
                }
            }
            guard full.length > 0 else { return }

            paint(full, style: style, content: content, ns: ns,
                  tokenizer: tokenizer, on: textView)
        }

        /// Repaint one range: reset it to the base style, then re-apply every
        /// token that touches it. The unit both the whole-document paint and the
        /// incremental reveal paint are built from.
        private func paint(_ range: NSRange, style: EditorStyle, content: String,
                           ns: NSString, tokenizer: EditorTokenizer,
                           on textView: STTextView) {
            guard range.length > 0 else { return }
            // Anything this range owned is about to be recomputed.
            paragraphStyles[range.location] = nil
            pendingMath.removeAll { NSIntersectionRange($0.range, range).length > 0 }

            textView.setAttributes([
                .font: style.font,
                .paragraphStyle: style.paragraphStyle,
                .foregroundColor: NSColor.labelColor,
            ], range: range)
            textView.removeRenderingAttribute(.foregroundColor, range: range)
            textView.removeRenderingAttribute(.backgroundColor, range: range)
            textView.removeRenderingAttribute(.underlineStyle, range: range)
            textView.removeRenderingAttribute(.strikethroughStyle, range: range)

            // Tokenizers memoize, so re-asking for the whole document's tokens
            // during an incremental repaint is a cache hit, not a re-parse.
            for token in tokenizer.tokens(in: content)
            where NSIntersectionRange(token.range, range).length > 0 {
                if style.rendersMarkup {
                    renderMarkup(token, style: style, in: ns, on: textView)
                } else if let color = TokenPalette.color(for: token.kind, dark: isDark) {
                    textView.addRenderingAttributes([.foregroundColor: color],
                                                    range: token.range)
                }
            }
        }

        private func dim(_ range: NSRange, on textView: STTextView) {
            textView.addRenderingAttributes(
                [.foregroundColor: NSColor.tertiaryLabelColor], range: range)
        }

        /// Markup delimiters: dimmed on the caret's line (visible for editing),
        /// hidden everywhere else. There's no display-only way to remove glyphs
        /// from layout, so "hidden" is a near-zero font (storage) plus a clear
        /// rendering color — the standard live-preview conceal.
        private func conceal(_ range: NSRange, on textView: STTextView) {
            if let revealed = revealedParagraph,
               NSIntersectionRange(revealed, range).length > 0
                || range.location == revealed.location {
                dim(range, on: textView)
            } else {
                textView.addAttributes([.font: NSFont.systemFont(ofSize: 0.1)],
                                       range: range)
                textView.addRenderingAttributes([.foregroundColor: NSColor.clear],
                                                range: range)
            }
        }

        /// The WYSIWYG-ish path: real formatting for markup, colors for the rest.
        /// Delimiters conceal on lines not being edited and show dimmed on the
        /// caret's line (the source stays honest where you're working).
        private func renderMarkup(_ token: (range: NSRange, kind: EditorTokenKind),
                                  style: EditorStyle, in ns: NSString, on textView: STTextView) {
            let dim = { (range: NSRange) in self.dim(range, on: textView) }
            let conceal = { (range: NSRange) in self.conceal(range, on: textView) }
            let concealEnds = { (range: NSRange, width: Int) in
                conceal(NSRange(location: range.location, length: width))
                conceal(NSRange(location: range.location + range.length - width, length: width))
            }

            switch token.kind {
            case .heading(let level):
                let scale: CGFloat = [1.6, 1.35, 1.2][min(level, 3) - 1]
                textView.addAttributes(
                    [.font: fontVariant(of: style.font, bold: true, scale: scale)],
                    range: token.range)
                let line = ns.substring(with: token.range)
                if let markerEnd = line.firstIndex(of: " ") {
                    conceal(NSRange(location: token.range.location,
                                    length: line.distance(from: line.startIndex,
                                                          to: markerEnd) + 1))
                }
            case .strong:
                textView.addAttributes([.font: fontVariant(of: style.font, bold: true)],
                                       range: token.range)
                concealEnds(token.range, 1)
            case .emphasis:
                textView.addAttributes([.font: fontVariant(of: style.font, italic: true)],
                                       range: token.range)
                concealEnds(token.range, 1)
            case .raw:
                // Fences and the language tag arrive as separate `punctuation`
                // tokens (they conceal); embedded code arrives as normal
                // comment/string/number/keyword tokens painted after this one.
                textView.addAttributes(
                    [.font: fontVariant(of: style.font, scale: 0.9, monospaced: true)],
                    range: token.range)
                textView.addRenderingAttributes(
                    [.backgroundColor: NSColor.quaternarySystemFill], range: token.range)
            case .aligned(let alignment):
                // Paragraph properties resolve from the paragraph's *start* — the
                // token range begins mid-line (inside the brackets), so the style
                // must cover the whole paragraph or it silently doesn't apply.
                composeParagraphStyle(over: ns.paragraphRange(for: token.range),
                                      base: style.paragraphStyle, on: textView) {
                    $0.alignment = switch alignment {
                    case .leading: .natural
                    case .center: .center
                    case .trailing: .right
                    }
                }
            case .link:
                textView.addRenderingAttributes([
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: token.range)
            case .listMarker:
                // Bullets and escapes carry meaning — dimmed, never concealed.
                dim(token.range)
            case .listItem:
                composeParagraphStyle(over: ns.paragraphRange(for: token.range),
                                      base: style.paragraphStyle, on: textView) {
                    $0.headIndent = style.font.pointSize * 1.4
                }
            case .term:
                textView.addAttributes([.font: fontVariant(of: style.font, bold: true)],
                                       range: token.range)
            case .struck:
                textView.addRenderingAttributes(
                    [.strikethroughStyle: NSUnderlineStyle.single.rawValue],
                    range: token.range)
            case .underlined:
                textView.addRenderingAttributes(
                    [.underlineStyle: NSUnderlineStyle.single.rawValue],
                    range: token.range)
            case .punctuation:
                // Structural delimiters (content brackets, decorator heads):
                // mono, concealed off the caret's line.
                textView.addAttributes(
                    [.font: fontVariant(of: style.font, scale: 0.9, monospaced: true)],
                    range: token.range)
                conceal(token.range)
            case .math(let block):
                renderMath(token.range, block: block, style: style, in: ns, on: textView)
            default:
                styleAsCode(token.range, kind: token.kind, style: style, on: textView)
            }
        }

        /// Code constructs read as code even in prose: monospaced and colored.
        /// Content stays serif; the machinery doesn't.
        private func styleAsCode(_ range: NSRange, kind: EditorTokenKind,
                                 style: EditorStyle, on textView: STTextView) {
            textView.addAttributes(
                [.font: fontVariant(of: style.font, scale: 0.9, monospaced: true)],
                range: range)
            if let color = TokenPalette.color(for: kind, dark: isDark) {
                textView.addRenderingAttributes([.foregroundColor: color], range: range)
            }
        }

        private func composeParagraphStyle(over paragraphRange: NSRange,
                                           base: NSParagraphStyle, on textView: STTextView,
                                           _ mutate: (NSMutableParagraphStyle) -> Void) {
            let paragraph = paragraphStyles[paragraphRange.location]
                ?? (base.mutableCopy() as! NSMutableParagraphStyle)
            mutate(paragraph)
            paragraphStyles[paragraphRange.location] = paragraph
            textView.addAttributes([.paragraphStyle: paragraph], range: paragraphRange)
        }

        // MARK: Rendered math

        /// The equation preview: off the caret's line, the source is hidden and
        /// its rendered image floats over reserved space. The reservation is
        /// pure attributes — a collapsed font plus trailing kern for the width,
        /// a minimum line height for the height — so the text storage stays the
        /// source, and undo/save never see a phantom character. On the caret's
        /// line (or while the render is still compiling) the equation stays as
        /// editable monospace source.
        private func renderMath(_ range: NSRange, block: Bool, style: EditorStyle,
                                in ns: NSString, on textView: STTextView) {
            let onCaretLine = revealedParagraph.map {
                NSIntersectionRange($0, range).length > 0 || range.location == $0.location
            } ?? false
            guard !onCaretLine, range.length > 0, let mathRenderer,
                  let equation = mathRenderer.renderedMath(
                    for: ns.substring(with: range),
                    fontSize: style.font.pointSize, dark: isDark, block: block,
                    completion: { [weak self] in
                        // Coalesced: on load, every equation completes at once —
                        // one debounced repaint, not one full repaint each.
                        self?.invalidateHighlight()
                        self?.scheduleHighlight()
                    })
            else {
                styleAsCode(range, kind: .math(block: block), style: style, on: textView)
                return
            }

            let image = equation.image
            textView.addAttributes([.font: NSFont.systemFont(ofSize: 0.1)], range: range)
            let last = NSRange(location: range.location + range.length - 1, length: 1)
            textView.addAttributes([.kern: image.size.width + 2], range: last)
            // A multi-line source still occupies one collapsed line per newline
            // (concealment can't remove characters) — split one image-box of
            // height across them, or every extra line reserves a whole empty box.
            let lines = CGFloat(ns.substring(with: range)
                .components(separatedBy: "\n").count)
            composeParagraphStyle(over: ns.paragraphRange(for: range),
                                  base: style.paragraphStyle, on: textView) {
                if lines > 1 {
                    $0.minimumLineHeight = (image.size.height + 2) / lines
                    $0.maximumLineHeight = (image.size.height + 2) / lines
                } else {
                    $0.minimumLineHeight = max(image.size.height + 2,
                                               style.naturalLineHeight)
                }
                // A block equation centers. The reserved box is invisible; what
                // centering buys is a caret that lands mid-column when clicking
                // around the image. (The image's own x is computed from the
                // column — see MathOverlayLayout.)
                if block { $0.alignment = .center }
            }
            textView.addRenderingAttributes([.foregroundColor: NSColor.clear], range: range)
            pendingMath.append((range, equation, block))
        }

        /// (Re)place equation images at their reserved spots. Runs a tick after
        /// each paint (layout must settle first) and again whenever layout moves
        /// under the overlays (scroll, resize).
        private func layoutMathOverlays() {
            // Placement forces the view's pending layout, which can scroll and
            // re-enter here through the bounds observer.
            guard !isPlacingOverlays else { return }
            isPlacingOverlays = true
            defer { isPlacingOverlays = false }

            guard let textView else { return }
            guard !pendingMath.isEmpty else {
                for view in mathOverlays { view.removeFromSuperview() }
                mathOverlays.removeAll()
                return
            }
            // Resolve the view's pending layout *before* measuring. A repaint's
            // attribute changes only flag the view as needing layout (STTextView
            // never invalidates the layout manager itself), so until that pass
            // runs every fragment origin still describes the pre-repaint
            // document — measured 36pt out in practice, uniformly, which is an
            // image sitting well below the equation it belongs to.
            textView.layoutSubtreeIfNeeded()
            let gutterWidth = textView.gutterView?.frame.width ?? 0

            var placed: [(image: NSImage, frame: CGRect)] = []
            for (range, equation, block) in pendingMath {
                // Placement is pure geometry over the layout manager — see
                // MathOverlayLayout for why it measures the way it does.
                guard var frame = MathOverlayLayout.frame(
                    forEquationAt: range,
                    image: equation.image.size,
                    imageBaseline: equation.baseline,
                    block: block,
                    lineHeightMultiple: lastStyle?.lineHeightMultiple ?? 1,
                    in: textView.textLayoutManager)
                else { continue }
                // Layout coordinates are content-view coordinates; the content
                // view sits right of the gutter (its one offset from the view).
                frame.origin.x += gutterWidth
                placed.append((equation.image, frame))
            }

            // Reuse the views. Adding or removing a subview invalidates the text
            // view's layout — done on every reposition, that re-dirties each
            // layout pass and feeds the constraint feedback loop that crashed
            // prose mode. Steady state (same equations, new geometry) must be
            // pure frame updates, which invalidate nothing.
            while mathOverlays.count > placed.count {
                mathOverlays.removeLast().removeFromSuperview()
            }
            while mathOverlays.count < placed.count {
                let overlay = NSImageView()
                textView.addSubview(overlay)
                mathOverlays.append(overlay)
            }
            for (view, target) in zip(mathOverlays, placed) {
                if view.image !== target.image { view.image = target.image }
                if view.frame != target.frame { view.frame = target.frame }
            }
        }

        // MARK: Scroll anchoring

        /// Pin the top of the viewport across the repaint, and note whether the
        /// caret was on screen — a reveal can make its paragraph taller and push
        /// it out, but only chase it back if the reader was looking at it.
        /// Note the height of a paragraph that sits *above* the viewport and is
        /// about to lose its reveal — the "scroll away from the caret, then
        /// click" case. Everything on screen sits below it, so whatever it
        /// gains or loses moves the whole view by exactly that much.
        ///
        /// Only its own height is recorded, never a document position: the
        /// prefix above the viewport is estimated and re-estimated by TextKit,
        /// which is what made absolute-position anchoring throw the view
        /// hundreds of points. A single fragment's height is local and honest.
        private func captureHeightCompensation(of paragraph: NSRange?) {
            pendingHeightCompensation = nil
            guard let textView, let paragraph,
                  let contentManager = textView.textLayoutManager.textContentManager,
                  let range = NSTextRange(NSRange(location: paragraph.location, length: 0),
                                          in: contentManager),
                  let frame = paragraphFrame(at: range.location,
                                             in: textView.textLayoutManager)
            else { return }
            // Entirely above the viewport: only then does its height shift what
            // the reader sees. A paragraph in view moves its own text, which is
            // the reveal doing its job.
            guard frame.maxY <= textView.visibleRect.minY else { return }
            pendingHeightCompensation = (range.location, frame.height)
        }

        /// Scroll by exactly what that paragraph's height changed, so the lines
        /// on screen stay where they were.
        private func applyHeightCompensation() {
            guard let (location, before) = pendingHeightCompensation, let textView else { return }
            pendingHeightCompensation = nil
            // Measure after the layout the repaint asked for, not before it.
            // A paragraph whose attributes changed is only flagged dirty; until
            // the pass runs it still reports the height it had, the delta is
            // zero, and nothing compensates for a change that is about to
            // happen anyway.
            textView.layoutSubtreeIfNeeded()
            guard let frame = paragraphFrame(at: location, in: textView.textLayoutManager)
            else { return }
            let delta = frame.height - before
            guard abs(delta) > 0.5 else { return }
            let visible = textView.visibleRect
            textView.scroll(CGPoint(x: visible.minX, y: max(0, visible.minY + delta)))
        }

        private func paragraphFrame(at location: NSTextLocation,
                                    in layoutManager: NSTextLayoutManager) -> CGRect? {
            var result: CGRect?
            layoutManager.enumerateTextLayoutFragments(from: location,
                                                       options: [.ensuresLayout]) { fragment in
                result = fragment.layoutFragmentFrame
                return false
            }
            return result
        }

        private func captureScrollAnchor() {
            guard let textView else { return }
            let visible = textView.visibleRect
            guard let anchor = ViewportAnchor.capture(
                in: textView.textLayoutManager, visible: visible)
            else { pendingScrollAnchor = nil; return }
            pendingScrollAnchor = (anchor, caretIsVisible(in: textView))
        }

        /// Put the anchored line back where it was, compensating for whatever
        /// line-height changes the repaint landed above it.
        private func restoreScrollAnchor() {
            guard let (anchor, caretWasVisible) = pendingScrollAnchor else { return }
            pendingScrollAnchor = nil
            guard let textView else { return }
            // Same rule as the height compensation: measure after the layout
            // the repaint asked for. A paragraph whose attributes changed is
            // only flagged dirty, so until the pass runs the anchored line
            // still reports where it used to be and the restore corrects to a
            // position that is about to stop being true.
            textView.layoutSubtreeIfNeeded()
            if let targetY = ViewportAnchor.targetY(for: anchor,
                                                    in: textView.textLayoutManager) {
                let visible = textView.visibleRect
                let clamped = max(0, targetY)
                if abs(clamped - visible.minY) > 0.5 {
                    textView.scroll(CGPoint(x: visible.minX, y: clamped))
                }
            }
            // Revealing the caret's paragraph makes it taller, which can push the
            // caret below the fold even though the view didn't move.
            if caretWasVisible, !caretIsVisible(in: textView) {
                textView.scrollToVisible(
                    NSRange(location: textView.textSelection.location, length: 0))
            }
        }

        private func caretIsVisible(in textView: STTextView) -> Bool {
            guard let contentManager = textView.textLayoutManager.textContentManager
            else { return false }
            let length = ((textView.text ?? "") as NSString).length
            let caret = min(textView.textSelection.location, length)
            guard let range = NSTextRange(NSRange(location: caret, length: 0),
                                          in: contentManager),
                  let frame = textView.textLayoutManager.textSegmentFrame(
                    at: range.location, type: .standard)
            else { return false }
            return frame.intersects(textView.visibleRect)
        }

    }
}
