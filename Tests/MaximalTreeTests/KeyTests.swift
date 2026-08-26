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

    /// The wider rule: anything focused that isn't the app's own chrome wants
    /// the keyboard. Naming classes could never cover this — a terminal is a
    /// plain NSView in a plugin the app cannot see, and typing into it was
    /// impossible while the modal layer assumed it was chrome.
    @Test func aFocusedCanvasViewKeepsItsKeys() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: .zero)
        window.contentView = content
        defer { window.orderOut(nil) }

        // A real terminal surface: no text view, no protocol, no cooperation.
        // Deliberately not put in the window — this is about how the view is
        // classified, and attaching one would start a shell for no reason.
        let terminal = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        #expect(KeyFocus.takesKeys(terminal, in: window),
                "the terminal was treated as chrome, so its keys were stolen")

        // The editor too, which is also not an NSTextView.
        #expect(KeyFocus.takesKeys(MaximalEditor.EditorTextView(frame: .zero), in: window))
    }

    /// With nothing in particular focused, the keys are the app's — this is
    /// what makes j and k move the tree.
    @Test func chromeAndNothingLeaveTheKeysToTheApp() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSHostingView(rootView: Text("chrome"))
        window.contentView = content
        defer { window.orderOut(nil) }

        #expect(!KeyFocus.takesKeys(nil, in: window))
        #expect(!KeyFocus.takesKeys(window, in: window))
        #expect(!KeyFocus.takesKeys(content, in: window), "the content view is chrome")
        // A SwiftUI hosting view anywhere in the tree is chrome as well.
        let nested = NSHostingView(rootView: Text("row"))
        content.addSubview(nested)
        #expect(!KeyFocus.takesKeys(nested, in: window))
    }

    /// And anything can say so outright, for a view the shape rule would
    /// otherwise call chrome.
    @Test func aViewCanClaimTheKeyboardOutright() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Text("chrome"))
        defer { window.orderOut(nil) }

        let hosted = NSHostingView(rootView: Text("special"))
        window.contentView?.addSubview(hosted)
        #expect(!KeyFocus.takesKeys(hosted, in: window))
        hosted.takesKeyboardInput = true
        #expect(KeyFocus.takesKeys(hosted, in: window))
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
        #expect(map.lookup(chords("i")) == .command("editor.focus"))
        #expect(map.lookup(chords("C-w l")) == .command("editor.focus"))
        #expect(map.lookup(chords("C-w h")) == .command("explorer.focus"))
    }
}
