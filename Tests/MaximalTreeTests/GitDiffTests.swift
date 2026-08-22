import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// The diff parser, line by line — the part a diff view is only as good as.
@Suite struct GitDiffParsingTests {
    private let sample = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1234567..89abcde 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,7 +10,8 @@ struct App {
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
        """

    @Test func readsPathsHunksAndKinds() throws {
        let files = GitDiff.parse(sample)
        let file = try #require(files.first)

        #expect(files.count == 1)
        #expect(file.path == "Sources/App.swift")
        #expect(file.hunks.count == 1)
        #expect(file.additions == 2)
        #expect(file.deletions == 1)
        // The section heading git puts after @@ is often the most useful thing
        // on screen, so it's kept whole.
        #expect(file.hunks[0].header.contains("struct App"))
    }

    /// Line numbers are what let a reader match the diff to the file in front
    /// of them: they start at the hunk header and advance per side.
    @Test func numbersLinesPerSide() throws {
        let hunk = try #require(GitDiff.parse(sample).first?.hunks.first)

        let context = try #require(hunk.lines.first)
        #expect(context.kind == .context)
        #expect(context.oldNumber == 10 && context.newNumber == 10)

        let removed = try #require(hunk.lines.first { $0.kind == .removed })
        #expect(removed.text == "let b = 2")
        #expect(removed.oldNumber == 11, "a removed line has no place in the new file")
        #expect(removed.newNumber == nil)

        let added = try #require(hunk.lines.first { $0.kind == .added })
        #expect(added.oldNumber == nil)
        #expect(added.newNumber == 11)

        // The trailing context sits after both insertions on the new side.
        let last = try #require(hunk.lines.last)
        #expect(last.text == "let d = 5")
        #expect(last.oldNumber == 12 && last.newNumber == 13)
    }

    @Test func readsSeveralFilesFromOneCommit() {
        let files = GitDiff.parse("""
            diff --git a/one.txt b/one.txt
            --- a/one.txt
            +++ b/one.txt
            @@ -1 +1 @@
            -old
            +new
            diff --git a/two.txt b/two.txt
            --- a/two.txt
            +++ b/two.txt
            @@ -1,0 +1,1 @@
            +added
            """)
        #expect(files.map(\.path) == ["one.txt", "two.txt"])
        #expect(files[1].additions == 1 && files[1].deletions == 0)
    }

    /// A deleted file's new side is /dev/null; it must still be named.
    @Test func namesADeletedFileByItsOldPath() throws {
        let files = GitDiff.parse("""
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            --- a/gone.txt
            +++ /dev/null
            @@ -1,2 +0,0 @@
            -one
            -two
            """)
        let file = try #require(files.first)
        #expect(file.path == "gone.txt")
        #expect(file.deletions == 2)
    }

    @Test func namesANewFileEvenThoughItHasNoOldSide() throws {
        let files = GitDiff.parse("""
            diff --git a/fresh.txt b/fresh.txt
            new file mode 100644
            --- /dev/null
            +++ b/fresh.txt
            @@ -0,0 +1 @@
            +hello
            """)
        #expect(try #require(files.first).path == "fresh.txt")
    }

    /// Paths with spaces are ambiguous on the `diff --git` line and exact on
    /// the +++ line, which is why the parser prefers the latter.
    @Test func handlesPathsWithSpaces() throws {
        let files = GitDiff.parse("""
            diff --git a/my notes.txt b/my notes.txt
            --- a/my notes.txt
            +++ b/my notes.txt
            @@ -1 +1 @@
            -a
            +b
            """)
        #expect(try #require(files.first).path == "my notes.txt")
    }

    @Test func reportsBinaryFilesInsteadOfShowingNothing() throws {
        let files = GitDiff.parse("""
            diff --git a/logo.png b/logo.png
            index 111..222 100644
            Binary files a/logo.png and b/logo.png differ
            """)
        let file = try #require(files.first)
        #expect(file.isBinary)
        #expect(file.hunks.isEmpty)
        #expect(!file.isEmpty, "binary is not the same as nothing to show")
    }

    /// A pure rename or mode change: git reports the file with no hunks.
    @Test func reportsAFileWithNoLineChanges() throws {
        let files = GitDiff.parse("""
            diff --git a/old.txt b/new.txt
            similarity index 100%
            rename from old.txt
            rename to new.txt
            """)
        let file = try #require(files.first)
        #expect(file.path == "new.txt")
        #expect(file.isEmpty)
    }

    /// The marker isn't part of the file and must not be counted as a line.
    @Test func ignoresTheNoNewlineMarker() throws {
        let files = GitDiff.parse("""
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1 +1 @@
            -one
            \\ No newline at end of file
            +one
            """)
        let file = try #require(files.first)
        #expect(file.additions == 1 && file.deletions == 1)
        #expect(file.hunks[0].lines.count == 2)
    }

    @Test func emptyInputIsNoFiles() {
        #expect(GitDiff.parse("").isEmpty)
        #expect(GitDiff.parse("\n\n").isEmpty)
    }
}

/// The whole path against a real repository: git's actual output, this git,
/// on this machine — the parser tests above only prove we read the shape we
/// think git writes.
@Suite struct GitDiffCommandTests {
    /// A repo with two commits: a file added, then edited and another added.
    private func makeRepo() throws -> (path: String, first: String, second: String)? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = dir.path
        // Identity on the command line: the machine running this may have no
        // global user configured, and commit would fail.
        let identity = ["-c", "user.email=test@example.com", "-c", "user.name=Test"]
        guard Git.run(repo, ["init", "-q"]) != nil else { return nil }

        try "one\ntwo\nthree\n".write(to: dir.appendingPathComponent("a.txt"),
                                      atomically: true, encoding: .utf8)
        _ = Git.run(repo, ["add", "."])
        _ = Git.run(repo, identity + ["commit", "-q", "-m", "first"])
        guard let first = Git.run(repo, ["rev-parse", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        try "one\nTWO\nthree\n".write(to: dir.appendingPathComponent("a.txt"),
                                      atomically: true, encoding: .utf8)
        try "new file\n".write(to: dir.appendingPathComponent("b.txt"),
                               atomically: true, encoding: .utf8)
        _ = Git.run(repo, ["add", "."])
        _ = Git.run(repo, identity + ["commit", "-q", "-m", "second"])
        guard let second = Git.run(repo, ["rev-parse", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        return (repo, first, second)
    }

    @Test func readsARealCommitsDiff() throws {
        guard let repo = try makeRepo() else { return }   // no usable git here
        defer { try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: repo.path).deletingLastPathComponent()) }

        let files = GitDiff.show(repo: repo.path, sha: repo.second)
        #expect(files.map(\.path).sorted() == ["a.txt", "b.txt"])

        let edited = try #require(files.first { $0.path == "a.txt" })
        #expect(edited.additions == 1 && edited.deletions == 1)
        #expect(edited.hunks.first?.lines.contains { $0.kind == .added && $0.text == "TWO" } == true)
    }

    @Test func readsOneFileOutOfACommit() throws {
        guard let repo = try makeRepo() else { return }
        defer { try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: repo.path).deletingLastPathComponent()) }

        let files = GitDiff.show(repo: repo.path, sha: repo.second, path: "b.txt")
        #expect(files.map(\.path) == ["b.txt"], "the path filter didn't hold")
        #expect(files.first?.additions == 1)
    }

    /// The first commit has no parent. `git show` handles it; a hand-rolled
    /// `sha^..sha` would fail, which is why the command doesn't do that.
    @Test func readsTheRootCommitWhichHasNoParent() throws {
        guard let repo = try makeRepo() else { return }
        defer { try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: repo.path).deletingLastPathComponent()) }

        let files = GitDiff.show(repo: repo.path, sha: repo.first)
        let added = try #require(files.first { $0.path == "a.txt" })
        #expect(added.additions == 3, "the root commit's file should read as all additions")
        #expect(added.deletions == 0)
    }
}
