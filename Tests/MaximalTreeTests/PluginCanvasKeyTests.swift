import Testing
import AppKit
import WebKit
@testable import MaximalEditorKit
@testable import MaximalTreeKit
@testable import MaximalTree

/// What a canvas claims and what it answers to.
///
/// A canvas declares its keys so which-key can describe them, and the app's
/// own bindings step aside for whatever it takes. Both halves are promises: a
/// key claimed but declined is an overlay entry that does nothing, and a key
/// taken but not claimed is one the reader is never told about.
@MainActor
@Suite struct PluginCanvasKeyTests {
    /// Feeds a declared binding through a handler, a key at a time — a
    /// sequence like `g g` only counts if every key of it lands.
    private func answers(_ binding: CanvasKeyBinding,
                         _ handler: (String, Bool, KeyMode) -> KeyMode?) -> Bool {
        var last: KeyMode?
        for key in binding.key.split(separator: " ") {
            last = handler(String(key), binding.control, binding.mode)
            if last == nil { return false }
        }
        return true
    }

    private func wellFormed(_ bindings: [CanvasKeyBinding], _ what: String) {
        #expect(!bindings.isEmpty, "\(what) declares nothing")
        for binding in bindings {
            #expect(!binding.key.isEmpty)
            #expect(!binding.title.isEmpty, "\(what): \(binding.key) has no label")
        }
        let keys = bindings.filter { $0.mode == .normal }.map(\.key)
        #expect(Set(keys).count == keys.count, "\(what) claims a key twice")
    }

    // MARK: The page

    @Test func theWebCanvasAnswersToEveryKeyItClaims() {
        let view = WebCanvasView(frame: .zero, configuration: WKWebViewConfiguration())
        for binding in WebCanvasView.bindings {
            #expect(answers(binding) { view.handleKey($0, control: $1, mode: $2) },
                    "\(binding.key) — \(binding.title) — is claimed but declined")
        }
    }

    @Test func theWebCanvasLeavesEverythingElseToTheApp() {
        let view = WebCanvasView(frame: .zero, configuration: WKWebViewConfiguration())
        // The leader and the app's own keys have to keep working over a page.
        for key in ["SPC", "/", "i", "w", "x", "p"] {
            #expect(view.handleKey(key, control: false, mode: .normal) == nil,
                    "the page took \(key), which belongs to the app")
        }
        // A control chord is never the page's.
        #expect(view.handleKey("w", control: true, mode: .normal) == nil)
    }

    @Test func theWebCanvasClaimsAreWellFormed() {
        wellFormed(WebCanvasView.bindings, "the web canvas")
    }

    // MARK: The terminal

    @Test func theTerminalAnswersToEveryKeyItClaims() {
        let view = TerminalSurfaceView(frame: .zero)
        for binding in TerminalSurfaceView.scrollBindings.map(\.binding) {
            #expect(answers(binding) { view.handleKey($0, control: $1, mode: $2) },
                    "\(binding.key) — \(binding.title) — is claimed but declined")
        }
    }

    /// The point of a terminal declining: in a commanding mode the app's
    /// bindings are what you want, and a terminal that swallowed them would
    /// leave no way out of itself.
    @Test func theTerminalLeavesEverythingElseToTheApp() {
        let view = TerminalSurfaceView(frame: .zero)
        // `G` and `g` are the terminal's now, so they are not in this list.
        for key in ["SPC", "/", "i", "h", "l", "RET", "w"] {
            #expect(view.handleKey(key, control: false, mode: .normal) == nil,
                    "the terminal took \(key), which belongs to the app")
        }
    }

    /// The amounts are libghostty's, named rather than guessed: faking a wheel
    /// delta scrolled a page where a line was meant, because a non-precision
    /// delta is counted in notches.
    @Test func theTerminalScrollsByNamedActions() {
        let names = Set(TerminalSurfaceView.scrollBindings.map(\.action))
        #expect(names.contains("scroll_page_lines:1"))
        #expect(names.contains("scroll_page_fractional:0.5"))
        #expect(names.contains("scroll_to_top"))
        // Every action is one of libghostty's scroll family.
        #expect(names.allSatisfy { $0.hasPrefix("scroll_") })
    }

    @Test func theTerminalClaimsAreWellFormed() {
        wellFormed(TerminalSurfaceView.scrollBindings.map(\.binding), "the terminal")
    }

    /// Handling a key must not change the mode: scrolling a page or a
    /// scrollback is not a reason to start typing.
    @Test func scrollingLeavesTheModeAlone() {
        let page = WebCanvasView(frame: .zero, configuration: WKWebViewConfiguration())
        #expect(page.handleKey("j", control: false, mode: .normal) == .normal)
        #expect(page.handleKey("j", control: false, mode: .visual) == .visual)

        let terminal = TerminalSurfaceView(frame: .zero)
        #expect(terminal.handleKey("j", control: false, mode: .normal) == .normal)
    }

    // MARK: The trip from a key press to a canvas

    /// Records what a canvas is actually handed.
    private final class Recorder: NSView, CanvasKeyHandling {
        var seen: [String] = []
        func handleKey(_ key: String, control: Bool, mode: KeyMode) -> KeyMode? {
            seen.append(key)
            return mode
        }
    }

    /// The bug this exists for: a chord keeps shift apart from the letter, so
    /// the keymap's `G` cannot clobber the `g` prefix it shares a node with.
    /// A canvas is handed a key and a control flag and nothing else, so shift
    /// has to be folded back in on the way — and it wasn't. Every uppercase
    /// binding in every canvas arrived lowercase: the editor's `G`, `I` and
    /// `A` did nothing at all, and its `O` and `P` did what `o` and `p` do.
    ///
    /// Tested through `KeyDispatch` rather than by calling the canvas, which
    /// is the whole point — feeding a handler the string it declares proves
    /// only that the handler agrees with itself.
    @Test func aCanvasIsHandedShiftedLettersAsCapitals() {
        let canvas = Recorder(frame: .zero)
        let keys = KeyEngine(keymap: Keymap())

        _ = KeyDispatch.handle(KeyChord("g", shift: true), keys: keys, canvas: canvas)
        _ = KeyDispatch.handle(KeyChord("g"), keys: keys, canvas: canvas)
        #expect(canvas.seen == ["G", "g"])
    }

    /// Symbols are already the shifted result — `/` is `/` however it was
    /// typed — so nothing is folded there.
    @Test func onlyLettersAreFoldedBack() {
        #expect(KeyChord("g", shift: true).canvasKey == "G")
        #expect(KeyChord("g").canvasKey == "g")
        #expect(KeyChord("/").canvasKey == "/")
        #expect(KeyChord("RET", shift: true).canvasKey == "RET")
        #expect(KeyChord("TAB", shift: true).canvasKey == "TAB")
    }

    /// The two halves together, which is where the bug lived: the drift test
    /// asks the engine about the string the editor declares, and the chord
    /// test asks what a canvas is handed. Neither noticed that the second was
    /// not the first.
    @Test func theEditorsCapitalVerbsSurviveTheTrip() {
        let text = "one\ntwo\nthree\n"
        for capital in ["G", "I", "A", "O", "P"] {
            let arriving = KeyChord(capital.lowercased(), shift: true).canvasKey
            #expect(arriving == capital)

            let engine = EditEngine()
            let outcome = engine.handle(EditKey(arriving), mode: .normal, text: text,
                                        selection: NSRange(location: 0, length: 0))
            #expect(outcome != nil,
                    "\(capital) arrives as \(arriving) and the engine declines it")
        }
    }
}
