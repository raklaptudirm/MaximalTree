import SwiftUI
import AppKit
import Highlightr

// The editor's highlighting vocabulary and machinery: the engine-neutral token
// kinds plugins emit, the palette that colors them in code styles, and the
// stock Highlightr tokenizer that serves every source file without a
// dedicated parser.

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
