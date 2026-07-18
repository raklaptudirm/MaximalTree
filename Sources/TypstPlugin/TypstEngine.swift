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

    // MARK: Tokenizer

    /// A token from the real typst parser, with an NSRange-ready UTF-16 range.
    /// Kinds are the FFI's strings ("heading", "strong", "function", "string",
    /// "punct", "aligned", …); the plugin maps them to the editor vocabulary.
    struct Token: Decodable, Equatable {
        let s: Int
        let l: Int
        let k: String
        let n: Int?
        let a: String?

        var range: NSRange { NSRange(location: s, length: l) }
    }

    /// Tokenize with the real parser. Nil on internal failure (caller falls back
    /// to the regex tokenizer). Mode-aware by construction — string literals only
    /// exist where typst says code mode, so prose quotes are never tokens.
    static func tokens(in source: String) -> [Token]? {
        var buffer = TypstBuffer()
        let status = source.withCString { typst_tokens($0, &buffer) }
        defer { typst_buffer_free(buffer) }
        guard status == 0, buffer.len > 0, let data = buffer.data else { return nil }
        return try? JSONDecoder().decode([Token].self,
                                         from: Data(bytes: data, count: buffer.len))
    }

    // MARK: Structure

    /// A structural element from the real parser: a section, a task (carrying the
    /// exact UTF-16 edit that toggles its done state), or a link target.
    struct StructureItem: Decodable, Equatable {
        let kind: String
        let line: Int?
        let level: Int?
        let title: String?
        let index: Int?
        let body: String?
        let done: Bool?
        let due: String?
        let tags: [String]?
        let ts: Int?
        let tl: Int?
        let tr: String?
        let target: String?
    }

    /// Parse `source`'s structure. Nil on internal failure.
    static func structure(in source: String) -> [StructureItem]? {
        var buffer = TypstBuffer()
        let status = source.withCString { typst_structure($0, &buffer) }
        defer { typst_buffer_free(buffer) }
        guard status == 0, buffer.len > 0, let data = buffer.data else {
            return status == 0 ? [] : nil    // empty document is a valid result
        }
        return try? JSONDecoder().decode([StructureItem].self,
                                         from: Data(bytes: data, count: buffer.len))
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
