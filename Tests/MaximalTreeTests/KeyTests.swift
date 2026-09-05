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
        #expect(map.lookup(chords("SPC SPC")) == .command("finder.nodes"))
        #expect(map.lookup(chords("SPC s v")) == .command("pane.splitRight"))
        #expect(map.lookup(chords("SPC g o")) == .command("git.open"))
        #expect(map.lookup(chords("g t")) == .command("tab.next"))
        if case .prefix(let label, _) = map.lookup(chords("SPC t")) {
            #expect(label == "tab")
        } else {
            Issue.record("SPC t should be a group")
        }
    }

    /// The groups are named for the app's own nouns.
    ///
    /// They were Doom's for a while — `w` window, `b` buffer, `p` project —
    /// and the comments spent their time translating. There is one window
    /// here, so a group called window could only have meant something else.
    @Test func theGroupsAreTheAppsOwnNouns() {
        let map = DefaultKeymap.make()
        let expected = ["f": "file", "s": "surface", "t": "tab",
                        "w": "workspace", "n": "new", "g": "git", "T": "terminal"]
        for (key, noun) in expected {
            guard case .prefix(let label, _) = map.lookup(chords("SPC \(key)")) else {
                Issue.record("SPC \(key) should be the \(noun) group")
                continue
            }
            #expect(label == noun, "SPC \(key) reads as \(label)")
        }
        // And the words that no longer describe anything are gone.
        for retired in ["b", "p"] {
            #expect(map.lookup(chords("SPC \(retired)")) == .unbound,
                    "SPC \(retired) still leads somewhere")
        }
    }

    /// Movement at each scale the app has one: between surfaces, tabs, and
    /// workspaces. Moving *within* the sidebar is the sidebar's own and lives
    /// in its surface map, not here. Bound twice over where Vim and Doom disagree about the
    /// prefix, since both sets of fingers show up here.
    @Test func everyScaleOfMovementIsBound() {
        let map = DefaultKeymap.make()
        let expected = [
            "C-w h": "surface.left", "C-w j": "surface.down",
            "C-w k": "surface.up", "C-w l": "surface.right",
            "C-w w": "surface.next", "C-w W": "surface.previous",
            "SPC s h": "surface.left", "SPC s l": "surface.right",
            "SPC s n": "surface.next", "SPC s p": "surface.previous",
            "SPC t n": "tab.next", "SPC t p": "tab.previous",
            "SPC t h": "tab.first", "SPC t l": "tab.last",
            "g t": "tab.next", "g T": "tab.previous",
            "g w": "workspace.next", "g W": "workspace.previous",
            "SPC w n": "workspace.next", "SPC w w": "finder.workspaces",
            "SPC w p": "workspace.previous",
            // The finder. The key you reach for without thinking goes to the
            // tree in front of you; searching everything is its own.
            "SPC SPC": "finder.nodes", "SPC /": "finder.all",
            "M-x": "finder.actions",
            "SPC f f": "finder.files", "SPC t t": "finder.buffers",
        ]
        for (keys, command) in expected {
            #expect(map.lookup(chords(keys)) == .command(command),
                    "\(keys) should run \(command)")
        }
    }

    // The "is every binding real?" check lives in CoreActionTests now, where
    // it can ask the action registry instead of a list kept by hand here. That
    // list went stale the moment an operation was added — which is the exact
    // failure it existed to catch.
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

    /// Backspace is the way *back* through a sequence, where Escape is the way
    /// out of it. A wrong third key shouldn't cost the two that were right.
    @Test func backspaceStepsBackOneKey() {
        let (engine, log) = makeEngine()
        _ = engine.handle(chord("SPC"), editing: false)
        _ = engine.handle(chord("f"), editing: false)
        #expect(engine.pending == [chord("SPC"), chord("f")])
        #expect(engine.prefixLabel == "file")

        #expect(engine.handle(chord("DEL"), editing: false) == .pendingSequence)
        #expect(engine.pending == [chord("SPC")])
        // And the level it stepped back to is live again, not just shorter.
        #expect(engine.continuations.map(\.chord) == [chord("f")])

        // Typing on from there still works.
        _ = engine.handle(chord("f"), editing: false)
        _ = engine.handle(chord("s"), editing: false)
        #expect(log().map(\.0) == ["save"])
    }

    @Test func backspacePastTheFirstKeyLeavesNothingPending() {
        let (engine, _) = makeEngine()
        _ = engine.handle(chord("SPC"), editing: false)
        _ = engine.handle(chord("DEL"), editing: false)
        #expect(engine.pending.isEmpty)
        #expect(engine.continuations.isEmpty)
        #expect(engine.prefixLabel.isEmpty)
    }

    /// A repeat is being typed one digit at a time, so backspace takes one
    /// digit — and the last one leaves no count rather than a zero.
    @Test func backspaceEditsACountBeingTyped() {
        let (engine, _) = makeEngine()
        _ = engine.handle(chord("1"), editing: false)
        _ = engine.handle(chord("2"), editing: false)
        #expect(engine.count == 12)

        _ = engine.handle(chord("DEL"), editing: false)
        #expect(engine.count == 1)
        _ = engine.handle(chord("DEL"), editing: false)
        #expect(engine.count == nil)
    }

    /// A count survives stepping back out of a sequence, the way it does in
    /// vim: `3 SPC` backspaced is still `3`.
    @Test func aCountOutlivesTheSequenceItPrefixed() {
        let (engine, _) = makeEngine()
        _ = engine.handle(chord("3"), editing: false)
        _ = engine.handle(chord("SPC"), editing: false)
        _ = engine.handle(chord("DEL"), editing: false)
        #expect(engine.pending.isEmpty)
        #expect(engine.count == 3)
    }

    /// With nothing being typed it is just a key, and belongs to whatever has
    /// the keyboard.
    @Test func backspaceWithNothingPendingIsNotOurs() {
        let (engine, _) = makeEngine()
        #expect(engine.handle(chord("DEL"), editing: false) == .passed)
    }

    /// What the peek shows while a surface has the keyboard.
    ///
    /// The defect this fixes: in a commanding mode the focused surface is
    /// asked before the app is, so listing the app's bindings plainly was a
    /// lie — `j` read as "move down the sidebar" while the editor took it to
    /// move the caret.
    @Test func thePeekLeadsWithTheSurfacesKeys() {
        let surface = [(keys: "j", label: "Down"), (keys: "w", label: "Next word")]
        let app = [(keys: "j", label: "Move Down"),
                   (keys: "SPC", label: "+leader"),
                   (keys: "/", label: "Find Anything…")]

        let rows = KeyWhichKey.peekRows(surface: surface, app: app, mode: .normal)

        // One row per key, saying what that key does here: `j` is the
        // surface's, so the app's `j` is gone rather than shown beside it.
        #expect(rows.map(\.keys) == ["j", "w", "SPC", "/"])
        #expect(rows.filter { $0.keys == "j" }.count == 1)
        #expect(rows.first { $0.keys == "j" }?.label == "Down")
    }

    /// With nothing claimed by the surface, it is the app's list unchanged.
    @Test func withNoSurfaceKeysThePeekIsJustTheApp() {
        let app = [(keys: "j", label: "Move Down"), (keys: "SPC", label: "+leader")]
        let rows = KeyWhichKey.peekRows(app: app, mode: .normal)
        #expect(rows.map(\.keys) == ["j", "SPC"])
        #expect(rows.map(\.label) == ["Move Down", "+leader"])
    }

    /// The peek is only useful if it shows all of them. The shipped keymap
    /// binds more keys at the top level than a mid-sequence group is allowed
    /// to show, which is why the peek has a limit of its own.
    @Test func everyTopLevelKeyFitsInThePeek() {
        let engine = KeyEngine(keymap: DefaultKeymap.make())
        // Both lists at once, which is what the peek shows over an editor.
        let together = engine.topLevelBindings.count
            + EditorKeys.bindings.count
        #expect(together <= KeyWhichKey.peekLimit)
        #expect(together > 18,
                "if this ever drops below the ordinary cap, the peek limit is dead weight")
    }

    /// The peek shows the keys that mean something with nothing typed — the
    /// plain ones, and the leader among them as the group it opens.
    @Test func theTopLevelKeysCanBeReadWithoutTypingAnything() {
        let (engine, _) = makeEngine()
        let top = engine.topLevelBindings
        #expect(top.map(\.chord).sorted { $0.description < $1.description }
                == [chord("SPC"), chord("j")])
        // `j` runs something; `SPC` is a group and says so, which is what
        // makes this readable rather than a list of letters.
        #expect(top.first { $0.chord == chord("j") }?.binding == .command("down"))
        if case .prefix? = top.first(where: { $0.chord == chord("SPC") })?.binding {} else {
            Issue.record("the leader should read as a group")
        }
    }

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


/// Finding the things a key might be handed to.
@MainActor
@Suite struct KeyFocusTests {
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

/// A surface's own normal-mode keys.
///
/// The editor is not a special case: it declares keys the way the sidebar and
/// the terminal do, and what it does not claim falls through to the app.
@MainActor
@Suite struct SurfaceOwnedKeyTests {
    /// The editor is driven the way every surface is: a key names a command
    /// and the command runs. It used to implement the canvas protocol and get
    /// raw keystrokes.
    @Test func theEditorRunsNamedCommands() {
        let editor = makeEditor()
        #expect(editor.run(.right, count: 1, mode: .normal) == .normal,
                "the editor declined a motion")
        #expect(editor.textSelection.location == 1)
    }

    /// And the count reaches it, which a raw keystroke never carried.
    @Test func aCountReachesTheEditor() {
        let editor = makeEditor()
        _ = editor.run(.right, count: 3, mode: .normal)
        #expect(editor.textSelection.location == 3)
    }

    /// Declaring no keys is allowed and means "they are the app's" — which is
    /// what the inspector says today, and what a canvas showing a picture
    /// would say forever.
    @Test func aSurfaceNeedNotClaimAnything() {
        let contribution = CanvasContribution(matches: { _ in true }) { _, _ in AnyView(EmptyView()) }
        #expect(contribution.keys.isEmpty)
    }

    /// The whole trip a key takes, with a real editor on the other end. Every
    /// mode bug so far lived here, between parts that each tested clean.
    @Test func theEditorsCommandReportsTheModeItLeft() {
        let editor = makeEditor()
        // A motion stays where it was; `i` and `v` say where they went.
        #expect(editor.run(.right, count: 1, mode: .normal) == .normal)
        #expect(editor.run(.insertBefore, count: 1, mode: .normal) == .insert)
        #expect(editor.run(.extendSelection, count: 1, mode: .normal) == .visual)
    }

    /// Escape is one assignment, so it needs nothing focused to work — which
    /// was a real bug when leaving insert meant notifying an object: focus
    /// moves while typing (a completion panel takes the key window), and the
    /// canvas still inserting was never told.
    @Test func escapeIsTheModeAlone() {
        let keys = KeyEngine(keymap: DefaultKeymap.make())
        keys.setMode(.insert)
        #expect(KeyDispatch.handle(KeyChord("ESC"), keys: keys))
        #expect(keys.mode == .normal)
    }

    /// A half-typed sequence is the core's now, not the editor's, and a mode
    /// set anywhere else abandons it rather than letting it finish under rules
    /// it was never started under.
    @Test func aHalfTypedSequenceIsAbandonedWhenTheModeChanges() {
        var map = Keymap()
        map.bind("g g", to: "editor.firstLine")
        let keys = KeyEngine(keymap: map)

        _ = keys.handle(KeyChord("g"), editing: false)
        #expect(!keys.pending.isEmpty, "`g` should be waiting for its second key")

        keys.setMode(.insert)
        #expect(keys.pending.isEmpty, "the half-typed sequence outlived the mode")
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
