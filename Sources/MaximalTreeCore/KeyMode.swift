import Foundation

/// Which keymap is in force.
///
/// The app's one mode. Not a copy per surface kept in step with the app's —
/// that arrangement cost three bugs in a row (letters swallowed as commands
/// because the app hadn't heard the editor enter insert; escape telling the
/// wrong canvas to leave; the app and the editor disagreeing about which mode
/// was even in force), because two things that must always agree eventually
/// won't. There is one value, and it decides how a key press is read.
///
/// Read it through `HostContext.keyMode`; a surface's action that starts
/// typing sets it with `setKeyMode(_:)`.
///
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
