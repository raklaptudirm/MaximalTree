import SwiftUI
import AppKit
import STTextView

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
