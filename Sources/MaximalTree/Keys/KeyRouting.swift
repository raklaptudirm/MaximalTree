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
        return mode == .insert ? .focusedView : .app
    }
}
