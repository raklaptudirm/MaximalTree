import AppKit
import MaximalTreeKit

/// The editor's commands, as actions.
///
/// Every plugin that puts an editor on a canvas registers these and declares
/// the keys that run them, so there is one editor vocabulary however many
/// canvases show one.
///
/// They find the editor the same way the app finds any focused view: the first
/// responder. A command with no editor in front of it does not apply, which is
/// what keeps "Delete Selection" out of a list while you are looking at a
/// terminal.
@MainActor
public enum EditorKeys {
    /// Helix's grammar: a motion selects, a verb acts on the selection.
    ///
    /// The key and the command it runs are written next to each other, so the
    /// binding and the thing it does cannot drift apart — which is what the
    /// declaration-plus-implementation pair could do, and did.
    public static let bindings: [(key: String, command: EditCommand, title: String)] = [
        // Moving, which is also selecting.
        ("h", .left, "Left"),
        ("l", .right, "Right"),
        ("j", .down, "Down"),
        ("k", .up, "Up"),
        ("w", .wordForward, "Next Word"),
        ("b", .wordBackward, "Previous Word"),
        ("e", .wordEnd, "End of Word"),
        ("0", .lineStart, "Line Start"),
        ("^", .firstNonBlank, "First Non-Blank"),
        ("$", .lineEnd, "Line End"),
        ("x", .selectLine, "Select Line"),
        ("%", .selectAll, "Select All"),
        ("G", .lastLine, "Last Line"),
        ("g g", .firstLine, "First Line"),
        ("g e", .documentEnd, "End of Document"),
        ("g h", .toLineStart, "Go to Line Start"),
        ("g l", .toLineEnd, "Go to Line End"),

        // Acting on what is selected.
        ("d", .delete, "Delete"),
        ("c", .change, "Change"),
        ("y", .yank, "Yank"),
        ("p", .pasteAfter, "Paste After"),
        ("P", .pasteBefore, "Paste Before"),
        ("i", .insertBefore, "Insert Before"),
        ("a", .insertAfter, "Insert After"),
        ("I", .insertAtLineStart, "Insert at Line Start"),
        ("A", .insertAtLineEnd, "Insert at Line End"),
        ("o", .openBelow, "Open Line Below"),
        ("O", .openAbove, "Open Line Above"),
        ("v", .extendSelection, "Extend Selection"),
        (";", .collapseSelection, "Collapse Selection"),
    ]

    /// The action id for a command, so the keys and the registrations agree by
    /// construction rather than by two lists being kept in step.
    public static func id(for command: EditCommand) -> String { "editor.\(command.rawValue)" }

    /// What a canvas showing an editor declares.
    public static var keys: [SurfaceKey] {
        bindings.map { SurfaceKey($0.key, id(for: $0.command)) }
    }

    /// The editor with the keyboard, if one has it.
    public static var focused: MaximalEditor.EditorTextView? {
        NSApp.keyWindow?.firstResponder as? MaximalEditor.EditorTextView
    }

    /// Leaving insert mode puts a selection back.
    ///
    /// Normal mode always has something selected — that is the whole of the
    /// select-then-act grammar, and every verb needs something to work on. The
    /// engine used to restore it when *it* saw Escape; Escape is the app's
    /// now, and the editor never sees a keystroke, so this is the editor
    /// reacting to a mode it does not own.
    public static func appModeChanged(to mode: KeyMode) {
        guard mode == .normal, let editor = focused, editor.modalEditing else { return }
        editor.run(.collapseSelection, count: 1, mode: .normal)
    }

    /// Asked for by every plugin whose canvas declares these keys.
    ///
    /// Safe to call more than once: the registry keeps one action per id, so
    /// the vocabulary exists whichever of those plugins is loaded and appears
    /// once however many of them ask.
    public static func register(with registry: PluginRegistry) {
        for binding in bindings {
            registry.register(action: Action(
                id: id(for: binding.command), title: binding.title,
                systemImage: "text.cursor",
                appliesTo: .custom { _ in focused?.modalEditing == true },
                // Thirty motions in the menu bar would bury what belongs
                // there; searchable and bindable is what they want to be.
                scope: .document, surfaces: [.palette]
            ) { ctx in
                guard let editor = focused else { return }
                // The command reports the mode it left behind, and that *is*
                // the app's mode rather than a second copy of it.
                if let next = editor.run(binding.command, count: ctx.count,
                                         mode: ctx.host.keyMode), next != ctx.host.keyMode {
                    ctx.host.setKeyMode(next)
                }
            })
        }
    }
}
