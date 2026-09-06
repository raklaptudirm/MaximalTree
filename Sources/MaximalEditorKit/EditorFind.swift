import SwiftUI
import AppKit

/// Finding text in the document you are editing.
///
/// The search text lives out here rather than in the bar's own state, for the
/// same reason the web page's does: it outlives the view — you search, you
/// scroll, you come back — and `n` has to be able to reach it from an action,
/// which cannot see a view's `@State`.
///
/// One query for the app rather than one per document, which is what `/` then
/// `n` means everywhere else: the last thing you looked for is the thing you
/// keep looking for, whichever document you are in.
@MainActor
@Observable
public final class EditorFind {
    public static let shared = EditorFind()

    public var query = ""
    /// Whether the bar is up. Set by the action, cleared by escape.
    public var isActive = false
    /// The last search found nothing — worth saying, since the alternative is
    /// a keypress that appears to do nothing at all.
    public private(set) var foundNothing = false

    private init() {}

    public func open() {
        isActive = true
        foundNothing = false
    }

    public func close() {
        isActive = false
        foundNothing = false
    }

    /// Move to the next match, wrapping. Nothing to find is not a failure.
    public func step(forward: Bool) {
        guard !query.isEmpty, let editor = EditorKeys.focused else { return }
        let text = editor.text ?? ""
        // Forward starts one past the caret so `n` advances rather than
        // finding the match it is already sitting on.
        let from = forward ? editor.textSelection.location + 1
                           : editor.textSelection.location
        guard let hit = EditorSearch.match(for: query, in: text,
                                           from: from, forward: forward) else {
            foundNothing = true
            return
        }
        foundNothing = false
        editor.moveCaret(to: hit)
    }
}

/// Where the next match is. Pure, so the wrapping and the direction can be
/// checked without a window.
public enum EditorSearch {
    /// The next match from `from`, wrapping through the end of the document.
    ///
    /// Case-insensitive, which is what a reader means by "find" until they say
    /// otherwise — and the search that finds too much is recoverable where the
    /// one that finds nothing looks broken.
    public static func match(for needle: String, in text: String,
                             from: Int, forward: Bool) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        let ns = text as NSString
        guard ns.length > 0 else { return nil }
        let start = min(max(from, 0), ns.length)
        let whole = NSRange(location: 0, length: ns.length)

        let options: NSString.CompareOptions =
            forward ? [.caseInsensitive] : [.caseInsensitive, .backwards]
        let ahead = forward ? NSRange(location: start, length: ns.length - start)
                            : NSRange(location: 0, length: start)
        let hit = ns.range(of: needle, options: options, range: ahead)
        if hit.location != NSNotFound { return hit }
        // Round the end and carry on from the other side.
        let wrapped = ns.range(of: needle, options: options, range: whole)
        return wrapped.location == NSNotFound ? nil : wrapped
    }
}

/// The find bar, above the text it searches.
///
/// A bar rather than a panel in the inspector: finding is something you do
/// *while* reading a line, and an answer that lives across the window is one
/// you have to look away to read. Sits where the external-change banner sits,
/// which is the same argument.
public struct EditorFindBar: View {
    @State private var find = EditorFind.shared
    @FocusState private var focused: Bool

    public init() {}

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $find.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { find.step(forward: true) }
            if find.foundNothing {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button { find.step(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Previous match")
            Button { find.step(forward: true) } label: { Image(systemName: "chevron.down") }
                .help("Next match")
            Button { find.close() } label: { Image(systemName: "xmark") }
                .help("Close")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focused = true }
    }
}
