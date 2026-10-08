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
    /// Where in `selection` the cursor is.
    ///
    /// A range has no direction, but a selection does: one end is the anchor
    /// the reader dropped and the other is the end they are moving. Extending
    /// downward puts the moving end at the *far* side, so anything that reads
    /// `selection.location` and calls it the caret is naming the position the
    /// cursor has just left — which is a view that scrolls back to the top of
    /// the selection on every keystroke that grows it.
    public var caret: Int
    public var mode: EditMode

    /// `caret` defaults to the start of the selection, which is right for
    /// every outcome that leaves the cursor collapsed or sweeps backwards.
    public init(edit: (range: NSRange, replacement: String)? = nil,
                selection: NSRange, caret: Int? = nil, mode: EditMode) {
        self.edit = edit
        self.selection = selection
        self.caret = caret ?? selection.location
        self.mode = mode
    }

    public static func == (a: EditOutcome, b: EditOutcome) -> Bool {
        a.edit?.range == b.edit?.range && a.edit?.replacement == b.edit?.replacement
            && a.selection == b.selection && a.caret == b.caret && a.mode == b.mode
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

    // Code: shifting lines, commenting them out, and the bracket that closes
    // the one you are on.
    case indent, outdent, toggleComment, matchBracket
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

    /// One level of indentation — the view sets it from its style.
    public var indentUnit = "    "
    /// How this file comments a line, or nil where it can't be.
    public var commentSyntax: CommentSyntax?

    public init() {}

    /// Run a named command.
    ///
    /// The entry point the app uses. `handle(_ key:)` remains for the tests
    /// that still speak keys and goes with them.
    /// - Parameter visualLine: where the caret lands `n` *wrapped* lines from
    ///   an offset, when the caller has a laid-out view to ask. Vertical motion
    ///   is the one thing this engine cannot work out from text alone: with
    ///   wrapping on, the line under you is a line on screen, not a line in the
    ///   file, and `j` walking paragraphs is wrong by exactly the amount the
    ///   text wrapped. Nil falls back to source lines, which is right for a
    ///   view that does not wrap and for the tests.
    public func perform(_ command: EditCommand, count: Int, mode: EditMode,
                        text: String, selection: NSRange,
                        visualLine: ((Int, Int) -> Int?)? = nil) -> EditOutcome? {
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
        let outcome = select(command, from: selection, count: repeats, mode: mode,
                             in: ns, visualLine: visualLine)
            // `head` is the end the motion just moved, which `span` and
            // `reach` have since sorted out of the range.
            .map { EditOutcome(selection: $0, caret: head, mode: mode) }
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
                        mode: EditMode, in ns: NSString,
                        visualLine: ((Int, Int) -> Int?)? = nil) -> NSRange? {
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
            let delta = command == .down ? count : -count
            // What is on screen first, what is in the file second.
            return moved(to: visualLine?(head, delta)
                            ?? line(from: head, by: delta, in: ns))

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

        // The bracket that pairs with the one under the cursor, or with the
        // first one after it on the line. A jump, so it moves rather than
        // sweeps — and extends in select mode, which is how a block is taken.
        case .matchBracket:
            // No bracket to match is an answer too: stay where you are.
            guard let target = matchingBracket(from: head, in: ns) else { return selection }
            return moved(to: target)

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

        case .indent, .outdent, .toggleComment:
            // On whole lines: every line the selection touches.
            let lines = ns.lineRange(for: range)
            let block = ns.substring(with: lines)
            let changed: String?
            switch command {
            case .indent: changed = Self.shift(block, by: count, unit: indentUnit)
            case .outdent: changed = Self.shift(block, by: -count, unit: indentUnit)
            default: changed = commentSyntax.map { Self.toggleComment(block, syntax: $0) }
            }
            guard let changed, changed != block else {
                return EditOutcome(selection: range, mode: mode)
            }
            // The same lines stay selected, so a second `>` shifts them again.
            let after = NSRange(location: lines.location, length: (changed as NSString).length)
            anchor = after.location
            head = NSMaxRange(after)
            return EditOutcome(edit: (lines, changed), selection: after, mode: mode)

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
        guard let outcome = editing.perform(
            command, count: count, mode: mode,
            text: text ?? "", selection: textSelection,
            // Only where lines actually wrap: with wrapping off a line on
            // screen *is* a line in the file, and asking the layout would be
            // the same answer through more machinery.
            visualLine: lastAppliedStyleWraps ? { [weak self] offset, delta in
                self?.offset(from: offset, byVisualLines: delta)
            } : nil)
        else { return nil }
        apply(outcome)
        return outcome.mode
    }
}

// MARK: - Code

extension EditEngine {
    /// Lines moved `levels` indents right (or left, when negative). Blank lines
    /// stay blank, and a line can't go further left than its margin.
    static func shift(_ block: String, by levels: Int, unit: String) -> String {
        guard levels != 0 else { return block }
        return mapLines(block) { line in
            guard !line.allSatisfy(\.isWhitespace) else { return line }
            if levels > 0 { return String(repeating: unit, count: levels) + line }
            var rest = Substring(line)
            for _ in 0..<(-levels) {
                if rest.hasPrefix("\t") { rest = rest.dropFirst(); continue }
                // Spaces, up to a unit's worth — a line indented by less than a
                // unit comes out at the margin rather than staying put.
                let width = unit == "\t" ? 4 : unit.count
                let spaces = rest.prefix(width).prefix { $0 == " " }.count
                guard spaces > 0 else { break }
                rest = rest.dropFirst(spaces)
            }
            return String(rest)
        }
    }

    /// Lines commented out, or put back if every one of them already was.
    ///
    /// A line comment goes at the shallowest indent among the lines, so a
    /// commented block keeps its shape. Lines that are only whitespace are left
    /// alone either way, as an editor's own comment command leaves them.
    static func toggleComment(_ block: String, syntax: CommentSyntax) -> String {
        switch syntax {
        case .line(let marker):
            let filled = lines(of: block).filter { !$0.allSatisfy(\.isWhitespace) }
            guard !filled.isEmpty else { return block }
            let commented = filled.allSatisfy {
                $0.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(marker)
            }
            if commented {
                return mapLines(block) { line in
                    let indent = line.prefix { $0 == " " || $0 == "\t" }
                    var rest = line.dropFirst(indent.count)
                    guard rest.hasPrefix(marker) else { return line }
                    rest = rest.dropFirst(marker.count)
                    if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                    return String(indent) + rest
                }
            }
            let margin = filled.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            return mapLines(block) { line in
                guard !line.allSatisfy(\.isWhitespace) else { return line }
                return String(line.prefix(margin)) + marker + " " + String(line.dropFirst(margin))
            }
        case .block(let open, let close):
            // Around everything between the first and last character that
            // isn't whitespace, so the surrounding indent and newline stay.
            guard let first = block.firstIndex(where: { !$0.isWhitespace }),
                  let last = block.lastIndex(where: { !$0.isWhitespace }) else { return block }
            let inside = block[first...last]
            if inside.hasPrefix(open), inside.hasSuffix(close),
               inside.count >= open.count + close.count {
                var body = inside.dropFirst(open.count).dropLast(close.count)
                if body.hasPrefix(" ") { body = body.dropFirst() }
                if body.hasSuffix(" ") { body = body.dropLast() }
                return String(block[..<first]) + body + String(block[block.index(after: last)...])
            }
            return String(block[..<first]) + open + " " + inside + " " + close
                + String(block[block.index(after: last)...])
        }
    }

    /// The text split after each newline, so joining puts it back exactly.
    private static func lines(of block: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in block {
            if character == "\n" {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty || block.isEmpty { result.append(current) }
        return result
    }

    /// Each line of `block` transformed, newlines kept where they were.
    private static func mapLines(_ block: String, _ transform: (String) -> String) -> String {
        let endsWithNewline = block.hasSuffix("\n")
        var parts = block.components(separatedBy: "\n")
        if endsWithNewline { parts.removeLast() }
        return parts.map(transform).joined(separator: "\n") + (endsWithNewline ? "\n" : "")
    }

    static let openers: [unichar: unichar] = [40: 41, 91: 93, 123: 125]    // ( [ {
    static let closers: [unichar: unichar] = [41: 40, 93: 91, 125: 123]

    /// Where the bracket pairing with the one at `offset` is — or, when there
    /// is none at `offset`, with the first bracket after it on the same line.
    /// Nesting is counted; strings and comments are not told apart.
    func matchingBracket(from offset: Int, in ns: NSString) -> Int? {
        var position = offset
        let end = lineEnd(at: offset, in: ns)
        while position < end {
            let character = ns.character(at: position)
            if Self.openers[character] != nil || Self.closers[character] != nil { break }
            position += 1
        }
        guard position < ns.length else { return nil }
        let start = ns.character(at: position)
        if let close = Self.openers[start] {
            var depth = 0
            for index in position..<ns.length {
                let character = ns.character(at: index)
                if character == start { depth += 1 }
                if character == close { depth -= 1; if depth == 0 { return index } }
            }
        } else if let open = Self.closers[start] {
            var depth = 0
            for index in stride(from: position, through: 0, by: -1) {
                let character = ns.character(at: index)
                if character == start { depth += 1 }
                if character == open { depth -= 1; if depth == 0 { return index } }
            }
        }
        return nil
    }
}
