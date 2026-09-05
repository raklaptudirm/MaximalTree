import Foundation
import TypstFFI

/// The in-process typst compiler (Rust, via C ABI — see Vendor/typst-ffi):
/// compile, export (PDF/SVG/PNG), math rendering, tokens, and structure all run
/// here — no process spawn, no CLI anywhere, and it's the only compile path
/// that can exist on iOS.
enum TypstEngine {
    private struct EngineDiagnostic: Decodable {
        let severity: String
        let message: String
        let line: Int?
        let column: Int?
    }

    /// Compile `source` as `<root><mainPath>`. Returns nil on *internal*
    /// engine failure (callers surface it as a diagnostic); compile errors are
    /// a normal result.
    static func compile(source: String, root: URL,
                        mainPath: String = "/main.typ") -> Output? {
        compile(source: source, root: root, mainPath: mainPath,
                packagesNamespaceDir: packagesRoot())
    }

    struct Output: Sendable {
        let pdf: Data?
        let diagnostics: [TypstDiagnostic]
    }

    /// Compile `source` as though it were the contents of `documentURL` —
    /// the async facade canvases use for live preview. The engine is the only
    /// compiler; an internal failure surfaces as a diagnostic, never a hang.
    static func compile(source: String, documentURL: URL,
                        mountedRoots: [URL]) async -> Output {
        await Task.detached(priority: .userInitiated) {
            let root = TypstProject.root(for: documentURL, mountedRoots: mountedRoots)
            return compile(source: source, root: root,
                           mainPath: TypstProject.mainPath(of: documentURL, in: root))
                ?? Output(pdf: nil, diagnostics: [
                    TypstDiagnostic(severity: .error, line: nil, column: nil,
                                    message: "the typst engine failed internally"),
                ])
        }.value
    }

    // MARK: Export

    enum ExportFormat: String, CaseIterable, Sendable {
        case pdf, svg, png

        var title: String { rawValue.uppercased() }
    }

    /// Compile `source` and write it to `destination` in the given format —
    /// all through the in-process engine. PDF and SVG are single files (SVG
    /// stacks pages); PNG rasterizes at 300 ppi, one file per page, numbered
    /// `name-N.png` when the document has more than one. Returns diagnostics;
    /// no errors among them means the export happened.
    static func export(source: String, documentURL: URL,
                       format: ExportFormat, to destination: URL,
                       mountedRoots: [URL]) async -> [TypstDiagnostic] {
        await Task.detached(priority: .userInitiated) {
            exportSync(source: source, documentURL: documentURL,
                       format: format, to: destination, mountedRoots: mountedRoots)
        }.value
    }

    static func exportSync(source: String, documentURL: URL,
                           format: ExportFormat, to destination: URL,
                           mountedRoots: [URL]) -> [TypstDiagnostic] {
        let root = TypstProject.root(for: documentURL, mountedRoots: mountedRoots)
        let mainPath = TypstProject.mainPath(of: documentURL, in: root)
        func failure(_ message: String) -> [TypstDiagnostic] {
            [TypstDiagnostic(severity: .error, line: nil, column: nil, message: message)]
        }

        do {
            switch format {
            case .pdf:
                guard let output = compile(source: source, root: root, mainPath: mainPath) else {
                    return failure("the typst engine failed internally")
                }
                guard let pdf = output.pdf else { return output.diagnostics }
                try pdf.write(to: destination)
                return output.diagnostics

            case .svg:
                guard let svg = renderSVG(source: source, root: root, mainPath: mainPath) else {
                    // Compile errors carry no location here; re-compile for them.
                    return compile(source: source, root: root, mainPath: mainPath)?.diagnostics
                        ?? failure("the typst engine failed internally")
                }
                try svg.write(to: destination)
                return []

            case .png:
                let scale = 300.0 / 72.0
                guard let first = renderPNG(source: source, root: root,
                                            page: 0, pixelPerPt: scale,
                                            mainPath: mainPath) else {
                    return compile(source: source, root: root, mainPath: mainPath)?.diagnostics
                        ?? failure("the typst engine failed internally")
                }
                guard first.pages > 1 else {
                    try first.png.write(to: destination)
                    return []
                }
                let stem = destination.deletingPathExtension()
                for page in 0..<first.pages {
                    let render = page == 0 ? first
                        : renderPNG(source: source, root: root,
                                    page: page, pixelPerPt: scale,
                                    mainPath: mainPath)
                    guard let render else { return failure("page \(page + 1) failed to render") }
                    let url = URL(fileURLWithPath: stem.path + "-\(page + 1).png")
                    try render.png.write(to: url)
                }
                return []
            }
        } catch {
            return failure("couldn't write export: \(error.localizedDescription)")
        }
    }

    /// The whole document as one SVG (pages stacked). Nil on compile failure.
    static func renderSVG(source: String, root: URL,
                          mainPath: String = "/main.typ") -> Data? {
        var buffer = TypstBuffer()
        let status = source.withCString { sourcePtr in
            root.path.withCString { rootPtr in
                mainPath.withCString { mainPtr in
                    packagesRoot().path.withCString { packagesPtr in
                        typst_render_svg(sourcePtr, rootPtr, mainPtr, packagesPtr, &buffer)
                    }
                }
            }
        }
        defer { typst_buffer_free(buffer) }
        guard status == 0, buffer.len > 0, let data = buffer.data else { return nil }
        return Data(bytes: data, count: buffer.len)
    }

    /// One page as PNG, plus the document's page count. Nil on compile failure
    /// or page out of range.
    static func renderPNG(source: String, root: URL, page: Int,
                          pixelPerPt: Double,
                          mainPath: String = "/main.typ") -> (png: Data, pages: Int)? {
        struct Info: Decodable { let pages: Int? }
        var pngBuffer = TypstBuffer()
        var infoBuffer = TypstBuffer()
        let status = source.withCString { sourcePtr in
            root.path.withCString { rootPtr in
                mainPath.withCString { mainPtr in
                    packagesRoot().path.withCString { packagesPtr in
                        typst_render_png(sourcePtr, rootPtr, mainPtr, packagesPtr,
                                         pixelPerPt, Int32(page),
                                         &pngBuffer, &infoBuffer)
                    }
                }
            }
        }
        defer {
            typst_buffer_free(pngBuffer)
            typst_buffer_free(infoBuffer)
        }
        guard status == 0, pngBuffer.len > 0, let pngData = pngBuffer.data,
              infoBuffer.len > 0, let infoData = infoBuffer.data,
              let info = try? JSONDecoder().decode(
                Info.self, from: Data(bytes: infoData, count: infoBuffer.len))
        else { return nil }
        return (Data(bytes: pngData, count: pngBuffer.len), info.pages ?? 1)
    }

    /// A rendered equation: PNG pixels plus the metrics an editor needs to
    /// place it — point size, and the typographic baseline measured from the
    /// image's top (from typst's own layout frame, so alignment is exact).
    struct MathRender: Decodable {
        var png = Data()
        let w: Double   // points
        let h: Double
        let b: Double   // baseline, points from the top

        private enum CodingKeys: String, CodingKey { case w, h, b }
    }

    /// Render a lone equation (`$…$`, delimiters included) with typst's native
    /// PNG renderer, on a page that hugs it. `fontSize` matches the editor;
    /// `dark` renders white ink (the page is transparent either way); `scale`
    /// is pixels per point (2 for retina). Nil when the equation doesn't
    /// compile — the editor keeps the monospace source.
    static func renderMath(equation: String, fontSize: Double, dark: Bool,
                           scale: Double, block: Bool = false) -> MathRender? {
        // The auto-height page hugs the text's *line box*; superscripts, tall
        // parens, and descenders can poke past it. The vertical margin scales
        // with the font so nothing renders clipped.
        //
        // Inline: the zero-width transparent strut plants a full-size glyph on
        // the paragraph's main baseline — the first text item in the frame,
        // which is how the renderer reports the baseline for ANY equation shape
        // (see find_baseline in the FFI). Block: NO strut — it would form its
        // own phantom line above the display equation and bloat the image; the
        // equation stands alone with its display-block spacing zeroed (the
        // editor centers block images in their line, no baseline needed).
        let body = block
            ? """
              #show math.equation: set block(above: 0pt, below: 0pt)
              \(equation)
              """
            : "#box(width: 0pt, text(fill: rgb(0, 0, 0, 0))[x])\(equation)"
        let source = """
        #set page(width: auto, height: auto, \
        margin: (x: 1pt, y: \(fontSize * 0.35)pt), fill: none)
        #set text(size: \(fontSize)pt\(dark ? ", fill: white" : ""))
        \(body)
        """

        var pngBuffer = TypstBuffer()
        var infoBuffer = TypstBuffer()
        let status = source.withCString { sourcePtr in
            FileManager.default.temporaryDirectory.path.withCString { rootPtr in
                "/main.typ".withCString { mainPtr in
                    packagesRoot().path.withCString { packagesPtr in
                        typst_render_png(sourcePtr, rootPtr, mainPtr, packagesPtr, scale, 0,
                                         &pngBuffer, &infoBuffer)
                    }
                }
            }
        }
        defer {
            typst_buffer_free(pngBuffer)
            typst_buffer_free(infoBuffer)
        }

        guard status == 0,
              pngBuffer.len > 0, let pngData = pngBuffer.data,
              infoBuffer.len > 0, let infoData = infoBuffer.data,
              var render = try? JSONDecoder().decode(
                MathRender.self, from: Data(bytes: infoData, count: infoBuffer.len))
        else { return nil }
        render.png = Data(bytes: pngData, count: pngBuffer.len)
        return render
    }

    /// First compile pays a system font scan (~1.4s); every one after is ~ms.
    /// Canvas `prepare` calls this off the main actor so the cost lands behind
    /// the host's loading indicator, never on the app loop. Thread-safe and
    /// once-only (`static let` initialization); a no-op when already warm.
    static func warmUp() {
        _ = fontScan
    }

    private static let fontScan: Void = {
        _ = compile(source: "", root: FileManager.default.temporaryDirectory)
    }()

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

    static func compile(source: String, root: URL, mainPath: String = "/main.typ",
                        packagesNamespaceDir: URL) -> Output? {
        var pdfBuffer = TypstBuffer()
        var diagnosticsBuffer = TypstBuffer()

        let status = source.withCString { sourcePtr in
            root.path.withCString { rootPtr in
                mainPath.withCString { mainPtr in
                    packagesNamespaceDir.path.withCString { packagesPtr in
                        typst_compile_pdf(sourcePtr, rootPtr, mainPtr, packagesPtr,
                                          &pdfBuffer, &diagnosticsBuffer)
                    }
                }
            }
        }
        defer {
            typst_buffer_free(pdfBuffer)
            typst_buffer_free(diagnosticsBuffer)
        }

        guard status != 2 else { return nil }   // internal error

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
        return Output(pdf: pdf, diagnostics: diagnostics)
    }
}
