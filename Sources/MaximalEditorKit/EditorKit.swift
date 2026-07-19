import SwiftUI
import AppKit
import STTextView

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
    /// An equation (`$…$`): monospaced number-colored (rendered equations would
    /// need layout participation the engine doesn't offer displays-only). The
    /// delimiters arrive separately as `punctuation`, so they conceal.
    case math
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
    private let controller: EditorController?

    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - fileURL: Reserved for language detection/services; unused by the
    ///     current engine except through `editorLanguageName(for:)`.
    ///   - initialCursorLine: 1-based line the caret starts on.
    ///   - tokenizer: Custom highlighting, painted as rendering attributes.
    public init(text: Binding<String>, fileURL: URL? = nil,
                style: EditorStyle = .code(),
                initialCursorLine: Int? = nil,
                tokenizer: EditorTokenizer? = nil,
                controller: EditorController? = nil) {
        self._text = text
        self.fileURL = fileURL
        self.style = style
        self.initialCursorLine = initialCursorLine
        self.tokenizer = tokenizer
        self.controller = controller
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, tokenizer: tokenizer)
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
        apply(style: style, to: textView)

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
        weak var textView: STTextView?
        var isEditing = false
        var lastStyle: EditorStyle?
        var isDark = false

        private var highlightTask: Task<Void, Never>?
        private var lastHighlightedText: String?
        private var lastHighlightedDark: Bool?
        private var lastHighlightedRevealStart: Int?

        /// The paragraph (line) holding the caret. Markup on this line shows its
        /// delimiters (dimmed) for editing; elsewhere they're concealed — the
        /// live-preview reveal-on-caret behavior.
        private var revealedParagraph: NSRange?

        init(text: Binding<String>, tokenizer: EditorTokenizer?) {
            self.text = text
            self.tokenizer = tokenizer
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
                let paragraph = (style.paragraphStyle.mutableCopy() as! NSMutableParagraphStyle)
                paragraph.alignment = switch alignment {
                case .leading: .natural
                case .center: .center
                case .trailing: .right
                }
                // Paragraph properties resolve from the paragraph's *start* — the
                // token range begins mid-line (inside the brackets), so the style
                // must cover the whole paragraph or it silently doesn't apply.
                textView.addAttributes([.paragraphStyle: paragraph],
                                       range: ns.paragraphRange(for: token.range))
            case .link:
                textView.addRenderingAttributes([
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: token.range)
            case .listMarker:
                // Bullets and escapes carry meaning — dimmed, never concealed.
                dim(token.range)
            case .listItem:
                let paragraph = (style.paragraphStyle.mutableCopy() as! NSMutableParagraphStyle)
                paragraph.headIndent = style.font.pointSize * 1.4
                textView.addAttributes([.paragraphStyle: paragraph],
                                       range: ns.paragraphRange(for: token.range))
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
            default:
                // Code constructs read as code even in prose: monospaced and
                // colored. Content stays serif; the machinery doesn't. Spans come
                // from the real parser, so no delimiter heuristics are needed.
                textView.addAttributes(
                    [.font: fontVariant(of: style.font, scale: 0.9, monospaced: true)],
                    range: token.range)
                if let color = TokenPalette.color(for: token.kind, dark: isDark) {
                    textView.addRenderingAttributes([.foregroundColor: color],
                                                    range: token.range)
                }
            }
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
