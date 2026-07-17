import Foundation

/// One compiler message, parsed from `--diagnostic-format short` output:
/// `<file>:<line>:<col>: <severity>: <message>` (location optional).
/// Lines are 1-based and columns 0-based, as typst reports them.
struct TypstDiagnostic: Equatable, Identifiable, Sendable {
    enum Severity: String, Sendable {
        case error, warning
    }

    let severity: Severity
    let line: Int?
    let column: Int?
    let message: String

    var id: String { "\(line ?? 0):\(column ?? 0):\(severity.rawValue):\(message)" }
}

/// Wraps the `typst` CLI. Compiles the *buffer* (not the saved file) by piping it
/// through stdin with `--root` at the document's directory, so live preview shows
/// unsaved edits while relative imports/images/reads still resolve.
enum TypstCompiler {
    struct Output: Sendable {
        let pdf: Data?
        let diagnostics: [TypstDiagnostic]
    }

    /// A GUI app doesn't inherit a login shell's PATH, so probe the places package
    /// managers actually install typst (Homebrew, Nix profiles, cargo).
    static let executable: URL? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/etc/profiles/per-user/\(NSUserName())/bin/typst",   // nix-darwin per-user
            "/run/current-system/sw/bin/typst",                   // nix-darwin system
            "\(home)/.nix-profile/bin/typst",
            "/opt/homebrew/bin/typst",
            "/usr/local/bin/typst",
            "\(home)/.cargo/bin/typst",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }()

    static var isAvailable: Bool { executable != nil }

    /// Compile `source` as though it were the contents of `documentURL`.
    static func compile(source: String, documentURL: URL) async -> Output {
        await Task.detached(priority: .userInitiated) {
            compileSync(source: source, documentURL: documentURL)
        }.value
    }

    static func compileSync(source: String, documentURL: URL) -> Output {
        guard let executable else {
            return Output(pdf: nil, diagnostics: [
                TypstDiagnostic(severity: .error, line: nil, column: nil,
                                message: "typst is not installed")
            ])
        }

        let root = documentURL.deletingLastPathComponent()
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typst-preview-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: outURL) }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["compile", "--diagnostic-format", "short",
                             "--root", root.path, "-", outURL.path]
        process.currentDirectoryURL = root

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = Pipe()
        process.standardError = stderrPipe

        do { try process.run() } catch {
            return Output(pdf: nil, diagnostics: [
                TypstDiagnostic(severity: .error, line: nil, column: nil,
                                message: "couldn't run typst: \(error.localizedDescription)")
            ])
        }

        stdinPipe.fileHandleForWriting.write(Data(source.utf8))
        stdinPipe.fileHandleForWriting.closeFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let diagnostics = parseDiagnostics(String(decoding: stderrData, as: UTF8.self))
        return Output(pdf: try? Data(contentsOf: outURL), diagnostics: diagnostics)
    }

    /// Parse `--diagnostic-format short` lines. Tolerates messages without a
    /// location (`error: no such file`) and skips anything that isn't a diagnostic.
    static func parseDiagnostics(_ stderr: String) -> [TypstDiagnostic] {
        let pattern = /^(?:(?<file>[^:\n]+):(?<line>\d+):(?<col>\d+):\s*)?(?<sev>error|warning):\s?(?<msg>.*)$/
        return stderr.split(separator: "\n").compactMap { rawLine in
            guard let match = String(rawLine).wholeMatch(of: pattern),
                  let severity = TypstDiagnostic.Severity(rawValue: String(match.sev))
            else { return nil }
            return TypstDiagnostic(
                severity: severity,
                line: match.line.flatMap { Int($0) },
                column: match.col.flatMap { Int($0) },
                message: String(match.msg)
            )
        }
    }
}

// MARK: - Notes

/// The notes side of the plugin: the local typst package our conventions live in,
/// plus note-file creation helpers. Typst-native by design — `#task(...)` renders
/// real checkboxes via the package AND emits `#metadata(...) <mt-task>` so structure
/// can be extracted with `typst query` (Phase 2).
enum TypstNotes {
    static let packageName = "mtnotes"
    static let packageVersion = "0.1.0"
    static var packageImport: String { "#import \"@local/\(packageName):\(packageVersion)\": *" }

    static let manifest = """
    [package]
    name = "mtnotes"
    version = "0.1.0"
    entrypoint = "lib.typ"
    authors = ["MaximalTree"]
    description = "Note and task helpers for MaximalTree's Typst plugin."
    """

    static let library = #"""
    // mtnotes — note and task helpers for MaximalTree's Typst plugin.
    //
    // Each construct both renders nicely AND emits queryable metadata, so the
    // MaximalTree agenda/outline can extract structure with `typst query`.

    // A task line: renders a checkbox, optional due date and tags.
    //   #task[Buy milk]
    //   #task(done: true, due: "2026-07-20", tags: ("errands",))[Post letter]
    #let task(done: false, due: none, tags: (), body) = block[
      #metadata((kind: "task", done: done, due: due, tags: tags)) <mt-task>
      #if done [☑] else [☐] #body
      #if tags.len() > 0 [
        #h(0.4em)
        #text(size: 0.8em, fill: luma(120))[#tags.map(t => "#" + t).join(" ")]
      ]
      #if due != none [
        #h(0.4em)
        #text(size: 0.8em, fill: luma(120))[due: #due]
      ]
    ]
    """#

    /// The package directory inside typst's data directory (or a custom root, for
    /// tests): `<data>/typst/packages/local/mtnotes/<version>/`.
    static func packageDirectory(dataDirectory: URL? = nil) -> URL {
        let base = dataDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("typst/packages/local", isDirectory: true)
            .appendingPathComponent(packageName, isDirectory: true)
            .appendingPathComponent(packageVersion, isDirectory: true)
    }

    /// Write the package if missing or stale. Idempotent; safe to call at every
    /// plugin load. Returns the package directory.
    @discardableResult
    static func installPackage(dataDirectory: URL? = nil) throws -> URL {
        let dir = packageDirectory(dataDirectory: dataDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeIfChanged(manifest, to: dir.appendingPathComponent("typst.toml"))
        try writeIfChanged(library, to: dir.appendingPathComponent("lib.typ"))
        return dir
    }

    private static func writeIfChanged(_ contents: String, to url: URL) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents {
            return
        }
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Note files

    /// `<dir>/2026-07-17 Untitled.typ`, uniqued with a counter when taken.
    static func newNoteURL(in directory: URL, date: Date = .now) -> URL {
        let day = isoDay(date)
        var name = "\(day) Untitled.typ"
        var counter = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(day) Untitled \(counter).typ"
            counter += 1
        }
        return directory.appendingPathComponent(name)
    }

    /// `<dir>/2026-07-17.typ` — one per day, shared by every "daily note" call.
    static func dailyNoteURL(in directory: URL, date: Date = .now) -> URL {
        directory.appendingPathComponent("\(isoDay(date)).typ")
    }

    static func noteTemplate(title: String) -> String {
        """
        \(packageImport)

        = \(title)

        """
    }

    static func dailyNoteTemplate(date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return """
        \(packageImport)

        = \(formatter.string(from: date))

        """
    }

    private static func isoDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Syntax

/// A fast, regex-based tokenizer for Typst markup. Foundation-only so it's unit
/// testable; the highlighter maps kinds to editor capture names. Deliberately
/// approximate — the goal is readable markup, not a grammar. (Replaced by semantic
/// tokens if/when tinymist lands, per the plugin plan.)
enum TypstSyntax {
    enum TokenKind: Equatable, Sendable {
        case comment, raw, math, heading, strong, emphasis, call, label, reference
    }

    struct Token: Equatable, Sendable {
        let range: NSRange
        let kind: TokenKind
    }

    /// Tokenize the whole text. Exclusive regions (comments, raw, math) are claimed
    /// first so their contents aren't re-tokenized as markup.
    static func tokens(in text: String) -> [Token] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var claimed = IndexSet()
        var result: [Token] = []

        func scan(_ pattern: String, _ kind: TokenKind,
                  options: NSRegularExpression.Options = [], exclusive: Bool = false) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            regex.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let range = match?.range, range.length > 0 else { return }
                let indices = range.location..<(range.location + range.length)
                guard !claimed.intersects(integersIn: indices) else { return }
                if exclusive { claimed.insert(integersIn: indices) }
                result.append(Token(range: range, kind: kind))
            }
        }

        scan(#"```[\s\S]*?```"#, .raw, exclusive: true)
        scan(#"/\*[\s\S]*?\*/"#, .comment, exclusive: true)
        scan(#"//[^\n]*"#, .comment, exclusive: true)
        scan(#"`[^`\n]+`"#, .raw, exclusive: true)
        scan(#"\$[^$]{1,400}?\$"#, .math, options: [.dotMatchesLineSeparators], exclusive: true)
        scan(#"^ *=+ [^\n]*"#, .heading, options: [.anchorsMatchLines])
        scan(#"\*[^*\n]+\*"#, .strong)
        scan(#"(?<![A-Za-z0-9])_[^_\n]+_(?![A-Za-z0-9])"#, .emphasis)
        scan(#"#[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)*"#, .call)
        scan(#"<[A-Za-z][A-Za-z0-9_-]*>"#, .label)
        scan(#"@[A-Za-z][A-Za-z0-9_:-]*"#, .reference)

        return result.sorted { $0.range.location < $1.range.location }
    }
}
