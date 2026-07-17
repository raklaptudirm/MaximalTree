import Testing
import Foundation
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
