import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// Writing to a repository.
///
/// Against a real repository in a temporary directory, because the thing worth
/// checking is that these are the right git commands — and only git can say so.
@MainActor
@Suite struct GitWriteTests {
    private func makeRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "gitwrite-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = Git.run(dir, ["init"])
        _ = Git.run(dir, ["config", "user.email", "t@example.com"])
        _ = Git.run(dir, ["config", "user.name", "Tester"])
        _ = Git.run(dir, ["config", "commit.gpgsign", "false"])
        try "one\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        _ = Git.run(dir, ["add", "."])
        _ = Git.run(dir, ["commit", "-m", "first"])
        return dir
    }

    private func status(_ repo: String) -> String {
        Git.run(repo, ["status", "--porcelain"]) ?? ""
    }

    // MARK: Reporting

    /// The reason `run` wasn't enough: it answers nil for every failure alike,
    /// and a write's failure is the only thing that explains it.
    @Test func aFailedCommandCarriesWhatGitSaid() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        let result = Git.perform(repo, ["checkout", "no-such-branch"])
        guard case .failure(let failure) = result else {
            Issue.record("checking out a branch that isn't there should fail")
            return
        }
        #expect(!failure.message.isEmpty, "the failure said nothing")
        #expect(failure.message.lowercased().contains("no-such-branch"))
    }

    @Test func aSucceedingCommandCarriesItsOutput() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        guard case .success(let out) = Git.perform(repo, ["log", "--oneline"]) else {
            Issue.record("reading the log should work")
            return
        }
        #expect(out.contains("first"))
    }

    // MARK: The commands the actions run

    @Test func stagingAndUnstagingOneFile() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try "two\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        #expect(status(repo).contains(" M a.txt"), "the change should start unstaged")

        _ = Git.perform(repo, ["add", "--", "a.txt"])
        #expect(status(repo).contains("M  a.txt"), "staging did not stage it")

        _ = Git.perform(repo, ["restore", "--staged", "--", "a.txt"])
        #expect(status(repo).contains(" M a.txt"), "unstaging did not unstage it")
    }

    @Test func committingWhatIsStaged() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try "two\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        _ = Git.perform(repo, ["add", "-A"])

        _ = Git.perform(repo, ["commit", "-m", "second"])
        #expect(status(repo).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "committing left changes behind")
        #expect(Git.run(repo, ["log", "--oneline"])?.contains("second") == true)
    }

    /// Committing with nothing staged has to fail loudly rather than quietly
    /// making an empty commit.
    @Test func committingNothingFails() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        guard case .failure = Git.perform(repo, ["commit", "-m", "empty"]) else {
            Issue.record("an empty commit should have been refused")
            return
        }
    }

    @Test func discardingRestoresTheFile() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try "changed\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)

        _ = Git.perform(repo, ["restore", "--", "a.txt"])
        let text = try String(contentsOfFile: repo + "/a.txt", encoding: .utf8)
        #expect(text == "one\n", "the file was not put back")
    }

    @Test func stashingAndRestoring() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try "stashed\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)

        _ = Git.perform(repo, ["stash", "push", "-u"])
        #expect(try String(contentsOfFile: repo + "/a.txt", encoding: .utf8) == "one\n")

        _ = Git.perform(repo, ["stash", "pop"])
        #expect(try String(contentsOfFile: repo + "/a.txt", encoding: .utf8) == "stashed\n")
    }

    // MARK: What the actions target

    @Test func aNodeSaysWhichRepoAndFileItIsAbout() throws {
        let staged = try #require(GitRef(repo: "/r", kind: .stagedFile, id: "src/a.swift").nodeID)
        #expect(GitActions.repo(of: staged) == "/r")
        #expect(GitActions.path(of: staged) == "src/a.swift")

        let commitFile = try #require(GitRef(repo: "/r", kind: .commitFile,
                                             id: "abc123/src/b.swift").nodeID)
        #expect(GitActions.path(of: commitFile) == "src/b.swift",
                "a commit's file has the sha in front of the path")

        // A commit is not a file, and has no path to act on.
        let commit = try #require(GitRef(repo: "/r", kind: .commit, id: "abc123").nodeID)
        #expect(GitActions.path(of: commit) == nil)
    }

    /// Whole-repository commands apply to the repo and to the lists hanging
    /// off it, so "Push" is offered from anywhere inside a repository rather
    /// than only from its root row.
    @Test func repositoryScopeCoversTheListsToo() throws {
        let host = HostContext()
        for kind in [GitRef.Kind.repo, .staged, .unstaged, .branches, .commits] {
            let id = try #require(GitRef(repo: "/r", kind: kind).nodeID)
            #expect(GitActions.isRepoScope(ActionContext(host: host, targets: [id])),
                    "\(kind.rawValue) should count as the repository")
        }
        for kind in [GitRef.Kind.commit, .stagedFile, .unstagedFile] {
            let id = try #require(GitRef(repo: "/r", kind: kind, id: "x").nodeID)
            #expect(!GitActions.isRepoScope(ActionContext(host: host, targets: [id])),
                    "\(kind.rawValue) is not the repository")
        }
    }

    /// A write changes several lists at once — staging moves a file between
    /// two of them and shifts the branch's ahead count — so the whole subtree
    /// is re-read rather than each affected node guessed at.
    @Test func aWriteRefreshesEveryListInTheRepository() throws {
        let host = HostContext()
        final class Backend: GraphBackend {
            var changes: [NodeChange] = []
            func notify(_ changes: [NodeChange]) { self.changes += changes }
            func open(_ id: NodeID) {}
            func select(_ ids: [NodeID]) {}
            func mount(_ uri: String) {}
            func openURI(_ uri: String) {}
            func apply(_ mutation: GraphMutation) {}
            func canApply(_ mutation: GraphMutation) -> Bool { false }
            func beginRename(_ id: NodeID) {}
            func pin(_ id: NodeID) {}
            func requestChildren(of id: NodeID) {}
            func requestMoreChildren(of id: NodeID) {}
            func requestRelated(of id: NodeID) {}
            func perform(actionID: String, count: Int) {}
        }
        let backend = Backend()
        host.backend = backend

        GitActions.refresh("/r", host)

        let refreshed = Set(backend.changes.compactMap { change -> String? in
            guard case .childrenChanged(let id) = change else { return nil }
            return GitRef(uri: id.uri)?.kind.rawValue
        })
        #expect(refreshed == ["repo", "staged", "unstaged", "branches", "commits"])
    }
}
