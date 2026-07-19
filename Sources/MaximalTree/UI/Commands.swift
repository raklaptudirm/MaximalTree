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
            Button("Command Palette…") { model.paletteVisible = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
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
        let actions = model.applicableActions()
        if actions.isEmpty {
            Button("No Actions") {}.disabled(true)
        } else {
            ForEach(actions) { action in
                Button(action.title) { model.run(action) }
            }
        }
    }
}

/// Xcode-style command palette: fuzzy-filter the applicable actions, arrow to
/// navigate, Return to run, Esc to dismiss. Same registry as the menu bar.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var results: [Action] {
        let actions = model.applicableActions()
        guard !query.isEmpty else { return actions }
        return actions
            .compactMap { action in fuzzyScore(query, action.title).map { ($0, action) } }
            .sorted { $0.0 > $1.0 }
            .map(\.1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Run action…", text: $query)
                .textFieldStyle(.plain)
                .font(.title2)
                .padding(14)
                .focused($focused)
                .onSubmit(runSelected)
                .onChange(of: query) { index = 0 }

            Divider()

            if results.isEmpty {
                Text("No matching actions")
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, action in
                            HStack(spacing: 10) {
                                Image(systemName: action.systemImage ?? "command")
                                    .frame(width: 20)
                                    .foregroundStyle(.secondary)
                                Text(action.title)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(i == index ? Color.accentColor.opacity(0.22) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                            .onTapGesture { index = i; runSelected() }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 540)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        .shadow(radius: 30, y: 10)
        .onAppear { focused = true; index = 0 }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onExitCommand { model.paletteVisible = false }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        index = min(max(index + delta, 0), results.count - 1)
    }

    private func runSelected() {
        guard results.indices.contains(index) else { return }
        model.run(results[index])
    }
}

/// Cheap subsequence fuzzy match: nil if `query` isn't a subsequence of `text`,
/// otherwise a score that rewards contiguous and early matches.
func fuzzyScore(_ query: String, _ text: String) -> Int? {
    let q = Array(query.lowercased())
    let t = Array(text.lowercased())
    guard !q.isEmpty else { return 0 }

    var qi = 0
    var score = 0
    var lastMatch = -2
    for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
        score += (ti == lastMatch + 1) ? 3 : 1   // contiguity bonus
        score += max(0, 5 - ti)                    // earliness bonus
        lastMatch = ti
        qi += 1
    }
    return qi == q.count ? score : nil
}
