import SwiftUI
import MaximalTreeKit

/// The menu bar, built from the action registry.
///
/// A menu item is an action, not a second implementation of one. Its title,
/// its key equivalent and whether it is greyed out all come from the action —
/// so an operation is defined once and the menu, the finder, the context menu
/// and the keymap can only ever agree about it. They did not before: the menu
/// said "Close Pane" and greyed itself out on `navigation.canClosePane` while
/// the same operation, bound to a key, decided for itself.
///
/// The menus themselves stay hand-arranged. Which operations belong together
/// under "Navigate" is editorial and no property of an action says it; what is
/// mechanical is *what each item does*, and that is what comes from the
/// registry. The `Actions` menu is the exception and is generated, because
/// there the arrangement is the registry's too.
struct AppCommands: Commands {
    var model: AppModel

    var body: some Commands {
        // Pane commands live in the system View menu, next to its layout controls.
        CommandGroup(after: .sidebar) {
            Divider()
            ActionItem(model: model, id: "toggle.zen",
                       titled: model.isZenMode ? "Exit Zen Mode" : "Enter Zen Mode")
            Divider()
            ActionItem(model: model, id: "pane.splitRight")
            ActionItem(model: model, id: "pane.splitDown")
            ActionItem(model: model, id: "pane.close")
            Divider()
        }
        CommandMenu("Workspace") {
            WorkspaceMenuItems(model: model, showShortcuts: true)
        }
        CommandMenu("Navigate") {
            ActionItem(model: model, id: "nav.back")
            ActionItem(model: model, id: "nav.forward")
            Divider()
            ActionItem(model: model, id: "tab.new")
            ActionItem(model: model, id: "tab.close")
        }
        CommandMenu("Actions") {
            ActionItem(model: model, id: "finder.all")
            ActionItem(model: model, id: "finder.files")
            ActionItem(model: model, id: "finder.actions")
            ActionItem(model: model, id: "finder.nodeActions")
            Divider()
            ActionMenuItems(model: model)
        }
    }
}

/// One menu item, standing for one registered action.
///
/// Renders nothing when the id names no action. A menu should not offer an
/// operation the app hasn't got, and a test asserts that every id used here
/// resolves — so a missing item means that test was ignored, not that the
/// reader should be shown a dead entry.
struct ActionItem: View {
    var model: AppModel
    var id: String
    /// Overrides the action's own title, for the few that read differently in
    /// a menu — "Enter Zen Mode" says which way it goes, which a list of every
    /// command in the app cannot.
    var titled: String?

    init(model: AppModel, id: String, titled: String? = nil) {
        self.model = model
        self.id = id
        self.titled = titled
    }

    var body: some View {
        if let action = model.action(id) {
            let button = Button(titled ?? action.title) { model.run(action) }
                .disabled(!model.canRun(action))
            if let shortcut = action.shortcut?.keyboardShortcut {
                button.keyboardShortcut(shortcut)
            } else {
                button
            }
        }
    }
}

/// The workspace switcher, shared by the menu bar (with ⌘⌥1–9 shortcuts) and the
/// sidebar toolbar menu (without, so the two surfaces don't register duplicate
/// shortcuts for the same keys).
struct WorkspaceMenuItems: View {
    var model: AppModel
    var showShortcuts: Bool

    var body: some View {
        let workspaces = model.workspaces
        ForEach(Array(workspaces.enumerated()), id: \.element.id) { index, workspace in
            let button = Button {
                model.switchWorkspace(to: workspace.id)
            } label: {
                // An ephemeral one says so: it is here because a file was
                // opened from the Finder, and it goes when the app does.
                let name = workspace.isEphemeral ? "\(workspace.name) — Unsaved" : workspace.name
                if workspace.id == model.activeWorkspaceID {
                    Label(name, systemImage: "checkmark")
                } else {
                    Text(name)
                }
            }
            if showShortcuts, index < 9,
               let key = "\(index + 1)".first {
                button.keyboardShortcut(KeyEquivalent(key), modifiers: [.command, .option])
            } else {
                button
            }
        }
        Divider()
        // Greyed out rather than hidden when it doesn't apply: the item stays
        // where you left it, and the action itself says when it is available.
        ActionItem(model: model, id: "workspace.keep")
        ActionItem(model: model, id: "workspace.create")
        ActionItem(model: model, id: "workspace.rename")
        ActionItem(model: model, id: "workspace.delete")
    }
}

/// Menu content is rebuilt when the menu opens, so it reflects the live selection.
private struct ActionMenuItems: View {
    var model: AppModel
    var body: some View {
        let groups = model.actionGroups(for: .menuBar)
        if groups.isEmpty {
            Button("No Actions") {}.disabled(true)
        } else {
            ForEach(groups) { group in
                Section {
                    ForEach(group.actions) { action in
                        // Actions carrying a key equivalent register it
                        // window-wide from here — the menu bar is what makes
                        // shortcuts global.
                        if let shortcut = action.shortcut?.keyboardShortcut {
                            Button(action.title) { model.run(action) }
                                .keyboardShortcut(shortcut)
                        } else {
                            Button(action.title) { model.run(action) }
                        }
                    }
                } header: {
                    if let title = group.title { Text(title) }
                }
            }
        }
    }
}

