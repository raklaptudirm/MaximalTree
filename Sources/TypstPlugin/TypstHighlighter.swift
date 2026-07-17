import Foundation
import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import CodeEditLanguages

/// Regex-based highlight provider for Typst markup, standing in until a real
/// grammar (tree-sitter or tinymist semantic tokens) is available. Tokenization
/// lives in `TypstSyntax` (Foundation-only, tested); this class just adapts it to
/// CodeEditSourceEditor's `HighlightProviding`.
final class TypstHighlighter: HighlightProviding {
    @MainActor func setUp(textView: TextView, codeLanguage: CodeLanguage) {}

    @MainActor func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        // Regex passes over note/document-sized text are cheap; invalidating the
        // whole document keeps multi-line constructs (raw blocks, block comments)
        // correct without incremental bookkeeping.
        let length = (textView.string as NSString).length
        completion(.success(IndexSet(integersIn: 0..<max(length, 1))))
    }

    @MainActor func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        // Tokenize the full document and filter: line-anchored and multi-line
        // patterns would misfire on a substring that cuts through a line or block.
        let tokens = TypstSyntax.tokens(in: textView.string)
        let highlights = tokens.compactMap { token -> HighlightRange? in
            guard NSIntersectionRange(token.range, range).length > 0 else { return nil }
            return HighlightRange(range: token.range, capture: Self.capture(for: token.kind))
        }
        completion(.success(highlights))
    }

    private static func capture(for kind: TypstSyntax.TokenKind) -> CaptureName {
        switch kind {
        case .comment:   return .comment
        case .raw:       return .string
        case .math:      return .number
        case .heading:   return .keyword      // bold + tinted in both themes
        case .strong:    return .type
        case .emphasis:  return .variable
        case .call:      return .function
        case .label:     return .tag
        case .reference: return .property
        }
    }
}
