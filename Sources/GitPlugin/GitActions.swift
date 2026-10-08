import AppKit
import SwiftUI
import MaximalTreeKit
import MaximalEditorKit

// The repository's writes are the core's (Core/GitWrites.swift). What is
// here is what needs this window: the canvas's state and keys, and the two
// writes that ask the reader something first — the commit's message, which is
// typed in the canvas, and whether to throw work away.

/// What the git UI is holding that isn't in the graph: a commit message being
/// typed, and each repository canvas's place. A failed write is not here: it
/// is reported by the host, as every command's failure is.
///
/// The same pattern as the typst plugin's `TypstUIState` — a canvas stays
/// content-only and actions need somewhere to put state that outlives a view.
@MainActor
@Observable
final class GitUIState {
    static let shared = GitUIState()

    /// Per repository, because two can be open at once and a message typed
    /// into one is not a message for the other.
    var messages: [String: String] = [:]

    /// One canvas model per repository node.
    ///
    /// The canvas used to own this as view state, which was fine while it
    /// handled its own keys. An action cannot reach a view's `@State`, so the
    /// selection lives here — the same reason the typst plugin and the web
    /// plugin keep theirs outside their canvases.
    private var canvases: [NodeID: RepoCanvasModel] = [:]

    func canvas(for id: NodeID) -> RepoCanvasModel {
        if let existing = canvases[id] { return existing }
        let model = RepoCanvasModel()
        canvases[id] = model
        return model
    }

    func message(for repo: String) -> String { messages[repo] ?? "" }
    func setMessage(_ text: String, for repo: String) { messages[repo] = text }
}


// MARK: - The actions themselves

extension GitPlugin {
    /// Registered in one place so the vocabulary can be read at a glance.
    @MainActor
    func registerActions(with registry: PluginRegistry) {
        // MARK: Moving and acting inside the repository canvas
        //
        // The canvas has a selection, so these are about *that* row rather
        // than about the node the pane is showing. They reach it through the
        // shared state the canvas keeps, which is why that stopped being view
        // state when the keys became actions.
        for item in GitActions.canvasCommands {
            registry.register(action: Action(
                id: item.id, title: item.title, systemImage: item.image,
                appliesTo: .type(TypeID("git.repo")),
                // Real operations, and searchable, but a list of "next change"
                // in the menu bar would bury what belongs there.
                scope: .container, surfaces: [.palette]
            ) { ctx in
                guard let target = ctx.targets.first else { return }
                item.run(GitUIState.shared.canvas(for: target), ctx.count)
            })
        }

        // MARK: The two that ask first

        // The message is the one typed in the repository canvas. Committing
        // with it is the core's (`git.commitMessage`, for whatever has a
        // message some other way).
        registry.register(action: Action(
            id: "git.commit", title: "Commit", systemImage: "checkmark.seal",
            appliesTo: .custom { ctx in
                guard GitActions.isRepoScope(ctx),
                      let repo = ctx.targets.compactMap(GitActions.repo(of:)).first
                else { return false }
                // Nothing to commit, or nothing to say about it, and the
                // action is not available rather than a failure to come.
                return !GitUIState.shared.message(for: repo)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            scope: .container
        ) { ctx in
            guard let repo = ctx.targets.compactMap(GitActions.repo(of:)).first else { return }
            try await GitActions.commit(repo, message: GitUIState.shared.message(for: repo), ctx.host)
            // Only once it took: a refused commit leaves what was written.
            GitUIState.shared.setMessage("", for: repo)
        })

        // The one write that destroys something. Everything else can be undone
        // by another git command; this cannot, so it asks first and names the
        // file it is about to lose. Discarding is the core's
        // (`git.discardFiles`); asking is this window's.
        registry.register(action: Action(
            id: "git.discard", title: "Discard Changes…", systemImage: "arrow.uturn.backward",
            appliesTo: .type(TypeID("git.unstagedfile")), scope: .node
        ) { ctx in
            let files = ctx.targets.compactMap(GitActions.path(of:))
            guard let repo = ctx.targets.compactMap(GitActions.repo(of:)).first,
                  !files.isEmpty, GitActions.confirmDiscard(files) else { return }
            try await GitActions.discard(repo, files: files, ctx.host)
        })
    }
}

extension GitActions {
    /// Asks before throwing work away, naming what would go.
    ///
    /// A sheet would be the app's to present and this is a plugin, which has
    /// no window of its own to hang one on — so it is an alert, which AppKit
    /// will run over whatever is in front.
    static func confirmDiscard(_ files: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = files.count == 1
            ? "Discard changes to \(files[0])?"
            : "Discard changes to \(files.count) files?"
        alert.informativeText = "This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}


extension GitActions {
    /// What the repository canvas can do to the change under the cursor.
    ///
    /// Keys and actions in one table, so the binding and the thing it runs are
    /// written next to each other and cannot drift apart.
    static let canvasCommands: [(id: String, title: String, image: String,
                                 key: String,
                                 run: @MainActor (RepoCanvasModel, Int) -> Void)] = [
        ("git.changeDown", "Next Change", "chevron.down", "j",
         { model, count in
            // The same motion in both halves of the canvas: over the changes
            // it moves the selection, in the message it moves the caret.
            if model.focus == .message { model.editMessage(.down, count: count) }
            else { for _ in 0..<count { model.move(1) } } }),
        ("git.changeUp", "Previous Change", "chevron.up", "k",
         { model, count in
            guard model.focus == .message else {
                for _ in 0..<count { model.move(-1) }
                return
            }
            // At the top of the message there is nowhere further up inside
            // it, so up leaves — the way `h` off the leftmost surface carries
            // on into the sidebar rather than stopping at the edge.
            if model.messageCaretIsAtTop { model.focusChanges() }
            else { model.editMessage(.up, count: count) } }),
        ("git.changeFirst", "First Change", "chevron.up.2", "g g",
         { model, _ in
            if model.focus == .message { model.editMessage(.firstLine, count: 1) }
            else { model.moveToEdge(last: false) } }),
        ("git.changeLast", "Last Change", "chevron.down.2", "G",
         { model, _ in
            if model.focus == .message { model.editMessage(.lastLine, count: 1) }
            else { model.moveToEdge(last: true) } }),
        // Return does the thing the keys are on: over a change it opens it,
        // in the message it commits. In insert mode it is still a newline —
        // the core dispatches no keys while you are typing — so this is the
        // one you press after escape, having written what you mean.
        ("git.openChange", "Open Change or Commit", "doc.text.magnifyingglass", "RET",
         { model, _ in
            if model.focus == .message { model.commit() } else { model.open() } }),
        // The remaining verbs are the changes', and mean nothing to a message
        // — least of all discard, which would throw a file away while you
        // described it.
        ("git.toggleStage", "Stage or Unstage", "plusminus", "s",
         { model, _ in if model.focus == .changes { model.stageOrUnstage() } }),
        ("git.discardChange", "Discard Change", "arrow.uturn.backward", "x",
         { model, _ in if model.focus == .changes { model.discard() } }),
    ]

    /// The keys the repository canvas claims.
    ///
    /// The editor's first, this canvas's second: a canvas gets one map, and
    /// the message in it is a real editor, so everything an editor does has to
    /// be reachable. Where the two want the same key — `j`, `k`, `g g`, `G`,
    /// `x` — this canvas wins and hands the motion on itself, because only it
    /// knows whether the keyboard is over a diff or inside the message.
    static var canvasKeys: [SurfaceKey] {
        EditorKeys.keys + canvasCommands.map { SurfaceKey($0.key, $0.id) }
    }
}
