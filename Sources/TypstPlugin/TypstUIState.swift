import Foundation

/// How a document's source is shown.
///
/// What is left of the three modes. Reading became a pane on the document's
/// pages and typesetting became that pane beside the source, so the only thing
/// still per-document is which way its own text is set: as a manuscript, or as
/// the source it actually is. Which panes are open is the tab's business now,
/// not a property of the file.
enum TypstSourceStyle: String, CaseIterable, Identifiable {
    case prose, source
    var id: String { rawValue }

    var title: String { self == .prose ? "Prose" : "Source" }

    /// Prose is note-taking and saves itself; editing source is deliberate and
    /// waits for ⌘S. The one distinction the modes carried that was never
    /// about layout, so it stays.
    var autosaves: Bool { self == .prose }

    private static func key(for url: URL) -> String {
        "typst.sourceStyle.\(url.absoluteString)"
    }

    static func stored(forFile url: URL?) -> TypstSourceStyle {
        guard let url else { return .source }
        if let raw = UserDefaults.standard.string(forKey: key(for: url)),
           let style = TypstSourceStyle(rawValue: raw) { return style }
        // A document that still remembers a mode: writing was prose, and
        // everything else was the source. Written back under the new name, so
        // this is asked once per document and never again.
        guard let legacy = UserDefaults.standard
            .string(forKey: "typst.mode.\(url.absoluteString)") else { return .source }
        let migrated: TypstSourceStyle = legacy == "write" ? .prose : .source
        migrated.store(forFile: url)
        return migrated
    }

    func store(forFile url: URL?) {
        guard let url else { return }
        UserDefaults.standard.set(rawValue, forKey: Self.key(for: url))
    }
}

/// Plugin-level UI state: what actions and inspectors mutate and canvases
/// observe. This is the channel that lets controls live OUTSIDE the canvas
/// (menu bar, palette, inspector) while the canvas itself stays content-only.
@MainActor
@Observable
final class TypstUIState {
    static let shared = TypstUIState()

    private var styles: [URL: TypstSourceStyle] = [:]

    /// Each open document: its live text, and what compiling it produced.
    ///
    /// The buffer used to be a bare dictionary of strings, published so the
    /// inspector's word count could read the text on screen rather than what
    /// happened to be on disk. It carries the compile now too, because a
    /// document can be looked at from more than one pane and neither of them
    /// should own it — see `TypstDocument`.
    private var documents: [URL: TypstDocument] = [:]

    /// The document for a file, made if this is the first look at it.
    func document(for url: URL) -> TypstDocument {
        if let existing = documents[url] { return existing }
        let document = TypstDocument(url: url)
        documents[url] = document
        return document
    }

    /// The document, only if something already has it open — for the views
    /// that report on a document rather than showing one.
    func existingDocument(for url: URL?) -> TypstDocument? {
        url.flatMap { documents[$0] }
    }

    func buffer(for url: URL?) -> String? {
        existingDocument(for: url)?.buffer
    }

    func setBuffer(_ text: String, for url: URL?) {
        guard let url else { return }
        document(for: url).setBuffer(text, compileAfter: .zero)
    }

    /// How many canvases are looking at each document.
    ///
    /// One document can be open in two panes — the source and its pages — so
    /// "a canvas went away" is not "the document went away". Counting is the
    /// difference between closing the editor and taking the pages down with
    /// it.
    private var readers: [URL: Int] = [:]

    /// Start looking at a document, making it if nobody was.
    @discardableResult
    func retainDocument(for url: URL) -> TypstDocument {
        readers[url, default: 0] += 1
        return document(for: url)
    }

    /// Stop looking. The last one out cancels the compile and drops the text.
    func releaseDocument(for url: URL?) {
        guard let url, let count = readers[url] else { return }
        guard count <= 1 else {
            readers[url] = count - 1
            return
        }
        readers[url] = nil
        documents[url]?.cancel()
        documents[url] = nil
    }
    /// Bumped by "Refresh Agenda"; agenda canvases reload on change.
    var agendaRefresh = 0

    /// How the last export went, for the canvas of the document it came from.
    ///
    /// Exporting reaches the engine, which answers with diagnostics — a
    /// compile error, a font it could not find, a destination it could not
    /// write. Those used to be discarded at the call site, so a failed export
    /// and a successful one looked exactly alike: nothing happened, and the
    /// file was or wasn't there.
    struct ExportReport: Equatable {
        let document: URL
        let destination: URL
        let diagnostics: [TypstDiagnostic]
        var failed: Bool { diagnostics.contains { $0.severity == .error } }
    }

    var exportReport: ExportReport?

    /// The report to show on this document's canvas, if it is the one that
    /// exported and the export had something to say.
    func exportReport(for url: URL?) -> ExportReport? {
        guard let url, let report = exportReport, report.document == url,
              !report.diagnostics.isEmpty else { return nil }
        return report
    }

    func clearExportReport() { exportReport = nil }

    /// The face Write mode sets prose in. App-wide rather than per-document:
    /// you are choosing how writing looks, not marking up one file.
    ///
    /// Observed, so the picker in the inspector and the canvas showing the
    /// text are the same decision seen twice.
    var proseFont: ProseFont = .stored {
        didSet { proseFont.store() }
    }

    /// How big Write mode sets prose, in points. Stored beside the face,
    /// because at a given size these families are not the same size.
    var proseSize: CGFloat = ProseSize.stored {
        didSet { ProseSize.store(proseSize) }
    }

    /// Nudge the size, staying inside what is still a manuscript.
    func stepProseSize(by points: CGFloat) {
        proseSize = ProseSize.clamped(proseSize + points)
    }

    /// Step through the installed faces — the fastest way to find the one you
    /// can read, which is by reading your own prose in each.
    func cycleProseFont(by offset: Int) {
        let fonts = ProseFont.available
        guard fonts.count > 1 else { return }
        let index = fonts.firstIndex(of: proseFont) ?? 0
        var next = (index + offset) % fonts.count
        if next < 0 { next += fonts.count }
        proseFont = fonts[next]
    }

    func sourceStyle(for url: URL?) -> TypstSourceStyle {
        guard let url else { return .source }
        return styles[url] ?? TypstSourceStyle.stored(forFile: url)
    }

    func setSourceStyle(_ style: TypstSourceStyle, for url: URL?) {
        guard let url else { return }
        styles[url] = style
        style.store(forFile: url)
    }
}
