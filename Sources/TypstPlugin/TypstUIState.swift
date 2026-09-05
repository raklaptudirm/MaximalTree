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

    /// The live buffer of each open document, published by its canvas on every
    /// edit. The inspector's stats are derived from the text you can see, not
    /// from what happens to be on disk — those differ for as long as an edit is
    /// unsaved, which is exactly when someone is watching a word count.
    private var buffers: [URL: String] = [:]

    func buffer(for url: URL?) -> String? {
        guard let url else { return nil }
        return buffers[url]
    }

    func setBuffer(_ text: String, for url: URL?) {
        guard let url else { return }
        buffers[url] = text
    }

    func clearBuffer(for url: URL?) {
        guard let url else { return }
        buffers[url] = nil
    }
    /// Bumped by "Refresh Agenda"; agenda canvases reload on change.
    var agendaRefresh = 0

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
