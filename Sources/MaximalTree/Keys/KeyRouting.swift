import Foundation

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
enum KeyRouting {
    enum Destination: Equatable {
        /// The app's keymap: leader sequences, motions, commands.
        case app
        /// Whatever has focus, untouched.
        case focusedView
    }

    static func destination(for chord: KeyChord, mode: KeyMode,
                            editorFocused: Bool, appHasPending: Bool) -> Destination {
        // Escape is how you leave, so it is never anyone else's.
        if chord.key == "ESC" { return .app }
        if mode == .insert { return .focusedView }

        // Normal mode with the editor focused: its own modal layer owns
        // motions and operators, since `j` there means the caret and not the
        // file tree. The leader still reaches through, and so does the rest of
        // a sequence already begun — otherwise half a command would vanish
        // into the document.
        if editorFocused, chord.key != "SPC", !appHasPending { return .focusedView }
        return .app
    }
}
