import Testing
import AppKit
import SwiftUI
@testable import MaximalEditorKit
@testable import MaximalTreeKit
@testable import MaximalTree

/// How a key press is written down.
@Suite struct KeyChordTests {
    @Test func parsesEmacsNotation() throws {
        #expect(KeyChord(parsing: "j") == KeyChord("j"))
        #expect(KeyChord(parsing: "SPC") == KeyChord("SPC"))
        #expect(KeyChord(parsing: "C-w") == KeyChord("w", control: true))
        #expect(KeyChord(parsing: "M-x") == KeyChord("x", option: true))
        #expect(KeyChord(parsing: "C-M-RET")
                == KeyChord("RET", control: true, option: true))
        #expect(KeyChord(parsing: "") == nil)
    }

    /// `G` is a shifted `g`, not a second `g`. Folding them together is what
    /// keeps a capital binding from clobbering the lowercase prefix it shares
    /// a node with — `G` once ate the whole `g` group.
    @Test func capitalsAreShiftedLettersNotSeparateKeys() throws {
        #expect(KeyChord(parsing: "G") == KeyChord("g", shift: true))
        #expect(KeyChord(parsing: "G") == KeyChord(parsing: "S-g"))
        #expect(KeyChord(parsing: "G") != KeyChord(parsing: "g"))
        #expect(KeyChord(parsing: "G")?.description == "G")
    }

    @Test func roundTripsThroughItsOwnNotation() throws {
        for text in ["j", "SPC", "C-w", "M-x", "s-k", "RET"] {
            let chord = try #require(KeyChord(parsing: text))
            #expect(chord.description == text, "\(text) came back as \(chord)")
        }
    }
}

/// A keymap is a tree, because the useful question is "what can follow this".
@MainActor
@Suite struct KeymapTests {
    private func chords(_ text: String) -> [KeyChord] {
        text.split(separator: " ").compactMap { KeyChord(parsing: String($0)) }
    }

    @Test func resolvesASequenceToItsCommand() {
        var map = Keymap()
        map.bind("SPC g s", to: "git.status")
        #expect(map.lookup(chords("SPC g s")) == .command("git.status"))
    }

    @Test func aHalfTypedSequenceOffersItsContinuations() throws {
        var map = Keymap()
        map.describe("SPC g", as: "git")
        map.bind("SPC g s", to: "git.status")
        map.bind("SPC g o", to: "git.open")

        guard case .prefix(let label, let continuations) = map.lookup(chords("SPC g"))
        else { Issue.record("expected a prefix"); return }
        #expect(label == "git")
        #expect(continuations.map(\.chord.description) == ["o", "s"], "listed in a stable order")
    }

    @Test func anUnknownSequenceIsUnbound() {
        var map = Keymap()
        map.bind("SPC g s", to: "git.status")
        #expect(map.lookup(chords("SPC q")) == .unbound)
        #expect(map.lookup(chords("z")) == .unbound)
    }

    /// Naming a group must not be undone by binding something under it.
    @Test func groupNamesSurviveTheirBindings() throws {
        var map = Keymap()
        map.describe("SPC f", as: "file")
        map.bind("SPC f s", to: "file.save")
        guard case .prefix(let label, _) = map.lookup(chords("SPC f")) else {
            Issue.record("expected a prefix"); return
        }
        #expect(label == "file")
    }

    /// The shipped map is what most of this is for.
    @Test func theDefaultMapBindsWhatItPromises() {
        let map = DefaultKeymap.make()
        #expect(map.lookup(chords("j")) == .command("explorer.down"))
        #expect(map.lookup(chords("SPC SPC")) == .command("palette.toggle"))
        #expect(map.lookup(chords("SPC w v")) == .command("pane.splitRight"))
        #expect(map.lookup(chords("SPC g o")) == .command("git.open"))
        #expect(map.lookup(chords("g t")) == .command("tab.next"))
        if case .prefix(let label, _) = map.lookup(chords("SPC b")) {
            #expect(label == "buffer")
        } else {
            Issue.record("SPC b should be a group")
        }
    }

    /// Movement at each scale the app has one: between surfaces, tabs, nodes,
    /// and workspaces. Bound twice over where Vim and Doom disagree about the
    /// prefix, since both sets of fingers show up here.
    @Test func everyScaleOfMovementIsBound() {
        let map = DefaultKeymap.make()
        let expected = [
            "C-w h": "surface.left", "C-w j": "surface.down",
            "C-w k": "surface.up", "C-w l": "surface.right",
            "C-w w": "surface.next", "C-w W": "surface.previous",
            "SPC w h": "surface.left", "SPC w l": "surface.right",
            "SPC b n": "tab.next", "SPC b p": "tab.previous",
            "SPC b h": "tab.first", "SPC b l": "tab.last",
            "g t": "tab.next", "g T": "tab.previous",
            "j": "explorer.down", "k": "explorer.up",
            "}": "node.nextSibling", "{": "node.previousSibling",
            "g p": "node.parent",
            "g g": "explorer.first", "G": "explorer.last",
            "g w": "workspace.next", "g W": "workspace.previous",
            "SPC p n": "workspace.next", "SPC p p": "workspace.previous",
        ]
        for (keys, command) in expected {
            #expect(map.lookup(chords(keys)) == .command(command),
                    "\(keys) should run \(command)")
        }
    }

    /// Every command a key names has to be one the app answers to, or the key
    /// is dead and nothing says so.
    @Test func everyBoundCommandIsOneTheAppKnows() {
        let known: Set<String> = [
            "mode.insert", "editor.focus", "explorer.focus", "inspector.focus",
            "palette.toggle",
            "explorer.down", "explorer.up", "explorer.expand", "explorer.collapse",
            "explorer.open", "explorer.first", "explorer.last",
            "node.nextSibling", "node.previousSibling", "node.parent",
            "nav.back", "nav.forward",
            "tab.next", "tab.previous", "tab.close", "tab.first", "tab.last",
            "pane.splitRight", "pane.splitDown", "pane.close",
            "surface.left", "surface.right", "surface.up", "surface.down",
            "surface.next", "surface.previous",
            "workspace.next", "workspace.previous", "workspace.addFolder",
            "toggle.sidebar", "toggle.inspector", "toggle.zen", "file.save",
        ]
        // The rest are plugin action ids, which the registry resolves at run
        // time and this test can't see.
        let pluginPrefixes = ["git.", "terminal.", "typst.", "web.", "file.", "core."]
        for command in DefaultKeymap.make().allCommands {
            guard !known.contains(command) else { continue }
            #expect(pluginPrefixes.contains { command.hasPrefix($0) },
                    "\(command) is bound but nothing runs it")
        }
    }
}

/// The modal layer itself.
@MainActor
@Suite struct KeyEngineTests {
    private func makeEngine() -> (KeyEngine, () -> [(String, Int)]) {
        var map = Keymap()
        map.describe("SPC f", as: "file")
        map.bind("j", to: "down")
        map.bind("SPC f s", to: "save")
        final class Log: @unchecked Sendable { var entries: [(String, Int)] = [] }
        let log = Log()
        let engine = KeyEngine(keymap: map)
        engine.perform = { id, count in log.entries.append((id, count)) }
        return (engine, { log.entries })
    }

    private func chord(_ text: String) -> KeyChord { KeyChord(parsing: text)! }

    @Test func aBoundKeyRunsItsCommand() {
        let (engine, log) = makeEngine()
        #expect(engine.handle(chord("j"), editing: false) == .consumed)
        #expect(log().map(\.0) == ["down"])
    }

    @Test func aSequenceRunsOnlyWhenItIsComplete() {
        let (engine, log) = makeEngine()
        #expect(engine.handle(chord("SPC"), editing: false) == .pendingSequence)
        #expect(engine.handle(chord("f"), editing: false) == .pendingSequence)
        #expect(log().isEmpty, "something ran halfway through a sequence")
        #expect(engine.handle(chord("s"), editing: false) == .consumed)
        #expect(log().map(\.0) == ["save"])
        #expect(engine.pending.isEmpty, "the sequence wasn't cleared")
    }

    /// Half a sequence must not leak into the app as a stray key.
    @Test func aDeadEndSwallowsTheKeyAndResets() {
        let (engine, log) = makeEngine()
        _ = engine.handle(chord("SPC"), editing: false)
        #expect(engine.handle(chord("z"), editing: false) == .consumed)
        #expect(engine.pending.isEmpty)
        #expect(log().isEmpty)
    }

    @Test func countsRepeatTheCommand() {
        let (engine, log) = makeEngine()
        #expect(engine.handle(chord("3"), editing: false) == .pendingSequence)
        _ = engine.handle(chord("j"), editing: false)
        #expect(log().map(\.1) == [3])
        // And the count doesn't stick around for the next key.
        _ = engine.handle(chord("j"), editing: false)
        #expect(log().map(\.1) == [3, 1])
    }

    @Test func multiDigitCountsWork() {
        let (engine, log) = makeEngine()
        for digit in ["1", "2"] { _ = engine.handle(chord(digit), editing: false) }
        _ = engine.handle(chord("j"), editing: false)
        #expect(log().map(\.1) == [12])
    }

    /// Typing in the editor is typing, whatever the keymap says.
    @Test func keysPassThroughWhileEditing() {
        let (engine, log) = makeEngine()
        #expect(engine.handle(chord("j"), editing: true) == .passed)
        #expect(log().isEmpty)
    }

    /// Escape is the way back, so it is never passed on.
    @Test func escapeAlwaysReturnsToNormal() {
        let (engine, _) = makeEngine()
        engine.setMode(.insert)
        #expect(engine.handle(chord("ESC"), editing: true) == .consumed)
        #expect(engine.mode == .normal)
    }

    @Test func escapeAbandonsAHalfTypedSequence() {
        let (engine, log) = makeEngine()
        _ = engine.handle(chord("SPC"), editing: false)
        _ = engine.handle(chord("ESC"), editing: false)
        #expect(engine.pending.isEmpty)
        #expect(log().isEmpty)
    }

    /// Insert mode hands the keyboard over wholesale.
    @Test func insertModePassesEverythingButEscape() {
        let (engine, log) = makeEngine()
        engine.setMode(.insert)
        #expect(engine.handle(chord("j"), editing: false) == .passed)
        #expect(log().isEmpty)
    }

    /// which-key needs to know what can follow.
    @Test func aPendingPrefixExposesItsContinuations() {
        let (engine, _) = makeEngine()
        _ = engine.handle(chord("SPC"), editing: false)
        _ = engine.handle(chord("f"), editing: false)
        #expect(engine.prefixLabel == "file")
        #expect(engine.continuations.map(\.chord.description) == ["s"])
    }
}


/// Who has the keyboard.
///
/// The bug this exists for: the editor is not an NSTextView. STTextView is an
/// NSView that implements text input itself, so the obvious check —
/// `firstResponder is NSTextView` — is false while the caret is in the
/// document, and the modal layer went on treating every `j` as a sidebar
/// motion no matter where focus was.
@MainActor
@Suite struct KeyFocusTests {
    @Test func theEditorCountsAsTakingText() {
        let editor = MaximalEditor.EditorTextView(frame: .zero)
        #expect(!(editor is NSTextView), "the premise of the bug: it is not an NSTextView")
        #expect(KeyFocus.isTextInput(editor), "the editor was not recognised as text input")
    }

    @Test func ordinaryTextViewsAndFieldsCountToo() {
        #expect(KeyFocus.isTextInput(NSTextView(frame: .zero)))
        // A text field hands editing to a field editor, which is an NSTextView.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let field = NSTextField(string: "hi")
        window.contentView = field
        window.makeFirstResponder(field)
        defer { window.orderOut(nil) }
        #expect(KeyFocus.isTextInput(window.firstResponder))
    }

    @Test func nothingElseCounts() {
        #expect(!KeyFocus.isTextInput(NSView(frame: .zero)))
        #expect(!KeyFocus.isTextInput(nil))
    }

    /// "Focus the editor" has to be able to find it in the view tree the
    /// canvas built, however deeply it is nested.
    @Test func theEditorIsFoundWhereverItIsNested() {
        let editor = MaximalEditor.EditorTextView(frame: .zero)
        let inner = NSView(frame: .zero)
        inner.addSubview(editor)
        let outer = NSView(frame: .zero)
        outer.addSubview(NSView(frame: .zero))
        outer.addSubview(inner)

        #expect(KeyFocus.firstEditor(in: outer) === editor)
        #expect(KeyFocus.firstEditor(in: NSView(frame: .zero)) == nil)
    }

    /// Focus moves have to be bound, or there is no way into the editor at all.
    @Test func focusMovesAreBound() {
        let map = DefaultKeymap.make()
        func chords(_ text: String) -> [KeyChord] {
            text.split(separator: " ").compactMap { KeyChord(parsing: String($0)) }
        }
        // `i` means start typing (see KeyRoutingTests); the window moves are
        // what put focus somewhere without typing.
        #expect(map.lookup(chords("i")) == .command("mode.insert"))
        // These used to name the explorer and the editor directly. They are
        // directions now, and reaching the explorer is what moving left off
        // the leftmost surface does — one rule instead of two, and it holds
        // wherever the keyboard happens to be.
        #expect(map.lookup(chords("C-w l")) == .command("surface.right"))
        #expect(map.lookup(chords("C-w h")) == .command("surface.left"))
    }
}


/// Who gets a key.
///
/// Decided by mode, not by view, and the same for every canvas. Deciding by
/// view was wrong twice: the editor went unrecognised and received nothing,
/// then every canvas was recognised and the leader key stopped working
/// anywhere.
@Suite struct KeyRoutingTests {
    private func chord(_ text: String) -> KeyChord { KeyChord(parsing: text)! }

    private func route(_ key: String, mode: KeyMode) -> KeyRouting.Destination {
        KeyRouting.destination(for: chord(key), mode: mode)
    }

    /// Insert mode is typing, wherever the keyboard is — a terminal, a page,
    /// an editor, a field. This is what was broken for the terminal.
    @Test func insertModeGivesEveryKeyToWhateverHasFocus() {
        for key in ["j", "SPC", "d", "3", "/"] {
            #expect(route(key, mode: .insert) == .focusedView,
                    "\(key) was taken from the thing being typed into")
        }
    }

    /// Normal mode is commands — the canvas gets first refusal, then the app.
    @Test func normalModeGoesToTheModalLayer() {
        for key in ["j", "SPC", "g", "3", "d"] {
            #expect(route(key, mode: .normal) == .app)
        }
    }

    /// Escape belongs to nobody else: it is the way back to normal.
    @Test func escapeIsAlwaysTheApps() {
        #expect(route("ESC", mode: .insert) == .app)
        #expect(route("ESC", mode: .normal) == .app)
    }

    /// `i` means start typing, whatever is focused — otherwise a terminal
    /// could never be typed into.
    @Test func iEntersInsertMode() {
        #expect(DefaultKeymap.make().lookup([chord("i")]) == .command("mode.insert"))
    }
}

/// A canvas's own normal-mode keys.
///
/// The editor is not a special case: it adopts the same protocol any canvas
/// can, and what it declines falls through to the app exactly like anyone
/// else's.
@MainActor
@Suite struct CanvasKeyTests {
    /// Stands in for any canvas — a diff stepping between hunks, a preview
    /// paging. It consumes `n` and declines everything else.
    private final class StubCanvas: NSView, CanvasKeyHandling {
        var consumed: [String] = []
        /// The mode each handled key arrived in, which is the only way this
        /// canvas learns of one — it keeps none.
        var modesSeen: [KeyMode] = []

        func handleKey(_ key: String, control: Bool, mode: KeyMode) -> KeyMode? {
            guard key == "n" else { return nil }
            consumed.append(key)
            modesSeen.append(mode)
            return mode
        }
    }

    @Test func aCanvasHandlesTheKeysItClaims() {
        let canvas = StubCanvas(frame: .zero)
        #expect(canvas.handleKey("n", control: false, mode: .normal) == .normal)
        #expect(canvas.consumed == ["n"])
    }

    @Test func whatItDeclinesIsLeftForTheApp() {
        let canvas = StubCanvas(frame: .zero)
        #expect(canvas.handleKey("j", control: false, mode: .normal) == nil,
                "a canvas that swallows everything would take the app's bindings with it")
    }

    /// The mode reaches a canvas as an argument, so there is nothing to keep
    /// in step and nothing to go stale.
    @Test func theModeArrivesWithTheKey() {
        let canvas = StubCanvas(frame: .zero)
        _ = canvas.handleKey("n", control: false, mode: .normal)
        _ = canvas.handleKey("n", control: false, mode: .visual)
        #expect(canvas.modesSeen == [.normal, .visual])
    }

    /// The editor is reached the same way, through the same protocol.
    @Test func theEditorIsJustAnotherCanvas() {
        let editor = MaximalEditor.EditorTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        editor.modalEditing = true
        editor.text = "alpha beta"
        editor.textSelection = NSRange(location: 0, length: 0)

        #expect(editor is CanvasKeyHandling, "the editor should adopt the canvas protocol")
        let canvas = editor as CanvasKeyHandling
        #expect(canvas.handleKey("l", control: false, mode: .normal) == .normal,
                "the editor declined a motion")
        #expect(editor.textSelection.location == 1)
    }

    /// Not adopting the protocol is allowed and means "keys are the app's" —
    /// which is what a terminal wants.
    @Test func aCanvasNeedNotHandleAnything() {
        let plain = NSView(frame: .zero)
        #expect(!(plain is CanvasKeyHandling))
    }

    /// The whole trip a key takes, with a real editor on the other end. Every
    /// mode bug so far lived here, between parts that each tested clean.
    @Test func theCanvasAnswerBecomesTheAppsMode() {
        let keys = KeyEngine(keymap: DefaultKeymap.make())
        let editor = makeEditor()

        #expect(KeyDispatch.handle(KeyChord("i"), keys: keys, canvas: editor))
        #expect(keys.mode == .insert, "the editor's `i` should have set the app's mode")

        #expect(KeyDispatch.handle(KeyChord("ESC"), keys: keys, canvas: editor))
        #expect(keys.mode == .normal)
    }

    /// Escape is one assignment now, so it works with no canvas at all — and
    /// with a different one than the key that entered insert went to. Both
    /// were real bugs when leaving insert meant notifying an object: focus
    /// moves while typing (a completion panel takes the key window), and the
    /// canvas still inserting was never told.
    @Test func escapeIsTheModesAloneAndNeedsNoCanvas() {
        for canvas in [nil, StubCanvas(frame: .zero)] {
            let keys = KeyEngine(keymap: DefaultKeymap.make())
            keys.setMode(.insert)
            #expect(KeyDispatch.handle(KeyChord("ESC"), keys: keys, canvas: canvas))
            #expect(keys.mode == .normal)
        }
    }

    /// The editor enters insert on its own recognizance — `i`, `o`, a visual
    /// `c` — and says so by answering with the mode it left behind, rather
    /// than by keeping one the app has to ask after.
    @Test func theEditorAnswersWithTheModeItsCommandLeft() {
        let editor = makeEditor()
        let canvas = editor as CanvasKeyHandling

        #expect(canvas.handleKey("l", control: false, mode: .normal) == .normal,
                "a motion stays in the mode it ran in")
        #expect(canvas.handleKey("i", control: false, mode: .normal) == .insert)
        #expect(canvas.handleKey("v", control: false, mode: .normal) == .visual)
    }

    /// The engine keeps no mode, so one set anywhere else — escape, a
    /// command, focus arriving — abandons whatever was half-typed rather than
    /// letting it finish under rules it was never started under.
    @Test func aHalfTypedCommandIsAbandonedWhenTheModeChangesElsewhere() {
        let editor = makeEditor()
        let canvas = editor as CanvasKeyHandling

        #expect(canvas.handleKey("d", control: false, mode: .normal) == .normal,
                "`d` waits for the motion that says how far")
        // The app went to insert and came back without the operator running.
        _ = canvas.handleKey("i", control: false, mode: .normal)
        #expect(canvas.handleKey("w", control: false, mode: .normal) == .normal)
        #expect(editor.text == "alpha beta", "the abandoned `d` finished after all")
    }

    private func makeEditor() -> MaximalEditor.EditorTextView {
        let editor = MaximalEditor.EditorTextView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        editor.modalEditing = true
        editor.text = "alpha beta"
        editor.textSelection = NSRange(location: 0, length: 0)
        return editor
    }
}
