import AppKit
import SwiftUI
import MaximalTreeKit

/// What you can do to a repository.
///
/// Actions rather than `GraphMutation`s. The generic vocabulary is rename,
/// delete and the like — things the host understands about any node — and
/// staging is not one of them: nothing about "stage this" generalises to a
/// bookmark or a terminal session. Growing a git shape into the mutation
/// protocol would make every provider carry it.
///
/// Every one of them ends by telling the host what changed, because a write
/// that leaves the tree showing the old answer is worse than no write at all.
/// The repository is the unit: `git add` moves a file between two lists and
/// changes the branch's ahead count, so the whole subtree is re-read rather
/// than each affected node guessed at.
@MainActor
enum GitActions {
    /// The repo a node belongs to, whatever kind of node it is.
    static func repo(of id: NodeID) -> String? {
        GitRef(uri: id.uri)?.repo
    }

    /// The path within the repo a changed-file node stands for.
    static func path(of id: NodeID) -> String? {
        guard let ref = GitRef(uri: id.uri) else { return nil }
        switch ref.kind {
        case .stagedFile, .unstagedFile: return ref.id
        case .commitFile: return ref.commitAndPath?.path
        default: return nil
        }
    }

    /// Re-read everything under a repository.
    ///
    /// Coarse on purpose. A commit changes the staged list, the unstaged list,
    /// the branch it was on and the commit list at once; naming each would be
    /// four chances to miss one, and the lists are small.
    static func refresh(_ repo: String, _ host: HostContext) {
        let roots: [GitRef.Kind] = [.repo, .staged, .unstaged, .branches, .commits]
        let changed = roots.compactMap { GitRef(repo: repo, kind: $0).nodeID }
            .map { NodeChange.childrenChanged($0) }
        host.notify(changed)
    }

    /// Run a write and say so when it fails.
    ///
    /// Off the main actor: git talks to the disk and the network, and `pull`
    /// on a slow remote would otherwise stop the app. The report comes back
    /// here, because that is where the reader is.
    static func run(_ repo: String, _ args: [String], _ host: HostContext,
                    describing what: String) {
        Task {
            let result = await Task.detached { Git.perform(repo, args) }.value
            await MainActor.run {
                switch result {
                case .success:
                    refresh(repo, host)
                case .failure(let failure):
                    GitUIState.shared.report(what, failure.message)
                }
            }
        }
    }
}

/// What the git UI is holding that isn't in the graph: a commit message being
/// typed, and the last thing that went wrong.
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
    /// The last failure, with the operation that produced it.
    var failure: (operation: String, message: String)?

    func message(for repo: String) -> String { messages[repo] ?? "" }
    func setMessage(_ text: String, for repo: String) { messages[repo] = text }

    func report(_ operation: String, _ message: String) {
        failure = (operation, message)
    }

    func clearFailure() { failure = nil }
}


// MARK: - The actions themselves

extension GitPlugin {
    /// Registered in one place so the vocabulary can be read at a glance.
    @MainActor
    func registerActions(with registry: PluginRegistry) {
        // MARK: Staging

        registry.register(action: Action(
            id: "git.stage", title: "Stage", systemImage: "plus.circle",
            appliesTo: .type(TypeID("git.unstagedfile")), scope: .node
        ) { ctx in
            for target in ctx.targets {
                guard let repo = GitActions.repo(of: target),
                      let path = GitActions.path(of: target) else { continue }
                GitActions.run(repo, ["add", "--", path], ctx.host, describing: "Stage")
            }
        })

        registry.register(action: Action(
            id: "git.unstage", title: "Unstage", systemImage: "minus.circle",
            appliesTo: .type(TypeID("git.stagedfile")), scope: .node
        ) { ctx in
            for target in ctx.targets {
                guard let repo = GitActions.repo(of: target),
                      let path = GitActions.path(of: target) else { continue }
                GitActions.run(repo, ["restore", "--staged", "--", path],
                               ctx.host, describing: "Unstage")
            }
        })

        registry.register(action: Action(
            id: "git.stageAll", title: "Stage All", systemImage: "plus.square.on.square",
            appliesTo: .custom { GitActions.isRepoScope($0) }, scope: .container
        ) { ctx in
            guard let repo = ctx.targets.compactMap(GitActions.repo).first else { return }
            GitActions.run(repo, ["add", "-A"], ctx.host, describing: "Stage All")
        })

        // MARK: Throwing work away

        // The one action here that destroys something. Everything else can be
        // undone by another git command; this cannot, so it asks first and
        // names the file it is about to lose.
        registry.register(action: Action(
            id: "git.discard", title: "Discard Changes…", systemImage: "arrow.uturn.backward",
            appliesTo: .type(TypeID("git.unstagedfile")), scope: .node
        ) { ctx in
            let files = ctx.targets.compactMap(GitActions.path)
            guard let repo = ctx.targets.compactMap(GitActions.repo).first,
                  !files.isEmpty,
                  GitActions.confirmDiscard(files) else { return }
            GitActions.run(repo, ["restore", "--"] + files, ctx.host, describing: "Discard")
        })

        // MARK: Committing

        registry.register(action: Action(
            id: "git.commit", title: "Commit", systemImage: "checkmark.seal",
            appliesTo: .custom { ctx in
                guard GitActions.isRepoScope(ctx), let repo = ctx.targets.compactMap(GitActions.repo).first
                else { return false }
                // Nothing to commit, or nothing to say about it, and the
                // action is not available rather than a failure to come.
                return !GitUIState.shared.message(for: repo)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            scope: .container
        ) { ctx in
            guard let repo = ctx.targets.compactMap(GitActions.repo).first else { return }
            let message = GitUIState.shared.message(for: repo)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            GitActions.run(repo, ["commit", "-m", message], ctx.host, describing: "Commit")
            GitUIState.shared.setMessage("", for: repo)
        })

        // MARK: The remote

        for (id, title, image, args) in [
            ("git.fetch", "Fetch", "arrow.down.circle", ["fetch", "--prune"]),
            ("git.pull", "Pull", "arrow.down.to.line", ["pull", "--ff-only"]),
            ("git.push", "Push", "arrow.up.to.line", ["push"]),
        ] as [(String, String, String, [String])] {
            registry.register(action: Action(
                id: id, title: title, systemImage: image,
                appliesTo: .custom { GitActions.isRepoScope($0) }, scope: .container
            ) { ctx in
                guard let repo = ctx.targets.compactMap(GitActions.repo).first else { return }
                GitActions.run(repo, args, ctx.host, describing: title)
            })
        }

        // MARK: Branches and the stash

        registry.register(action: Action(
            id: "git.checkout", title: "Check Out", systemImage: "arrow.triangle.branch",
            appliesTo: .type(TypeID("git.branch")), scope: .node
        ) { ctx in
            guard let target = ctx.targets.first,
                  let repo = GitActions.repo(of: target),
                  let branch = GitRef(uri: target.uri)?.id else { return }
            GitActions.run(repo, ["checkout", branch], ctx.host, describing: "Check Out")
        })

        registry.register(action: Action(
            id: "git.stash", title: "Stash Changes", systemImage: "tray.and.arrow.down",
            appliesTo: .custom { GitActions.isRepoScope($0) }, scope: .container
        ) { ctx in
            guard let repo = ctx.targets.compactMap(GitActions.repo).first else { return }
            GitActions.run(repo, ["stash", "push", "-u"], ctx.host, describing: "Stash")
        })

        registry.register(action: Action(
            id: "git.stashPop", title: "Restore Stashed Changes",
            systemImage: "tray.and.arrow.up",
            appliesTo: .custom { GitActions.isRepoScope($0) }, scope: .container
        ) { ctx in
            guard let repo = ctx.targets.compactMap(GitActions.repo).first else { return }
            GitActions.run(repo, ["stash", "pop"], ctx.host, describing: "Restore Stash")
        })
    }
}

extension GitActions {
    /// Whether this targets the repository as a whole rather than one file in
    /// it — the repo node itself, or one of the lists hanging off it.
    static func isRepoScope(_ ctx: ActionContext) -> Bool {
        guard let target = ctx.targets.first, let ref = GitRef(uri: target.uri) else { return false }
        switch ref.kind {
        case .repo, .staged, .unstaged, .branches, .commits: return true
        default: return false
        }
    }

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
