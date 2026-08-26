import Foundation

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
public enum VimMode: String, Sendable {
    case normal, insert, visual

    public var label: String { rawValue.uppercased() }
}

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
    public private(set) var mode: VimMode = .normal
    /// The keys typed so far towards a command — `d` waiting for a motion,
    /// `g` waiting for its second half.
    public private(set) var pending: [VimKey] = []
    private var count: Int?
    /// The last thing deleted or yanked, and whether it was whole lines.
    private var register: (text: String, linewise: Bool)?
    /// Where visual mode started.
    private var visualAnchor: Int?

    public init() {}

    public func setMode(_ mode: VimMode) {
        self.mode = mode
        pending = []
        count = nil
        if mode != .visual { visualAnchor = nil }
    }

    /// Feed a key. Returns nil when the key isn't ours — in insert mode that
    /// is everything except Escape, which is how typing stays typing.
    public func handle(_ key: VimKey, text: String, caret: Int) -> VimOutcome? {
        let ns = text as NSString

        if key.key == "ESC" {
            let outcome = VimOutcome(edit: nil,
                                     caret: mode == .insert ? max(caret - 0, 0) : caret,
                                     mode: .normal, selection: nil)
            setMode(.normal)
            return outcome
        }
        guard mode != .insert else { return nil }

        // Counts, Vim's multiplier. `0` is a motion unless a count is running.
        if pending.isEmpty, let digit = Int(key.key), key.key.count == 1,
           digit > 0 || count != nil {
            count = (count ?? 0) * 10 + digit
            return VimOutcome(edit: nil, caret: caret, mode: mode, selection: selectionNow(caret))
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
            return VimOutcome(edit: nil, caret: caret, mode: mode, selection: selectionNow(caret))
        }

        defer { if pending.isEmpty { count = nil } }
        return command(sequence, caret: caret, count: repeats, in: ns)
    }

    // MARK: Commands

    private func command(_ sequence: [VimKey], caret: Int, count: Int,
                         in ns: NSString) -> VimOutcome? {
        let key = sequence.last?.key ?? ""

        // Entering insert, each from its own place.
        switch key {
        case "i" where sequence.count == 1:
            reset(); setMode(.insert)
            return VimOutcome(edit: nil, caret: caret, mode: .insert, selection: nil)
        case "a" where sequence.count == 1:
            reset(); setMode(.insert)
            return VimOutcome(edit: nil, caret: min(caret + 1, ns.length),
                              mode: .insert, selection: nil)
        case "I" where sequence.count == 1:
            reset(); setMode(.insert)
            return VimOutcome(edit: nil, caret: firstNonBlank(ofLineAt: caret, in: ns),
                              mode: .insert, selection: nil)
        case "A" where sequence.count == 1:
            reset(); setMode(.insert)
            return VimOutcome(edit: nil, caret: lineEnd(at: caret, in: ns),
                              mode: .insert, selection: nil)
        case "o", "O":
            reset(); setMode(.insert)
            let atEnd = key == "o"
            let insertion = atEnd ? lineEnd(at: caret, in: ns) : lineStart(at: caret, in: ns)
            let indent = leadingWhitespace(ofLineAt: caret, in: ns)
            let inserted = atEnd ? "\n" + indent : indent + "\n"
            return VimOutcome(edit: (NSRange(location: insertion, length: 0), inserted),
                              caret: atEnd ? insertion + 1 + indent.count : insertion + indent.count,
                              mode: .insert, selection: nil)

        case "v":
            visualAnchor = caret
            setMode(.visual)
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
            if key == "C" { setMode(.insert) }
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
                setMode(.normal)
                return VimOutcome(edit: nil, caret: clamped.location, mode: .normal, selection: nil)
            }
            setMode(key == "c" ? .insert : .normal)
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
            setMode(.insert)
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
            setMode(.insert)
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

    private func selectionNow(_ caret: Int) -> NSRange? {
        guard mode == .visual, let anchor = visualAnchor else { return nil }
        return NSRange(location: min(anchor, caret), length: abs(caret - anchor) + 1)
    }
}

private extension String {
    var trimmingTrailingNewline: String {
        hasSuffix("\n") ? String(dropLast()) : self
    }
}
