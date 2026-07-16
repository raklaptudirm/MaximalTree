import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

@Suite struct GitURITests {
    @Test func uriRoundTrips() {
        let refs = [
            GitRef(repo: "/Users/x/proj", kind: .repo),
            GitRef(repo: "/Users/x/proj", kind: .commits),
            GitRef(repo: "/Users/x/proj", kind: .commit, id: "abc123"),
            GitRef(repo: "/Users/x/proj", kind: .branch, id: "feature/foo"),
            GitRef(repo: "/Users/x/my proj", kind: .commitFile, id: "abc/dir/file name.txt"),
        ]
        for ref in refs {
            #expect(GitRef(uri: ref.uri) == ref)
        }
    }

    @Test func canonicalizesIdempotentlyAndRoutes() throws {
        // The critical property: the git URI survives NodeID canonicalization
        // unchanged and still parses back to the same ref, with scheme "git".
        let ref = GitRef(repo: "/Users/x/my proj", kind: .commit, id: "deadbeef")
        let canon = try #require(NodeID(ref.uri)?.uri)
        #expect(NodeID(canon)?.uri == canon)          // idempotent
        #expect(GitRef(uri: canon) == ref)            // still parses to same ref
        #expect(NodeID(canon)?.scheme == "git")       // routes to the git provider
    }

    @Test func commitFileSplitsShaAndPath() {
        let ref = GitRef(repo: "/r", kind: .commitFile, id: "abc123/src/main.swift")
        #expect(ref.commitAndPath?.sha == "abc123")
        #expect(ref.commitAndPath?.path == "src/main.swift")
    }
}

@Suite struct GitProviderTests {
    private func makeTempRepo() throws -> String {
        let dir = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = Git.run(dir, ["init"])
        _ = Git.run(dir, ["config", "user.email", "t@example.com"])
        _ = Git.run(dir, ["config", "user.name", "Tester"])
        _ = Git.run(dir, ["config", "commit.gpgsign", "false"])   // this machine signs by default
        try "hello".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        _ = Git.run(dir, ["add", "."])
        _ = Git.run(dir, ["commit", "-m", "first commit"])
        return dir
    }

    @Test func logReturnsCommits() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let commits = GitProvider.logCommits(repo).items
        #expect(commits.count >= 1)
        let first = try #require(commits.first)
        #expect(first.type == TypeID("git.commit"))
        #expect(first.attributes["subject"] == .string("first commit"))
    }

    @Test func branchesListed() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let branches = GitProvider.branches(repo)
        #expect(branches.count >= 1)                     // the default branch
        #expect(branches.first?.type == TypeID("git.branch"))
    }

    /// The cohesion feature: a git repo node lists Branches/Commits *and* the working
    /// tree, with the file nodes coming from the FileSystem provider via the broker.
    @Test func repoNodeIncludesWorkingTreeFromFileSystemProvider() async throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let broker = HostBroker()
        broker.install([FileSystemProvider()])          // only file:// is registered
        let provider = GitProvider(broker: broker)
        let repoID = try #require(GitRef(repo: repo, kind: .repo).nodeID)

        let children = await provider.children(of: repoID, page: nil)
        let labels = children.items.map(\.label)
        #expect(labels.contains("Branches"))
        #expect(labels.contains("Commits"))
        #expect(labels.contains("a.txt"))               // spliced in from the other plugin

        // And it's genuinely the FileSystem plugin's node, not a git-made imitation.
        let file = try #require(children.items.first { $0.label == "a.txt" })
        #expect(file.id.scheme == "file")
        #expect(file.type == TypeID("file.file"))
        #expect(file.icon != nil)
    }

    @Test func changedFileStatusIcons() {
        #expect(GitProvider.statusIcon("A").systemName == "plus.circle")
        #expect(GitProvider.statusIcon("D").systemName == "minus.circle")
        #expect(GitProvider.statusIcon("M").systemName == "pencil.circle")
    }

    @Test func changedFilesForCommit() throws {
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        let sha = try #require(GitProvider.logCommits(repo).items.first?.attributes["sha"])
        guard case .string(let shaValue) = sha else { Issue.record("no sha"); return }
        let files = GitProvider.changedFiles(repo, sha: shaValue)
        #expect(files.contains { $0.label == "a.txt" })
    }
}
