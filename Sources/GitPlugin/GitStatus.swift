import Foundation

/// Where a repository stands: the branch, how it compares to its upstream, and
/// what has changed.
///
/// Read from `git status --branch --porcelain=v1`, which answers all of it in
/// one call. The alternative was four — `rev-parse` for the branch,
/// `rev-list --count` twice for the counts, `diff --name-status` twice for the
/// files — each with its own chance to disagree with the others about a
/// repository that is being written to while they run.
struct GitStatus: Equatable {
    var branch: String?
    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0
    /// Staged and unstaged entries, each with git's one-letter code.
    var staged: [Entry] = []
    var unstaged: [Entry] = []

    struct Entry: Equatable, Identifiable {
        /// `M`, `A`, `D`, `R`, or `?` for something not yet tracked.
        let code: Character
        let path: String
        var id: String { "\(code)\(path)" }

        /// What the letter means, spelled out.
        var describes: String {
            switch code {
            case "M": return "Modified"
            case "A": return "Added"
            case "D": return "Deleted"
            case "R": return "Renamed"
            case "C": return "Copied"
            case "?": return "Untracked"
            case "U": return "Conflicted"
            default: return String(code)
            }
        }
    }

    var isClean: Bool { staged.isEmpty && unstaged.isEmpty }

    static func read(_ repo: String) -> GitStatus {
        guard let out = Git.run(repo, ["status", "--branch", "--porcelain=v1"])
        else { return GitStatus() }
        return parse(out)
    }

    /// Parses porcelain v1 with a branch header.
    ///
    /// The format is stable by promise — that is what "porcelain" means — which
    /// is why it is worth parsing at all rather than reading the human output.
    ///
    /// Two columns of status: the first is what is staged, the second what is
    /// changed since. A file can be in both at once, which is exactly the case
    /// that makes "staged" and "unstaged" separate lists rather than one.
    static func parse(_ text: String) -> GitStatus {
        var status = GitStatus()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                parseBranch(String(line.dropFirst(3)), into: &status)
                continue
            }
            guard line.count > 3 else { continue }
            let characters = Array(line)
            let index = String(characters[0]), work = String(characters[1])
            // Untracked is reported as `??`, and belongs with the unstaged
            // work: it is what committing would miss.
            let path = unquote(String(characters[3...]))
            if index == "?" {
                status.unstaged.append(Entry(code: "?", path: path))
                continue
            }
            if index != " ", let code = index.first {
                status.staged.append(Entry(code: code, path: renamedTarget(path)))
            }
            if work != " ", let code = work.first {
                status.unstaged.append(Entry(code: code, path: renamedTarget(path)))
            }
        }
        return status
    }

    /// `main...origin/main [ahead 1, behind 2]`, or just `main` with no
    /// upstream, or `HEAD (no branch)` when detached.
    private static func parseBranch(_ text: String, into status: inout GitStatus) {
        var head = text
        if let bracket = head.firstIndex(of: "[") {
            let counts = head[head.index(after: bracket)...].prefix { $0 != "]" }
            for part in counts.components(separatedBy: ", ") {
                let words = part.split(separator: " ")
                guard words.count == 2, let n = Int(words[1]) else { continue }
                if words[0] == "ahead" { status.ahead = n }
                if words[0] == "behind" { status.behind = n }
            }
            head = String(head[..<bracket])
        }
        head = head.trimmingCharacters(in: .whitespaces)
        if let separator = head.range(of: "...") {
            status.branch = String(head[..<separator.lowerBound])
            status.upstream = String(head[separator.upperBound...])
        } else {
            status.branch = head.isEmpty ? nil : head
        }
    }

    /// A rename reads `old -> new`; the file that exists now is the new one.
    private static func renamedTarget(_ path: String) -> String {
        guard let arrow = path.range(of: " -> ") else { return path }
        return unquote(String(path[arrow.upperBound...]))
    }

    /// git quotes a path containing anything unusual. Only the quotes are
    /// stripped: the escapes inside are git's own and rare enough that
    /// mangling them here would be worse than leaving them visible.
    private static func unquote(_ path: String) -> String {
        guard path.hasPrefix("\""), path.hasSuffix("\""), path.count > 1 else { return path }
        return String(path.dropFirst().dropLast())
    }
}
