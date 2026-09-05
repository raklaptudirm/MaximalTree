import Foundation

enum TypstMode: String, CaseIterable, Identifiable {
    case write, typeset, read
    var id: String { rawValue }

    var title: String {
        switch self {
        case .write: return "Write"
        case .typeset: return "Typeset"
        case .read: return "Read"
        }
    }

    /// Write and Read behave like a notes app (autosave); Typeset keeps explicit
    /// save points.
    var autosaves: Bool { self != .typeset }

    // Keyed by the *file*, not the opened node, so a document keeps its mode
    // whether opened directly or through one of its section/task nodes.
    static func stored(forFile url: URL?) -> TypstMode {
        guard let url else { return .typeset }
        return UserDefaults.standard.string(forKey: "typst.mode.\(url.absoluteString)")
            .flatMap(TypstMode.init(rawValue:)) ?? .typeset
    }

    func store(forFile url: URL?) {
        guard let url else { return }
        UserDefaults.standard.set(rawValue, forKey: "typst.mode.\(url.absoluteString)")
    }
}

/// Plugin-level UI state: what actions and inspectors mutate and canvases
/// observe. This is the channel that lets controls live OUTSIDE the canvas
/// (menu bar, palette, inspector) while the canvas itself stays content-only.
@MainActor
@Observable
final class TypstUIState {
    static let shared = TypstUIState()

    private var modes: [URL: TypstMode] = [:]

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

    func clearBuffer(for url: URL?) {
        guard let url else { return }
        // Phase 3 note: with an editor and a preview open on one document this
        // has to count its readers, or closing either takes the document from
        // under the other. One pane today, so the last look is the only look.
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

    func mode(for url: URL?) -> TypstMode {
        guard let url else { return .typeset }
        return modes[url] ?? TypstMode.stored(forFile: url)
    }

    func setMode(_ mode: TypstMode, for url: URL?) {
        guard let url else { return }
        modes[url] = mode
        mode.store(forFile: url)
    }
}
