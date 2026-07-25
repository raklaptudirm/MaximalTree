import SwiftUI
import AppKit
import MaximalEditorKit
import MaximalTreeKit

// The editor-seam implementations: parser-backed tokens (with the editor's
// stock tokenizer for embedded foreign code), tinymist-backed completions, and
// compiler-backed rendered math.

// MARK: - Tokenizer

/// Maps the real typst parser's tokens (via the FFI) to the editor's
/// engine-neutral vocabulary. Foreign-language code inside raw blocks arrives
/// as `embed` regions carrying their language; those are expanded through the
/// editor framework's shared syntax tokenizer.
final class TypstTokenizer: EditorTokenizer {
    func tokens(in text: String) -> [(range: NSRange, kind: EditorTokenKind)] {
        // The real parser (mode-aware, exact spans) — the only tokenizer.
        guard let parsed = TypstEngine.tokens(in: text) else { return [] }
        let ns = text as NSString
        var out: [(range: NSRange, kind: EditorTokenKind)] = []
        for token in parsed {
            let kind: EditorTokenKind
            switch token.k {
            case "comment":  kind = .comment
            case "string":   kind = .string
            case "math":     kind = .math(block: token.a == "block")
            case "raw":      kind = .raw
            case "heading":  kind = .heading(level: token.n ?? 1)
            case "strong":   kind = .strong
            case "emphasis": kind = .emphasis
            case "function": kind = .function
            case "tag":      kind = .tag
            case "property": kind = .property
            case "punct":    kind = .punctuation
            case "link":     kind = .link
            case "marker":   kind = .listMarker
            case "item":     kind = .listItem
            case "term":     kind = .term
            case "struck":   kind = .struck
            case "underlined": kind = .underlined
            case "aligned":
                switch token.a {
                case "center":   kind = .aligned(.center)
                case "trailing": kind = .aligned(.trailing)
                default:         kind = .aligned(.leading)
                }
            case "embed":
                guard let language = token.a,
                      token.range.location + token.range.length <= ns.length
                else { continue }
                out += embeddedTokens(for: ns.substring(with: token.range),
                                      language: language,
                                      at: token.range.location)
                continue
            default: continue
            }
            out.append((token.range, kind))
        }
        return out
    }

    private func embeddedTokens(for code: String, language: String,
                                at offset: Int) -> [(range: NSRange, kind: EditorTokenKind)] {
        // Raw-block tags are whatever the author typed (`yml`, `sh`, `C++`) —
        // normalize to a canonical highlighter language first.
        guard let id = EditorLanguage.id(forTag: language) else { return [] }
        return SyntaxTokenizer.highlight(code, language: id).map {
            (NSRange(location: $0.0.location + offset, length: $0.0.length), $0.1)
        }
    }
}

// MARK: - Completions (tinymist)

/// Bridges the editor's completion seam to tinymist, the typst language
/// server. Instances are stateless — the shared client owns the server
/// process; when tinymist isn't installed, completions are simply absent.
final class TypstCompletionProvider: EditorCompletionProvider {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func completions(in text: String, at offset: Int) async -> [EditorCompletion] {
        await TinymistClient.shared
            .completions(fileURL: fileURL, text: text, offset: offset)
            .map {
                EditorCompletion(label: $0.label, detail: $0.detail,
                                 insertText: $0.insertText,
                                 replaceRange: $0.replaceRange)
            }
    }
}

// MARK: - Math renderer

/// Renders `$…$` equations for the prose editor's inline preview using typst's
/// native PNG renderer (2× for retina), which also reports the equation's
/// typographic baseline from the layout frame — the editor sits the image
/// exactly on the text baseline. Compiles run off the main actor; results and
/// failures are cached so the paint path is a dictionary lookup.
final class TypstMathRenderer: EditorMathRenderer {
    static let shared = TypstMathRenderer()

    private var rendered: [String: RenderedEquation] = [:]
    private var pending: Set<String> = []
    private var failed: Set<String> = []

    func renderedMath(for equation: String, fontSize: CGFloat, dark: Bool,
                      block: Bool,
                      completion: @escaping @MainActor () -> Void) -> RenderedEquation? {
        let key = "\(dark ? "dark" : "light")|\(block ? "b" : "i")|\(fontSize)|\(equation)"
        if let hit = rendered[key] { return hit }
        guard !failed.contains(key), !pending.contains(key) else { return nil }

        pending.insert(key)
        Task.detached(priority: .userInitiated) {
            let render = TypstEngine.renderMath(equation: equation,
                                                fontSize: fontSize, dark: dark,
                                                scale: 2, block: block)
            await MainActor.run {
                self.pending.remove(key)
                if let render, let image = NSImage(data: render.png) {
                    // The PNG is 2×; its point size and baseline come from the
                    // layout, in points.
                    image.size = NSSize(width: render.w, height: render.h)
                    if self.rendered.count > 256 {
                        self.rendered.removeAll(keepingCapacity: true)
                    }
                    self.rendered[key] = RenderedEquation(image: image,
                                                          baseline: render.b)
                    completion()
                } else {
                    // Mid-edit equations rarely parse; cache the failure so we
                    // don't recompile on every paint. Any edit changes the key.
                    self.failed.insert(key)
                }
            }
        }
        return nil
    }
}
