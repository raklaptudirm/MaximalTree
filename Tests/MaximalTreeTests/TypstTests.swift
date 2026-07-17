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
}
