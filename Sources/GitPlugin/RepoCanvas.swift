import AppKit
import SwiftUI
import MaximalTreeKit

/// A repository at a glance: where the branch stands, and what has changed.
///
/// The canvas a repo node gets instead of the generic list of its four child
/// folders, which said nothing a sidebar row didn't. Content only, in the way
/// the app means it — the operations are the same actions the menu, the finder
/// and the keys run, reached here by pointing at a row.
struct RepoCanvas: View {
    let nodeID: NodeID
    @Environment(HostContext.self) private var host
    @State private var model = RepoCanvasModel()

    var body: some View {
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
        .background(RepoKeyCatcher(model: model))
        .task(id: nodeID) { model.attach(to: nodeID, host: host) }
        // The provider re-reads its children after a write; this canvas reads
        // its own status, so it has to be told the same news.
        .onChange(of: host.children(of: nodeID)) { _, _ in model.reload() }
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
    private(set) var status = GitStatus()
    /// The row the keys are on, by `Entry.id`.
    var selected: String?

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
        guard !all.isEmpty else { return }
        guard let selected, let index = all.firstIndex(of: selected) else {
            self.selected = offset > 0 ? all.first : all.last
            return
        }
        self.selected = all[min(max(index + offset, 0), all.count - 1)]
    }

    func moveToEdge(last: Bool) {
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

    func discard() {
        guard let current, !current.staged else { return }
        run("git.discard", on: current.entry)
    }
}

/// Gives the repo canvas a first responder, so its keys can reach it.
///
/// A leaf `NSView` that takes focus: the app finds the thing to focus in a
/// pane by looking for one of those, and walks up from the first responder to
/// find the canvas that handles keys. A SwiftUI `List` offers neither.
struct RepoKeyCatcher: NSViewRepresentable {
    let model: RepoCanvasModel

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.model = model
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) { view.model = model }

    typealias ViewForTesting = KeyView

    final class KeyView: NSView, CanvasKeyHandling {
        var model: RepoCanvasModel?
        override var acceptsFirstResponder: Bool { true }

        static let bindings: [CanvasKeyBinding] = [
            .init("j", title: "Next change"),
            .init("k", title: "Previous change"),
            .init("g g", title: "First change"),
            .init("G", title: "Last change"),
            .init("RET", title: "Open diff"),
            .init("s", title: "Stage or unstage"),
            .init("x", title: "Discard change"),
        ]

        var keyBindings: [CanvasKeyBinding] { Self.bindings }

        private var pendingG = false

        func handleKey(_ key: String, control: Bool, mode: KeyMode) -> KeyMode? {
            guard !control, let model else { return nil }
            if pendingG {
                pendingG = false
                guard key == "g" else { return nil }
                model.moveToEdge(last: false)
                return mode
            }
            switch key {
            case "j": model.move(1)
            case "k": model.move(-1)
            case "g": pendingG = true
            case "G": model.moveToEdge(last: true)
            case "RET": model.open()
            case "s": model.stageOrUnstage()
            case "x": model.discard()
            default: return nil
            }
            return mode
        }
    }
}


/// The repo canvas's key view, by a name a test can say.
typealias RepoKeyCatcherViewForTesting = RepoKeyCatcher.KeyView
