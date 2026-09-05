import Foundation
import Observation
import MaximalTreeKit

/// The modal keyboard layer.
///
/// Holds the mode, the keys typed so far towards a sequence, and the count
/// prefix — `3j` moves three rows. Deliberately knows nothing about what the
/// commands *do*: it turns key presses into command ids and a repeat count,
/// which is what makes it testable without an app around it.
@MainActor
@Observable
final class KeyEngine {
    private(set) var mode: KeyMode = .normal
    /// Keys typed towards a sequence that isn't finished. Drives which-key.
    private(set) var pending: [KeyChord] = []
    /// Digits typed before a command — `3j` moves three rows.
    private(set) var count: Int?

    var keymap: Keymap
    /// What the pending sequence could still become.
    private(set) var continuations: [(chord: KeyChord, binding: KeyBinding)] = []
    private(set) var prefixLabel: String = ""

    /// Runs a command id, `count` times where that makes sense.
    var perform: ((String, Int) -> Void)?

    /// Showing what a key would do from here, with nothing typed yet.
    ///
    /// Reached by pressing backspace once more than there are keys to undo:
    /// backspace walks a sequence back a key at a time, and stepping back off
    /// the leader lands here, on the keys that mean something with nothing
    /// typed at all. Asking "what is there" is the same gesture as "not that,
    /// go back", carried one step further.
    ///
    /// It used to appear while ⌘ was held. Every shortcut in the app passes
    /// through that modifier, so the menu answered questions nobody had asked.
    var isPeeking = false

    /// Every key that means something on its own, before any sequence has
    /// begun: `j`, `k`, `i`, and the leader among them as the group it is.
    ///
    /// The answer to "what do the keys do", which is a question worth being
    /// able to ask without committing to a sequence first.
    var topLevelBindings: [(chord: KeyChord, binding: KeyBinding)] {
        guard case .prefix(_, let continuations) = keymap.lookup([]) else { return [] }
        return continuations
    }

    init(keymap: Keymap) { self.keymap = keymap }

    enum Outcome: Equatable {
        /// Handled; the key must not reach anything else.
        case consumed
        /// Part of a sequence so far — also consumed, but nothing ran yet.
        case pendingSequence
        /// Not ours; let it through.
        case passed
    }

    /// Reports every mode change, so the host context can mirror it for the
    /// surfaces that read it.
    var onModeChange: ((KeyMode) -> Void)?

    func setMode(_ mode: KeyMode) {
        self.mode = mode
        reset()
        onModeChange?(mode)
    }

    /// Feed a key press.
    ///
    /// - Parameter editing: whether the keyboard currently belongs to a text
    ///   view. Nothing is intercepted there except Escape, which is how you
    ///   get back out — an editor that swallowed every `j` would be unusable,
    ///   and this layer doesn't do the editing modes *inside* text.
    func handle(_ chord: KeyChord, editing: Bool) -> Outcome {
        // Any key answers the question the peek was asking, including the
        // backspace that would open it again.
        isPeeking = false
        if chord == KeyChord("ESC") {
            // Escape always means "back to normal, forget what I was typing".
            let wasPending = !pending.isEmpty || count != nil
            setMode(.normal)
            return wasPending || editing ? .consumed : .consumed
        }
        // Visual is still a commanding mode, so the keymap applies there too:
        // the leader has to work with a selection up, not just without one.
        guard !mode.isTyping, !editing else { return .passed }

        // Backspace undoes the last key of a sequence rather than the whole
        // thing. Escape is the way out; this is the way *back*, so a mistyped
        // third key doesn't cost you the two that were right.
        if chord == KeyChord("DEL") {
            if !pending.isEmpty {
                stepBack()
                return .pendingSequence
            }
            if let current = count {
                // Same idea for a repeat being typed: 12 becomes 1, and the
                // last digit leaves no count behind rather than a zero.
                count = current >= 10 ? current / 10 : nil
                return count == nil ? .consumed : .pendingSequence
            }
            return .passed
        }

        // Counts: digits before a sequence, but `0` alone is a motion, not a
        // count, so it only counts when one is already being typed.
        if pending.isEmpty, let digit = Int(chord.key), chord.key.count == 1,
           digit > 0 || count != nil {
            count = (count ?? 0) * 10 + digit
            return .pendingSequence
        }

        let sequence = pending + [chord]
        switch keymap.lookup(sequence) {
        case .command(let id):
            let repeats = count ?? 1
            reset()
            perform?(id, repeats)
            return .consumed
        case .prefix(let label, let continuations):
            pending = sequence
            prefixLabel = label
            self.continuations = continuations
            return .pendingSequence
        case .unbound:
            // A dead end swallows the key rather than letting half a sequence
            // leak into the app as a stray shortcut.
            let hadPending = !pending.isEmpty
            reset()
            return hadPending ? .consumed : .passed
        }
    }

    /// Run a key against a surface's own map.
    ///
    /// Sequences within a surface's map work the same way the app's do — `g g`
    /// is two keys there too — so the pending state is shared. What differs is
    /// only which map answered.
    ///
    /// - Returns: whether the surface took it.
    func handleSurface(_ chord: KeyChord, map: Keymap) -> Bool {
        switch map.lookup(pending + [chord]) {
        case .command(let id):
            let repeats = count ?? 1
            reset()
            perform?(id, repeats)
            return true
        case .prefix(let label, let continuations):
            pending = pending + [chord]
            prefixLabel = label
            self.continuations = continuations
            isSurfaceSequence = true
            return true
        case .unbound:
            return false
        }
    }

    /// Whether the sequence in progress belongs to a surface's map rather than
    /// the app's — so the next key is looked up where the first one was.
    private(set) var isSurfaceSequence = false

    /// Abandon a sequence that led nowhere, without leaving its keys to be
    /// read as something else.
    func cancelSequence() { reset() }

    /// Drop the last chord and put the state back to what it was before it.
    ///
    /// Re-looked-up rather than remembered: the label and the continuations
    /// are what the map says about a sequence, and the map is the only thing
    /// that knows. A stack of previous states would be a second copy of it.
    private func stepBack() {
        let shortened = pending.dropLast()
        guard !shortened.isEmpty,
              case .prefix(let label, let continuations) = keymap.lookup(Array(shortened)) else {
            // Back past the first key is back to nothing pending — but a count
            // already typed survives, the way it does in vim. And rather than
            // leaving nothing on screen, show what the keys do from here:
            // stepping back off the leader is exactly the moment you wanted
            // the question answered.
            let repeats = count
            reset()
            count = repeats
            isPeeking = true
            return
        }
        pending = Array(shortened)
        prefixLabel = label
        self.continuations = continuations
    }

    private func reset() {
        isSurfaceSequence = false
        pending = []
        count = nil
        continuations = []
        prefixLabel = ""
    }
}
