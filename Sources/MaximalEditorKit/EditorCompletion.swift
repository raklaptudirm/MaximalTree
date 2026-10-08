import SwiftUI
import AppKit
import STTextView
import MaximalTreeKit

// The completion seam: providers (typically language-server-backed) feed the
// engine's built-in completion window; the coordinator triggers it while
// typing inside completable contexts.

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
    /// Where the window opens without being asked for — see
    /// `EditorCompletionTrigger`. A sigil (`#`, `@`) unless a provider says.
    var trigger: EditorCompletionTrigger { get }
}

public extension EditorCompletionProvider {
    var trigger: EditorCompletionTrigger { .sigils(["#", "@"]) }
}

/// Where completions are offered while typing, before anyone asks.
public enum EditorCompletionTrigger: Sendable {
    /// In a run of identifier characters that one of these introduced —
    /// typst's `#` and `@`, which are where code starts inside prose.
    case sigils(Set<Character>)
    /// After a `.`, or two characters into a word: what a code editor offers.
    case code

    /// Whether the caret at `offset` is somewhere this fires.
    public func fires(at offset: Int, in text: NSString) -> Bool {
        func identifier(_ character: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(character) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        switch self {
        case .sigils(let sigils):
            var index = offset
            while index > 0 {
                guard let scalar = Unicode.Scalar(text.character(at: index - 1)) else { return false }
                if CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "_" || scalar == "-" || scalar == "." {
                    index -= 1
                    continue
                }
                return sigils.contains(Character(scalar))
            }
            return false
        case .code:
            guard offset > 0 else { return false }
            if text.character(at: offset - 1) == 46 { return true }      // .
            var start = offset
            while start > 0, identifier(text.character(at: start - 1)) { start -= 1 }
            // Not a number, and long enough to have meant something.
            guard offset - start >= 2,
                  let first = Unicode.Scalar(text.character(at: start)),
                  !CharacterSet.decimalDigits.contains(first) else { return false }
            return true
        }
    }
}

/// The completion window fed by a `LanguageService` — a language server, or
/// anything else a plugin registered for the file's language.
public final class LanguageServiceCompletions: EditorCompletionProvider {
    private let service: LanguageService
    private let url: URL
    public let trigger: EditorCompletionTrigger

    public init(service: LanguageService, url: URL, trigger: EditorCompletionTrigger = .code) {
        self.service = service
        self.url = url
        self.trigger = trigger
    }

    public func completions(in text: String, at offset: Int) async -> [EditorCompletion] {
        await service.completions(in: CodeDocument(url: url, text: text), at: offset).map {
            EditorCompletion(label: $0.label, detail: $0.detail,
                             insertText: $0.insertText, replaceRange: $0.replaceRange)
        }
    }
}

// MARK: - Completion list items

/// Adapts an `EditorCompletion` to the engine's completion window: a plain
/// label row (mono) with the detail dimmed after it. The protocol is
/// nonisolated but the engine only asks for `view` on the main actor.
final class CompletionListItem: STCompletionItem {
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
