import SwiftUI
import AppKit
import Highlightr
import STTextView
import STTextKitPlus

// MaximalEditorKit: the one place MaximalTree touches its editor engine.
//
// Engine: STTextView (TextKit 2). Chosen for cross-platform reach — the same
// package ships AppKit and UIKit implementations, so the iOS version of this
// framework wraps the same engine — and for maintenance health. Plugins depend on
// this framework only; swapping engines is a one-file job by design (this file's
// previous life wrapped CodeEditSourceEditor).
//
// Improvements over the previous engine's semantics:
// - The text binding is live: external changes push into the view (the old
//   read-once-at-construction wart is gone).
// - Highlighting uses *rendering attributes* — display-only, never touching the
//   text storage or the undo stack.

// MARK: - Style

/// How an editor should look and behave. Presets cover the two personalities used
/// in MaximalTree: `.code` (monospaced IDE) and `.prose` (serif manuscript).
public struct EditorStyle: Equatable {
    public enum Design {
        case monospaced, serif
    }

    public var design: Design
    public var size: CGFloat
    public var lineHeightMultiple: Double
    public var wrapLines: Bool
    public var indentSpaces: Int
    public var showsLineNumbers: Bool
    /// When set, markup tokens render as live formatting — headings sized and
    /// bolded, `*strong*`/`_emphasis_` styled, `#align` bodies aligned, delimiters
    /// dimmed — instead of syntax colors. The WYSIWYG-ish prose experience.
    public var rendersMarkup: Bool

    public init(design: Design, size: CGFloat, lineHeightMultiple: Double,
                wrapLines: Bool, indentSpaces: Int, showsLineNumbers: Bool = true,
                rendersMarkup: Bool = false) {
        self.design = design
        self.size = size
        self.lineHeightMultiple = lineHeightMultiple
        self.wrapLines = wrapLines
        self.indentSpaces = indentSpaces
        self.showsLineNumbers = showsLineNumbers
        self.rendersMarkup = rendersMarkup
    }

    public static func code(size: CGFloat = 12, wrapLines: Bool = false,
                            indentSpaces: Int = 4) -> EditorStyle {
        EditorStyle(design: .monospaced, size: size, lineHeightMultiple: 1.2,
                    wrapLines: wrapLines, indentSpaces: indentSpaces)
    }

    /// Manuscript, not IDE: no line-number gutter, markup rendered as formatting.
    public static func prose(size: CGFloat = 15) -> EditorStyle {
        EditorStyle(design: .serif, size: size, lineHeightMultiple: 1.5,
                    wrapLines: true, indentSpaces: 2, showsLineNumbers: false,
                    rendersMarkup: true)
    }

    var font: NSFont {
        switch design {
        case .monospaced:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .serif:
            let base = NSFont.systemFont(ofSize: size)
            if let descriptor = base.fontDescriptor.withDesign(.serif),
               let serif = NSFont(descriptor: descriptor, size: size) {
                return serif
            }
            return base
        }
    }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        return style
    }
}

// MARK: - Tokenizer

/// The engine-neutral token vocabulary plugins highlight with. The first group is
/// semantic (colored); the second is presentational markup, which styles *as*
/// formatting (fonts, alignment) when the style has `rendersMarkup` — the
/// live-preview feel — and falls back to colors in code styles.
public enum EditorTokenKind: Equatable {
    case comment, string, number, keyword, type, variable, function, tag, property
    case heading(level: Int)
    case strong, emphasis, raw
    /// An equation (`$…$`): rendered as an image off the caret's line when a
    /// math renderer is present, monospace number-colored otherwise. Block
    /// equations (`$ x $`) center in their line. The delimiters arrive
    /// separately as `punctuation`, so they conceal.
    case math(block: Bool)
    /// A token colored by an external highlighter (embedded foreign-language
    /// code): the tokenizer supplies both appearances, paint-time picks one.
    case colored(light: NSColor, dark: NSColor)
    case aligned(EditorAlignment)
    /// Structural delimiters (content brackets, decorator-call heads): dimmed mono
    /// in markup rendering — and *concealed* on lines not being edited — uncolored
    /// in code styles.
    case punctuation
    /// A URL in markup: link-colored and underlined.
    case link
    /// A list/enum/term bullet (or escape/linebreak shorthand): always visible,
    /// dimmed — it carries meaning, unlike delimiters.
    case listMarker
    /// A whole list/enum/term item: hanging indent so wrapped lines align.
    case listItem
    /// The term half of a `/ term: description` item: bold.
    case term
    /// Bodies of `#strike[…]` / `#underline[…]`: drawn with the decoration.
    case struck
    case underlined
}

public enum EditorAlignment: Equatable {
    case leading, center, trailing
}

/// A plugin-supplied lexer. Return every token in `text`; the framework paints
/// them as display-only rendering attributes. Engine-neutral so tokenizers
/// survive engine swaps. Main-actor: it's only ever called from the paint path,
/// and implementations may hold main-confined machinery (JS contexts, caches).
@MainActor
public protocol EditorTokenizer: AnyObject {
    func tokens(in text: String) -> [(range: NSRange, kind: EditorTokenKind)]
}

/// One completion the editor can offer. `replaceRange` (UTF-16, against the
/// text the provider was called with) is what inserting replaces; nil means
/// "the identifier being typed", which the editor computes itself.
public struct EditorCompletion: Sendable {
    public let label: String
    public let detail: String?
    public let insertText: String
    public let replaceRange: NSRange?

    public init(label: String, detail: String? = nil,
                insertText: String, replaceRange: NSRange? = nil) {
        self.label = label
        self.detail = detail
        self.insertText = insertText
        self.replaceRange = replaceRange
    }
}

/// Supplies completions for the editor's built-in completion window (invoked
/// with Escape/F5). Async and off-actor: implementations typically consult a
/// language server. Return [] freely — an empty result just means no window.
public protocol EditorCompletionProvider: AnyObject, Sendable {
    func completions(in text: String, at offset: Int) async -> [EditorCompletion]
}

/// A rendered equation and where its typographic baseline sits (points from
/// the image's top) — the editor aligns that to the text's own baseline.
public struct RenderedEquation {
    public let image: NSImage
    public let baseline: CGFloat

    public init(image: NSImage, baseline: CGFloat) {
        self.image = image
        self.baseline = baseline
    }
}

/// Renders equations for the inline math preview. Return a cached result
/// immediately, or nil while producing one asynchronously — then call
/// `completion` (once, on success only) and the editor repaints with it. On
/// failure return nil and never complete; the editor keeps the monospace
/// source. `block` distinguishes display equations: they render as standalone
/// blocks (tight, no surrounding-line machinery) and the editor centers them
/// in their line instead of baseline-aligning.
@MainActor
public protocol EditorMathRenderer: AnyObject {
    func renderedMath(for equation: String, fontSize: CGFloat, dark: Bool,
                      block: Bool,
                      completion: @escaping @MainActor () -> Void) -> RenderedEquation?
}

/// Token colors, resolved per appearance. Values carried over from the previous
/// Xcode-like themes so highlighting looks unchanged across the engine swap.
/// Presentation kinds map onto semantic colors for code styles; in markup-rendering
/// styles most of them are drawn as *formatting* instead (see the coordinator).
private enum TokenPalette {
    static func color(for kind: EditorTokenKind, dark: Bool) -> NSColor? {
        switch kind {
        case .comment:  return NSColor(hex: dark ? "7F8C98" : "267507")
        case .string, .raw:
            return NSColor(hex: dark ? "FF8170" : "C41A16")
        case .number, .math:
            return NSColor(hex: dark ? "D9C97C" : "1C00CF")
        case .keyword:  return NSColor(hex: dark ? "FF7AB2" : "9B2393")
        case .heading:  return NSColor(hex: dark ? "FF7AB2" : "9B2393")
        case .type, .strong:
            return NSColor(hex: dark ? "6BDFFF" : "0B4F79")
        case .variable, .emphasis:
            return NSColor(hex: dark ? "4EB0CC" : "0F68A0")
        case .function: return NSColor(hex: dark ? "78C2B3" : "326D74")
        case .tag:      return NSColor(hex: dark ? "CC9768" : "815F03")
        case .property: return NSColor(hex: dark ? "B281EB" : "6C36A9")
        case .link:     return .linkColor
        case .colored(let light, let darkColor):
            return dark ? darkColor : light
        case .aligned, .punctuation, .listMarker, .listItem, .term,
             .struck, .underlined:
            return nil
        }
    }
}

/// Font variants for markup rendering, derived from the style's base font.
private func fontVariant(of base: NSFont, bold: Bool = false, italic: Bool = false,
                         scale: CGFloat = 1, monospaced: Bool = false) -> NSFont {
    let size = base.pointSize * scale
    if monospaced { return .monospacedSystemFont(ofSize: size, weight: .regular) }
    var traits: NSFontDescriptor.SymbolicTraits = []
    if bold { traits.insert(.bold) }
    if italic { traits.insert(.italic) }
    let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
    return NSFont(descriptor: descriptor, size: size) ?? base
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
        textView.textSelection = selection
        textView.scrollRangeToVisible(selection)
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
        textView.textSelection = range
        textView.scrollRangeToVisible(range)
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
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, tokenizer: tokenizer, mathRenderer: mathRenderer,
                    completionProvider: completionProvider)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = STTextView.scrollableTextView()
        let textView = scrollView.documentView as! STTextView

        textView.textDelegate = context.coordinator
        context.coordinator.textView = textView
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
        apply(style: style, to: textView)
        context.coordinator.installObservers(for: textView, in: scrollView)

        context.coordinator.push(text, into: textView)

        if let initialCursorLine {
            let offset = Self.offset(ofLine: initialCursorLine, column: 1, in: text)
            // Deferred one runloop turn: scrolling before the view is in the window
            // and laid out gets silently dropped by TextKit 2.
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.textSelection = NSRange(location: offset, length: 0)
                textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
            }
        }
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? STTextView else { return }
        controller?.textView = textView
        context.coordinator.isDark = colorScheme == .dark

        // External text changes (file loads, programmatic rewrites) push in and
        // repaint immediately; echoes of the view's own edits are filtered by
        // comparison, and their highlighting rides the debounced typing path —
        // repainting here too would double the per-keystroke work (it stutters).
        if !context.coordinator.isEditing, textView.text != text {
            context.coordinator.push(text, into: textView)
        }
        if context.coordinator.lastStyle != style {
            context.coordinator.lastStyle = style
            apply(style: style, to: textView)
            // Styling depends on the style (fonts, markup rendering) — repaint.
            context.coordinator.invalidateHighlight()
            context.coordinator.highlightNow()
        }
        context.coordinator.highlightIfAppearanceChanged()
    }

    private func apply(style: EditorStyle, to textView: STTextView) {
        textView.font = style.font
        textView.defaultParagraphStyle = style.paragraphStyle
        textView.widthTracksTextView = style.wrapLines
        textView.showsLineNumbers = style.showsLineNumbers
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

        /// The caret's viewport position captured before a repaint, restored
        /// after layout settles. Lazily arriving math images change line
        /// heights; without anchoring, a fragment jump (or plain reading
        /// position) drifts as the document reflows above the caret.
        private var pendingScrollAnchor: (location: NSTextLocation, offset: CGFloat)?
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
        func installObservers(for textView: STTextView, in scrollView: NSScrollView) {
            let reposition: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.layoutMathOverlays() }
            }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main, using: reposition))
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: textView, queue: .main, using: reposition))
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

        public func textViewDidChangeText(_ notification: Notification) {
            guard !isPushingText, let textView else { return }
            isEditing = true
            text.wrappedValue = textView.text ?? ""
            isEditing = false
            // Debounced: a full-document repaint per keystroke stutters; colors
            // catching up ~100ms after typing pauses is imperceptible.
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
            revealedParagraph = paragraph
            if moved { highlightNow() }
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
            // Repaints can change layout (math reservations landing, markup
            // concealment) — anchor the caret's viewport position now so the
            // text doesn't jump under the reader when line heights change.
            pendingScrollAnchor = caretScrollAnchor()
            // Every exit re-syncs overlays and the anchor — including removal
            // when the doc emptied or the style stopped rendering markup.
            // Deferred a tick: TextKit must lay out the new attributes first.
            defer {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.layoutMathOverlays()
                        self?.restoreScrollAnchor()
                    }
                }
            }
            guard full.length > 0 else { return }

            // Base reset: uniform font/paragraph/color, clearing prior markup styling.
            textView.setAttributes([
                .font: style.font,
                .paragraphStyle: style.paragraphStyle,
                .foregroundColor: NSColor.labelColor,
            ], range: full)
            textView.removeRenderingAttribute(.foregroundColor, range: full)
            textView.removeRenderingAttribute(.backgroundColor, range: full)
            textView.removeRenderingAttribute(.underlineStyle, range: full)
            textView.removeRenderingAttribute(.strikethroughStyle, range: full)

            for token in tokenizer.tokens(in: content) {
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
            composeParagraphStyle(over: ns.paragraphRange(for: range),
                                  base: style.paragraphStyle, on: textView) {
                $0.minimumLineHeight = max(image.size.height + 2,
                                           style.font.pointSize * style.lineHeightMultiple)
                // A block equation centers: the collapsed source + kern is the
                // reserved box, so centering the paragraph centers the image
                // (which is placed at the reserved box's segment frame).
                if block { $0.alignment = .center }
            }
            textView.addRenderingAttributes([.foregroundColor: NSColor.clear], range: range)
            pendingMath.append((range, equation, block))
        }

        /// (Re)place equation images at their reserved spots. Runs a tick after
        /// each paint (layout must settle first) and again whenever layout moves
        /// under the overlays (scroll, resize).
        private func layoutMathOverlays() {
            for view in mathOverlays { view.removeFromSuperview() }
            mathOverlays.removeAll()
            guard let textView, !pendingMath.isEmpty,
                  let contentManager = textView.textLayoutManager.textContentManager
            else { return }

            for (range, equation, block) in pendingMath {
                guard let textRange = NSTextRange(range, in: contentManager),
                      let segment = textView.textLayoutManager.textSegmentFrame(
                        in: textRange, type: .standard)
                else { continue }
                let image = equation.image
                // Inline equations baseline-align: the image's internal baseline
                // (from typst's layout) sits exactly on the text line's drawn
                // baseline. Block equations own their whole line — they center
                // in it (also the fallback when line metrics can't be read).
                let y: CGFloat
                if !block, let baseline = textBaselineY(at: textRange.location,
                                                        near: segment, in: textView) {
                    y = baseline - equation.baseline
                } else {
                    y = segment.minY + (segment.height - image.size.height) / 2
                }
                // Layout coordinates are content-view coordinates; the content
                // view sits right of the gutter (its one offset from the view).
                let gutterWidth = textView.gutterView?.frame.width ?? 0
                let overlay = NSImageView(image: image)
                overlay.frame = CGRect(
                    origin: CGPoint(x: segment.minX + gutterWidth, y: y),
                    size: image.size)
                textView.addSubview(overlay)
                mathOverlays.append(overlay)
            }
        }

        // MARK: Completion

        /// Feeds the engine's built-in completion window (Escape/F5). The sync
        /// variant declines so the engine takes this async path.
        public func textView(_ textView: STTextView,
                             completionItemsAtLocation location: any NSTextLocation)
            async -> [any STCompletionItem]? {
            guard let completionProvider,
                  let contentManager = textView.textLayoutManager.textContentManager
            else { return nil }
            let text = textView.text ?? ""
            let offset = contentManager.offset(from: contentManager.documentRange.location,
                                               to: location)
            let completions = await completionProvider.completions(in: text, at: offset)

            // Prefix-filter against what's typed so the retriggering window
            // live-narrows even when the provider returns unfiltered lists —
            // but trust the provider (fuzzy matching etc.) when filtering
            // would leave nothing.
            let ns = text as NSString
            let typed = ns.substring(with: Self.identifierRange(endingAt: offset, in: ns))
                .drop { $0 == "#" || $0 == "@" }
                .lowercased()
            let filtered = typed.isEmpty ? completions
                : completions.filter { $0.label.lowercased().hasPrefix(typed) }
            let final = filtered.isEmpty ? completions : filtered
            return final.isEmpty ? nil : final.map(CompletionListItem.init)
        }

        public func textView(_ textView: STTextView,
                             insertCompletionItem item: any STCompletionItem) {
            guard let item = item as? CompletionListItem else { return }
            let ns = (textView.text ?? "") as NSString
            let caret = min(textView.textSelection.location, ns.length)
            let range = item.completion.replaceRange
                ?? Self.identifierRange(endingAt: caret, in: ns)
            guard range.location + range.length <= ns.length else { return }
            textView.replaceCharacters(in: range, with: item.completion.insertText)
            let end = range.location + (item.completion.insertText as NSString).length
            textView.textSelection = NSRange(location: end, length: 0)
        }

        /// The identifier being typed just before `offset` — what a completion
        /// replaces when the provider didn't say (alphanumerics, `_`, `-`, and
        /// the `#`/`@` that introduce typst calls and references).
        static func identifierRange(endingAt offset: Int, in text: NSString) -> NSRange {
            var start = offset
            while start > 0 {
                let char = text.character(at: start - 1)
                guard let scalar = Unicode.Scalar(char),
                      CharacterSet.alphanumerics.contains(scalar)
                        || scalar == "_" || scalar == "-" || scalar == "#" || scalar == "@"
                else { break }
                start -= 1
            }
            return NSRange(location: start, length: offset - start)
        }

        // MARK: Scroll anchoring

        /// Where the caret sits in the viewport right now — nil when it isn't
        /// visible (then the repaint shouldn't touch the scroll position).
        private func caretScrollAnchor() -> (location: NSTextLocation, offset: CGFloat)? {
            guard let textView,
                  let contentManager = textView.textLayoutManager.textContentManager
            else { return nil }
            let length = ((textView.text ?? "") as NSString).length
            let caret = min(textView.textSelection.location, length)
            guard let range = NSTextRange(NSRange(location: caret, length: 0),
                                          in: contentManager),
                  let frame = textView.textLayoutManager.textSegmentFrame(
                    at: range.location, type: .standard)
            else { return nil }
            let visible = textView.visibleRect
            guard frame.midY >= visible.minY, frame.midY <= visible.maxY else { return nil }
            return (range.location, frame.minY - visible.minY)
        }

        /// Put the caret's line back at the viewport offset it had before the
        /// repaint, compensating for whatever line-height changes landed above it.
        private func restoreScrollAnchor() {
            guard let anchor = pendingScrollAnchor else { return }
            pendingScrollAnchor = nil
            guard let textView,
                  let frame = textView.textLayoutManager.textSegmentFrame(
                    at: anchor.location, type: .standard)
            else { return }
            let visible = textView.visibleRect
            let targetY = max(0, frame.minY - anchor.offset)
            if abs(targetY - visible.minY) > 0.5 {
                textView.scroll(CGPoint(x: visible.minX, y: targetY))
            }
        }

        /// The y of the *drawn* text baseline for the line containing `segment`,
        /// in layout coordinates. The engine draws each line fragment shifted by
        /// -(height × (lineHeightMultiple − 1) / 2) — text centered within the
        /// multiplied line height — so the on-screen baseline is the fragment's
        /// glyph origin plus that same correction.
        private func textBaselineY(at location: NSTextLocation, near segment: CGRect,
                                   in textView: STTextView) -> CGFloat? {
            let multiple = max(lastStyle?.lineHeightMultiple ?? 1, 1)
            var baseline: CGFloat?
            textView.textLayoutManager.enumerateTextLayoutFragments(
                from: location, options: []) { fragment in
                for line in fragment.textLineFragments {
                    let top = fragment.layoutFragmentFrame.minY
                        + line.typographicBounds.minY
                    guard segment.midY >= top,
                          segment.midY <= top + line.typographicBounds.height
                    else { continue }
                    let centering = -(line.typographicBounds.height * (multiple - 1) / 2)
                    baseline = top + centering + line.glyphOrigin.y
                    return false
                }
                return false   // only the fragment containing the location
            }
            return baseline
        }
    }
}

// MARK: - Stock tokenizer (Highlightr)

/// The framework's batteries-included tokenizer: whole-document syntax
/// highlighting via Highlightr (highlight.js, ~190 languages), emitted as
/// appearance-paired `.colored` tokens so one tokenize serves light and dark.
/// Plugins with a real parser (typst) use their own tokenizer; everything else
/// gets this one for free.
@MainActor
public final class HighlightrTokenizer: EditorTokenizer {
    /// One highlighter per appearance, shared process-wide. Lazily built on
    /// first use (a JS context + highlight.js load, ~100ms once).
    private static let lightHighlighter: Highlightr? = {
        let highlighter = Highlightr()
        highlighter?.setTheme(to: "xcode")
        return highlighter
    }()
    private static let darkHighlighter: Highlightr? = {
        let highlighter = Highlightr()
        highlighter?.setTheme(to: "atom-one-dark")
        return highlighter
    }()

    /// Highlighted runs per (language, code). Whole documents make big keys —
    /// keep the cache tiny; its job is absorbing repaints, not history.
    private static var cache: [String: [(NSRange, EditorTokenKind)]] = [:]

    /// Skip pathological inputs: highlight.js is O(document) per repaint.
    private static let sizeLimit = 512 * 1024

    private let language: String

    public init(language: String) {
        self.language = language
    }

    /// Nil when the file's language is unknown — pass no tokenizer, plain text.
    public convenience init?(fileURL: URL) {
        guard let name = editorLanguageName(for: fileURL) else { return nil }
        self.init(language: Self.hljsName(for: name))
    }

    /// Pay the JS-context + highlight.js load behind a loading indicator
    /// instead of the first paint.
    public static func warmUp() {
        _ = lightHighlighter
        _ = darkHighlighter
    }

    public func tokens(in text: String) -> [(range: NSRange, kind: EditorTokenKind)] {
        Self.highlight(text, language: language)
            .map { (range: $0.0, kind: $0.1) }
    }

    /// The reusable core: highlight `code` as `language`, cached. Also serves
    /// embedded regions (typst raw blocks) at an offset the caller applies.
    public static func highlight(_ code: String,
                                 language: String) -> [(NSRange, EditorTokenKind)] {
        guard code.utf8.count <= sizeLimit else { return [] }
        let key = "\(language)\u{0}\(code)"
        if let cached = cache[key] { return cached }

        var runs: [(NSRange, EditorTokenKind)] = []
        if let light = lightHighlighter?.highlight(code, as: language),
           let dark = darkHighlighter?.highlight(code, as: language),
           light.string == code, dark.length == light.length {
            light.enumerateAttribute(.foregroundColor,
                                     in: NSRange(location: 0, length: light.length)) { value, range, _ in
                guard let lightColor = value as? NSColor else { return }
                let darkColor = dark.attribute(.foregroundColor, at: range.location,
                                               effectiveRange: nil) as? NSColor ?? lightColor
                runs.append((range, .colored(light: lightColor, dark: darkColor)))
            }
        }
        if cache.count >= 4 { cache.removeAll(keepingCapacity: true) }
        cache[key] = runs
        return runs
    }

    /// `editorLanguageName` speaks display names; highlight.js has its own ids.
    static func hljsName(for languageName: String) -> String {
        switch languageName {
        case "objective-c": return "objectivec"
        case "c++": return "cpp"
        case "html": return "xml"
        case "shell": return "bash"
        default: return languageName
        }
    }
}

// MARK: - Completion list items

/// Adapts an `EditorCompletion` to the engine's completion window: a plain
/// label row (mono) with the detail dimmed after it. The protocol is
/// nonisolated but the engine only asks for `view` on the main actor.
private final class CompletionListItem: STCompletionItem {
    let completion: EditorCompletion
    var id: String { completion.label + (completion.detail ?? "") }

    init(_ completion: EditorCompletion) {
        self.completion = completion
    }

    var view: NSView {
        let completion = self.completion   // Sendable copy for the isolated hop
        return MainActor.assumeIsolated {
            let label = NSMutableAttributedString(
                string: completion.label,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ])
            if let detail = completion.detail {
                label.append(NSAttributedString(
                    string: "  \(detail)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
            }
            let field = NSTextField(labelWithAttributedString: label)
            field.lineBreakMode = .byTruncatingTail
            return field
        }
    }
}

// MARK: - Language names

/// A display name for a file's language ("swift", "markdown", …), nil for plain
/// or unknown types. For header badges.
public func editorLanguageName(for url: URL) -> String? {
    let names: [String: String] = [
        "swift": "swift", "m": "objective-c", "mm": "objective-c",
        "c": "c", "h": "c", "cpp": "c++", "cc": "c++", "hpp": "c++",
        "rs": "rust", "py": "python", "rb": "ruby", "go": "go",
        "js": "javascript", "jsx": "javascript", "ts": "typescript",
        "tsx": "typescript", "java": "java", "kt": "kotlin",
        "md": "markdown", "json": "json", "yaml": "yaml", "yml": "yaml",
        "toml": "toml", "html": "html", "css": "css", "sh": "shell",
        "bash": "shell", "zsh": "shell", "sql": "sql", "lua": "lua",
        "hs": "haskell", "typ": "typst",
    ]
    return names[url.pathExtension.lowercased()]
}

// MARK: - Helpers

private extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
