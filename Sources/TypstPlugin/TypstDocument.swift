import Foundation
import PDFKit

/// One open typst document: its live text, and what compiling it produced.
///
/// Owned by the document rather than by a canvas, because a document can be
/// looked at from more than one place at once — the editor and the preview are
/// two panes on two names for the same thing. A canvas that owned this would
/// mean two compiles of one file, or a preview that only worked while the
/// editor it borrowed from was on screen.
///
/// It also settles where diagnostics live. Compiling in the preview would have
/// been tempting — it is the pane whose job is output — but then a document
/// being *written*, with no preview open, would never compile, and the error
/// dot that catches a broken `#` call while drafting would go with it. So the
/// document compiles, the preview draws the pages, and the editor draws the
/// dot and the bar. Both read; neither owns.
@MainActor
@Observable
final class TypstDocument {
    let url: URL

    /// What the editor last published — the text on screen, which differs from
    /// disk for exactly as long as an edit is unsaved.
    private(set) var buffer: String = ""
    private(set) var preview: PDFDocument?
    private(set) var previewData: Data?
    private(set) var diagnostics: [TypstDiagnostic] = []
    private(set) var isCompiling = false

    var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    /// The scope the document may import from. Set by whichever canvas has a
    /// host to ask; a compile before anyone has said is a compile rooted at
    /// the document's own directory, which is the old default and wrong for a
    /// note that reaches above itself.
    @ObservationIgnored var mountedRoots: [URL] = []

    @ObservationIgnored private var task: Task<Void, Never>?

    init(url: URL) { self.url = url }

    /// Publish the text and compile it after `delay`.
    ///
    /// Debounced by cancelling: a compile per keystroke is work nobody reads,
    /// and the one that matters is the one after the typing stops.
    func setBuffer(_ text: String, compileAfter delay: Duration) {
        buffer = text
        compile(after: delay)
    }

    func compile(after delay: Duration = .zero) {
        task?.cancel()
        let source = buffer
        let roots = mountedRoots
        task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            self?.isCompiling = true
            let output = await TypstEngine.compile(source: source, documentURL: self?.url ?? URL(fileURLWithPath: "/"),
                                                   mountedRoots: roots)
            guard !Task.isCancelled, let self else { return }
            isCompiling = false
            diagnostics = output.diagnostics
            // On error the last good pages stay: a preview that blanked on
            // every half-typed expression would be unreadable while writing.
            if let pdf = output.pdf {
                previewData = pdf
                preview = PDFDocument(data: pdf)
            }
        }
    }

    /// Stop compiling — the last pane looking at this document has gone.
    func cancel() {
        task?.cancel()
        task = nil
    }
}
