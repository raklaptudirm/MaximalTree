import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

@Suite struct TypstDiagnosticsTests {
    @Test func parsesErrorWithLocation() {
        let diags = TypstCompiler.parseDiagnostics(
            "<stdin>:2:1: error: unknown variable: nonexistent\n")
        #expect(diags == [TypstDiagnostic(severity: .error, line: 2, column: 1,
                                          message: "unknown variable: nonexistent")])
    }

    @Test func parsesWarningWithFilePath() {
        let diags = TypstCompiler.parseDiagnostics(
            "chapters/intro.typ:14:8: warning: unknown font family: nosuchfont\n")
        #expect(diags.count == 1)
        #expect(diags[0].severity == .warning)
        #expect(diags[0].line == 14)
        #expect(diags[0].column == 8)
    }

    @Test func parsesLocationlessError() {
        let diags = TypstCompiler.parseDiagnostics("error: input file not found\n")
        #expect(diags == [TypstDiagnostic(severity: .error, line: nil, column: nil,
                                          message: "input file not found")])
    }

    @Test func skipsNonDiagnosticNoise() {
        let diags = TypstCompiler.parseDiagnostics(
            "compiling...\n<stdin>:1:0: error: boom\nsome trailing output\n")
        #expect(diags.count == 1)
        #expect(diags[0].message == "boom")
    }
}

@Suite struct TypstNotesTests {
    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typst-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func packageInstallIsIdempotent() throws {
        let data = try tempDir()
        defer { try? FileManager.default.removeItem(at: data) }

        let dir = try TypstNotes.installPackage(dataDirectory: data)
        let manifest = dir.appendingPathComponent("typst.toml")
        let library = dir.appendingPathComponent("lib.typ")
        #expect(FileManager.default.fileExists(atPath: manifest.path))
        #expect(try String(contentsOf: library, encoding: .utf8) == TypstNotes.library)

        let firstDate = try FileManager.default
            .attributesOfItem(atPath: library.path)[.modificationDate] as? Date
        try TypstNotes.installPackage(dataDirectory: data)   // second run: no rewrite
        let secondDate = try FileManager.default
            .attributesOfItem(atPath: library.path)[.modificationDate] as? Date
        #expect(firstDate == secondDate)
    }

    @Test func newNoteURLsAreUniqued() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)

        let first = TypstNotes.newNoteURL(in: dir, date: date)
        try "x".write(to: first, atomically: true, encoding: .utf8)
        let second = TypstNotes.newNoteURL(in: dir, date: date)

        #expect(first != second)
        #expect(second.lastPathComponent.hasSuffix(" 2.typ"))
    }

    @Test func dailyNoteURLIsStableForADay() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let noon = Date(timeIntervalSince1970: 1_790_000_000)
        let laterSameDay = noon.addingTimeInterval(3600)
        #expect(TypstNotes.dailyNoteURL(in: dir, date: noon)
                == TypstNotes.dailyNoteURL(in: dir, date: laterSameDay))
    }

    @Test func templatesImportThePackage() {
        #expect(TypstNotes.noteTemplate(title: "T").contains("@local/mtnotes"))
        #expect(TypstNotes.dailyNoteTemplate().contains("@local/mtnotes"))
    }
}

@Suite struct TypstSyntaxTests {
    private func kinds(_ text: String) -> [TypstSyntax.TokenKind] {
        TypstSyntax.tokens(in: text).map(\.kind)
    }

    @Test func tokenizesHeadingsAtLineStartOnly() {
        #expect(kinds("= Title\n") == [.heading])
        #expect(kinds("a = b\n").isEmpty)                 // not a heading mid-line
    }

    @Test func commentsClaimTheirContents() {
        // The #call inside the comment must not be tokenized separately.
        #expect(kinds("// has #call inside\n") == [.comment])
        #expect(kinds("/* = not a heading */") == [.comment])
    }

    @Test func markupKinds() {
        #expect(kinds("*bold*") == [.strong])
        #expect(kinds("_emph_") == [.emphasis])
        #expect(kinds("`raw`") == [.raw])
        #expect(kinds("$x^2$") == [.math])
        #expect(kinds("#import x") == [.call])
        #expect(kinds("<label>") == [.label])
        #expect(kinds("@reference") == [.reference])
    }

    @Test func rawClaimsItsContents() {
        let tokens = TypstSyntax.tokens(in: "```\n#code() = *x*\n```")
        #expect(tokens.count == 1)
        #expect(tokens[0].kind == .raw)
    }

    @Test func tokenRangesAreValid() {
        let text = "= H\nSome *bold* and #call(x) here $m$\n"
        let ns = text as NSString
        for token in TypstSyntax.tokens(in: text) {
            #expect(token.range.location + token.range.length <= ns.length)
        }
    }
}

@Suite struct TypstRefTests {
    @Test func urisRoundTripAndCanonicalize() throws {
        let refs = [
            TypstRef.section(file: "/Users/x/my notes/doc.typ", line: 12),
            TypstRef.task(file: "/Users/x/doc.typ", index: 3),
            TypstRef.agenda(dir: "/Users/x/notes"),
        ]
        for ref in refs {
            #expect(TypstRef(uri: ref.uri) == ref)
            let canonical = try #require(NodeID(ref.uri)?.uri)
            #expect(NodeID(canonical)?.uri == canonical)      // idempotent
            #expect(TypstRef(uri: canonical) == ref)          // survives canonicalization
        }
    }
}

@Suite struct TypstStructureTests {
    private let doc = """
    = Project
    #task[Top-level thing]

    == Design
    Some prose.
    #task(done: true)[Sketch the API]
    #task(due: "2026-07-20", tags: ("deep", "urgent"))[Write the core]

    == Build
    #task(done: false)[Set up CI]

    = Appendix
    """

    @Test func outlineFindsSectionsAndTasks() {
        let items = TypstStructure.outline(of: doc)
        let sections = items.compactMap { if case .section(let s) = $0 { return s } else { return nil } }
        let tasks = items.compactMap { if case .task(let t) = $0 { return t } else { return nil } }

        #expect(sections.map(\.title) == ["Project", "Design", "Build", "Appendix"])
        #expect(sections.map(\.level) == [1, 2, 2, 1])
        #expect(tasks.count == 4)
        #expect(tasks[0].body == "Top-level thing")
        #expect(tasks[1].done)
        #expect(tasks[2].due == "2026-07-20")
        #expect(tasks[2].tags == ["deep", "urgent"])
        #expect(!tasks[3].done)
    }

    @Test func nestingAssignsChildrenCorrectly() throws {
        let items = TypstStructure.outline(of: doc)

        // Top level: the two level-1 sections; the top task belongs to "Project".
        let top = TypstStructure.directChildren(ofSectionAt: nil, in: items)
        #expect(top.count == 2)

        let projectLine = 1
        let projectChildren = TypstStructure.directChildren(ofSectionAt: projectLine, in: items)
        // task + Design + Build (the deeper tasks belong to those subsections)
        #expect(projectChildren.count == 3)
        guard case .task(let firstChild) = projectChildren[0] else {
            Issue.record("expected the top-level task first"); return
        }
        #expect(firstChild.body == "Top-level thing")

        guard case .section(let design) = projectChildren[1] else {
            Issue.record("expected Design"); return
        }
        let designChildren = TypstStructure.directChildren(ofSectionAt: design.line, in: items)
        #expect(designChildren.count == 2)     // its two tasks
    }

    @Test func togglingFlipsExplicitDone() throws {
        let toggled = try #require(TypstStructure.togglingTask(at: 1, in: doc))
        #expect(toggled.contains("#task(done: false)[Sketch the API]"))
        let back = try #require(TypstStructure.togglingTask(at: 1, in: toggled))
        #expect(back.contains("#task(done: true)[Sketch the API]"))
    }

    @Test func togglingInsertsDoneIntoExistingArgs() throws {
        let toggled = try #require(TypstStructure.togglingTask(at: 2, in: doc))
        #expect(toggled.contains(#"#task(done: true, due: "2026-07-20""#))
    }

    @Test func togglingBareTaskGainsArgs() throws {
        let toggled = try #require(TypstStructure.togglingTask(at: 0, in: doc))
        #expect(toggled.contains("#task(done: true)[Top-level thing]"))
    }

    @Test func agendaScansAndSorts() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typst-agenda-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "#task(due: \"2026-09-01\")[Later]\n#task(done: true)[Finished]"
            .write(to: dir.appendingPathComponent("b.typ"), atomically: true, encoding: .utf8)
        try "#task(due: \"2026-08-01\")[Sooner]\n#task[Undated]"
            .write(to: dir.appendingPathComponent("a.typ"), atomically: true, encoding: .utf8)

        let tasks = TypstStructure.agendaTasks(under: dir)
        #expect(tasks.map { $0.task.body } == ["Sooner", "Later", "Undated", "Finished"])
    }
}

@Suite struct TypstEditTests {
    private func apply(_ edit: TypstEdit.Edit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test func wrapSelection() {
        let text = "make this bold"
        let edit = TypstEdit.toggleWrap("*", in: text, selection: NSRange(location: 10, length: 4))
        #expect(apply(edit, to: text) == "make this *bold*")
        #expect(edit.selection == NSRange(location: 11, length: 4))   // inner text stays selected
    }

    @Test func unwrapWhenSelectionIncludesMarkers() {
        let text = "make this *bold*"
        let edit = TypstEdit.toggleWrap("*", in: text, selection: NSRange(location: 10, length: 6))
        #expect(apply(edit, to: text) == "make this bold")
    }

    @Test func unwrapWhenMarkersSitOutsideSelection() {
        let text = "make this *bold*"
        let edit = TypstEdit.toggleWrap("*", in: text, selection: NSRange(location: 11, length: 4))
        #expect(apply(edit, to: text) == "make this bold")
        #expect(edit.selection == NSRange(location: 10, length: 4))
    }

    @Test func emptySelectionInsertsPairWithCaretInside() {
        let edit = TypstEdit.toggleWrap("_", in: "ab", selection: NSRange(location: 1, length: 0))
        #expect(apply(edit, to: "ab") == "a__b")
        #expect(edit.selection == NSRange(location: 2, length: 0))
    }

    @Test func insertTaskWrapsSelection() {
        let text = "Buy milk"
        let edit = TypstEdit.insertTask(in: text, selection: NSRange(location: 0, length: 8))
        #expect(apply(edit, to: text) == "#task[Buy milk]")
    }

    @Test func insertTaskAtCaret() {
        let edit = TypstEdit.insertTask(in: "", selection: NSRange(location: 0, length: 0))
        #expect(apply(edit, to: "") == "#task[]")
        #expect(edit.selection == NSRange(location: 6, length: 0))    // caret in brackets
    }
}

@Suite struct TypstLinksTests {
    @Test func parsesIncludesAndImportsSkippingPackages() {
        let source = """
        #import "@local/mtnotes:0.1.0": *
        #import "helpers.typ": thing
        #include "chapters/one.typ"
        """
        #expect(TypstStructure.links(of: source) == ["helpers.typ", "chapters/one.typ"])
    }

    @Test func backlinksResolveRelativePaths() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typst-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let target = dir.appendingPathComponent("target.typ")
        try "= Target".write(to: target, atomically: true, encoding: .utf8)
        try "#include \"../target.typ\"".write(
            to: dir.appendingPathComponent("sub/linker.typ"), atomically: true, encoding: .utf8)
        try "= Unrelated".write(
            to: dir.appendingPathComponent("other.typ"), atomically: true, encoding: .utf8)

        let backlinks = TypstStructure.backlinks(to: target, under: dir)
        #expect(backlinks.map(\.lastPathComponent) == ["linker.typ"])
    }
}

/// The in-process engine (Vendor/typst-ffi). NOT gated on the CLI — the library is
/// linked into the test target, making these hermetic.
@Suite struct TypstEngineTests {
    private func tempRoot() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typst-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func compilesToPDF() throws {
        let output = TypstEngine.compile(source: "= Hello\nFrom the engine.",
                                         root: try tempRoot())
        let result = try #require(output, "engine must not internal-error")
        #expect(result.pdf != nil)
        #expect(result.diagnostics.isEmpty)
    }

    @Test func reportsLocatedErrors() throws {
        let output = TypstEngine.compile(source: "= Bad\n#nonexistent()",
                                         root: try tempRoot())
        let result = try #require(output)
        #expect(result.pdf == nil)
        #expect(result.diagnostics.contains { $0.severity == .error && $0.line == 2 })
    }

    @Test func resolvesRelativeFilesAgainstRoot() throws {
        let root = try tempRoot()
        try "world".write(to: root.appendingPathComponent("data.txt"),
                          atomically: true, encoding: .utf8)
        let output = TypstEngine.compile(source: "#read(\"data.txt\")", root: root)
        let result = try #require(output)
        #expect(result.pdf != nil)
    }

    @Test func resolvesLocalPackages() throws {
        try TypstNotes.installPackage()
        let source = """
        \(TypstNotes.packageImport)
        #task[Engine-compiled task]
        """
        let output = TypstEngine.compile(source: source, root: try tempRoot())
        let result = try #require(output)
        #expect(result.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(result.pdf != nil)
    }
}

/// Integration tests against the real typst CLI; skipped on machines without it.
@Suite(.enabled(if: TypstCompiler.isAvailable))
struct TypstCompilerTests {
    /// The document's directory must exist — it becomes the compiler's --root and
    /// working directory.
    private func tempDocURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("typst-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("doc.typ")
    }

    @Test func compilesValidDocument() async throws {
        let output = await TypstCompiler.compile(source: "= Hello\nWorld.",
                                                 documentURL: try tempDocURL())
        #expect(output.pdf != nil)
        #expect(output.diagnostics.isEmpty)
    }

    @Test func reportsErrorsWithLocationAndNoPDF() async throws {
        let output = await TypstCompiler.compile(source: "= Bad\n#nonexistent()",
                                                 documentURL: try tempDocURL())
        #expect(output.pdf == nil)
        #expect(output.diagnostics.contains { $0.severity == .error && $0.line == 2 })
    }

    @Test func warningsStillProduceAPDF() async throws {
        let output = await TypstCompiler.compile(
            source: "#set text(font: \"NoSuchFont\")\nhi",
            documentURL: try tempDocURL())
        #expect(output.pdf != nil)
        #expect(output.diagnostics.contains { $0.severity == .warning })
    }

    @Test func exportsSVGPerPage() async throws {
        let doc = try tempDocURL()
        let dest = doc.deletingLastPathComponent().appendingPathComponent("out.svg")
        let diagnostics = await TypstCompiler.export(
            source: "= Page One\n#pagebreak()\n= Page Two",
            documentURL: doc, format: .svg, to: dest)

        #expect(diagnostics.filter { $0.severity == .error }.isEmpty)
        let dir = dest.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out-1.svg").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("out-2.svg").path))
    }

    /// The whole notes convention hinges on this: the bundled package installs into
    /// typst's real data directory and a `#task` document compiles against it.
    @Test func bundledPackageCompiles() async throws {
        try TypstNotes.installPackage()
        let source = """
        \(TypstNotes.packageImport)

        = Notes
        #task[Buy milk]
        #task(done: true, due: "2026-07-20", tags: ("errands",))[Post letter]
        """
        let output = await TypstCompiler.compile(source: source,
                                                 documentURL: try tempDocURL())
        #expect(output.diagnostics.filter { $0.severity == .error }.isEmpty)
        #expect(output.pdf != nil)
    }
}
