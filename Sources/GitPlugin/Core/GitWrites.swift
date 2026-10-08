import Foundation
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
///
/// And every one of them waits for git and throws what it said when it
/// refuses. That is how a failure reaches the reader whatever is in front of
/// them: the host reports a command's failure — the app in its alert, `mtree`
/// on standard error — so a rejected push needs no canvas to say so. Waiting
/// also puts git's writes in the command queue, in order: a stage finishes
/// before the commit after it starts.
@MainActor
enum GitActions {
    /// What git said when it refused, under the name of what was asked.
    struct Failed: LocalizedError {
        let operation: String
        let message: String
        var errorDescription: String? { "\(operation) failed: \(message)" }
    }

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

    /// Whether this targets the repository as a whole rather than one file in
    /// it — the repo node itself, or one of the lists hanging off it.
    static func isRepoScope(_ ctx: ActionContext) -> Bool {
        guard let target = ctx.targets.first, let ref = GitRef(uri: target.uri) else { return false }
        switch ref.kind {
        case .repo, .staged, .unstaged, .branches, .commits: return true
        default: return false
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

    /// Run a write, and throw what git said if it refused.
    ///
    /// Off the main actor: git talks to the disk and the network, and `pull`
    /// on a slow remote would otherwise stop the app. The repository is re-read
    /// either way — a pull that conflicted has still changed things.
    static func run(_ repo: String, _ args: [String], _ host: HostContext,
                    describing what: String) async throws {
        let result = await Task.detached { Git.perform(repo, args) }.value
        refresh(repo, host)
        if case .failure(let failure) = result {
            throw Failed(operation: what, message: failure.message)
        }
    }

    /// Commit what is staged with `message`. Nothing to say is nothing to do.
    static func commit(_ repo: String, message: String, _ host: HostContext) async throws {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        try await run(repo, ["commit", "-m", message], host, describing: "Commit")
    }

    /// Throw away the working copy's changes to `files`. Asks nothing: a shell
    /// that offers this asks first (see the Mac's `git.discard`).
    static func discard(_ repo: String, files: [String], _ host: HostContext) async throws {
        guard !files.isEmpty else { return }
        try await run(repo, ["restore", "--"] + files, host, describing: "Discard")
    }

    // MARK: - Registered

    /// Every write that needs nothing but git: staging, the remote, branches
    /// and the stash as actions, and committing and discarding as commands
    /// that take what a shell would have asked the reader for.
    static func registerCore(with registry: CoreRegistry) {
        // MARK: Staging

        registry.register(action: Action(
            id: "git.stage", title: "Stage", systemImage: "plus.circle",
            appliesTo: .type(TypeID("git.unstagedfile")), scope: .node
        ) { ctx in
            for target in ctx.targets {
                guard let repo = GitActions.repo(of: target), let path = GitActions.path(of: target) else { continue }
                try await run(repo, ["add", "--", path], ctx.host, describing: "Stage")
            }
        })

        registry.register(action: Action(
            id: "git.unstage", title: "Unstage", systemImage: "minus.circle",
            appliesTo: .type(TypeID("git.stagedfile")), scope: .node
        ) { ctx in
            for target in ctx.targets {
                guard let repo = GitActions.repo(of: target), let path = GitActions.path(of: target) else { continue }
                try await run(repo, ["restore", "--staged", "--", path], ctx.host, describing: "Unstage")
            }
        })

        registry.register(action: Action(
            id: "git.stageAll", title: "Stage All", systemImage: "plus.square.on.square",
            appliesTo: .custom { isRepoScope($0) }, scope: .container
        ) { ctx in
            guard let repo = ctx.targets.compactMap(GitActions.repo(of:)).first else { return }
            try await run(repo, ["add", "-A"], ctx.host, describing: "Stage All")
        })

        // MARK: The remote

        for (id, title, image, args) in [
            ("git.fetch", "Fetch", "arrow.down.circle", ["fetch", "--prune"]),
            ("git.pull", "Pull", "arrow.down.to.line", ["pull", "--ff-only"]),
            ("git.push", "Push", "arrow.up.to.line", ["push"]),
        ] as [(String, String, String, [String])] {
            registry.register(action: Action(
                id: id, title: title, systemImage: image,
                appliesTo: .custom { isRepoScope($0) }, scope: .container
            ) { ctx in
                guard let repo = ctx.targets.compactMap(GitActions.repo(of:)).first else { return }
                try await run(repo, args, ctx.host, describing: title)
            })
        }

        // MARK: Branches and the stash

        registry.register(action: Action(
            id: "git.checkout", title: "Check Out", systemImage: "arrow.triangle.branch",
            appliesTo: .type(TypeID("git.branch")), scope: .node
        ) { ctx in
            guard let target = ctx.targets.first, let repo = GitActions.repo(of: target),
                  let branch = GitRef(uri: target.uri)?.id else { return }
            try await run(repo, ["checkout", branch], ctx.host, describing: "Check Out")
        })

        registry.register(action: Action(
            id: "git.stash", title: "Stash Changes", systemImage: "tray.and.arrow.down",
            appliesTo: .custom { isRepoScope($0) }, scope: .container
        ) { ctx in
            guard let repo = ctx.targets.compactMap(GitActions.repo(of:)).first else { return }
            try await run(repo, ["stash", "push", "-u"], ctx.host, describing: "Stash")
        })

        registry.register(action: Action(
            id: "git.stashPop", title: "Restore Stashed Changes",
            systemImage: "tray.and.arrow.up",
            appliesTo: .custom { isRepoScope($0) }, scope: .container
        ) { ctx in
            guard let repo = ctx.targets.compactMap(GitActions.repo(of:)).first else { return }
            try await run(repo, ["stash", "pop"], ctx.host, describing: "Restore Stash")
        })

        // MARK: What a shell asks the reader for first

        registry.register(GitCommit())
        registry.register(GitDiscard())
    }
}

/// Commit what is staged in `repo` with `message` — what the Mac's `git.commit`
/// does with the message typed in the repository canvas, for whatever has a
/// message some other way.
struct GitCommit: Command {
    struct Input: Codable, Sendable {
        var repo: String
        var message: String
    }

    static let id = "git.commitMessage"

    @MainActor
    func run(_ input: Input, in context: ActionContext) async throws -> NoAnswer {
        try await GitActions.commit(input.repo, message: input.message, context.host)
        return NoAnswer()
    }
}

/// Throw away the changes to `files` in `repo`. Listed nowhere, and asks
/// nothing: whatever reaches it by id has said exactly which files, which is
/// the asking. The Mac's `git.discard` confirms and then does this.
struct GitDiscard: Command {
    struct Input: Codable, Sendable {
        var repo: String
        var files: [String]
    }

    static let id = "git.discardFiles"

    @MainActor
    func run(_ input: Input, in context: ActionContext) async throws -> NoAnswer {
        try await GitActions.discard(input.repo, files: input.files, context.host)
        return NoAnswer()
    }
}
