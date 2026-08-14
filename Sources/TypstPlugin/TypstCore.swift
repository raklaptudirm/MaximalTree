import Foundation

/// One compiler message, as the in-process engine reports it.
/// Lines are 1-based and columns 0-based, matching typst's conventions.
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

    /// All sections and tasks, in document order — extracted by the real typst
    /// parser (via the FFI). The parser is error-tolerant, so broken and unsaved
    /// buffers still produce an outline.
    static func outline(of source: String) -> [Item] {
        guard let parsed = TypstEngine.structure(in: source) else { return [] }
        return parsed.compactMap { item -> Item? in
            switch item.kind {
            case "section":
                guard let line = item.line, let level = item.level else { return nil }
                return .section(Section(level: level, title: item.title ?? "", line: line))
            case "task":
                guard let line = item.line, let index = item.index else { return nil }
                return .task(TaskItem(index: index, body: item.body ?? "task",
                                      done: item.done ?? false, due: item.due,
                                      tags: item.tags ?? [], line: line))
            default:
                return nil
            }
        }
        .sorted { $0.line < $1.line }
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

    /// Rewrite the source so the n-th `#task` flips its `done:` state, applying
    /// the exact edit the parser computed (flip the literal, insert into existing
    /// args, or add args to a bare call). Nil when the task can't be located.
    static func togglingTask(at index: Int, in source: String) -> String? {
        guard let parsed = TypstEngine.structure(in: source),
              let task = parsed.first(where: { $0.kind == "task" && $0.index == index }),
              let start = task.ts, let length = task.tl, let replacement = task.tr
        else { return nil }
        let ns = source as NSString
        guard start + length <= ns.length else { return nil }
        return ns.replacingCharacters(in: NSRange(location: start, length: length),
                                      with: replacement)
    }

    /// Outline of a document on disk (empty when unreadable).
    static func outline(ofFileAt url: URL) -> [Item] {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return outline(of: source)
    }

    /// Local files this document references via `#include`/`#import` — from the
    /// real parser; package imports (`@…`) are not file links.
    /// Words in a document, for the inspector's stats.
    ///
    /// Deliberately counts the source as written — typst markup included —
    /// because that's what the editor shows and what the reader is watching
    /// change. Rendering first would give a different (and, mid-edit,
    /// unstable) number.
    static func wordCount(of text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    static func links(of source: String) -> [String] {
        (TypstEngine.structure(in: source) ?? [])
            .filter { $0.kind == "link" }
            .compactMap(\.target)
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

}
