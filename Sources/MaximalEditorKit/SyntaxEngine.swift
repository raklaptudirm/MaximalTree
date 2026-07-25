import Foundation
import JavaScriptCore

/// highlight.js, run directly.
///
/// We drive the bundled JS ourselves rather than through a wrapper because the
/// wrappers hand back an already-*coloured* attributed string, throwing away the
/// part we actually want: highlight.js's **semantic class names**. Keeping them
/// means code maps onto `EditorTokenKind` like every other tokenizer, so the
/// editor's palette themes source and typst markup consistently, appearance
/// changes repaint without re-tokenizing, and each snippet is highlighted once
/// instead of once per appearance.
@MainActor
enum SyntaxEngine {
    /// One JS context for the process. Built lazily (~100ms: engine + grammars).
    private static let context: JSContext? = {
        guard let context = JSContext(),
              let url = Bundle(for: BundleMarker.self)
                  .url(forResource: "highlight.min", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        context.exceptionHandler = { _, value in
            NSLog("[MaximalEditorKit] highlight.js: \(value?.toString() ?? "unknown error")")
        }
        context.evaluateScript(source)
        return context
    }()

    /// Languages the bundled grammars actually cover.
    static let supportedLanguages: Set<String> = {
        guard let list = context?.objectForKeyedSubscript("hljs")?
            .invokeMethod("listLanguages", withArguments: [])?.toArray() as? [String]
        else { return [] }
        return Set(list)
    }()

    static func warmUp() {
        _ = context
        _ = supportedLanguages
    }

    /// Highlight `code` as `language`, returning semantic runs over the *original*
    /// text. Empty when the language is unknown or anything looks off — never a
    /// guess (highlight.js falls back to auto-detection when asked for a language
    /// it doesn't have, which paints confident nonsense).
    static func runs(for code: String, language: String) -> [(NSRange, String)] {
        guard supportedLanguages.contains(language),
              let hljs = context?.objectForKeyedSubscript("hljs"),
              let result = hljs.invokeMethod("highlight",
                                             withArguments: [language, code, true]),
              !result.isUndefined,
              let html = result.objectForKeyedSubscript("value")?.toString()
        else { return [] }
        return parse(html: html, matching: code)
    }

    // MARK: HTML → runs

    /// Walk highlight.js's output — nested `<span class="hljs-…">` plus escaped
    /// entities, nothing else — into (range, class) runs against the decoded
    /// text. The decoded text must reproduce the input exactly; if it doesn't,
    /// something changed upstream and we'd rather paint nothing than paint at
    /// the wrong offsets.
    static func parse(html: String, matching code: String) -> [(NSRange, String)] {
        var runs: [(NSRange, String)] = []
        var classes: [String] = []          // open <span> stack
        var decoded = ""
        decoded.reserveCapacity(code.count)
        var utf16Length = 0                 // NSRange coordinates

        var index = html.startIndex
        while index < html.endIndex {
            let character = html[index]
            switch character {
            case "<":
                if html[index...].hasPrefix("</span>") {
                    if !classes.isEmpty { classes.removeLast() }
                    index = html.index(index, offsetBy: 7)
                } else if html[index...].hasPrefix("<span class=\"") {
                    let start = html.index(index, offsetBy: 13)
                    guard let quote = html[start...].firstIndex(of: "\"") else {
                        return []           // malformed: bail rather than guess
                    }
                    classes.append(String(html[start..<quote]))
                    guard let close = html[quote...].firstIndex(of: ">") else { return [] }
                    index = html.index(after: close)
                } else {
                    return []               // an element we don't know: bail
                }
            case "&":
                guard let semicolon = html[index...].firstIndex(of: ";"),
                      let entity = Self.entities[String(html[index...semicolon])]
                else { return [] }
                append(entity, to: &decoded, length: &utf16Length,
                       classes: classes, runs: &runs)
                index = html.index(after: semicolon)
            default:
                // Take the whole plain stretch up to the next markup character.
                let next = html[index...].firstIndex { $0 == "<" || $0 == "&" } ?? html.endIndex
                append(String(html[index..<next]), to: &decoded, length: &utf16Length,
                       classes: classes, runs: &runs)
                index = next
            }
        }

        guard decoded == code else { return [] }
        return runs
    }

    /// Emit `text` under the innermost class that maps to something, merging
    /// with the previous run when it carries the same class.
    private static func append(_ text: String, to decoded: inout String,
                               length: inout Int, classes: [String],
                               runs: inout [(NSRange, String)]) {
        guard !text.isEmpty else { return }
        decoded += text
        let utf16Count = text.utf16.count
        defer { length += utf16Count }

        // Innermost first: `<span class="hljs-title function_">` inside a
        // `hljs-function` wrapper should read as a function title.
        guard let name = classes.reversed().first(where: { !$0.isEmpty }) else { return }
        if var last = runs.last, last.1 == name,
           last.0.location + last.0.length == length {
            last.0.length += utf16Count
            runs[runs.count - 1] = last
        } else {
            runs.append((NSRange(location: length, length: utf16Count), name))
        }
    }

    /// highlight.js escapes exactly these.
    private static let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">",
        "&quot;": "\"", "&#x27;": "'", "&#39;": "'",
    ]
}

/// Anchors `Bundle(for:)` on this framework — an Xcode framework target has no
/// generated `Bundle.module`.
private final class BundleMarker {}
