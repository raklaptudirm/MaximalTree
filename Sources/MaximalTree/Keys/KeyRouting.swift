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
        /// The modal layer: the surface holding the keyboard gets first
        /// refusal on its declared keys, then the app's keymap.
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
                       surface: @autoclosure () -> Keymap = Keymap()) -> Bool {
        guard KeyRouting.destination(for: chord, mode: keys.mode) == .app else { return false }

        // Escape is one assignment, because there is one mode. Nothing to
        // notify, nothing that can be left behind still typing.
        if chord.key == "ESC" {
            keys.setMode(.normal)
            return true
        }

        // A sequence already begun continues in the map that began it. Asking
        // the other one halfway through would resolve `g g` in the sidebar
        // against the app's `g` group, which is a different `g` entirely.
        if !keys.pending.isEmpty {
            guard keys.isSurfaceSequence else { return app(chord, keys) }
            if keys.handleSurface(chord, map: surface()) { return true }
            // A dead end in the surface's map is still the surface's: half a
            // sequence must not leak out as a stray app binding.
            keys.cancelSequence()
            return true
        }

        // Nothing pending. The surface holding the keyboard gets first
        // refusal, except on the leader, which is the app's wherever you are.
        if chord.key != "SPC" {
            // Its declared keys: the surface says what it claims and the core
            // runs the action, so no surface sees a raw keystroke in a
            // commanding mode. That is what makes its keys rebindable,
            // listable, and callable by name like everything else.
            if keys.handleSurface(chord, map: surface()) { return true }

        }

        return app(chord, keys)
    }

    @MainActor
    private static func app(_ chord: KeyChord, _ keys: KeyEngine) -> Bool {
        switch keys.handle(chord, editing: false) {
        case .consumed, .pendingSequence: return true
        case .passed: return false
        }
    }
}
