import AppKit

/// A canvas that does something with keys while the app is in normal mode.
///
/// Normal mode means keys are commands, and a canvas is entitled to its own:
/// an editor moves its caret with `j`, a diff might step between hunks, a
/// preview might page. Whatever a canvas declines falls through to the app's
/// keymap, so the leader and every global binding keep working over it.
///
/// Insert mode never comes here — there, keys are text and go straight to
/// whatever has focus. No canvas is a special case in either direction; a
/// canvas that doesn't adopt this simply leaves normal mode to the app.
@MainActor
public protocol CanvasKeyHandling: AnyObject {
    /// Handle a key press. Return false to let the app have it.
    ///
    /// - Parameters:
    ///   - key: a single character, or a name like `RET`, `TAB`, `ESC`.
    ///   - control: whether Control was held.
    func handleNormalModeKey(_ key: String, control: Bool) -> Bool

    /// Told when the app switches modes, so a canvas showing its own state —
    /// a caret shape, a selection — can follow.
    func canvasModeChanged(toInsert: Bool)
}

public extension CanvasKeyHandling {
    func canvasModeChanged(toInsert: Bool) {}
}
