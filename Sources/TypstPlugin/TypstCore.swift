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

    /// Compile `source` as though it were the contents of `documentURL`. Prefers
    /// the in-process engine (Vendor/typst-ffi); falls back to the CLI only when
    /// the engine reports an internal failure.
    static func compile(source: String, documentURL: URL) async -> Output {
        await Task.detached(priority: .userInitiated) {
            let root = documentURL.deletingLastPathComponent()
            if let output = TypstEngine.compile(source: source, root: root) {
                return output
            }
            return compileSync(source: source, documentURL: documentURL)
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

    enum ExportFormat: String, CaseIterable {
        case pdf, svg, png

        var title: String { rawValue.uppercased() }
        /// Paged formats need a `{p}` page marker in the output path.
        var isPaged: Bool { self != .pdf }
    }

    /// Compile `source` to `destination` in the given format. For paged formats the
    /// filename gains `-{p}` (page number) before the extension, since a multi-page
    /// document can't land in a single SVG/PNG. Returns diagnostics; empty of errors
    /// means the export happened.
    static func export(source: String, documentURL: URL,
                       format: ExportFormat, to destination: URL) async -> [TypstDiagnostic] {
        await Task.detached(priority: .userInitiated) {
            exportSync(source: source, documentURL: documentURL,
                       format: format, to: destination)
        }.value
    }

    static func exportSync(source: String, documentURL: URL,
                           format: ExportFormat, to destination: URL) -> [TypstDiagnostic] {
        guard let executable else {
            return [TypstDiagnostic(severity: .error, line: nil, column: nil,
                                    message: "typst is not installed")]
        }

        var outPath = destination.path
        if format.isPaged {
            let stem = destination.deletingPathExtension()
            outPath = stem.path + "-{p}." + format.rawValue
        }

        let root = documentURL.deletingLastPathComponent()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["compile", "--diagnostic-format", "short",
                             "--format", format.rawValue,
                             "--root", root.path, "-", outPath]
        if format == .png { process.arguments?.insert(contentsOf: ["--ppi", "300"], at: 2) }
        process.currentDirectoryURL = root

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = Pipe()
        process.standardError = stderrPipe

        do { try process.run() } catch {
            return [TypstDiagnostic(severity: .error, line: nil, column: nil,
                                    message: "couldn't run typst: \(error.localizedDescription)")]
        }
        stdinPipe.fileHandleForWriting.write(Data(source.utf8))
        stdinPipe.fileHandleForWriting.closeFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseDiagnostics(String(decoding: stderrData, as: UTF8.self))
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

// MARK: - Editing operations

/// Pure text-edit computations for the prose keybindings. Each returns a minimal
/// `Edit` (what to replace, with what, and where the selection lands) rather than a
/// whole new document, so the editor applies it with proper undo granularity.
enum TypstEdit {
    struct Edit: Equatable {
        let range: NSRange          // region of the original text to replace
        let replacement: String
        let selection: NSRange      // selection in the *resulting* text
    }

    /// Toggle a symmetric marker (Typst: `*` strong, `_` emphasis, `` ` `` raw)
    /// around the selection:
    /// - empty selection → insert a marker pair, caret inside;
    /// - selection includes the markers → strip them;
    /// - markers sit just outside the selection → strip them;
    /// - otherwise → wrap, selection covering the inner text.
    static func toggleWrap(_ marker: String, in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let markerLength = (marker as NSString).length
        let selected = selection.length > 0 ? ns.substring(with: selection) : ""

        if selection.length == 0 {
            return Edit(range: selection,
                        replacement: marker + marker,
                        selection: NSRange(location: selection.location + markerLength, length: 0))
        }

        if selection.length >= 2 * markerLength,
           selected.hasPrefix(marker), selected.hasSuffix(marker) {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            return Edit(range: selection,
                        replacement: inner,
                        selection: NSRange(location: selection.location,
                                           length: (inner as NSString).length))
        }

        let before = NSRange(location: selection.location - markerLength, length: markerLength)
        let after = NSRange(location: selection.location + selection.length, length: markerLength)
        if before.location >= 0, after.location + after.length <= ns.length,
           ns.substring(with: before) == marker, ns.substring(with: after) == marker {
            return Edit(range: NSRange(location: before.location,
                                       length: selection.length + 2 * markerLength),
                        replacement: selected,
                        selection: NSRange(location: before.location, length: selection.length))
        }

        return Edit(range: selection,
                    replacement: marker + selected + marker,
                    selection: NSRange(location: selection.location + markerLength,
                                       length: selection.length))
    }

    /// Turn the selection into a `#task[…]` (or insert an empty one at the caret,
    /// caret placed inside the brackets).
    static func insertTask(in text: String, selection: NSRange) -> Edit {
        let ns = text as NSString
        let selected = selection.length > 0 ? ns.substring(with: selection) : ""
        let replacement = "#task[\(selected)]"
        let innerStart = selection.location + ("#task[" as NSString).length
        return Edit(range: selection,
                    replacement: replacement,
                    selection: selection.length > 0
                        ? NSRange(location: innerStart, length: (selected as NSString).length)
                        : NSRange(location: innerStart, length: 0))
    }
}

// MARK: - Structure references

/// A structural element of a Typst document, encoded as a canonicalizable
/// `typst://` NodeID (same URLComponents discipline as the git plugin's URIs):
///   typst://section?file=<path>&line=<n>
///   typst://task?file=<path>&index=<n>
///   typst://agenda?dir=<path>
struct TypstRef: Equatable {
    enum Kind: String {
        case section, task, agenda
    }

    let kind: Kind
    let path: String        // document path (section/task) or directory (agenda)
    let line: Int?          // section anchor
    let index: Int?         // n-th #task in the document

    static func section(file: String, line: Int) -> TypstRef {
        TypstRef(kind: .section, path: file, line: line, index: nil)
    }
    static func task(file: String, index: Int) -> TypstRef {
        TypstRef(kind: .task, path: file, line: nil, index: index)
    }
    static func agenda(dir: String) -> TypstRef {
        TypstRef(kind: .agenda, path: dir, line: nil, index: nil)
    }

    init(kind: Kind, path: String, line: Int?, index: Int?) {
        self.kind = kind
        self.path = path
        self.line = line
        self.index = index
    }

    init?(uri: String) {
        guard let components = URLComponents(string: uri), components.scheme == "typst",
              let host = components.host, let kind = Kind(rawValue: host) else { return nil }
        let query = { (name: String) -> String? in
            components.queryItems?.first { $0.name == name }?.value
        }
        switch kind {
        case .section:
            guard let file = query("file"), let line = query("line").flatMap(Int.init) else { return nil }
            self = .section(file: file, line: line)
        case .task:
            guard let file = query("file"), let index = query("index").flatMap(Int.init) else { return nil }
            self = .task(file: file, index: index)
        case .agenda:
            guard let dir = query("dir") else { return nil }
            self = .agenda(dir: dir)
        }
    }

    var uri: String {
        var components = URLComponents()
        components.scheme = "typst"
        components.host = kind.rawValue
        switch kind {
        case .section:
            components.queryItems = [URLQueryItem(name: "file", value: path),
                                     URLQueryItem(name: "line", value: line.map(String.init))]
        case .task:
            components.queryItems = [URLQueryItem(name: "file", value: path),
                                     URLQueryItem(name: "index", value: index.map(String.init))]
        case .agenda:
            components.queryItems = [URLQueryItem(name: "dir", value: path)]
        }
        return components.string ?? "typst://\(kind.rawValue)"
    }

    var fileURL: URL { URL(fileURLWithPath: path) }
}

// MARK: - Document structure

/// Source-level structure extraction: headings and `#task(...)` calls with their
/// locations. Parses text (not the compiler) so outlines stay alive on unsaved and
/// even broken buffers — a deliberate deviation from query-based extraction; the
/// conventions themselves are typst-native, so a `typst query` upgrade is drop-in.
enum TypstStructure {
    struct Section: Equatable, Sendable {
        let level: Int
        let title: String
        let line: Int          // 1-based
    }

    struct TaskItem: Equatable, Sendable {
        let index: Int         // n-th #task in the document, the toggle key
        let body: String
        let done: Bool
        let due: String?       // as written, conventionally "YYYY-MM-DD"
        let tags: [String]
        let line: Int          // 1-based
    }

    enum Item: Equatable, Sendable {
        case section(Section)
        case task(TaskItem)

        var line: Int {
            switch self {
            case .section(let section): return section.line
            case .task(let task): return task.line
            }
        }
    }

    /// All sections and tasks, in document order.
    static func outline(of source: String) -> [Item] {
        var items: [Item] = []
        let ns = source as NSString

        if let headingRegex = try? NSRegularExpression(pattern: #"^ *(=+) +(.*)$"#,
                                                       options: [.anchorsMatchLines]) {
            headingRegex.enumerateMatches(in: source,
                                          range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match else { return }
                let level = match.range(at: 1).length
                let title = ns.substring(with: match.range(at: 2))
                    .trimmingCharacters(in: .whitespaces)
                items.append(.section(Section(level: level, title: title,
                                              line: line(of: match.range.location, in: ns))))
            }
        }

        for (index, occurrence) in taskOccurrences(in: source).enumerated() {
            let details = parseTask(after: occurrence, in: ns)
            items.append(.task(TaskItem(index: index,
                                        body: details.body,
                                        done: details.done,
                                        due: details.due,
                                        tags: details.tags,
                                        line: line(of: occurrence.location, in: ns))))
        }

        return items.sorted { $0.line < $1.line }
    }

    /// The direct children of the section anchored at `sectionLine` (nil = the
    /// document's top level): child sections one visible level down, plus tasks not
    /// inside any child section.
    static func directChildren(ofSectionAt sectionLine: Int?, in items: [Item]) -> [Item] {
        var parentLevel = 0
        var slice = items[...]

        if let sectionLine {
            guard let start = items.firstIndex(where: {
                if case .section(let section) = $0 { return section.line == sectionLine }
                return false
            }), case .section(let parent) = items[start] else { return [] }
            parentLevel = parent.level
            var end = items.endIndex
            for i in items.index(after: start)..<items.endIndex {
                if case .section(let section) = items[i], section.level <= parentLevel {
                    end = i
                    break
                }
            }
            slice = items[items.index(after: start)..<end]
        }

        let childLevel = slice.compactMap { item -> Int? in
            if case .section(let section) = item { return section.level }
            return nil
        }.min()

        var result: [Item] = []
        var insideChild = false
        for item in slice {
            switch item {
            case .section(let section):
                if section.level == childLevel {
                    result.append(item)
                    insideChild = true
                }
            case .task:
                if !insideChild { result.append(item) }
            }
        }
        return result
    }

    /// Rewrite the source so the n-th `#task` flips its `done:` state. Returns nil
    /// when the task can't be located.
    static func togglingTask(at index: Int, in source: String) -> String? {
        let occurrences = taskOccurrences(in: source)
        guard occurrences.indices.contains(index) else { return nil }
        let ns = source as NSString
        let occurrence = occurrences[index]
        let afterTask = occurrence.location + occurrence.length

        guard afterTask < ns.length else { return nil }
        if ns.character(at: afterTask) == UInt8(ascii: "(") {
            guard let args = balancedRange(in: ns, from: afterTask,
                                           open: "(", close: ")") else { return nil }
            let argsText = ns.substring(with: args)
            let inner = NSRange(location: args.location + 1, length: args.length - 2)
            if let doneRegex = try? NSRegularExpression(pattern: #"done\s*:\s*(true|false)"#),
               let match = doneRegex.firstMatch(in: source, range: args) {
                let flipped = ns.substring(with: match.range(at: 1)) == "true"
                    ? "done: false" : "done: true"
                return ns.replacingCharacters(in: match.range, with: flipped)
            }
            // Args without done: — prepend it.
            let insertion = inner.length == 0 || argsText.dropFirst().dropLast()
                .trimmingCharacters(in: .whitespaces).isEmpty ? "done: true" : "done: true, "
            return ns.replacingCharacters(in: NSRange(location: args.location + 1, length: 0),
                                          with: insertion)
        }
        // Bare `#task[...]` — give it arguments.
        return ns.replacingCharacters(in: NSRange(location: afterTask, length: 0),
                                      with: "(done: true)")
    }

    /// Outline of a document on disk (empty when unreadable).
    static func outline(ofFileAt url: URL) -> [Item] {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return outline(of: source)
    }

    /// Local files this document references via `#include "…"` / `#import "…"`.
    /// Package imports (`@local/…`, `@preview/…`) are not file links and are skipped.
    static func links(of source: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"#(?:include|import)\s*"([^"@][^"]*)""#) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    /// All `.typ` files under `dir` (recursive, hidden skipped, capped).
    static func typFiles(under dir: URL, limit: Int = 300) -> [URL] {
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "typ" { files.append(url) }
                if files.count >= limit { break }
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Documents under `dir` that link to `file` (their `#include`/`#import` paths,
    /// resolved relative to each document, hit `file`).
    static func backlinks(to file: URL, under dir: URL) -> [URL] {
        let target = file.standardizedFileURL.path
        return typFiles(under: dir).filter { candidate in
            guard candidate.standardizedFileURL.path != target,
                  let source = try? String(contentsOf: candidate, encoding: .utf8)
            else { return false }
            let base = candidate.deletingLastPathComponent()
            return links(of: source).contains { link in
                URL(fileURLWithPath: link, relativeTo: base).standardizedFileURL.path == target
            }
        }
    }

    /// Every task in every `.typ` under `dir` (recursive, hidden files skipped,
    /// capped defensively), sorted: undone before done, then by due date (none
    /// last), then location. ISO dates sort lexically.
    static func agendaTasks(under dir: URL) -> [(file: URL, task: TaskItem)] {
        var files: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if url.pathExtension.lowercased() == "typ" { files.append(url) }
                if files.count >= 300 { break }
            }
        }
        var result: [(file: URL, task: TaskItem)] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            for item in outline(ofFileAt: file) {
                if case .task(let task) = item { result.append((file, task)) }
            }
        }
        return result.sorted { a, b in
            if a.task.done != b.task.done { return !a.task.done }
            switch (a.task.due, b.task.due) {
            case (let l?, let r?) where l != r: return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return (a.file.path, a.task.line) < (b.file.path, b.task.line)
            }
        }
    }

    // MARK: Internals

    private static func taskOccurrences(in source: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: #"#task(?![A-Za-z0-9_-])"#)
        else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map(\.range)
    }

    private static func parseTask(
        after occurrence: NSRange, in ns: NSString
    ) -> (body: String, done: Bool, due: String?, tags: [String]) {
        var cursor = occurrence.location + occurrence.length
        var done = false
        var due: String?
        var tags: [String] = []

        if cursor < ns.length, ns.character(at: cursor) == UInt8(ascii: "("),
           let args = balancedRange(in: ns, from: cursor, open: "(", close: ")") {
            let text = ns.substring(with: args)
            done = text.range(of: #"done\s*:\s*true"#, options: .regularExpression) != nil
            if let match = text.range(of: #"due\s*:\s*"([^"]*)""#, options: .regularExpression) {
                let matched = String(text[match])
                due = matched.split(separator: "\"").dropFirst().first.map(String.init)
            }
            if let match = text.range(of: #"tags\s*:\s*\(([^)]*)\)"#, options: .regularExpression) {
                let inner = String(text[match]).drop { $0 != "(" }.dropFirst().dropLast()
                tags = inner.split(separator: ",").map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                }.filter { !$0.isEmpty }
            }
            cursor = args.location + args.length
        }

        var body = ""
        if cursor < ns.length, ns.character(at: cursor) == UInt8(ascii: "["),
           let bodyRange = balancedRange(in: ns, from: cursor, open: "[", close: "]") {
            body = ns.substring(with: NSRange(location: bodyRange.location + 1,
                                              length: bodyRange.length - 2))
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if body.count > 80 { body = String(body.prefix(79)) + "…" }
        }
        return (body.isEmpty ? "task" : body, done, due, tags)
    }

    /// Range of a balanced delimiter pair starting at `start` (which must hold
    /// `open`), inclusive of both delimiters.
    private static func balancedRange(
        in ns: NSString, from start: Int, open: Character, close: Character
    ) -> NSRange? {
        let openChar = open.asciiValue.map(UInt16.init) ?? 0
        let closeChar = close.asciiValue.map(UInt16.init) ?? 0
        var depth = 0
        var i = start
        while i < ns.length {
            let char = ns.character(at: i)
            if char == openChar { depth += 1 }
            if char == closeChar {
                depth -= 1
                if depth == 0 { return NSRange(location: start, length: i - start + 1) }
            }
            i += 1
        }
        return nil
    }

    private static func line(of location: Int, in ns: NSString) -> Int {
        var line = 1
        var i = 0
        while i < location && i < ns.length {
            if ns.character(at: i) == UInt8(ascii: "\n") { line += 1 }
            i += 1
        }
        return line
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
