import Foundation
import MaximalTreeKit

/// Modal editing over text and a caret.
///
/// Deliberately knows nothing about views: it takes the text, where the caret
/// is, and a key, and says what the text and caret should become. Everything
/// hard about Vim is in the *rules* — what `d` does when followed by `w`,
/// where `e` lands on punctuation, whether `dd` on the last line leaves a
/// trailing newline — and rules are worth being able to test a thousand times
/// a second without a window on screen.
///
/// Offsets are UTF-16, because that is what the text views measure in.

/// The mode is the app's, not the editor's: `KeyMode` from the SDK, passed in
/// on every key and handed back with the outcome. Aliased so the engine still
/// reads as a Vim engine.
public typealias VimMode = KeyMode

public struct VimKey: Equatable, Sendable {
    public let key: String
    public let control: Bool

    public init(_ key: String, control: Bool = false) {
        self.key = key
        self.control = control
    }
}

/// What the editor should do about a key.
public struct VimOutcome: Equatable, Sendable {
    /// Replace this range with `replacement` — nil means nothing was edited.
    public var edit: (range: NSRange, replacement: String)?
    public var caret: Int
    public var mode: VimMode
    /// Selection to show, for visual mode.
    public var selection: NSRange?

    public static func == (a: VimOutcome, b: VimOutcome) -> Bool {
        a.edit?.range == b.edit?.range && a.edit?.replacement == b.edit?.replacement
            && a.caret == b.caret && a.mode == b.mode && a.selection == b.selection
    }
}

@MainActor
public final class VimEngine {
    /// The keys typed so far towards a command — `d` waiting for a motion,
    /// `g` waiting for its second half.
    public private(set) var pending: [VimKey] = []
    private var count: Int?
    /// The last thing deleted or yanked, and whether it was whole lines.
    private var register: (text: String, linewise: Bool)?
    /// Where visual mode started.
    private var visualAnchor: Int?
    /// The mode the last key arrived in, so a change made anywhere else —
    /// escape, a command, another canvas handing focus over — abandons a
    /// half-typed command rather than letting it finish in a mode that was
    /// never meant to run it.
    private var lastMode: VimMode = .normal

    public init() {}

    /// Feed a key in the mode it arrived in. Returns nil when the key isn't
    /// ours — in insert mode that is everything, which is how typing stays
    /// typing.
    ///
    /// The mode goes in and comes back out on the outcome; none of it is kept
    /// here beyond noticing that it changed.
    public func handle(_ key: VimKey, mode: VimMode, text: String,
                       caret: Int) -> VimOutcome? {
        // Set from anywhere else — escape, a command, focus arriving — a
        // half-typed `d` has no business finishing in the mode that follows.
        if mode != lastMode {
            reset()
            if mode != .visual { visualAnchor = nil }
            lastMode = mode
        }
        guard let outcome = compute(key, mode: mode, text: text, caret: caret) else { return nil }
        lastMode = outcome.mode
        if outcome.mode != .visual { visualAnchor = nil }
        return outcome
    }

    private func compute(_ key: VimKey, mode: VimMode, text: String,
                         caret: Int) -> VimOutcome? {
        let ns = text as NSString

        if key.key == "ESC" {
            reset()
            return VimOutcome(edit: nil, caret: caret, mode: .normal, selection: nil)
        }
        guard mode != .insert else { return nil }
        // A control chord is a different key from the letter in it, and this
        // engine binds none of them. Without this `motion` compares only the
        // letter, so `C-w` read as the word motion and the editor swallowed
        // the app's window prefix — along with `C-o` and `C-i`, which is to
        // say the whole of navigation history — before the keymap saw it.
        guard !key.control else { return nil }

        // Counts, Vim's multiplier. `0` is a motion unless a count is running.
        if pending.isEmpty, let digit = Int(key.key), key.key.count == 1,
           digit > 0 || count != nil {
            count = (count ?? 0) * 10 + digit
            return VimOutcome(edit: nil, caret: caret, mode: mode, selection: selectionNow(caret, mode: mode))
        }

        let sequence = pending + [key]
        let repeats = count ?? 1

        // An operator waiting for a motion: `d` + `w`, `y` + `$`.
        if let op = sequence.first?.key, sequence.count > 1,
           ["d", "c", "y"].contains(op), !sequence[0].control {
            let rest = Array(sequence.dropFirst())
            // Doubled operator: whole lines.
            if rest.count == 1, rest[0].key == op {
                return applyLinewise(op, at: caret, lines: repeats, in: ns)
            }
            guard let target = motion(rest, from: caret, count: repeats, in: ns) else {
                // Still incomplete (`dg`), or nonsense (`dz`) — one waits, the
                // other is abandoned rather than doing something surprising.
                if isMotionPrefix(rest) {
                    pending = sequence
                    return VimOutcome(edit: nil, caret: caret, mode: mode, selection: nil)
                }
                reset()
                return VimOutcome(edit: nil, caret: caret, mode: .normal, selection: nil)
            }
            return applyOperator(op, from: caret, to: target, in: ns)
        }

        // An operator on its own waits for the motion that tells it how far
        // to reach. In visual mode it doesn't wait — the selection already
        // says how far.
        if mode == .normal, pending.isEmpty, sequence.count == 1,
           ["d", "c", "y"].contains(key.key), !key.control {
            pending = sequence
            return VimOutcome(edit: nil, caret: caret, mode: mode, selection: nil)
        }

        // A motion prefix that needs another key: `g`.
        if isMotionPrefix(sequence) {
            pending = sequence
            return VimOutcome(edit: nil, caret: caret, mode: mode, selection: selectionNow(caret, mode: mode))
        }

        defer { if pending.isEmpty { count = nil } }
        return command(sequence, mode: mode, caret: caret, count: repeats, in: ns)
    }

    // MARK: Commands

    private func command(_ sequence: [VimKey], mode: VimMode, caret: Int, count: Int,
                         in ns: NSString) -> VimOutcome? {
        let key = sequence.last?.key ?? ""

        // Entering insert, each from its own place.
        switch key {
        case "i" where sequence.count == 1:
            reset()
            return VimOutcome(edit: nil, caret: caret, mode: .insert, selection: nil)
        case "a" where sequence.count == 1:
            reset()
            return VimOutcome(edit: nil, caret: min(caret + 1, ns.length),
                              mode: .insert, selection: nil)
        case "I" where sequence.count == 1:
            reset()
            return VimOutcome(edit: nil, caret: firstNonBlank(ofLineAt: caret, in: ns),
                              mode: .insert, selection: nil)
        case "A" where sequence.count == 1:
            reset()
            return VimOutcome(edit: nil, caret: lineEnd(at: caret, in: ns),
                              mode: .insert, selection: nil)
        case "o", "O":
            reset()
            let atEnd = key == "o"
            let insertion = atEnd ? lineEnd(at: caret, in: ns) : lineStart(at: caret, in: ns)
            let indent = leadingWhitespace(ofLineAt: caret, in: ns)
            let inserted = atEnd ? "\n" + indent : indent + "\n"
            return VimOutcome(edit: (NSRange(location: insertion, length: 0), inserted),
                              caret: atEnd ? insertion + 1 + indent.count : insertion + indent.count,
                              mode: .insert, selection: nil)

        case "v":
            visualAnchor = caret
            return VimOutcome(edit: nil, caret: caret, mode: .visual,
                              selection: NSRange(location: caret, length: 0))

        // Deletions that don't need a motion.
        case "x":
            let end = min(caret + count, lineEnd(at: caret, in: ns))
            guard end > caret else { return VimOutcome(edit: nil, caret: caret, mode: mode, selection: nil) }
            let range = NSRange(location: caret, length: end - caret)
            register = (ns.substring(with: range), false)
            reset()
            return VimOutcome(edit: (range, ""), caret: caret, mode: .normal, selection: nil)
        case "D", "C":
            let range = NSRange(location: caret, length: lineEnd(at: caret, in: ns) - caret)
            register = (ns.substring(with: range), false)
            reset()
            return VimOutcome(edit: (range, ""), caret: caret,
                              mode: key == "C" ? .insert : .normal, selection: nil)

        // Paste.
        case "p", "P":
            guard let register else { return VimOutcome(edit: nil, caret: caret, mode: mode, selection: nil) }
            reset()
            if register.linewise {
                let at = key == "p" ? lineEnd(at: caret, in: ns) : lineStart(at: caret, in: ns)
                let payload = key == "p" ? "\n" + register.text : register.text + "\n"
                let caretAfter = key == "p" ? at + 1 : at
                return VimOutcome(edit: (NSRange(location: at, length: 0), payload),
                                  caret: caretAfter, mode: .normal, selection: nil)
            }
            let at = key == "p" ? min(caret + 1, ns.length) : caret
            return VimOutcome(edit: (NSRange(location: at, length: 0), register.text),
                              caret: at + (register.text as NSString).length - 1,
                              mode: .normal, selection: nil)

        default:
            break
        }

        // Anything left is a motion.
        if let target = motion(sequence, from: caret, count: count, in: ns) {
            if mode == .visual, let anchor = visualAnchor {
                pending = []
                // Inclusive of both ends, the way Vim highlights: the caret's
                // own character is part of the selection.
                let start = min(anchor, target)
                let length = min(abs(target - anchor) + 1, ns.length - start)
                return VimOutcome(edit: nil, caret: target, mode: .visual,
                                  selection: NSRange(location: start, length: max(length, 0)))
            }
            reset()
            return VimOutcome(edit: nil, caret: target, mode: mode, selection: nil)
        }

        // Visual mode operators work on the selection.
        if mode == .visual, let anchor = visualAnchor, ["d", "c", "y", "x"].contains(key) {
            let range = NSRange(location: min(anchor, caret),
                                length: abs(caret - anchor) + 1)
            let clamped = NSRange(location: range.location,
                                  length: min(range.length, ns.length - range.location))
            register = (ns.substring(with: clamped), false)
            reset()
            if key == "y" {
                return VimOutcome(edit: nil, caret: clamped.location, mode: .normal, selection: nil)
            }
            return VimOutcome(edit: (clamped, ""), caret: clamped.location,
                              mode: key == "c" ? .insert : .normal, selection: nil)
        }

        reset()
        return nil
    }

    // MARK: Operators

    private func applyOperator(_ op: String, from caret: Int, to target: Int,
                               in ns: NSString) -> VimOutcome {
        let range = NSRange(location: min(caret, target), length: abs(target - caret))
        register = (ns.substring(with: range), false)
        reset()
        switch op {
        case "y":
            return VimOutcome(edit: nil, caret: range.location, mode: .normal, selection: nil)
        case "c":
            return VimOutcome(edit: (range, ""), caret: range.location, mode: .insert, selection: nil)
        default:
            return VimOutcome(edit: (range, ""), caret: range.location, mode: .normal, selection: nil)
        }
    }

    private func applyLinewise(_ op: String, at caret: Int, lines: Int,
                               in ns: NSString) -> VimOutcome {
        var range = ns.lineRange(for: NSRange(location: caret, length: 0))
        for _ in 1..<max(lines, 1) {
            guard NSMaxRange(range) < ns.length else { break }
            let next = ns.lineRange(for: NSRange(location: NSMaxRange(range), length: 0))
            range = NSRange(location: range.location, length: NSMaxRange(next) - range.location)
        }
        register = (ns.substring(with: range).trimmingTrailingNewline, true)
        reset()
        switch op {
        case "y":
            return VimOutcome(edit: nil, caret: range.location, mode: .normal, selection: nil)
        case "c":
            // `cc` keeps the line, empties it, and leaves you typing on it.
            let indent = leadingWhitespace(ofLineAt: caret, in: ns)
            return VimOutcome(edit: (range, indent + "\n"),
                              caret: range.location + indent.count, mode: .insert, selection: nil)
        default:
            return VimOutcome(edit: (range, ""),
                              caret: min(range.location, max(ns.length - range.length, 0)),
                              mode: .normal, selection: nil)
        }
    }

    private func reset() {
        pending = []
        count = nil
    }

    private func selectionNow(_ caret: Int, mode: VimMode) -> NSRange? {
        guard mode == .visual, let anchor = visualAnchor else { return nil }
        return NSRange(location: min(anchor, caret), length: abs(caret - anchor) + 1)
    }
}

private extension String {
    var trimmingTrailingNewline: String {
        hasSuffix("\n") ? String(dropLast()) : self
    }
}

extension MaximalEditor.EditorTextView: CanvasKeyHandling {
    /// The editor's share of the commanding modes: motions, operators, counts.
    /// What it doesn't understand goes back to the app, which is how the
    /// leader and every global binding keep working with the caret in a
    /// document.
    public func handleKey(_ key: String, control: Bool, mode: KeyMode) -> KeyMode? {
        guard vimEnabled else { return nil }
        guard let outcome = vim.handle(VimKey(key, control: control), mode: mode,
                                       text: text ?? "", caret: textSelection.location)
        else {
            // Nothing to do with it — but a bare character must not fall
            // through and be *typed*: in a commanding mode the app decides,
            // and if the app has no binding either, nothing happens.
            return nil
        }
        applyVim(outcome)
        return outcome.mode
    }
}
