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

    init(keymap: Keymap) { self.keymap = keymap }

    enum Outcome: Equatable {
        /// Handled; the key must not reach anything else.
        case consumed
        /// Part of a sequence so far — also consumed, but nothing ran yet.
        case pendingSequence
        /// Not ours; let it through.
        case passed
    }

    func setMode(_ mode: KeyMode) {
        self.mode = mode
        reset()
    }

    /// Feed a key press.
    ///
    /// - Parameter editing: whether the keyboard currently belongs to a text
    ///   view. Nothing is intercepted there except Escape, which is how you
    ///   get back out — an editor that swallowed every `j` would be unusable,
    ///   and this layer doesn't do the editing modes *inside* text.
    func handle(_ chord: KeyChord, editing: Bool) -> Outcome {
        if chord == KeyChord("ESC") {
            // Escape always means "back to normal, forget what I was typing".
            let wasPending = !pending.isEmpty || count != nil
            setMode(.normal)
            return wasPending || editing ? .consumed : .consumed
        }
        // Visual is still a commanding mode, so the keymap applies there too:
        // the leader has to work with a selection up, not just without one.
        guard !mode.isTyping, !editing else { return .passed }

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

    private func reset() {
        pending = []
        count = nil
        continuations = []
        prefixLabel = ""
    }
}
