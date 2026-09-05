import Foundation
import MaximalTreeKit

/// Who gets a key press.
///
/// The mode decides, not the view. That is the whole idea of a modal app: in
/// insert mode keys are text and belong to whatever has focus — an editor, a
/// terminal, a web page, a field — and in normal mode they are commands and
/// belong to the app.
///
/// Deciding by *view* instead was two bugs in a row: first the editor wasn't
/// recognised, so it never received anything; then every canvas was, so the
/// leader key stopped working anywhere. A view can't answer "is this a
/// command or a character" — only the mode can.
///
/// No canvas is a special case. In normal mode the focused canvas gets first
/// refusal on the key and the app's keymap takes whatever it declines; in
/// insert mode every key belongs to whatever has focus. An editor is simply a
/// canvas that declines less.
enum KeyRouting {
    enum Destination: Equatable {
        /// The modal layer: the focused canvas gets first refusal (see
        /// `CanvasKeyHandling`), then the app's keymap.
        case app
        /// Whatever has focus, untouched.
        case focusedView
    }

    static func destination(for chord: KeyChord, mode: KeyMode) -> Destination {
        // Escape is how you leave, so it is never anyone else's.
        if chord.key == "ESC" { return .app }
        return mode.isTyping ? .focusedView : .app
    }
}

/// One key press, all the way through: routed, offered to the canvas, then to
/// the keymap. Separate from the event monitor that feeds it so it can be run
/// without a window — the mode bugs this has had were all invisible to every
/// test, because there was no way to reach this decision from one.
enum KeyDispatch {
    /// - Returns: whether the key was consumed, and must not reach AppKit.
    @MainActor
    static func handle(_ chord: KeyChord, keys: KeyEngine,
                       canvas: @autoclosure () -> CanvasKeyHandling?) -> Bool {
        guard KeyRouting.destination(for: chord, mode: keys.mode) == .app else { return false }

        // Escape is one assignment, because there is one mode. Nothing to
        // notify, nothing that can be left behind still typing.
        if chord.key == "ESC" {
            keys.setMode(.normal)
            return true
        }

        // The focused canvas gets first refusal — its own motions, its own
        // operators — but never the leader or the rest of a sequence already
        // begun, which belong to the app wherever the keyboard is.
        let reserved = chord.key == "SPC" || !keys.pending.isEmpty
        if !reserved, let canvas = canvas(),
           let next = canvas.handleKey(chord.canvasKey, control: chord.control, mode: keys.mode) {
            // The canvas reports the mode its own command left behind — `i`,
            // `o`, a visual `c` all answer `.insert` — and that answer *is*
            // the app's mode, rather than a second copy of it.
            if next != keys.mode { keys.setMode(next) }
            return true
        }

        switch keys.handle(chord, editing: false) {
        case .consumed, .pendingSequence: return true
        case .passed: return false
        }
    }
}
