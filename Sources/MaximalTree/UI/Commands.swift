import SwiftUI
import MaximalTreeKit

/// Menu-bar surface for the action registry. One `Actions` menu lists whatever
/// applies to the current selection, plus the command-palette entry point.
struct AppCommands: Commands {
    var model: AppModel

    var body: some Commands {
        // Pane commands live in the system View menu, next to its layout controls.
        CommandGroup(after: .sidebar) {
            Divider()
            Button(model.isZenMode ? "Exit Zen Mode" : "Enter Zen Mode") {
                model.toggleZenMode()
            }
            .keyboardShortcut("z", modifiers: [.command, .control])
            Divider()
            Button("Split Right") { model.splitPaneRight() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Split Down") { model.splitPaneDown() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Close Pane") { model.closeActivePane() }
                .keyboardShortcut("w", modifiers: [.command, .control])
                .disabled(!model.navigation.canClosePane)
            Divider()
        }
        CommandMenu("Workspace") {
            WorkspaceMenuItems(model: model, showShortcuts: true)
        }
        CommandMenu("Navigate") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.navigation.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.navigation.canGoForward)
            Divider()
            Button("New Tab") { model.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Close Tab") { model.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.navigation.tabs.count <= 1)
        }
        CommandMenu("Actions") {
            Button("Find Anything…") { model.openFinder() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Find File…") { model.openFinder(scope: "files") }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Run Action…") { model.openFinder(scope: "actions") }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Divider()
            ActionMenuItems(model: model)
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
                if workspace.id == model.activeWorkspaceID {
                    Label(workspace.name, systemImage: "checkmark")
                } else {
                    Text(workspace.name)
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
        Button("New Workspace…") { model.showingCreateWorkspace = true }
        Button("Rename Workspace…") { model.showingRenameWorkspace = true }
        Button("Delete Workspace", role: .destructive) { model.deleteActiveWorkspace() }
            .disabled(workspaces.count <= 1)
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
                        if let shortcut = action.shortcut {
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

