import SwiftUI
import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import CodeEditLanguages

// MaximalEditorKit: the one place MaximalTree touches its editor engine.
//
// Plugins depend on this framework (linked, not embedded — the app ships one
// copy), never on CodeEditSourceEditor directly. That containment is the point:
// the engine has real integration warts (Swift 5-only protocol conformances, a
// build-tool plugin we stub out, binding-read-once semantics) and a pre-1.0 API —
// this seam keeps those paid-for once, and makes a future engine change
// (STTextView, our own TextKit 2 view, tinymist semantic tokens) a one-target job.
//
// This target deliberately builds in Swift 5 language mode: it conforms to
// HighlightProviding and TextViewCoordinator from a Swift 5 module, which Swift 6
// witness checking rejects in every spelling.

// MARK: - Style

/// How an editor should look and behave. Presets cover the two personalities used
/// in MaximalTree: `.code` (monospaced IDE) and `.prose` (serif manuscript).
public struct EditorStyle {
    public enum Design {
        case monospaced, serif
    }

    public var design: Design
    public var size: CGFloat
    public var lineHeightMultiple: Double
    public var wrapLines: Bool
    public var indentSpaces: Int

    public init(design: Design, size: CGFloat, lineHeightMultiple: Double,
                wrapLines: Bool, indentSpaces: Int) {
        self.design = design
        self.size = size
        self.lineHeightMultiple = lineHeightMultiple
        self.wrapLines = wrapLines
        self.indentSpaces = indentSpaces
    }

    public static func code(size: CGFloat = 12, wrapLines: Bool = false,
                            indentSpaces: Int = 4) -> EditorStyle {
        EditorStyle(design: .monospaced, size: size, lineHeightMultiple: 1.2,
                    wrapLines: wrapLines, indentSpaces: indentSpaces)
    }

    public static func prose(size: CGFloat = 15) -> EditorStyle {
        EditorStyle(design: .serif, size: size, lineHeightMultiple: 1.5,
                    wrapLines: true, indentSpaces: 2)
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
}

// MARK: - Tokenizer

/// The engine-neutral token vocabulary plugins highlight with.
public enum EditorTokenKind {
    case comment, string, number, keyword, type, variable, function, tag, property
}

/// A plugin-supplied lexer. Return every token in `text`; the framework adapts it
/// to the engine's highlighter. Kept engine-neutral so tokenizers survive an
/// engine swap (and stay Foundation-only and unit-testable in plugin cores).
public protocol EditorTokenizer: AnyObject {
    func tokens(in text: String) -> [(range: NSRange, kind: EditorTokenKind)]
}

/// Adapts an `EditorTokenizer` to the engine's `HighlightProviding`.
private final class TokenizerHighlighter: HighlightProviding {
    private let tokenizer: EditorTokenizer

    init(_ tokenizer: EditorTokenizer) { self.tokenizer = tokenizer }

    @MainActor func setUp(textView: TextView, codeLanguage: CodeLanguage) {}

    @MainActor func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        // Full invalidation keeps multi-line constructs correct without
        // incremental bookkeeping; regex passes at document scale are cheap.
        let length = (textView.string as NSString).length
        completion(.success(IndexSet(integersIn: 0..<max(length, 1))))
    }

    @MainActor func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        // Tokenize the full document and filter: line-anchored and multi-line
        // patterns would misfire on a substring that cuts through a line.
        let highlights = tokenizer.tokens(in: textView.string).compactMap { token -> HighlightRange? in
            guard NSIntersectionRange(token.range, range).length > 0 else { return nil }
            return HighlightRange(range: token.range, capture: Self.capture(for: token.kind))
        }
        completion(.success(highlights))
    }

    private static func capture(for kind: EditorTokenKind) -> CaptureName {
        switch kind {
        case .comment:  return .comment
        case .string:   return .string
        case .number:   return .number
        case .keyword:  return .keyword
        case .type:     return .type
        case .variable: return .variable
        case .function: return .function
        case .tag:      return .tag
        case .property: return .property
        }
    }
}

// MARK: - Controller

/// A handle for programmatic edits and cursor movement on a live editor. Pass one
/// to `MaximalEditor(controller:)` and keep it in view `@State`.
public final class EditorController {
    fileprivate let coordinator = Coordinator()

    public init() {}

    /// Replace `range` with `replacement`, then select `selection` (coordinates in
    /// the resulting text). Undo-registered by the engine.
    @MainActor
    public func applyEdit(range: NSRange, replacement: String, selection: NSRange) {
        guard let textView = coordinator.controller?.textView else { return }
        textView.replaceCharacters(in: range, with: replacement)
        textView.selectionManager.setSelectedRange(selection)
        textView.scrollSelectionToVisible()
    }

    /// Current text and primary selection, for computing edits.
    @MainActor
    public func textAndSelection() -> (text: String, selection: NSRange)? {
        guard let textView = coordinator.controller?.textView else { return nil }
        let selection = textView.selectionManager.textSelections.first?.range
            ?? NSRange(location: 0, length: 0)
        return (textView.string, selection)
    }

    /// Move the caret to a 1-based line/column and scroll it into view.
    @MainActor
    public func moveCursor(toLine line: Int, column: Int) {
        coordinator.controller?.setCursorPositions(
            [CursorPosition(line: line, column: max(column, 1))],
            scrollToVisible: true
        )
    }

    fileprivate final class Coordinator: TextViewCoordinator {
        weak var controller: TextViewController?
        func prepareCoordinator(controller: TextViewController) { self.controller = controller }
        func destroy() { controller = nil }
    }
}

// MARK: - Editor view

/// MaximalTree's editor. Wraps the engine behind a stable surface.
///
/// Engine semantics callers must respect: the text binding is read **once, at
/// construction** — never build a `MaximalEditor` before its text is loaded, and
/// give it a per-document `.id(...)` so switching documents rebuilds it.
public struct MaximalEditor: View {
    @Binding private var text: String
    private let fileURL: URL?
    private let style: EditorStyle
    private let tokenizer: EditorTokenizer?
    private let controller: EditorController?

    @State private var editorState = SourceEditorState()
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - fileURL: Used for language detection when no `tokenizer` is given.
    ///   - style: Look and behavior; see `EditorStyle` presets.
    ///   - initialCursorLine: 1-based line the caret starts on. Must be given at
    ///     construction (a controller only attaches afterwards).
    ///   - tokenizer: Custom highlighting; overrides language detection.
    public init(text: Binding<String>, fileURL: URL? = nil,
                style: EditorStyle = .code(),
                initialCursorLine: Int? = nil,
                tokenizer: EditorTokenizer? = nil,
                controller: EditorController? = nil) {
        self._text = text
        self.fileURL = fileURL
        self.style = style
        self.tokenizer = tokenizer
        self.controller = controller
        var state = SourceEditorState()
        if let initialCursorLine {
            state.cursorPositions = [CursorPosition(line: initialCursorLine, column: 1)]
        }
        self._editorState = State(initialValue: state)
    }

    public var body: some View {
        SourceEditor(
            $text,
            language: language,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: colorScheme == .dark ? .maximalDark : .maximalLight,
                    font: style.font,
                    lineHeightMultiple: style.lineHeightMultiple,
                    wrapLines: style.wrapLines
                ),
                behavior: .init(indentOption: .spaces(count: style.indentSpaces))
            ),
            state: $editorState,
            highlightProviders: tokenizer.map { [TokenizerHighlighter($0)] },
            coordinators: controller.map { [$0.coordinator] } ?? []
        )
    }

    private var language: CodeLanguage {
        guard tokenizer == nil, let fileURL else { return .default }
        return CodeLanguage.detectLanguageFrom(url: fileURL)
    }
}

/// The detected language name for a file ("swift", "markdown", …), nil when
/// detection falls back to plain text. For header badges.
public func editorLanguageName(for url: URL) -> String? {
    let language = CodeLanguage.detectLanguageFrom(url: url)
    return language == .default ? nil : language.id.rawValue
}

// MARK: - Theme (shared Xcode-like light/dark)

private extension EditorTheme {
    static var maximalLight: EditorTheme {
        EditorTheme(
            text: Attribute(color: NSColor(hex: "000000")),
            insertionPoint: NSColor(hex: "000000"),
            invisibles: Attribute(color: NSColor(hex: "D6D6D6")),
            background: NSColor(hex: "FFFFFF"),
            lineHighlight: NSColor(hex: "ECF5FF"),
            selection: NSColor(hex: "B2D7FF"),
            keywords: Attribute(color: NSColor(hex: "9B2393"), bold: true),
            commands: Attribute(color: NSColor(hex: "326D74")),
            types: Attribute(color: NSColor(hex: "0B4F79"), bold: true),
            attributes: Attribute(color: NSColor(hex: "815F03")),
            variables: Attribute(color: NSColor(hex: "0F68A0"), italic: true),
            values: Attribute(color: NSColor(hex: "6C36A9")),
            numbers: Attribute(color: NSColor(hex: "1C00CF")),
            strings: Attribute(color: NSColor(hex: "C41A16")),
            characters: Attribute(color: NSColor(hex: "1C00CF")),
            comments: Attribute(color: NSColor(hex: "267507"))
        )
    }

    static var maximalDark: EditorTheme {
        EditorTheme(
            text: Attribute(color: NSColor(hex: "FFFFFF")),
            insertionPoint: NSColor(hex: "007AFF"),
            invisibles: Attribute(color: NSColor(hex: "53606E")),
            background: NSColor(hex: "292A30"),
            lineHighlight: NSColor(hex: "2F3239"),
            selection: NSColor(hex: "646F83"),
            keywords: Attribute(color: NSColor(hex: "FF7AB2"), bold: true),
            commands: Attribute(color: NSColor(hex: "78C2B3")),
            types: Attribute(color: NSColor(hex: "6BDFFF"), bold: true),
            attributes: Attribute(color: NSColor(hex: "CC9768")),
            variables: Attribute(color: NSColor(hex: "4EB0CC"), italic: true),
            values: Attribute(color: NSColor(hex: "B281EB")),
            numbers: Attribute(color: NSColor(hex: "D9C97C")),
            strings: Attribute(color: NSColor(hex: "FF8170")),
            characters: Attribute(color: NSColor(hex: "D9C97C")),
            comments: Attribute(color: NSColor(hex: "7F8C98"))
        )
    }
}

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
