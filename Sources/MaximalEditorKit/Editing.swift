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
public final class EditEngine {
    /// Digits typed before a motion — `3w` selects across three words.
    private var count: Int?
    /// Keys towards a motion that needs a second, which is only `g`.
    private(set) var pending: [EditKey] = []
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

    /// Feed a key in the mode it arrived in. Returns nil when the key isn't
    /// ours — in insert mode that is everything, which is how typing stays
    /// typing.
    public func handle(_ key: EditKey, mode: EditMode, text: String,
                       selection: NSRange) -> EditOutcome? {
        if mode != lastMode {
            reset()
            lastMode = mode
        }
        // Not ours: someone clicked, or searched. Both ends start again from
        // what they left.
        if emitted != selection {
            anchor = selection.location
            head = selection.location
        }
        guard let outcome = compute(key, mode: mode, text: text, selection: selection)
        else { return nil }
        lastMode = outcome.mode
        emitted = outcome.selection
        return outcome
    }

    private func compute(_ key: EditKey, mode: EditMode, text: String,
                         selection: NSRange) -> EditOutcome? {
        let ns = text as NSString

        if key.key == "ESC" {
            reset()
            // Back to a bare cursor where the selection was.
            return EditOutcome(selection: cursor(at: selection.location, in: ns), mode: .normal)
        }
        guard mode != .insert else { return nil }
        // A control chord is a different key from the letter in it, and this
        // engine binds none of them.
        guard !key.control else { return nil }

        // Counts. `0` is a motion unless a count is already running.
        if pending.isEmpty, let digit = Int(key.key), key.key.count == 1,
           digit > 0 || count != nil {
            count = (count ?? 0) * 10 + digit
            return EditOutcome(selection: selection, mode: mode)
        }

        let sequence = pending + [key]
        let repeats = count ?? 1
        defer { if pending.isEmpty { count = nil } }

        // `g` is the one motion that needs a second key.
        if sequence.count == 1, key.key == "g" {
            pending = sequence
            return EditOutcome(selection: selection, mode: mode)
        }

        if let range = select(sequence, from: selection, count: repeats, mode: mode, in: ns) {
            pending = []
            return EditOutcome(selection: range, mode: mode)
        }
        pending = []
        return act(key, mode: mode, selection: selection, count: repeats, in: ns)
    }

    // MARK: Selecting

    /// What a motion selects.
    ///
    /// In select mode the anchor stays put and the motion moves the far end,
    /// so a selection can be grown a piece at a time. Otherwise each motion
    /// starts a new selection, which is what keeps a bare cursor from
    /// dragging everything it passes along with it.
    private func select(_ sequence: [EditKey], from selection: NSRange, count: Int,
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

        switch sequence.map(\.key) {
        case ["h"]:
            return moved(to: max(head - count, lineStart(at: head, in: ns)))
        case ["l"]:
            return moved(to: min(head + count, max(lineEnd(at: head, in: ns) - 1, head)))
        case ["j"], ["k"]:
            return moved(to: line(from: head, by: sequence[0].key == "j" ? count : -count,
                                  in: ns))

        // Words. The selection covers what was crossed, which is the whole
        // point: `w` then `d` deletes the word you can see is selected.
        case ["w"]:
            var target = head
            for _ in 0..<count { target = wordForward(from: target, in: ns) }
            return swept(to: target)
        case ["b"]:
            var target = head
            for _ in 0..<count { target = wordBackward(from: target, in: ns) }
            return swept(to: target)
        case ["e"]:
            var target = head
            for _ in 0..<count { target = wordEnd(from: target, in: ns) }
            return swept(to: min(target + 1, ns.length))

        // Line pieces.
        case ["0"]:
            return swept(to: lineStart(at: head, in: ns))
        case ["^"]:
            return swept(to: firstNonBlank(ofLineAt: head, in: ns))
        case ["$"]:
            return swept(to: lineEnd(at: head, in: ns))

        // Whole lines. Helix's `x`, which selects rather than deletes — the
        // deleting is `d`'s job, on whatever happens to be selected.
        case ["x"]:
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

        case ["%"]:
            anchor = 0
            head = ns.length
            return NSRange(location: 0, length: ns.length)

        case ["g", "g"]:
            return swept(to: count > 1 ? offset(ofLine: count - 1, in: ns) : 0)
        case ["g", "e"]:
            return swept(to: lastLineStart(in: ns))
        case ["g", "h"]:
            return swept(to: lineStart(at: head, in: ns))
        case ["g", "l"]:
            return swept(to: lineEnd(at: head, in: ns))
        case ["G"]:
            return swept(to: count > 1 ? offset(ofLine: count - 1, in: ns)
                                       : lastLineStart(in: ns))

        default:
            return nil
        }
    }

    // MARK: Acting on what is selected

    /// The verbs. Every one of them works on the selection it is handed and
    /// none of them waits for anything.
    private func act(_ key: EditKey, mode: EditMode, selection: NSRange,
                     count: Int, in ns: NSString) -> EditOutcome? {
        let range = clamp(selection, in: ns)

        switch key.key {
        case "d":
            register = (ns.substring(with: range), false)
            anchor = range.location
            head = range.location
            return EditOutcome(edit: (range, ""),
                               selection: cursor(at: range.location, in: ns), mode: .normal)
        case "c":
            register = (ns.substring(with: range), false)
            return EditOutcome(edit: (range, ""),
                               selection: NSRange(location: range.location, length: 0),
                               mode: .insert)
        case "y":
            register = (ns.substring(with: range), range.length > 0
                        && ns.substring(with: range).hasSuffix("\n"))
            return EditOutcome(selection: range, mode: .normal)

        // Insert, at one end of the selection or the other.
        case "i":
            return EditOutcome(selection: NSRange(location: range.location, length: 0),
                               mode: .insert)
        case "a":
            return EditOutcome(selection: NSRange(location: NSMaxRange(range), length: 0),
                               mode: .insert)
        case "I":
            return EditOutcome(
                selection: NSRange(location: firstNonBlank(ofLineAt: range.location, in: ns),
                                   length: 0), mode: .insert)
        case "A":
            return EditOutcome(
                selection: NSRange(location: lineEnd(at: range.location, in: ns), length: 0),
                mode: .insert)

        case "o", "O":
            let below = key.key == "o"
            let at = below ? lineEnd(at: range.location, in: ns)
                           : lineStart(at: range.location, in: ns)
            let indent = leadingWhitespace(ofLineAt: range.location, in: ns)
            let inserted = below ? "\n" + indent : indent + "\n"
            let caret = below ? at + 1 + indent.count : at + indent.count
            return EditOutcome(edit: (NSRange(location: at, length: 0), inserted),
                               selection: NSRange(location: caret, length: 0), mode: .insert)

        case "p", "P":
            guard let register else { return EditOutcome(selection: range, mode: mode) }
            if register.linewise {
                let at = key.key == "p" ? lineEnd(at: range.location, in: ns)
                                        : lineStart(at: range.location, in: ns)
                let payload = key.key == "p" ? "\n" + register.text : register.text + "\n"
                return EditOutcome(edit: (NSRange(location: at, length: 0), payload),
                                   selection: cursor(at: key.key == "p" ? at + 1 : at, in: ns),
                                   mode: .normal)
            }
            // Over the selection for `p`, which is Helix's replace-with-yank.
            let at = key.key == "p" ? NSMaxRange(range) : range.location
            return EditOutcome(edit: (NSRange(location: at, length: 0), register.text),
                               selection: NSRange(location: at,
                                                  length: (register.text as NSString).length),
                               mode: .normal)

        case "v":
            // Toggle extending. The anchor stays where the selection begins,
            // so the next motion grows from here.
            if mode == .visual { return EditOutcome(selection: range, mode: .normal) }
            anchor = range.location
            head = NSMaxRange(range)
            return EditOutcome(selection: range, mode: .visual)

        case ";":
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

    private func reset() {
        pending = []
        count = nil
    }
}

extension MaximalEditor.EditorTextView: CanvasKeyHandling {
    /// The keys this editor takes, so which-key can say so.
    ///
    /// Written out rather than derived: `EditEngine` decides by pattern-match
    /// over key sequences, and a switch cannot be asked what it matches. The
    /// list is beside the switch it describes, and a test walks it to check
    /// the engine really answers to every key claimed here — which is the part
    /// that would otherwise drift.
    public nonisolated var keyBindings: [CanvasKeyBinding] {
        guard modalEditing else { return [] }
        return Self.modalBindings
    }

    /// Helix's grammar: a motion selects, a verb acts on the selection.
    static let modalBindings: [CanvasKeyBinding] = [
        // Moving, which is also selecting.
        .init("h", title: "Left"),
        .init("l", title: "Right"),
        .init("j", title: "Down"),
        .init("k", title: "Up"),
        .init("w", title: "Next word"),
        .init("b", title: "Previous word"),
        .init("e", title: "End of word"),
        .init("0", title: "Line start"),
        .init("^", title: "First non-blank"),
        .init("$", title: "Line end"),
        .init("x", title: "Select line"),
        .init("%", title: "Select all"),
        .init("G", title: "Last line"),
        .init("g g", title: "First line"),
        .init("g e", title: "Last line"),
        .init("g h", title: "Line start"),
        .init("g l", title: "Line end"),

        // Acting on what is selected.
        .init("d", title: "Delete"),
        .init("c", title: "Change"),
        .init("y", title: "Yank"),
        .init("p", title: "Paste after"),
        .init("P", title: "Paste before"),
        .init("i", title: "Insert before"),
        .init("a", title: "Insert after"),
        .init("I", title: "Insert at line start"),
        .init("A", title: "Insert at line end"),
        .init("o", title: "Open line below"),
        .init("O", title: "Open line above"),
        .init("v", title: "Extend selection"),
        .init(";", title: "Collapse selection"),
    ]

    /// The editor's share of the commanding modes: selections and the verbs
    /// that act on them. What it doesn't understand goes back to the app,
    /// which is how the leader and every global binding keep working with the
    /// caret in a document.
    public func handleKey(_ key: String, control: Bool, mode: KeyMode) -> KeyMode? {
        guard modalEditing else { return nil }
        guard let outcome = editing.handle(EditKey(key, control: control), mode: mode,
                                           text: text ?? "", selection: textSelection)
        else {
            // Nothing to do with it — but a bare character must not fall
            // through and be *typed*: in a commanding mode the app decides,
            // and if the app has no binding either, nothing happens.
            return nil
        }
        apply(outcome)
        return outcome.mode
    }
}
