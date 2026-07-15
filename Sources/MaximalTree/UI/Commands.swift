import SwiftUI
import MaximalTreeKit

/// Menu-bar surface for the action registry. One `Actions` menu lists whatever
/// applies to the current selection, plus the command-palette entry point.
struct AppCommands: Commands {
    var model: AppModel

    var body: some Commands {
        CommandMenu("Actions") {
            Button("Command Palette…") { model.paletteVisible = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            ActionMenuItems(model: model)
        }
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
