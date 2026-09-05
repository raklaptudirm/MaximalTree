import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// Reading where a repository stands.
///
/// Parsed from porcelain v1, whose format is stable by promise — which is the
/// only reason it is worth parsing rather than calling git four more times.
@Suite struct GitStatusParsingTests {
    @Test func branchWithAnUpstreamAndBothCounts() {
        let status = GitStatus.parse("## main...origin/main [ahead 2, behind 3]\n")
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 2)
        #expect(status.behind == 3)
    }

    @Test func aheadOnly() {
        let status = GitStatus.parse("## work...origin/work [ahead 1]\n")
        #expect(status.ahead == 1)
        #expect(status.behind == 0)
    }

    /// A branch level with its upstream has no bracket at all, and a branch
    /// with no upstream has no `...` either.
    @Test func aBranchNeedNotHaveAnUpstreamOrCounts() {
        let level = GitStatus.parse("## main...origin/main\n")
        #expect(level.branch == "main")
        #expect(level.upstream == "origin/main")
        #expect(level.ahead == 0 && level.behind == 0)

        let alone = GitStatus.parse("## scratch\n")
        #expect(alone.branch == "scratch")
        #expect(alone.upstream == nil)
    }

    /// The case that makes staged and unstaged two lists rather than one: a
    /// file can be in both, having been staged and then changed again.
    @Test func aFileCanBeStagedAndChangedSince() {
        let status = GitStatus.parse("""
        ## main
        MM both.txt
        M  staged.txt
         M unstaged.txt
        """)
        #expect(status.staged.map(\.path) == ["both.txt", "staged.txt"])
        #expect(status.unstaged.map(\.path) == ["both.txt", "unstaged.txt"])
    }

    /// Untracked is unstaged work: it is what committing would miss.
    @Test func untrackedFilesCountAsUnstaged() {
        let status = GitStatus.parse("## main\n?? new.txt\n")
        #expect(status.unstaged.map(\.path) == ["new.txt"])
        #expect(status.unstaged.first?.code == "?")
        #expect(status.staged.isEmpty)
    }

    /// A rename names both paths; the file that exists now is the second.
    @Test func aRenameReportsWhereTheFileIsNow() {
        let status = GitStatus.parse("## main\nR  old.txt -> new.txt\n")
        #expect(status.staged.map(\.path) == ["new.txt"])
        #expect(status.staged.first?.code == "R")
    }

    @Test func quotedPathsLoseTheirQuotes() {
        let status = GitStatus.parse("## main\n M \"a file.txt\"\n")
        #expect(status.unstaged.map(\.path) == ["a file.txt"])
    }

    @Test func aCleanRepositoryIsClean() {
        let status = GitStatus.parse("## main...origin/main\n")
        #expect(status.isClean)
        #expect(!GitStatus.parse("## main\n M a.txt\n").isClean)
    }

    @Test func theCodesReadAsWords() {
        #expect(GitStatus.Entry(code: "M", path: "a").describes == "Modified")
        #expect(GitStatus.Entry(code: "?", path: "a").describes == "Untracked")
        #expect(GitStatus.Entry(code: "D", path: "a").describes == "Deleted")
    }
}

/// Against a real repository, because the point is that this is what git says.
@MainActor
@Suite struct GitStatusReadingTests {
    private func makeRepo() throws -> String {
        let dir = NSTemporaryDirectory() + "gitstatus-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = Git.run(dir, ["init", "-b", "main"])
        _ = Git.run(dir, ["config", "user.email", "t@example.com"])
        _ = Git.run(dir, ["config", "user.name", "Tester"])
        _ = Git.run(dir, ["config", "commit.gpgsign", "false"])
        try "one\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        _ = Git.run(dir, ["add", "."])
        _ = Git.run(dir, ["commit", "-m", "first"])
        return dir
    }

    @Test func readsTheBranchAndTheChanges() throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(atPath: repo) }

        #expect(GitStatus.read(repo).branch == "main")
        #expect(GitStatus.read(repo).isClean)

        try "two\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo + "/b.txt", atomically: true, encoding: .utf8)
        let dirty = GitStatus.read(repo)
        #expect(dirty.unstaged.map(\.path).sorted() == ["a.txt", "b.txt"])
        #expect(dirty.staged.isEmpty)

        _ = Git.perform(repo, ["add", "--", "a.txt"])
        let staged = GitStatus.read(repo)
        #expect(staged.staged.map(\.path) == ["a.txt"])
        #expect(staged.unstaged.map(\.path) == ["b.txt"])
    }

    /// Not a repository at all: an empty status rather than a crash or a lie.
    @Test func somewhereThatIsNotARepository() throws {
        let dir = NSTemporaryDirectory() + "notarepo-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let status = GitStatus.read(dir)
        #expect(status.branch == nil)
        #expect(status.isClean)
    }
}
