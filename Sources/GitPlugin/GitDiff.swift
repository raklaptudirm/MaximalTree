import Foundation

/// Unified diff, parsed into something a view can draw.
///
/// Kept apart from both the git CLI and the views: this is the part that has
/// to be exactly right, and the only part worth testing line by line.
enum GitDiff {
    struct Line: Equatable, Identifiable {
        enum Kind: Equatable { case context, added, removed }

        let kind: Kind
        let text: String
        /// Line numbers on each side, absent where the line doesn't exist —
        /// an added line has no number in the old file, and vice versa.
        let oldNumber: Int?
        let newNumber: Int?

        var id: String { "\(oldNumber ?? -1):\(newNumber ?? -1):\(kind)" }
    }

    struct Hunk: Equatable, Identifiable {
        /// The `@@ … @@` line, section heading and all — git puts the enclosing
        /// function there, which is often the most useful thing on screen.
        let header: String
        let lines: [Line]

        var id: String { header }
    }

    struct File: Equatable, Identifiable {
        let path: String
        let hunks: [Hunk]
        /// Git won't diff binary content; say so rather than showing nothing.
        let isBinary: Bool

        var id: String { path }
        var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } } }
        var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .removed } } }
        /// A file git considers changed but shows no lines for — a pure rename,
        /// a mode change, an empty file.
        var isEmpty: Bool { hunks.isEmpty && !isBinary }
    }

    /// The diff a commit introduced — for one file, or all of them.
    ///
    /// Explicitly `--no-color`/`--no-ext-diff`: this parses git's output, and a
    /// user whose config turns on colour or hands diffing to an external tool
    /// would otherwise get an unreadable one. Rename detection is on, so a
    /// moved file reads as a move instead of a delete and an add.
    static func show(repo: String, sha: String, path: String? = nil) -> [File] {
        var arguments = ["show", "--patch", "--format=", "--no-color", "--no-ext-diff",
                         "-M", sha]
        if let path { arguments += ["--", path] }
        guard let output = Git.run(repo, arguments) else { return [] }
        return parse(output)
    }

    /// What staging this file recorded: HEAD against the index.
    static func staged(repo: String, path: String? = nil) -> [File] {
        diff(repo: repo, arguments: ["--cached"], path: path)
    }

    /// What staging *missed*: the index against the file on disk.
    ///
    /// This is the diff between the version `git commit` would record and the
    /// one in front of you — edits made after staging, which are easy to lose
    /// track of and are exactly what a staged-file view should be able to show.
    static func unstaged(repo: String, path: String? = nil) -> [File] {
        diff(repo: repo, arguments: [], path: path)
    }

    private static func diff(repo: String, arguments: [String], path: String?) -> [File] {
        var command = ["diff", "--no-color", "--no-ext-diff", "-M"] + arguments
        if let path { command += ["--", path] }
        guard let output = Git.run(repo, command) else { return [] }
        return parse(output)
    }

    /// Parse `git diff`/`git show` output. Unknown lines are skipped rather
    /// than guessed at: this runs on whatever the installed git prints, and a
    /// diff that renders a bit less is better than one that renders wrong.
    static func parse(_ text: String) -> [File] {
        var files: [File] = []
        var path: String?
        var hunks: [Hunk] = []
        var isBinary = false
        var header: String?
        var lines: [Line] = []
        var oldNumber = 0
        var newNumber = 0

        func closeHunk() {
            if let header { hunks.append(Hunk(header: header, lines: lines)) }
            header = nil
            lines = []
        }
        func closeFile() {
            closeHunk()
            if let path { files.append(File(path: path, hunks: hunks, isBinary: isBinary)) }
            path = nil
            hunks = []
            isBinary = false
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                closeFile()
                // Only a fallback: a path containing a space is ambiguous here,
                // and unambiguous on the +++/--- lines below.
                path = line.components(separatedBy: " b/").last
                continue
            }
            if line.hasPrefix("+++ ") {
                let value = String(line.dropFirst(4))
                // /dev/null means the file was deleted — keep the old path,
                // which the `---` line already gave us.
                if value != "/dev/null" { path = strippingPrefix(value) }
                continue
            }
            if line.hasPrefix("--- ") {
                let value = String(line.dropFirst(4))
                if value != "/dev/null", path == nil { path = strippingPrefix(value) }
                continue
            }
            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                isBinary = true
                continue
            }
            if line.hasPrefix("@@") {
                closeHunk()
                header = line
                let numbers = hunkStart(line)
                oldNumber = numbers.old
                newNumber = numbers.new
                continue
            }
            guard header != nil else { continue }   // index/mode/similarity lines
            if line.hasPrefix("+") {
                lines.append(Line(kind: .added, text: String(line.dropFirst()),
                                  oldNumber: nil, newNumber: newNumber))
                newNumber += 1
            } else if line.hasPrefix("-") {
                lines.append(Line(kind: .removed, text: String(line.dropFirst()),
                                  oldNumber: oldNumber, newNumber: nil))
                oldNumber += 1
            } else if line.hasPrefix(" ") || line.isEmpty {
                // Git writes context with a leading space; some tools drop it
                // on empty lines, so an empty line inside a hunk is context.
                lines.append(Line(kind: .context, text: String(line.dropFirst()),
                                  oldNumber: oldNumber, newNumber: newNumber))
                oldNumber += 1
                newNumber += 1
            }
            // "\ No newline at end of file" and anything else: not a real line.
        }
        closeFile()
        return files
    }

    /// `a/path` and `b/path` prefixes are git's, not the file's.
    private static func strippingPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") { return String(path.dropFirst(2)) }
        return path
    }

    /// The starting line numbers in `@@ -old,count +new,count @@`.
    private static func hunkStart(_ header: String) -> (old: Int, new: Int) {
        var old = 1
        var new = 1
        for field in header.split(separator: " ") {
            let numbers = field.dropFirst()      // the - or +
                .split(separator: ",").first.flatMap { Int($0) }
            guard let numbers else { continue }
            if field.hasPrefix("-") { old = numbers }
            if field.hasPrefix("+") { new = numbers }
        }
        return (old, new)
    }
}
