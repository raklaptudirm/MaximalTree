import Foundation
import SwiftUI
import MaximalTreeKit
import MaximalEditorKit

// MARK: - URI model

/// A git object encoded as a canonicalizable `git://` NodeID. Structure:
///   `git://<kind>/<id>?repo=<absolute-repo-path>`
/// The `kind` is the URL host (always alphanumeric), the `id` (sha / branch name /
/// "sha/filepath") is the URL path, and the repo path rides in the query so it never
/// collides with the object path. Built and parsed through `URLComponents`, which is
/// exactly what `NodeID` canonicalization uses — so the form is stable/idempotent.
struct GitRef: Equatable {
    enum Kind: String {
        case repo, branches, commits, branch, commit, staged, unstaged
        case commitFile = "commitfile"
        /// A file with staged changes: what committing would record.
        case stagedFile = "stagedfile"
        /// A file changed since it was staged: what committing would miss.
        case unstagedFile = "unstagedfile"
    }

    let repo: String
    let kind: Kind
    let id: String?

    init(repo: String, kind: Kind, id: String? = nil) {
        self.repo = repo
        self.kind = kind
        self.id = id
    }

    init?(uri: String) {
        guard let c = URLComponents(string: uri), c.scheme == "git",
              let host = c.host, let kind = Kind(rawValue: host),
              let repo = c.queryItems?.first(where: { $0.name == "repo" })?.value
        else { return nil }
        let path = c.path.hasPrefix("/") ? String(c.path.dropFirst()) : c.path
        self.init(repo: repo, kind: kind, id: path.isEmpty ? nil : path)
    }

    var uri: String {
        var c = URLComponents()
        c.scheme = "git"
        c.host = kind.rawValue
        if let id, !id.isEmpty { c.path = "/" + id }
        c.queryItems = [URLQueryItem(name: "repo", value: repo)]
        return c.string ?? "git://\(kind.rawValue)"
    }

    var nodeID: NodeID? { NodeID(uri) }
    var typeID: TypeID { TypeID("git.\(kind.rawValue)") }

    /// For a `commitFile` id of the form "sha/path/to/file", split into the two parts.
    var commitAndPath: (sha: String, path: String)? {
        guard kind == .commitFile, let id else { return nil }
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }
}

// MARK: - git CLI

enum Git {
    /// Run `git -C <repo> <args>` and return stdout, or nil on failure. Synchronous;
    /// call from a detached task so it never blocks the main actor.
    static func run(_ repo: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// What a command did, when it matters whether it worked.
    ///
    /// `run` answers nil for every failure alike, which is all a read needs —
    /// a branch list that can't be read is an empty list. A write is different:
    /// "nothing added to commit" and "updates were rejected" are things the
    /// reader has to be told, and they arrive on stderr.
    struct Failure: Error {
        let message: String
    }

    @discardableResult
    static func perform(_ repo: String, _ args: [String]) -> Result<String, Failure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
        // Read before waiting: a pipe that fills up blocks the child forever,
        // and a rejected push has plenty to say.
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        let problem = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = problem.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Failure(message: text.isEmpty
                                    ? "git \(args.first ?? "") failed" : text))
        }
        return .success(output)
    }

    static func looksLikeRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/.git")
    }
}

// MARK: - Provider

struct GitProvider: NodeProvider {
    let schemes: Set<String> = ["git"]

    /// Used to pull the working tree in from whichever provider owns `file://`.
    let broker: NodeBroker

    init(broker: NodeBroker) { self.broker = broker }

    func resolve(_ uri: String) -> NodeID? {
        guard let ref = GitRef(uri: uri), Git.looksLikeRepo(ref.repo) else { return nil }
        return ref.nodeID
    }

    func node(for id: NodeID) async -> Node? {
        guard let ref = GitRef(uri: id.uri) else { return nil }
        return await Task.detached(priority: .userInitiated) { Self.makeNode(ref) }.value
    }

    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        guard let ref = GitRef(uri: id.uri) else { return Page(items: []) }
        let page = await Task.detached(priority: .userInitiated) { Self.children(ref, cursor: cursor) }.value

        // A repo isn't just git metadata — it's a working tree. Ask whoever owns
        // file:// for the directory's children rather than re-listing it here, so the
        // files arrive with the FileSystem plugin's labels, icons, and metadata (and
        // stay editable by the TextEditor plugin). This is what makes a repo node
        // cohesive: Branches, Commits, and the actual files, in one place.
        if ref.kind == .repo {
            let workingTree = URL(fileURLWithPath: ref.repo).absoluteString
            let files = await broker.children(of: workingTree, page: nil).items
            return Page(items: page.items + files, next: page.next)
        }
        return page
    }

    /// The heavier half of a commit's row, fetched only for the ones on
    /// screen. Everything else answers as it always did.
    func attributes(of id: NodeID) async -> Attributes {
        guard let ref = GitRef(uri: id.uri), ref.kind == .commit else {
            return await node(for: id)?.attributes ?? .init()
        }
        return await Task.detached(priority: .userInitiated) {
            Self.commitStat(ref.repo, sha: ref.id ?? "")
        }.value
    }

    func related(to id: NodeID) async -> [Related] {
        guard let ref = GitRef(uri: id.uri) else { return [] }
        return await Task.detached(priority: .userInitiated) { Self.related(ref) }.value
    }

    // MARK: Node construction (off-main)

    static func makeNode(_ ref: GitRef) -> Node? {
        guard let id = ref.nodeID else { return nil }
        let name: String
        let icon: NodeIcon
        var hasChildren = false
        var identities: [NodeID] = []
        switch ref.kind {
        case .repo:
            name = URL(fileURLWithPath: ref.repo).lastPathComponent
            icon = NodeIcon("arrow.triangle.branch", tint: .orange)
            hasChildren = true
            // A repository *is* the working tree's directory. Saying so is
            // what gets it rename, trash, reveal, New File — everything the
            // FileSystem plugin knows how to do to a folder.
            identities = [NodeID(URL(fileURLWithPath: ref.repo)
                .standardizedFileURL.absoluteString)].compactMap { $0 }
        case .branches:
            name = "Branches"; icon = NodeIcon("arrow.triangle.branch", tint: .green); hasChildren = true
        case .commits:
            name = "Commits"; icon = NodeIcon("clock", tint: .blue); hasChildren = true
        case .staged:
            name = "Staged"
            icon = NodeIcon("tray.full", tint: .yellow)
            // Cheap and honest: nothing staged means no disclosure triangle.
            hasChildren = !changedPaths(ref.repo, staged: true).isEmpty
        case .unstaged:
            name = "Unstaged"
            icon = NodeIcon("pencil.circle", tint: .orange)
            hasChildren = !changedPaths(ref.repo, staged: false).isEmpty
        case .branch:
            name = ref.id ?? "branch"; icon = NodeIcon("arrow.triangle.branch", tint: .green)
        case .commit:
            name = String((ref.id ?? "").prefix(7))
            icon = NodeIcon("circle.fill", tint: .blue)
            hasChildren = true    // changed files
        case .commitFile:
            name = ref.commitAndPath?.path ?? (ref.id ?? "")
            icon = NodeIcon("doc.text", tint: .secondary)
        case .stagedFile, .unstagedFile:
            name = ref.id ?? ""
            icon = NodeIcon("doc.text", tint: .secondary)
        }
        return Node(id: id, type: ref.typeID, label: name, icon: icon,
                    hasChildren: hasChildren, identities: identities)
    }

    /// Icon for a changed file, by its git status letter.
    static func statusIcon(_ status: String) -> NodeIcon {
        switch status {
        case "A": return NodeIcon("plus.circle", tint: .green)
        case "D": return NodeIcon("minus.circle", tint: .red)
        case "M": return NodeIcon("pencil.circle", tint: .orange)
        case "R": return NodeIcon("arrow.right.circle", tint: .blue)
        default:  return NodeIcon("doc.text", tint: .secondary)
        }
    }

    static func children(_ ref: GitRef, cursor: Cursor? = nil) -> Page<Node> {
        switch ref.kind {
        case .repo:
            let nodes = [GitRef(repo: ref.repo, kind: .staged),
                         GitRef(repo: ref.repo, kind: .unstaged),
                         GitRef(repo: ref.repo, kind: .branches),
                         GitRef(repo: ref.repo, kind: .commits)].compactMap(makeNode)
            return Page(items: nodes)
        case .staged:
            return Page(items: changedFiles(ref.repo, staged: true))
        case .unstaged:
            return Page(items: changedFiles(ref.repo, staged: false))
        case .commits:
            // The cursor is our own token: the offset into the log.
            return logCommits(ref.repo, skip: cursor.flatMap { Int($0.token) } ?? 0)
        case .branches:
            return Page(items: branches(ref.repo))
        case .commit:
            return Page(items: changedFiles(ref.repo, sha: ref.id ?? ""))
        case .branch, .commitFile, .stagedFile, .unstagedFile:
            return Page(items: [])
        }
    }

    // MARK: git queries

    static func logCommits(_ repo: String, skip: Int = 0, limit: Int = 50) -> Page<Node> {
        guard let out = Git.run(repo, ["log", "--skip", "\(skip)", "-n", "\(limit)",
                                       "--format=%H%x1f%an%x1f%aI%x1f%s%x1f%P"]) else { return Page(items: []) }
        let iso = ISO8601DateFormatter()
        // Built once for the page rather than once per row, and locally rather
        // than statically: a formatter is not Sendable and this runs detached.
        let relative = RelativeDateTimeFormatter()
        let nodes = out.split(separator: "\n").compactMap { line -> Node? in
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count >= 4 else { return nil }
            let sha = f[0]
            guard let id = GitRef(repo: repo, kind: .commit, id: sha).nodeID else { return nil }
            var attrs = Attributes()
            attrs["sha"] = .string(sha)
            attrs["author"] = .string(f[1])
            attrs["subject"] = .string(f[3])
            if let date = iso.date(from: f[2]) { attrs["date"] = .date(date) }
            if f.count >= 5 { attrs["parents"] = .string(f[4]) }   // space-separated shas
            // The author and the date cost nothing — `git log` printed them
            // on the same line as the subject. The diff stat is not here for
            // the same reason: it is a query per commit, and this is fifty of
            // them. See `attributes(of:)`.
            var subtitle = f[1]
            if let date = iso.date(from: f[2]) {
                subtitle += " · " + relative.localizedString(for: date, relativeTo: .now)
            }
            return Node(id: id, type: TypeID("git.commit"),
                        label: "\(sha.prefix(7))  \(f[3])",
                        icon: NodeIcon("circle.fill", tint: .blue),
                        attributes: attrs, subtitle: subtitle, hasChildren: true)
        }
        // A full page means there may be more history; a short one means we hit the
        // root. (A history length that's an exact multiple costs one empty fetch.)
        let next = nodes.count == limit ? Cursor("\(skip + limit)") : nil
        return Page(items: nodes, next: next)
    }

    /// What a commit changed, as one line — the expensive half of its row.
    ///
    /// Its own `git show` per commit, which is exactly why it is not in the
    /// listing: fifty of these to draw a page, and thousands to scroll one.
    static func commitStat(_ repo: String, sha: String) -> Attributes {
        var attrs = Attributes()
        guard !sha.isEmpty,
              let out = Git.run(repo, ["show", "--shortstat", "--format=", sha])
        else { return attrs }
        // " 3 files changed, 42 insertions(+), 7 deletions(-)"
        func number(before word: String) -> Int? {
            guard let range = out.range(of: word) else { return nil }
            return Int(out[..<range.lowerBound].split(separator: " ").last ?? "")
        }
        let added = number(before: "insertion") ?? 0
        let removed = number(before: "deletion") ?? 0
        attrs["insertions"] = .int(added)
        attrs["deletions"] = .int(removed)
        guard added + removed > 0 else { return attrs }
        attrs["detail"] = .string("+\(added) −\(removed)")
        return attrs
    }

    static func branches(_ repo: String) -> [Node] {
        // Tab delimiter: branch names can't contain tabs.
        guard let out = Git.run(repo, ["for-each-ref",
                                       "--format=%(refname:short)\t%(objectname)", "refs/heads"])
        else { return [] }
        return out.split(separator: "\n").compactMap { line -> Node? in
            let f = line.components(separatedBy: "\t")
            guard let name = f.first, !name.isEmpty,
                  let id = GitRef(repo: repo, kind: .branch, id: name).nodeID else { return nil }
            var attrs = Attributes()
            var anchor: NodeAnchor?
            if f.count > 1 {
                attrs["tip"] = .string(f[1])
                // A branch IS a pointer to its head commit — phony: opening it
                // opens that commit's canvas, with the branch kept selected.
                anchor = GitRef(repo: repo, kind: .commit, id: f[1]).nodeID
                    .map { NodeAnchor(node: $0) }
            }
            return Node(id: id, type: TypeID("git.branch"),
                        label: name,
                        icon: NodeIcon("arrow.triangle.branch", tint: .green),
                        attributes: attrs, hasChildren: false, anchor: anchor)
        }
    }

    /// Forward links. This is where the forest gains its graph-ness — and where a
    /// git commit-file points at the `file://` node in a *different* provider.
    static func related(_ ref: GitRef) -> [Related] {
        switch ref.kind {
        case .commit:
            guard let sha = ref.id,
                  let out = Git.run(ref.repo, ["log", "-1", "--format=%P", sha]) else { return [] }
            let parents = out.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ").map(String.init)
            return parents.enumerated().map { index, parent in
                let label = parents.count > 1 ? "parent \(index + 1)" : "parent"
                return Related(label: label, target: GitRef(repo: ref.repo, kind: .commit, id: parent).uri)
            }

        case .branch:
            guard let name = ref.id,
                  let tip = Git.run(ref.repo, ["rev-parse", name])?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !tip.isEmpty else { return [] }
            return [Related(label: "tip commit",
                            target: GitRef(repo: ref.repo, kind: .commit, id: tip).uri)]

        case .commitFile:
            // Cross-provider: jump to the file on disk (which the FileSystem plugin
            // provides, and the TextEditor plugin may render).
            guard let (_, path) = ref.commitAndPath else { return [] }
            let fileURL = URL(fileURLWithPath: ref.repo).appendingPathComponent(path)
            return [Related(label: "working tree file", target: fileURL.absoluteString)]

        case .stagedFile, .unstagedFile:
            guard let path = ref.id else { return [] }
            let fileURL = URL(fileURLWithPath: ref.repo).appendingPathComponent(path)
            var references = [Related(label: "working tree file",
                                      target: fileURL.absoluteString)]
            // The file's other side of the index, when it has one: staged and
            // then edited again is the case worth being able to cross to.
            let otherKind: GitRef.Kind = ref.kind == .stagedFile ? .unstagedFile : .stagedFile
            let otherStaged = otherKind == .stagedFile
            if changedPaths(ref.repo, staged: otherStaged).contains(where: { $0.path == path }) {
                references.append(Related(
                    label: otherStaged ? "staged version" : "unstaged changes",
                    target: GitRef(repo: ref.repo, kind: otherKind, id: path).uri))
            }
            return references

        default:
            return []
        }
    }

    /// The two sides of the index.
    ///
    /// Staged is HEAD against the index — what `git commit` would record.
    /// Unstaged is the index against the files on disk — what it would miss.
    /// The same file can appear in both, having been staged and then edited
    /// again, which is exactly why they are separate lists.
    static func changedPaths(_ repo: String,
                             staged: Bool) -> [(status: String, path: String)] {
        var arguments = ["diff", "--name-status", "-M"]
        if staged { arguments.append("--cached") }
        guard let out = Git.run(repo, arguments) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2, let path = parts.last else { return nil }
            return (String(parts[0].prefix(1)), path)
        }
    }

    static func changedFiles(_ repo: String, staged: Bool) -> [Node] {
        let kind: GitRef.Kind = staged ? .stagedFile : .unstagedFile
        return changedPaths(repo, staged: staged).compactMap { entry in
            guard let id = GitRef(repo: repo, kind: kind, id: entry.path).nodeID
            else { return nil }
            var attrs = Attributes()
            attrs["status"] = .string(entry.status)
            return Node(id: id, type: TypeID("git.\(kind.rawValue)"),
                        label: entry.path,
                        icon: statusIcon(entry.status),
                        attributes: attrs, hasChildren: false)
        }
    }

    static func changedFiles(_ repo: String, sha: String) -> [Node] {
        guard !sha.isEmpty,
              let out = Git.run(repo, ["show", "--name-status", "--format=", sha]) else { return [] }
        return out.split(separator: "\n").compactMap { line -> Node? in
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2, let path = parts.last else { return nil }
            let status = String(parts[0].prefix(1))
            guard let id = GitRef(repo: repo, kind: .commitFile, id: "\(sha)/\(path)").nodeID else { return nil }
            var attrs = Attributes()
            attrs["status"] = .string(status)
            return Node(id: id, type: TypeID("git.commitfile"),
                        label: path,
                        icon: statusIcon(status),
                        attributes: attrs, hasChildren: false)
        }
    }
}

// MARK: - Plugin

@objc(GitPlugin)
final class GitPlugin: NSObject, Plugin {
    override init() { super.init() }

    func register(with registry: PluginRegistry) {
        registry.register(provider: GitProvider(broker: registry.broker))

        // Cross-plugin integration: offer to open a filesystem directory that is a
        // git repo as a git:// root. Cheap predicate (checks for a .git directory).
        registry.register(action: Action(
            id: "git.open",
            title: "Open as Git Repository",
            systemImage: "arrow.triangle.branch",
            appliesTo: .custom { ctx in
                guard ctx.selection.count == 1, let path = GitPlugin.repoPath(for: ctx.selection[0]) else { return false }
                return Git.looksLikeRepo(path)
            },
            run: { ctx in
                guard let dir = ctx.selection.first, let path = GitPlugin.repoPath(for: dir) else { return }
                ctx.mount(GitRef(repo: path, kind: .repo).uri)
            }
        ))

        registerActions(with: registry)
        // The repo canvas writes its commit message in the app's editor, so
        // the actions its keys name have to exist whether or not the plugin
        // that usually registers them happens to be loaded.
        EditorKeys.register(with: registry)

        registry.register(canvas: CanvasContribution(priority: 10,
            matches: { $0.type == TypeID("git.commit") }) { id, host in
                AnyView(CommitCanvas(nodeID: id).environment(host))
        })
        registry.register(canvas: CanvasContribution(priority: 10,
            matches: { $0.type == TypeID("git.stagedfile")
                    || $0.type == TypeID("git.unstagedfile") }) { id, host in
                AnyView(WorkingCopyFileCanvas(nodeID: id).environment(host))
        })
        // A changed file's canvas is its diff. Without this it fell through to
        // the generic list canvas, which had nothing to list.
        registry.register(canvas: CanvasContribution(priority: 10,
            matches: { $0.type == TypeID("git.commitfile") }) { id, host in
                AnyView(CommitFileCanvas(nodeID: id).environment(host))
        })
        // A repository gets its status rather than a list of its four folders,
        // which said nothing a sidebar row didn't.
        registry.register(canvas: CanvasContribution(priority: 20,
            matches: { $0.type == TypeID("git.repo") },
            keys: GitActions.canvasKeys) { id, host in
                AnyView(RepoCanvas(nodeID: id).environment(host))
        })
        registry.register(canvas: CanvasContribution(priority: 0,
            matches: { $0.type.raw.hasPrefix("git.") }) { id, host in
                AnyView(GitListCanvas(nodeID: id).environment(host))
        })
        registry.register(inspector: InspectorContribution(
            matches: { $0.type.raw.hasPrefix("git.") }) { id, host in
                AnyView(GitInspector(nodeID: id).environment(host))
        })
    }

    private static func repoPath(for id: NodeID) -> String? {
        guard id.scheme == "file", let url = URL(string: id.uri) else { return nil }
        return url.path
    }
}
