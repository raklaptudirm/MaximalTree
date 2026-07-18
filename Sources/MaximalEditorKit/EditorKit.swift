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

    public init(design: Design, size: CGFloat, lineHeightMultiple: Double,
                wrapLines: Bool, indentSpaces: Int, showsLineNumbers: Bool = true) {
        self.design = design
        self.size = size
        self.lineHeightMultiple = lineHeightMultiple
        self.wrapLines = wrapLines
        self.indentSpaces = indentSpaces
        self.showsLineNumbers = showsLineNumbers
    }

    public static func code(size: CGFloat = 12, wrapLines: Bool = false,
                            indentSpaces: Int = 4) -> EditorStyle {
        EditorStyle(design: .monospaced, size: size, lineHeightMultiple: 1.2,
                    wrapLines: wrapLines, indentSpaces: indentSpaces)
    }

    /// Manuscript, not IDE: no line-number gutter.
    public static func prose(size: CGFloat = 15) -> EditorStyle {
        EditorStyle(design: .serif, size: size, lineHeightMultiple: 1.5,
                    wrapLines: true, indentSpaces: 2, showsLineNumbers: false)
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

/// The engine-neutral token vocabulary plugins highlight with.
public enum EditorTokenKind {
    case comment, string, number, keyword, type, variable, function, tag, property
}

/// A plugin-supplied lexer. Return every token in `text`; the framework paints
/// them as display-only rendering attributes. Engine-neutral so tokenizers
/// survive engine swaps (and stay Foundation-only and testable in plugin cores).
public protocol EditorTokenizer: AnyObject {
    func tokens(in text: String) -> [(range: NSRange, kind: EditorTokenKind)]
}

/// Token colors, resolved per appearance. Values carried over from the previous
/// Xcode-like themes so highlighting looks unchanged across the engine swap.
private enum TokenPalette {
    static func color(for kind: EditorTokenKind, dark: Bool) -> NSColor {
        switch kind {
        case .comment:  return NSColor(hex: dark ? "7F8C98" : "267507")
        case .string:   return NSColor(hex: dark ? "FF8170" : "C41A16")
        case .number:   return NSColor(hex: dark ? "D9C97C" : "1C00CF")
        case .keyword:  return NSColor(hex: dark ? "FF7AB2" : "9B2393")
        case .type:     return NSColor(hex: dark ? "6BDFFF" : "0B4F79")
        case .variable: return NSColor(hex: dark ? "4EB0CC" : "0F68A0")
        case .function: return NSColor(hex: dark ? "78C2B3" : "326D74")
        case .tag:      return NSColor(hex: dark ? "CC9768" : "815F03")
        case .property: return NSColor(hex: dark ? "B281EB" : "6C36A9")
        }
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

        /// Repaint token colors as rendering attributes: display-only, so the text
        /// storage and undo stack stay untouched. No-ops when nothing changed.
        func highlightNow() {
            guard let textView, let tokenizer else { return }
            let content = textView.text ?? ""
            if content == lastHighlightedText && isDark == lastHighlightedDark { return }
            lastHighlightedText = content
            lastHighlightedDark = isDark

            let full = NSRange(location: 0, length: (content as NSString).length)
            guard full.length > 0 else { return }
            textView.removeRenderingAttribute(.foregroundColor, range: full)
            for token in tokenizer.tokens(in: content) {
                textView.addRenderingAttributes(
                    [.foregroundColor: TokenPalette.color(for: token.kind, dark: isDark)],
                    range: token.range
                )
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
