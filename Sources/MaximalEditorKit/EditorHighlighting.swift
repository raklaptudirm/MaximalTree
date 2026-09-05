import SwiftUI
import AppKit

// The editor's highlighting vocabulary and machinery: the engine-neutral token
// kinds plugins emit, the palette that colors them, and the stock tokenizer
// that serves every source file without a dedicated parser.

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
    /// A token whose colour a tokenizer pins itself, for the rare thing with no
    /// semantic equivalent (diff additions/deletions read *as* colours). Both
    /// appearances are supplied; paint-time picks one.
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
enum TokenPalette {
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
func fontVariant(of base: NSFont, bold: Bool = false, italic: Bool = false,
                         scale: CGFloat = 1, monospaced: Bool = false) -> NSFont {
    let size = base.pointSize * scale
    if monospaced { return .monospacedSystemFont(ofSize: size, weight: .regular) }
    var traits: NSFontDescriptor.SymbolicTraits = []
    if bold { traits.insert(.bold) }
    if italic { traits.insert(.italic) }
    let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
    return NSFont(descriptor: descriptor, size: size) ?? base
}

// MARK: - Stock tokenizer (highlight.js)

/// The framework's batteries-included tokenizer: whole-document highlighting via
/// the bundled highlight.js (~190 grammars), emitted as the editor's **own**
/// token kinds rather than baked-in colours. Plugins with a real parser (typst)
/// use their own tokenizer; everything else gets this one for free.
///
/// Because the tokens are semantic, one pass serves both appearances — the
/// palette resolves colours at paint time — so switching light/dark repaints
/// from cache instead of re-highlighting.
@MainActor
public final class SyntaxTokenizer: EditorTokenizer {
    /// Runs per (language, code). Whole documents make big keys — keep the cache
    /// tiny; its job is absorbing repaints, not history.
    private static var cache: [String: [(NSRange, EditorTokenKind)]] = [:]

    /// Skip pathological inputs: highlight.js is O(document) per repaint.
    private static let sizeLimit = 512 * 1024

    private let language: String

    public init(language: String) {
        self.language = language
    }

    /// Nil when the file's language is unknown — pass no tokenizer, plain text.
    public convenience init?(fileURL: URL) {
        guard let id = EditorLanguage.id(for: fileURL) else { return nil }
        self.init(language: id)
    }

    /// Pay the JS-context + grammar load behind a loading indicator instead of
    /// the first paint.
    public static func warmUp() { SyntaxEngine.warmUp() }

    /// Whether `language` can be highlighted. Worth checking before every call:
    /// handed an unknown name, highlight.js silently falls back to *auto
    /// detection*, which paints confident but wrong colors.
    public static func isSupported(_ language: String) -> Bool {
        SyntaxEngine.supportedLanguages.contains(language)
    }

    public func tokens(in text: String) -> [(range: NSRange, kind: EditorTokenKind)] {
        Self.highlight(text, language: language)
            .map { (range: $0.0, kind: $0.1) }
    }

    /// The reusable core: highlight `code` as `language`, cached. Also serves
    /// embedded regions (typst raw blocks) at an offset the caller applies.
    public static func highlight(_ code: String,
                                 language: String) -> [(NSRange, EditorTokenKind)] {
        guard code.utf8.count <= sizeLimit, isSupported(language) else { return [] }
        let key = "\(language)\u{0}\(code)"
        if let cached = cache[key] { return cached }

        let runs = SyntaxEngine.runs(for: code, language: language)
            .compactMap { range, className -> (NSRange, EditorTokenKind)? in
                kind(for: className).map { (range, $0) }
            }
        if cache.count >= 4 { cache.removeAll(keepingCapacity: true) }
        cache[key] = runs
        return runs
    }

    /// highlight.js class → the editor's token vocabulary.
    ///
    /// Deliberately restricted to *colour-only* kinds. The markup kinds
    /// (`.heading`, `.punctuation`, `.listItem`, …) also drive concealment and
    /// layout in prose styles, which would be wrong inside a code block — a
    /// markdown snippet in a typst document must not hide its own `#` markers.
    static func kind(for className: String) -> EditorTokenKind? {
        // Classes arrive as `hljs-title function_` — try the whole thing, then
        // the leading scope.
        if let direct = kinds[className] { return direct }
        guard let head = className.split(separator: " ").first else { return nil }
        return kinds[String(head)]
    }

    private static let kinds: [String: EditorTokenKind] = [
        "hljs-comment": .comment, "hljs-quote": .comment, "hljs-doctag": .comment,

        "hljs-string": .string, "hljs-regexp": .string, "hljs-char": .string,
        "hljs-char.escape_": .string, "hljs-template-tag": .string,

        "hljs-number": .number, "hljs-formula": .number,

        "hljs-keyword": .keyword, "hljs-literal": .keyword,
        "hljs-selector-tag": .keyword, "hljs-section": .keyword,
        "hljs-strong": .keyword, "hljs-bullet": .keyword,

        "hljs-type": .type, "hljs-built_in": .type, "hljs-class": .type,
        "hljs-title.class_": .type, "hljs-title class_": .type,
        "hljs-title.class_.inherited__": .type,

        "hljs-title": .function, "hljs-title.function_": .function,
        "hljs-title function_": .function, "hljs-function": .function,

        "hljs-variable": .variable, "hljs-template-variable": .variable,
        "hljs-variable.language_": .variable, "hljs-variable.constant_": .variable,
        "hljs-params": .variable, "hljs-emphasis": .variable,

        "hljs-attr": .property, "hljs-attribute": .property,
        "hljs-property": .property, "hljs-meta": .property,
        "hljs-symbol": .property, "hljs-selector-attr": .property,
        "hljs-selector-pseudo": .property, "hljs-meta.keyword_": .property,

        "hljs-tag": .tag, "hljs-name": .tag,
        "hljs-selector-id": .tag, "hljs-selector-class": .tag,

        "hljs-link": .link, "hljs-code": .raw,

        // Diffs read by colour, not by category — the one place we still pin
        // both appearances ourselves.
        "hljs-addition": .colored(light: NSColor(hex: "267507"),
                                  dark: NSColor(hex: "7EE787")),
        "hljs-deletion": .colored(light: NSColor(hex: "C41A16"),
                                  dark: NSColor(hex: "FF8170")),
    ]
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
