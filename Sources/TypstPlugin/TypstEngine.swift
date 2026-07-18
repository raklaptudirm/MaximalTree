import Foundation
import TypstFFI

/// The in-process typst compiler (Rust, via C ABI — see Vendor/typst-ffi).
/// Replaces the CLI for the hot path: no process spawn, structured diagnostics
/// instead of stderr parsing, and it's the only compile path that can exist on
/// iOS. The CLI remains as a fallback and for export formats not yet in the FFI.
enum TypstEngine {
    private struct EngineDiagnostic: Decodable {
        let severity: String
        let message: String
        let line: Int?
        let column: Int?
    }

    /// Compile `source` as `<root>/main.typ`. Returns nil on *internal* engine
    /// failure (caller falls back to the CLI); compile errors are a normal result.
    static func compile(source: String, root: URL) -> TypstCompiler.Output? {
        compile(source: source, root: root, packagesNamespaceDir: packagesRoot())
    }

    /// `<data>/typst/packages` — the FFI resolves `@<ns>/<name>/<version>` beneath it.
    static func packagesRoot() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("typst/packages", isDirectory: true)
    }

    static func compile(source: String, root: URL,
                        packagesNamespaceDir: URL) -> TypstCompiler.Output? {
        var pdfBuffer = TypstBuffer()
        var diagnosticsBuffer = TypstBuffer()

        let status = source.withCString { sourcePtr in
            root.path.withCString { rootPtr in
                packagesNamespaceDir.path.withCString { packagesPtr in
                    typst_compile_pdf(sourcePtr, rootPtr, packagesPtr,
                                      &pdfBuffer, &diagnosticsBuffer)
                }
            }
        }
        defer {
            typst_buffer_free(pdfBuffer)
            typst_buffer_free(diagnosticsBuffer)
        }

        guard status != 2 else { return nil }   // internal error → CLI fallback

        var diagnostics: [TypstDiagnostic] = []
        if diagnosticsBuffer.len > 0, let data = diagnosticsBuffer.data {
            let json = Data(bytes: data, count: diagnosticsBuffer.len)
            if let decoded = try? JSONDecoder().decode([EngineDiagnostic].self, from: json) {
                diagnostics = decoded.compactMap { d in
                    guard let severity = TypstDiagnostic.Severity(rawValue: d.severity)
                    else { return nil }
                    return TypstDiagnostic(severity: severity, line: d.line,
                                           column: d.column, message: d.message)
                }
            }
        }

        var pdf: Data?
        if status == 0, pdfBuffer.len > 0, let data = pdfBuffer.data {
            pdf = Data(bytes: data, count: pdfBuffer.len)
        }
        return TypstCompiler.Output(pdf: pdf, diagnostics: diagnostics)
    }
}
