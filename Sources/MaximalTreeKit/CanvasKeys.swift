import AppKit

/// Which keymap is in force.
///
/// The app's one mode. Not a copy per canvas kept in step with the app's —
/// that arrangement cost three bugs in a row (letters swallowed as commands
/// because the app hadn't heard the editor enter insert; escape telling the
/// wrong canvas to leave; the app and the editor disagreeing about which mode
/// was even in force), because two things that must always agree eventually
/// won't. There is one value, and it decides how a key press is read.
/// Frozen: these three are the whole vocabulary, and the framework is built
/// with library evolution on, so without this every caller switching over a
/// mode has to carry an `@unknown default` for a case that never arrives.
@frozen
public enum KeyMode: String, Sendable {
    /// Keys are commands. Where the app spends its time.
    case normal
    /// Keys are text, and belong to whatever has focus.
    case insert
    /// Keys are commands still, extending a selection as they go.
    case visual

    public var label: String { rawValue.capitalized }

    /// Whether keys are text rather than commands — the one distinction
    /// routing actually turns on.
    public var isTyping: Bool { self == .insert }
}

/// One key a canvas takes, so the app can say so before it is pressed.
///
/// The same vocabulary `handleKey` speaks — a key name and whether Control
/// was held — plus what it does and the mode it does it in.
public struct CanvasKeyBinding: Sendable {
    /// A single character, or a name like `RET`, `TAB`, `ESC`. A sequence is
    /// written with spaces, as `"g g"`.
    public let key: String
    public let control: Bool
    /// The mode this applies in. A canvas that takes the same key in more
    /// than one lists it once per mode.
    public let mode: KeyMode
    /// What it does, in the words the reader should see.
    public let title: String

    public init(_ key: String, control: Bool = false,
                mode: KeyMode = .normal, title: String) {
        self.key = key
        self.control = control
        self.mode = mode
        self.title = title
    }
}

/// A canvas that does something with keys itself.
///
/// A canvas is entitled to its own commands: an editor moves its caret with
/// `j`, a diff might step between hunks, a preview might page. Whatever it
/// declines falls through to the app's keymap, so the leader and every global
/// binding keep working over it.
///
/// The mode comes in as an argument and goes back out as a return value; the
/// canvas never stores it. A canvas that doesn't adopt this simply leaves
/// every key to the app.
@MainActor
public protocol CanvasKeyHandling: AnyObject {
    /// What this canvas does with keys.
    ///
    /// Declared so the app can *show* them: in normal mode the focused canvas
    /// gets first refusal on every key, which means the app's own bindings are
    /// not what will happen while a canvas has the keyboard. Which-key listed
    /// them anyway, and confidently — `j` reads as "move down the sidebar"
    /// while the editor is quietly taking it to move the caret.
    ///
    /// Empty by default: a canvas that declares nothing is described as taking
    /// nothing, which is wrong but no worse than before.
    var keyBindings: [CanvasKeyBinding] { get }

    /// Handle a key press in the app's current mode.
    ///
    /// - Parameters:
    ///   - key: a single character, or a name like `RET`, `TAB`, `ESC`.
    ///   - control: whether Control was held.
    ///   - mode: the mode in force, which the canvas reads rather than keeps.
    /// - Returns: the mode the app should be in now — usually the one that
    ///   came in, but `i` and `o` and a visual `c` all answer `.insert` — or
    ///   nil to decline the key and leave it to the app.
    func handleKey(_ key: String, control: Bool, mode: KeyMode) -> KeyMode?
}

public extension CanvasKeyHandling {
    var keyBindings: [CanvasKeyBinding] { [] }
}
