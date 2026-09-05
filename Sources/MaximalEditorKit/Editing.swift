import Foundation
import MaximalTreeKit

/// Modal editing over text and a selection.
///
/// Helix's order, not Vim's: you select a thing and then say what to do with
/// it, rather than naming a verb and leaving it hanging while you describe its
/// object. `wd` deletes a word — `w` selects one, `d` deletes what is
/// selected — where Vim would say `dw` and have to remember, between the two
/// keys, that a deletion was owed a range.
///
/// That inversion takes a whole mechanism out. There is no operator-pending
/// state here, because the selection *is* the pending state: it is on screen,
/// you can see what you are about to act on, and you can adjust it before
/// committing. Vim's `d` waiting silently for a motion — the thing that made
/// `dg` ambiguous and `dz` a decision — has nowhere to live.
///
/// Deliberately knows nothing about views: text, selection and a key in; the
/// text, selection and mode they become out. The rules are the hard part and
/// they are worth testing thousands of times a second without a window.
///
/// Offsets are UTF-16, because that is what the text views measure in.

/// The mode is the app's, not the editor's: `KeyMode` from the SDK, passed in
/// on every key and handed back with the outcome. `.visual` is Helix's select
/// mode, where motions extend the selection instead of replacing it.
public typealias EditMode = KeyMode

public struct EditKey: Equatable, Sendable {
    public let key: String
    public let control: Bool

    public init(_ key: String, control: Bool = false) {
        self.key = key
        self.control = control
    }
}

/// What the editor should do about a key.
public struct EditOutcome: Equatable, Sendable {
    /// Replace this range with `replacement` — nil means nothing was edited.
    public var edit: (range: NSRange, replacement: String)?
    /// What is selected afterwards. In a commanding mode this is what the next
    /// verb will act on, so it is never nothing; while inserting it is the
    /// caret, empty.
    public var selection: NSRange
    public var mode: EditMode

    public init(edit: (range: NSRange, replacement: String)? = nil,
                selection: NSRange, mode: EditMode) {
        self.edit = edit
        self.selection = selection
        self.mode = mode
    }

    public static func == (a: EditOutcome, b: EditOutcome) -> Bool {
        a.edit?.range == b.edit?.range && a.edit?.replacement == b.edit?.replacement
            && a.selection == b.selection && a.mode == b.mode
    }
}

@MainActor
/// What the editor can be asked to do.
///
/// Named, rather than a key. The engine used to be driven by key strings and
/// keep its own pending-sequence and count state to parse them — a second,
/// smaller copy of the modal layer that already existed one level up. A
/// surface declares which key runs which of these and the core does the rest.
public enum EditCommand: String, Sendable, CaseIterable {
    // Motions. Each selects what it crosses, which is the whole grammar: the
    // motion says what, the verb says what to do with it.
    case left, right, down, up
    case wordForward, wordBackward, wordEnd
    case lineStart, firstNonBlank, lineEnd
    case selectLine, selectAll
    case firstLine, lastLine, documentEnd, toLineStart, toLineEnd

    // Verbs, each on whatever is selected.
    case delete, change, yank, pasteAfter, pasteBefore
    case insertBefore, insertAfter, insertAtLineStart, insertAtLineEnd
    case openBelow, openAbove
    case extendSelection, collapseSelection
}

public final class EditEngine {
    /// The last thing deleted or yanked, and whether it was whole lines.
    private var register: (text: String, linewise: Bool)?
    /// Where the selection is fixed, and where it moves.
    ///
    /// An NSRange has no direction, so it cannot say which end a motion should
    /// carry on from: `w` twice would restart from the beginning of the word it
    /// had just selected. Helix's model is an anchor and a head, so keep both
    /// and hand out the range they span.
    private var anchor = 0
    private var head = 0
    /// The selection this engine last produced, to tell its own work from a
    /// selection made elsewhere — a click, a find — which resets both ends.
    private var emitted: NSRange?
    /// The mode the last key arrived in, so a change made anywhere else —
    /// escape, a command, focus arriving — abandons a half-typed motion rather
    /// than letting it finish under rules it was never begun under.
    private var lastMode: EditMode = .normal

    public init() {}

    /// Run a named command.
    ///
    /// The entry point the app uses. `handle(_ key:)` remains for the tests
    /// that still speak keys and goes with them.
    public func perform(_ command: EditCommand, count: Int, mode: EditMode,
                        text: String, selection: NSRange) -> EditOutcome? {
        lastMode = mode
        // Not ours: someone clicked, or searched. Both ends start again from
        // what they left.
        if emitted != selection {
            anchor = selection.location
            head = selection.location
        }
        // Nothing is a command while you are typing. The core does not
        // dispatch in insert mode, but an action can be run from a list, and
        // "Delete" from the finder mid-word would be a surprise.
        guard mode != .insert else { return nil }
        let ns = text as NSString
        let repeats = max(count, 1)
        let outcome = select(command, from: selection, count: repeats, mode: mode, in: ns)
            .map { EditOutcome(selection: $0, mode: mode) }
            ?? act(command, mode: mode, selection: selection, count: repeats, in: ns)
        guard let outcome else { return nil }
        lastMode = outcome.mode
        emitted = outcome.selection
        return outcome
    }

    // MARK: Selecting

    /// What a motion selects.
    ///
    /// In select mode the anchor stays put and the motion moves the far end,
    /// so a selection can be grown a piece at a time. Otherwise each motion
    /// starts a new selection, which is what keeps a bare cursor from
    /// dragging everything it passes along with it.
    private func select(_ command: EditCommand, from selection: NSRange, count: Int,
                        mode: EditMode, in ns: NSString) -> NSRange? {
        let extending = mode == .visual
        // A plain move carries the cursor; a sweep drags a selection behind
        // it. Either way the motion starts from the head, which is what makes
        // `ww` reach the second word rather than reselecting the first.
        func moved(to target: Int) -> NSRange {
            head = target
            if !extending { anchor = target }
            return extending ? span(anchor, head, in: ns) : cursor(at: target, in: ns)
        }
        func swept(to target: Int) -> NSRange {
            let start = extending ? anchor : head
            head = target
            anchor = start
            return reach(from: start, to: target, in: ns)
        }

        switch command {
        case .left:
            return moved(to: max(head - count, lineStart(at: head, in: ns)))
        case .right:
            return moved(to: min(head + count, max(lineEnd(at: head, in: ns) - 1, head)))
        case .down, .up:
            return moved(to: line(from: head, by: command == .down ? count : -count, in: ns))

        // Words. The selection covers what was crossed, which is the whole
        // point: `w` then `d` deletes the word you can see is selected.
        case .wordForward:
            var target = head
            for _ in 0..<count { target = wordForward(from: target, in: ns) }
            return swept(to: target)
        case .wordBackward:
            var target = head
            for _ in 0..<count { target = wordBackward(from: target, in: ns) }
            return swept(to: target)
        case .wordEnd:
            var target = head
            for _ in 0..<count { target = wordEnd(from: target, in: ns) }
            return swept(to: min(target + 1, ns.length))

        // Line pieces.
        case .lineStart:
            return swept(to: lineStart(at: head, in: ns))
        case .firstNonBlank:
            return swept(to: firstNonBlank(ofLineAt: head, in: ns))
        case .lineEnd:
            return swept(to: lineEnd(at: head, in: ns))

        // Whole lines. Helix's `x`, which selects rather than deletes — the
        // deleting is `d`'s job, on whatever happens to be selected.
        case .selectLine:
            var range = ns.lineRange(for: selection.length > 0 ? selection
                                        : NSRange(location: selection.location, length: 0))
            for _ in 1..<max(count, 1) {
                guard NSMaxRange(range) < ns.length else { break }
                let next = ns.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
                range = NSRange(location: range.location,
                                length: NSMaxRange(next) - range.location)
            }
            anchor = range.location
            head = NSMaxRange(range)
            return range

        case .selectAll:
            anchor = 0
            head = ns.length
            return NSRange(location: 0, length: ns.length)

        // The gotos move rather than sweep. A word motion selects what it
        // crosses — that is the grammar, and what makes `w d` delete the word
        // you can see — but a jump to the top of the file is not crossing
        // anything you meant to select, and `g g` selecting everything above
        // you is a surprise every time. In visual mode `moved` extends, so
        // growing a selection to the ends still works.
        case .firstLine:
            return moved(to: count > 1 ? offset(ofLine: count - 1, in: ns) : 0)
        case .documentEnd:
            return moved(to: ns.length)
        case .toLineStart:
            return moved(to: lineStart(at: head, in: ns))
        case .toLineEnd:
            return moved(to: lineEnd(at: head, in: ns))
        case .lastLine:
            return moved(to: count > 1 ? offset(ofLine: count - 1, in: ns)
                                       : lastLineStart(in: ns))

        default:
            return nil
        }
    }

    // MARK: Acting on what is selected

    /// The verbs. Every one of them works on the selection it is handed and
    /// none of them waits for anything.
    private func act(_ command: EditCommand, mode: EditMode, selection: NSRange,
                     count: Int, in ns: NSString) -> EditOutcome? {
        let range = clamp(selection, in: ns)

        switch command {
        case .delete:
            remember(ns.substring(with: range))
            anchor = range.location
            head = range.location
            return EditOutcome(edit: (range, ""),
                               selection: cursor(at: range.location, in: ns), mode: .normal)
        case .change:
            remember(ns.substring(with: range))
            return EditOutcome(edit: (range, ""),
                               selection: NSRange(location: range.location, length: 0),
                               mode: .insert)
        case .yank:
            remember(ns.substring(with: range))
            return EditOutcome(selection: range, mode: .normal)

        // Insert, at one end of the selection or the other.
        case .insertBefore:
            return EditOutcome(selection: NSRange(location: range.location, length: 0),
                               mode: .insert)
        case .insertAfter:
            return EditOutcome(selection: NSRange(location: NSMaxRange(range), length: 0),
                               mode: .insert)
        case .insertAtLineStart:
            return EditOutcome(
                selection: NSRange(location: firstNonBlank(ofLineAt: range.location, in: ns),
                                   length: 0), mode: .insert)
        case .insertAtLineEnd:
            return EditOutcome(
                selection: NSRange(location: lineEnd(at: range.location, in: ns), length: 0),
                mode: .insert)

        case .openBelow, .openAbove:
            let below = command == .openBelow
            let at = below ? lineEnd(at: range.location, in: ns)
                           : lineStart(at: range.location, in: ns)
            let indent = leadingWhitespace(ofLineAt: range.location, in: ns)
            let inserted = below ? "\n" + indent : indent + "\n"
            let caret = below ? at + 1 + indent.count : at + indent.count
            return EditOutcome(edit: (NSRange(location: at, length: 0), inserted),
                               selection: NSRange(location: caret, length: 0), mode: .insert)

        case .pasteAfter, .pasteBefore:
            guard let register else { return EditOutcome(selection: range, mode: mode) }
            if register.linewise {
                // Whole lines land between lines, never inside one — so paste
                // at a line boundary and let the text carry its own newline.
                // Adding one on top of the newline the register already ends
                // with is where the blank line after every linewise paste came
                // from.
                let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
                let at = command == .pasteAfter ? NSMaxRange(line) : line.location
                var payload = register.text
                if !payload.hasSuffix("\n") { payload += "\n" }
                // Pasting after a last line that ends without one: the document
                // has no boundary there yet, so make one.
                if at == ns.length, at > 0, ns.character(at: at - 1) != 10 {
                    payload = "\n" + payload
                }
                return EditOutcome(edit: (NSRange(location: at, length: 0), payload),
                                   selection: cursor(at: at, in: ns), mode: .normal)
            }
            // Over the selection for `p`, which is Helix's replace-with-yank.
            let at = command == .pasteAfter ? NSMaxRange(range) : range.location
            return EditOutcome(edit: (NSRange(location: at, length: 0), register.text),
                               selection: NSRange(location: at,
                                                  length: (register.text as NSString).length),
                               mode: .normal)

        case .extendSelection:
            // Toggle extending. The anchor stays where the selection begins,
            // so the next motion grows from here.
            if mode == .visual { return EditOutcome(selection: range, mode: .normal) }
            anchor = range.location
            head = NSMaxRange(range)
            return EditOutcome(selection: range, mode: .visual)

        case .collapseSelection:
            // Collapse to a bare cursor, keeping where you are.
            anchor = range.location
            head = range.location
            return EditOutcome(selection: cursor(at: range.location, in: ns), mode: mode)

        default:
            return nil
        }
    }

    // MARK: Ranges

    /// A bare cursor: one character wide where there is one, so that something
    /// is always selected and every verb has something to work on.
    private func cursor(at offset: Int, in ns: NSString) -> NSRange {
        let start = min(max(offset, 0), ns.length)
        return NSRange(location: start, length: start < ns.length ? 1 : 0)
    }

    /// From here to there, whichever way round they are, at least one wide.
    private func reach(from: Int, to: Int, in ns: NSString) -> NSRange {
        let start = min(from, to), end = max(from, to)
        guard end > start else { return cursor(at: start, in: ns) }
        return NSRange(location: start, length: min(end - start, ns.length - start))
    }

    /// The same, but always covering both ends — what extending wants, so the
    /// character under the anchor stays in.
    private func span(_ from: Int, _ to: Int, in ns: NSString) -> NSRange {
        let start = min(from, to), end = max(from, to)
        return NSRange(location: start, length: min(end - start + 1, ns.length - start))
    }

    private func clamp(_ range: NSRange, in ns: NSString) -> NSRange {
        let start = min(max(range.location, 0), ns.length)
        return NSRange(location: start, length: min(range.length, ns.length - start))
    }

    /// What `p` will paste, and whether it pastes as whole lines.
    ///
    /// One rule for all three verbs that fill it. Delete used to record
    /// "never linewise" while yank worked it out from the text, so `x d p`
    /// put the line back in the middle of another one and `x y p` did not —
    /// the same selection, the same paste, two answers.
    private func remember(_ text: String) {
        register = (text, text.hasSuffix("\n"))
    }
}

extension MaximalEditor.EditorTextView {
    /// Run a named command against this editor.
    ///
    /// The whole of what an action needs: the engine works out what the
    /// command selects or changes, and this applies it.
    /// - Returns: the mode the command left behind — `i`, `o` and a visual
    ///   `c` all answer `.insert` — or nil when it did nothing.
    @discardableResult
    func run(_ command: EditCommand, count: Int, mode: KeyMode) -> KeyMode? {
        guard modalEditing else { return nil }
        guard let outcome = editing.perform(command, count: count, mode: mode,
                                            text: text ?? "", selection: textSelection)
        else { return nil }
        apply(outcome)
        return outcome.mode
    }
}

