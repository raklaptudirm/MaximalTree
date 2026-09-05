import AppKit
import SwiftUI
import MaximalTreeKit
import MaximalEditorKit

/// A repository at a glance: where the branch stands, and what has changed.
///
/// The canvas a repo node gets instead of the generic list of its four child
/// folders, which said nothing a sidebar row didn't. Content only, in the way
/// the app means it — the operations are the same actions the menu, the finder
/// and the keys run, reached here by pointing at a row.
struct RepoCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    // Held outside the view so the actions its keys run can reach it.
    private var model: RepoCanvasModel { GitUIState.shared.canvas(for: nodeID) }

    var body: some View {
        VStack(spacing: 0) {
            changes
            // The message belongs beside what it describes, not in a panel
            // across the window: writing one is reading the diff and saying
            // what it did, and the two were a glance apart.
            if let repo = GitActions.repo(of: nodeID),
               !(model.status.isClean && model.status.branch == nil) {
                Divider()
                CommitBox(repo: repo, model: model)
            }
        }
        .task(id: nodeID) { model.attach(to: nodeID, host: host) }
        // The provider re-reads its children after a write; this canvas reads
        // its own status, so it has to be told the same news.
        .onChange(of: host.children(of: nodeID)) { _, _ in model.reload() }
    }

    private var changes: some View {
        Group {
            if model.status.isClean && model.status.branch == nil {
                ContentUnavailableView("Not a Repository", systemImage: "arrow.triangle.branch")
            } else {
                ScrollViewReader { proxy in
                    List(selection: Binding(
                        get: { model.selected },
                        set: { model.selected = $0 })) {
                        BranchHeader(status: model.status)
                        section("Staged", model.status.staged, staged: true)
                        section("Unstaged", model.status.unstaged, staged: false)
                        if model.status.isClean {
                            Text("Nothing to commit")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: model.selected) { _, selection in
                        if let selection { proxy.scrollTo(selection) }
                    }
                }
            }
        }
        .background(RepoFocusCatcher(model: model))
    }

    @ViewBuilder
    private func section(_ title: String, _ entries: [GitStatus.Entry],
                         staged: Bool) -> some View {
        if !entries.isEmpty {
            Section("\(title) (\(entries.count))") {
                ForEach(entries) { entry in
                    ChangedFileRow(entry: entry, staged: staged) {
                        model.run(staged ? "git.unstage" : "git.stage", on: entry)
                    }
                    .tag(entry.id)
                }
            }
        }
    }
}

/// Where the branch stands relative to where it came from.
private struct BranchHeader: View {
    let status: GitStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.green)
            Text(status.branch ?? "detached")
                .font(.headline)
            if let upstream = status.upstream {
                Text(upstream).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Only shown when there is something to say: a branch level with
            // its upstream needs no numbers.
            if status.ahead > 0 {
                Label("\(status.ahead)", systemImage: "arrow.up")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if status.behind > 0 {
                Label("\(status.behind)", systemImage: "arrow.down")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ChangedFileRow: View {
    let entry: GitStatus.Entry
    let staged: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(String(entry.code))
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 14)
            Text(entry.path).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
            Button(action: toggle) {
                Image(systemName: staged ? "minus.circle" : "plus.circle")
            }
            .buttonStyle(.borderless)
            .help(staged ? "Unstage" : "Stage")
        }
        .contentShape(Rectangle())
    }

    private var color: Color {
        switch entry.code {
        case "A", "?": return .green
        case "D": return .red
        case "R", "C": return .blue
        default: return .orange
        }
    }
}

/// What the canvas is showing and what the keys move.
///
/// The selection lives here rather than in the view because the keys need it:
/// a canvas that declares `j` has to have something for `j` to move, which is
/// exactly why git's list canvas declared no keys when the terminal and the
/// page got theirs — it had no selection of its own to move.
@MainActor
@Observable
final class RepoCanvasModel {
    /// Which part of the canvas the keys are working on.
    ///
    /// The changes and the commit message are one surface — the core resolves
    /// a canvas's keys once, by the node its pane shows, so they cannot have a
    /// map each. What they can have is a *place*: the motions mean "next
    /// thing" in both, and crossing the boundary is what `j` past the last
    /// change and `k` at the top of the message do.
    enum Focus: Equatable { case changes, message }

    private(set) var status = GitStatus()
    /// The row the keys are on, by `Entry.id`.
    var selected: String?
    private(set) var focus: Focus = .changes

    /// The message editor, so the keys can hand it the keyboard and ask where
    /// its caret is. Not observed: it is a handle, not state to draw from.
    @ObservationIgnored var editor: EditorController?
    /// The view that holds the keyboard for the change list.
    @ObservationIgnored weak var catcher: NSView?

    @ObservationIgnored private var repo: String?
    @ObservationIgnored private var host: HostContext?

    /// Every changed file, staged then unstaged — the order the keys walk.
    var rows: [(entry: GitStatus.Entry, staged: Bool)] {
        status.staged.map { ($0, true) } + status.unstaged.map { ($0, false) }
    }

    /// Sets the status without reading a repository, so the key handling can
    /// be exercised without one on disk.
    func setStatusForTesting(_ status: GitStatus) {
        self.status = status
        if let selected, !rows.contains(where: { $0.entry.id == selected }) {
            self.selected = rows.first?.entry.id
        }
    }

    func attach(to id: NodeID, host: HostContext) {
        self.host = host
        repo = GitRef(uri: id.uri)?.repo
        reload()
    }

    func reload() {
        guard let repo else { return }
        Task {
            let fresh = await Task.detached { GitStatus.read(repo) }.value
            await MainActor.run {
                status = fresh
                // A row that has gone — staged, discarded — must not leave the
                // selection pointing at nothing, or the next `j` starts over.
                if let selected, !rows.contains(where: { $0.entry.id == selected }) {
                    self.selected = rows.first?.entry.id
                }
            }
        }
    }

    /// Run one of the git actions against a row.
    ///
    /// Through the host by id, not by calling git here: these are the same
    /// operations the menu and the keys offer, and there should be one of each.
    func run(_ actionID: String, on entry: GitStatus.Entry) {
        guard let repo, let host else { return }
        let kind: GitRef.Kind = actionID == "git.unstage" ? .stagedFile : .unstagedFile
        guard let target = GitRef(repo: repo, kind: kind, id: entry.path).nodeID else { return }
        host.select([target])
        host.perform(actionID)
        // The action re-reads the repository; this canvas reads its own status.
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            reload()
        }
    }

    // MARK: Keys

    func move(_ offset: Int) {
        let all = rows.map(\.entry.id)
        // Down off the end of the changes is into the message — the next
        // thing, which is what the motion says.
        guard !all.isEmpty else {
            if offset > 0 { focusMessage() }
            return
        }
        guard let selected, let index = all.firstIndex(of: selected) else {
            self.selected = offset > 0 ? all.first : all.last
            return
        }
        let next = index + offset
        if next >= all.count { focusMessage(); return }
        self.selected = all[max(next, 0)]
    }

    // MARK: Crossing into the message and back

    func focusMessage() {
        focus = .message
        editor?.focus()
    }

    /// Back to the changes, on the row the message sits under.
    func focusChanges() {
        focus = .changes
        if selected == nil { selected = rows.last?.entry.id }
        catcher?.window?.makeFirstResponder(catcher)
    }

    /// Whether the caret is on the message's first line — the edge that `k`
    /// leaves from, the way `h` off the leftmost surface carries on into the
    /// sidebar rather than stopping.
    var messageCaretIsAtTop: Bool {
        guard let (text, selection) = editor?.textAndSelection() else { return true }
        let ns = text as NSString
        let caret = min(max(selection.location, 0), ns.length)
        return ns.lineRange(for: NSRange(location: caret, length: 0)).location == 0
    }

    /// Run an editor command on the message, by id.
    ///
    /// Through the host rather than by reaching into the editor: these are
    /// actions, and the git canvas has no more right to call them directly
    /// than the menu does.
    func editMessage(_ command: EditCommand, count: Int) {
        host?.perform(EditorKeys.id(for: command), count: count)
    }

    func moveToEdge(last: Bool) {
        focus = .changes
        selected = last ? rows.last?.entry.id : rows.first?.entry.id
    }

    /// The row under the keys, if there is one.
    var current: (entry: GitStatus.Entry, staged: Bool)? {
        rows.first { $0.entry.id == selected }
    }

    func stageOrUnstage() {
        guard let current else { return }
        run(current.staged ? "git.unstage" : "git.stage", on: current.entry)
    }

    func open() {
        guard let current, let repo, let host else { return }
        let kind: GitRef.Kind = current.staged ? .stagedFile : .unstagedFile
        guard let target = GitRef(repo: repo, kind: kind, id: current.entry.path).nodeID
        else { return }
        host.open(target)
    }

    /// Commit what is staged, with what has been written.
    ///
    /// Nothing to say is nothing to do — the same condition that greys the
    /// button out, rather than handing git an empty message and reporting
    /// its complaint.
    func commit() {
        guard let repo, !GitUIState.shared.message(for: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        host?.perform("git.commit")
    }

    func discard() {
        guard let current, !current.staged else { return }
        run("git.discard", on: current.entry)
    }
}

/// Where a commit message is written.
///
/// It lived in the inspector because a canvas is content and a plugin has no
/// window to put a sheet on — but the message is content too, and reading a
/// diff to say what it did across two surfaces was the wrong shape.
///
/// The app's editor rather than a plain text field, so the motions inside it
/// are the motions everywhere else: `i` to type, escape to stop, `w` and `b`
/// and `d` doing what they do in a document. Committing is `git.commit`, the
/// same action the menu and the keys run; this is only where the text lives.
private struct CommitBox: View {
    let repo: String
    let model: RepoCanvasModel
    @Environment(HostContext.self) private var host
    @State private var state = GitUIState.shared
    @State private var controller = EditorController()

    private var message: String { state.message(for: repo) }
    private var isEmpty: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Commit message")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { host.perform("git.commit") } label: {
                    Label("Commit", systemImage: "checkmark.seal")
                }
                .disabled(isEmpty)
                .controlSize(.small)
            }
            MaximalEditor(
                text: Binding(get: { state.message(for: repo) },
                              set: { state.setMessage($0, for: repo) }),
                style: .plain(),
                controller: controller)
                // Ten lines at the plain style's size: a summary, a blank,
                // and a body worth writing — 88pt held five, which is a
                // subject line and an apology.
                .frame(height: 160)
                // Clipped to its own border: the editor draws a gutter and a
                // selected-line band edge to edge, and without this they carry
                // on past the box they are supposed to be inside.
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5).stroke(
                        model.focus == .message ? Color.accentColor
                                                : Color.secondary.opacity(0.25)))
        }
        .padding(10)
        // The model drives the keyboard: it is what `j` off the last change
        // and `k` at the top of the message act on.
        .onAppear { model.editor = controller }
    }
}

/// Gives the repo canvas a first responder.
///
/// A pane is focused by finding a leaf view that takes the keyboard, and a
/// SwiftUI `List` is not one — it has subviews of its own. Without this,
/// moving into the pane would focus nothing, the app would go on thinking the
/// keyboard was wherever it last was, and the canvas's keys would never be
/// the ones consulted.
///
/// It handles no keys itself. Those are actions now, declared on the
/// contribution and resolved by the core.
struct RepoFocusCatcher: NSViewRepresentable {
    /// Handed to the model, which needs something to give the keyboard back
    /// to when the keys leave the commit message.
    let model: RepoCanvasModel

    func makeNSView(context: Context) -> Catcher {
        let view = Catcher()
        model.catcher = view
        return view
    }

    func updateNSView(_ view: Catcher, context: Context) { model.catcher = view }

    final class Catcher: NSView {
        override var acceptsFirstResponder: Bool { true }
    }
}
