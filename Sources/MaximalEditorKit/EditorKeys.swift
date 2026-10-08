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

        // Code.
        (">", .indent, "Indent"),
        ("<", .outdent, "Outdent"),
        ("g c", .toggleComment, "Toggle Comment"),
        // Helix's key: `%` here is select all, as it is there.
        ("m m", .matchBracket, "Matching Bracket"),
    ]

    /// The action id for a command, so the keys and the registrations agree by
    /// construction rather than by two lists being kept in step.
    public static func id(for command: EditCommand) -> String { "editor.\(command.rawValue)" }

    /// What a canvas showing an editor declares.
    ///
    /// The motions and verbs, plus finding — which is not an `EditCommand`
    /// because it is not an edit: it moves the selection to the next match.
    /// `/` is the editor's here rather than the app finder's, which is what it
    /// means in a document; the finder is still `SPC /` and `SPC SPC`.
    public static var keys: [SurfaceKey] {
        bindings.map { SurfaceKey($0.key, id(for: $0.command)) }
            + [SurfaceKey("/", "editor.find"),
               SurfaceKey("n", "editor.findNext"),
               SurfaceKey("N", "editor.findPrevious"),
               SurfaceKey("u", "editor.undo"),
               SurfaceKey("C-r", "editor.redo")]
    }

    /// The editor with the keyboard, if one has it.
    public static var focused: MaximalEditor.EditorTextView? {
        NSApp.keyWindow?.firstResponder as? MaximalEditor.EditorTextView
    }

    /// The mode the app is in, as last reported.
    ///
    /// The editor has no mode of its own — there is one and it belongs to the
    /// app — but it still has to *react* to it, and it never sees a keystroke.
    public private(set) static var appMode: KeyMode = .normal

    /// Leaving insert mode puts a selection back.
    ///
    /// Normal mode always has something selected — that is the whole of the
    /// select-then-act grammar, and every verb needs something to work on. The
    /// engine used to restore it when *it* saw Escape; Escape is the app's
    /// now, and the editor never sees a keystroke, so this is the editor
    /// reacting to a mode it does not own.
    public static func appModeChanged(to mode: KeyMode) {
        appMode = mode
        if mode == .normal { EditorFind.shared.close() }
        guard mode == .normal, let editor = focused, editor.modalEditing else { return }
        editor.run(.collapseSelection, count: 1, mode: .normal)
    }

    /// Asked for by every plugin whose canvas declares these keys.
    ///
    /// Safe to call more than once: the registry keeps one action per id, so
    /// the vocabulary exists whichever of those plugins is loaded and appears
    /// once however many of them ask.
    public static func register(with registry: PluginRegistry) {
        let inAnEditor = ActionPredicate.custom { _ in focused?.modalEditing == true }
        registry.register(action: Action(
            id: "editor.find", title: "Find…", systemImage: "magnifyingglass",
            appliesTo: inAnEditor, scope: .document
        ) { _ in EditorFind.shared.open() })
        registry.register(action: Action(
            id: "editor.findNext", title: "Find Next", systemImage: "chevron.down",
            appliesTo: .custom { _ in
                focused?.modalEditing == true && !EditorFind.shared.query.isEmpty
            },
            scope: .document
        ) { _ in EditorFind.shared.step(forward: true) })
        registry.register(action: Action(
            id: "editor.findPrevious", title: "Find Previous", systemImage: "chevron.up",
            appliesTo: .custom { _ in
                focused?.modalEditing == true && !EditorFind.shared.query.isEmpty
            },
            scope: .document
        ) { _ in EditorFind.shared.step(forward: false) })

        // The view's own history, which every edit — typed or commanded —
        // already goes through, so there is nothing for the engine to keep.
        registry.register(action: Action(
            id: "editor.undo", title: "Undo", systemImage: "arrow.uturn.backward",
            appliesTo: .custom { _ in focused?.undoManager?.canUndo == true },
            scope: .document, surfaces: [.palette]
        ) { ctx in
            guard let editor = focused else { return }
            for _ in 0..<max(ctx.count, 1) where editor.undoManager?.canUndo == true {
                editor.undoManager?.undo()
            }
        })
        registry.register(action: Action(
            id: "editor.redo", title: "Redo", systemImage: "arrow.uturn.forward",
            appliesTo: .custom { _ in focused?.undoManager?.canRedo == true },
            scope: .document, surfaces: [.palette]
        ) { ctx in
            guard let editor = focused else { return }
            for _ in 0..<max(ctx.count, 1) where editor.undoManager?.canRedo == true {
                editor.undoManager?.redo()
            }
        })

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
