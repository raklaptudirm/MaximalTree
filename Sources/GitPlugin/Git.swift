import Foundation
import SwiftUI
import MaximalTreeKit

// MARK: - URI model

/// A git object encoded as a canonicalizable `git://` NodeID. Structure:
///   `git://<kind>/<id>?repo=<absolute-repo-path>`
/// The `kind` is the URL host (always alphanumeric), the `id` (sha / branch name /
/// "sha/filepath") is the URL path, and the repo path rides in the query so it never
/// collides with the object path. Built and parsed through `URLComponents`, which is
/// exactly what `NodeID` canonicalization uses — so the form is stable/idempotent.
struct GitRef: Equatable {
    enum Kind: String {
        case repo, branches, commits, branch, commit
        case commitFile = "commitfile"
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

    static func looksLikeRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/.git")
    }
}

// MARK: - Provider

struct GitProvider: NodeProvider {
    let schemes: Set<String> = ["git"]

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
        return await Task.detached(priority: .userInitiated) { Self.children(ref) }.value
    }

    func related(to id: NodeID) async -> [Related] {
        guard let ref = GitRef(uri: id.uri) else { return [] }
        return await Task.detached(priority: .userInitiated) { Self.related(ref) }.value
    }

    // MARK: Node construction (off-main)

    static func makeNode(_ ref: GitRef) -> Node? {
        guard let id = ref.nodeID else { return nil }
        let name: String
        var hasChildren = false
        switch ref.kind {
        case .repo:
            name = URL(fileURLWithPath: ref.repo).lastPathComponent
            hasChildren = true
        case .branches: name = "Branches"; hasChildren = true
        case .commits:  name = "Commits";  hasChildren = true
        case .branch:   name = ref.id ?? "branch"
        case .commit:
            name = String((ref.id ?? "").prefix(7))
            hasChildren = true    // changed files
        case .commitFile:
            name = ref.commitAndPath?.path ?? (ref.id ?? "")
        }
        return Node(id: id, type: ref.typeID, attributes: .named(name), hasChildren: hasChildren)
    }

    static func children(_ ref: GitRef) -> Page<Node> {
        switch ref.kind {
        case .repo:
            let nodes = [GitRef(repo: ref.repo, kind: .branches),
                         GitRef(repo: ref.repo, kind: .commits)].compactMap(makeNode)
            return Page(items: nodes)
        case .commits:
            return Page(items: logCommits(ref.repo))
        case .branches:
            return Page(items: branches(ref.repo))
        case .commit:
            return Page(items: changedFiles(ref.repo, sha: ref.id ?? ""))
        case .branch, .commitFile:
            return Page(items: [])
        }
    }

    // MARK: git queries

    static func logCommits(_ repo: String, limit: Int = 50) -> [Node] {
        guard let out = Git.run(repo, ["log", "-n", "\(limit)",
                                       "--format=%H%x1f%an%x1f%aI%x1f%s%x1f%P"]) else { return [] }
        let iso = ISO8601DateFormatter()
        return out.split(separator: "\n").compactMap { line -> Node? in
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count >= 4 else { return nil }
            let sha = f[0]
            guard let id = GitRef(repo: repo, kind: .commit, id: sha).nodeID else { return nil }
            var attrs = Attributes.named("\(sha.prefix(7))  \(f[3])")
            attrs["sha"] = .string(sha)
            attrs["author"] = .string(f[1])
            attrs["subject"] = .string(f[3])
            if let date = iso.date(from: f[2]) { attrs["date"] = .date(date) }
            if f.count >= 5 { attrs["parents"] = .string(f[4]) }   // space-separated shas
            return Node(id: id, type: TypeID("git.commit"), attributes: attrs, hasChildren: true)
        }
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
            var attrs = Attributes.named(name)
            if f.count > 1 { attrs["tip"] = .string(f[1]) }
            return Node(id: id, type: TypeID("git.branch"), attributes: attrs, hasChildren: false)
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

        default:
            return []
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
            var attrs = Attributes.named(path)
            attrs["status"] = .string(status)
            return Node(id: id, type: TypeID("git.commitfile"), attributes: attrs, hasChildren: false)
        }
    }
}

// MARK: - Plugin

@objc(GitPlugin)
final class GitPlugin: NSObject, Plugin {
    override init() { super.init() }

    func register(with registry: PluginRegistry) {
        registry.register(provider: GitProvider())

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
            handler: { ctx in
                guard let dir = ctx.selection.first, let path = GitPlugin.repoPath(for: dir) else { return }
                ctx.host.mount(GitRef(repo: path, kind: .repo).uri)
            }
        ))

        registry.register(canvas: CanvasContribution(priority: 10,
            matches: { $0.type == TypeID("git.commit") }) { id, host in
                AnyView(CommitCanvas(nodeID: id).environment(host))
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
