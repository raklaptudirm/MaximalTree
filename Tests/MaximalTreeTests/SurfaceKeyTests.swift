import Testing
import AppKit
@testable import MaximalTreeKit
@testable import MaximalTree

/// A surface declares its keys and the core runs the actions.
///
/// The mechanism that replaces `CanvasKeyHandling`. What it buys: a surface's
/// keys are rebindable, listable and callable by name, and no surface sees a
/// raw keystroke in a commanding mode. The sidebar proves it first, being the
/// surface that could never use the old one — its motions were app bindings
/// carrying a predicate that named a surface.
@MainActor
@Suite struct SurfaceKeyTests {
    private func engine(_ ran: @escaping (String, Int) -> Void) -> KeyEngine {
        var app = Keymap()
        app.describe("SPC g", as: "git")
        app.bind("SPC g c", to: "git.commit")
        app.bind("/", to: "finder.all")
        app.bind("g t", to: "tab.next")
        let engine = KeyEngine(keymap: app)
        engine.perform = { id, count in ran(id, count) }
        return engine
    }

    private func surface(_ keys: [SurfaceKey]) -> Keymap {
        var map = Keymap()
        for key in keys { map.bind(key.sequence, to: key.action) }
        return map
    }

    private func chord(_ text: String) -> KeyChord { KeyChord(parsing: text)! }

    // MARK: Text fields

    /// While the keyboard is in a plain text field, letters are letters.
    ///
    /// Nothing sets insert mode when a field takes focus, so without this the
    /// modal layer went on claiming keys and every field in the app lost the
    /// ones its surface bound — typing "join" into an inspector field ran the
    /// `j` motion and dropped the character.
    @Test func aTextFieldKeepsTheKeysItsSurfaceWouldHaveTaken() {
        var ran: [String] = []
        let keys = engine { id, _ in ran.append(id) }
        let map = surface([SurfaceKey("j", "explorer.down")])

        // Its own key, and one of the app's.
        for key in ["j", "/"] {
            #expect(!KeyDispatch.handle(chord(key), keys: keys, surface: map, editing: true),
                    "\(key) was taken from a text field")
        }
        #expect(ran.isEmpty, "a field's typing ran commands: \(ran)")
    }

    /// Except the one that gets you out, which is never anyone else's.
    @Test func escapeStillBelongsToTheAppInATextField() {
        let keys = engine { _, _ in }
        keys.setMode(.insert)
        #expect(KeyDispatch.handle(chord("ESC"), keys: keys, surface: Keymap(), editing: true))
        #expect(keys.mode == .normal)
    }

    // MARK: The basic hand-off

    @Test func aSurfaceKeyRunsItsAction() {
        var ran: [String] = []
        let keys = engine { id, _ in ran.append(id) }
        let map = surface([SurfaceKey("j", "explorer.down")])

        #expect(KeyDispatch.handle(chord("j"), keys: keys, surface: map))
        #expect(ran == ["explorer.down"])
    }

    /// What the surface declines still belongs to the app, which is what keeps
    /// every global binding working with the keyboard anywhere.
    @Test func whatTheSurfaceDeclinesFallsThroughToTheApp() {
        var ran: [String] = []
        let keys = engine { id, _ in ran.append(id) }
        let map = surface([SurfaceKey("j", "explorer.down")])

        #expect(KeyDispatch.handle(chord("/"), keys: keys, surface: map))
        #expect(ran == ["finder.all"])
    }

    /// The leader is the app's wherever you are. A surface that could shadow
    /// `SPC` would be able to take the way out of itself.
    @Test func aSurfaceCannotTakeTheLeader() {
        var ran: [String] = []
        let keys = engine { id, _ in ran.append(id) }
        // Even declared, it never gets the chance.
        let map = surface([SurfaceKey("SPC", "explorer.down")])

        _ = KeyDispatch.handle(chord("SPC"), keys: keys, surface: map)
        _ = KeyDispatch.handle(chord("g"), keys: keys, surface: map)
        _ = KeyDispatch.handle(chord("c"), keys: keys, surface: map)
        #expect(ran == ["git.commit"], "the surface intercepted the leader")
    }

    // MARK: Sequences

    /// The flaw the first version had: once a surface started a sequence the
    /// pending state was not empty, so the next key was looked up in the app's
    /// map — resolving the sidebar's `g g` against the app's `g` group, which
    /// is a different `g` entirely.
    @Test func aSurfaceSequenceContinuesInTheSurfacesMap() {
        var ran: [String] = []
        let keys = engine { id, _ in ran.append(id) }
        let map = surface([SurfaceKey("g g", "explorer.first")])

        #expect(KeyDispatch.handle(chord("g"), keys: keys, surface: map))
        #expect(ran.isEmpty, "a prefix should not run anything yet")
        #expect(KeyDispatch.handle(chord("g"), keys: keys, surface: map))
        #expect(ran == ["explorer.first"])
    }

    /// And the app's sequences still resolve in the app's map, even when the
    /// surface has a binding for the same first key.
    @Test func anAppSequenceIsNotStolenMidway() {
        var ran: [String] = []
        let keys = engine { id, _ in ran.append(id) }
        let map = surface([SurfaceKey("t", "explorer.down")])

        // `g t` is the app's; the surface binds `t` alone.
        _ = KeyDispatch.handle(chord("g"), keys: keys, surface: map)
        _ = KeyDispatch.handle(chord("t"), keys: keys, surface: map)
        #expect(ran == ["tab.next"], "the surface took a key mid-sequence")
    }

    /// Half a surface sequence must not leak out as a stray app binding.
    @Test func aDeadEndInASurfaceSequenceIsStillTheSurfaces() {
        var ran: [String] = []
        let keys = engine { id, _ in ran.append(id) }
        let map = surface([SurfaceKey("g g", "explorer.first")])

        _ = KeyDispatch.handle(chord("g"), keys: keys, surface: map)
        // `g` then `/` is nothing in the surface's map. It must not become the
        // app's `/`.
        #expect(KeyDispatch.handle(chord("/"), keys: keys, surface: map))
        #expect(ran.isEmpty, "a dead end ran something")
        #expect(keys.pending.isEmpty, "the sequence was left half-typed")
    }

    // MARK: Counts

    /// A repeat typed before a surface key reaches its action, the same way it
    /// does for the app's.
    @Test func aCountReachesASurfaceAction() {
        var counts: [Int] = []
        let keys = engine { _, count in counts.append(count) }
        let map = surface([SurfaceKey("j", "explorer.down")])

        _ = KeyDispatch.handle(chord("5"), keys: keys, surface: map)
        _ = KeyDispatch.handle(chord("j"), keys: keys, surface: map)
        #expect(counts == [5])
    }

    // MARK: What the sidebar declares

    @Test func theSidebarClaimsItsOwnMotions() {
        let declared = Dictionary(uniqueKeysWithValues:
            AppModel.sidebarKeys.map { ($0.sequence, $0.action) })
        #expect(declared["j"] == "explorer.down")
        #expect(declared["g g"] == "explorer.first")
        #expect(declared["g p"] == "node.parent")
        #expect(declared["RET"] == "explorer.open")
    }

    /// They are gone from the app's map: that is the point. `j` in a terminal
    /// is the terminal's, and in the inspector it is nothing.
    @Test func theyAreNoLongerAppBindings() {
        let app = DefaultKeymap.make()
        for key in ["j", "k", "h", "l", "RET", "o", "G", "{", "}"] {
            #expect(app.lookup([KeyChord(parsing: key)!]) == .unbound,
                    "\(key) is still an app binding")
        }
    }

    /// And the actions no longer carry a rule about which surface they belong
    /// to — the binding says that now.
    @Test func theExplorerActionsNoLongerNameASurface() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("surfacekeys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(),
                             workspaceFile: dir.appendingPathComponent("workspaces.json"))
        model.registerCoreActions(with: model.pluginHost.registry)

        let ctx = ActionContext(host: model.host)
        for id in ["explorer.down", "explorer.up", "node.parent"] {
            let action = try #require(model.pluginHost.registry.actions.first { $0.id == id })
            #expect(action.appliesTo.matches(ctx),
                    "\(id) still refuses to apply based on which surface has focus")
        }
    }

    // MARK: Not rebuilt on every keystroke

    private func makeModel() throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("keycache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(),
                             workspaceFile: dir.appendingPathComponent("workspaces.json"))
        model.registerCoreActions(with: model.pluginHost.registry)
        return model
    }

    /// An answer given before the node's record existed must not be kept.
    ///
    /// The memo is keyed on the surface and the node, and nothing invalidates
    /// it when the record arrives — so an empty map built during the moment
    /// between a canvas appearing and its node being cached was remembered for
    /// as long as that pane showed that document. Every key the canvas
    /// declares then resolved to nothing, fell through to the view, and was
    /// typed as a character.
    @Test func aMapBuiltBeforeTheNodeArrivedIsNotRemembered() throws {
        let model = try makeModel()
        model.start()
        TextEditorPlugin().register(with: model.pluginHost.registry)
        let id = try #require(NodeID("file:///tmp/keycache.txt"))
        let pane = SurfaceID.pane(UUID())

        // Asked while the record is still on its way: nothing to resolve.
        #expect(model.surfaceKeymap(for: pane, showing: id).lookup([KeyChord("j")]) == .unbound)

        model.host._ingest(Node(id: id, type: TypeID("file.file")))

        #expect(model.surfaceKeymap(for: pane, showing: id).lookup([KeyChord("j")])
                    == .command("editor.down"),
                "the empty answer from before the record existed was cached")
    }

    /// Resolving a canvas runs every registered matcher and then builds a trie
    /// from the winner's bindings. That was happening on every key press.
    @Test func theSameSurfaceAndNodeIsAnsweredFromMemory() throws {
        let model = try makeModel()

        _ = model.surfaceKeymap(for: .sidebar, showing: nil)
        let after = model.surfaceKeymapBuilds
        for _ in 0..<20 { _ = model.surfaceKeymap(for: .sidebar, showing: nil) }
        #expect(model.surfaceKeymapBuilds == after, "rebuilt for a keystroke that changed nothing")

        // And the answer is still right, not merely fast.
        let map = model.surfaceKeymap(for: .sidebar, showing: nil)
        #expect(map.lookup([KeyChord("j")]) == .command("explorer.down"))
    }

    @Test func movingToAnotherSurfaceRebuildsIt() throws {
        let model = try makeModel()
        _ = model.surfaceKeymap(for: .sidebar, showing: nil)
        let after = model.surfaceKeymapBuilds

        _ = model.surfaceKeymap(for: .inspector, showing: nil)
        #expect(model.surfaceKeymapBuilds == after + 1)
        // And it is the inspector's own map, not the sidebar's served again:
        // `j` means something in both, and different things.
        #expect(model.surfaceKeymap(for: .inspector, showing: nil)
                    .lookup([KeyChord("j")]) == .command("inspector.scrollDown"))
    }

    /// A pane showing something else is a different question, and a rename
    /// makes a new node — which is how a file that becomes a `.typ`, and so
    /// changes which canvas draws it, also changes this.
    @Test func aPaneShowingAnotherNodeRebuildsIt() throws {
        let model = try makeModel()
        model.start()
        TextEditorPlugin().register(with: model.pluginHost.registry)
        let pane = UUID()
        let a = try #require(NodeID("file:///tmp/a.txt"))
        let b = try #require(NodeID("file:///tmp/b.txt"))
        // With records, so each lookup is an answer worth remembering. Without
        // them neither node resolves and this measured the memoising of a
        // shrug — which is the bug it now sits next to.
        model.host._ingest(Node(id: a, type: TypeID("file.file")))
        model.host._ingest(Node(id: b, type: TypeID("file.file")))

        _ = model.surfaceKeymap(for: .pane(pane), showing: a)
        let after = model.surfaceKeymapBuilds
        _ = model.surfaceKeymap(for: .pane(pane), showing: a)
        #expect(model.surfaceKeymapBuilds == after, "the same node rebuilt it")

        _ = model.surfaceKeymap(for: .pane(pane), showing: b)
        #expect(model.surfaceKeymapBuilds == after + 1, "a different node did not")
    }

    // MARK: What an unbound key does in a commanding mode

    /// Nothing. That is what the mode means.
    ///
    /// It used to reach the view and be typed, so a binding that failed to
    /// resolve — a canvas whose keys were not ready, a pane the registry no
    /// longer knew — did not look like a missing binding. It looked like the
    /// editor dropping out of normal mode and taking dictation.
    @Test func anUnboundKeyIsDroppedRatherThanTyped() {
        let keys = engine { _, _ in }
        for key in ["q", "Z", "RET", "TAB", "DEL", ";"] {
            #expect(KeyDispatch.handle(chord(key), keys: keys, surface: Keymap()),
                    "\(key) reached the view in normal mode")
        }
    }

    /// A key nothing binds is still not a command, so nothing runs.
    @Test func droppingAKeyRunsNothing() {
        var ran: [String] = []
        let keys = engine { id, _ in ran.append(id) }
        _ = KeyDispatch.handle(chord("q"), keys: keys, surface: Keymap())
        #expect(ran.isEmpty)
    }

    /// Except the ones that only move the view. Reading a document must not
    /// require being in a mode that can change it.
    @Test func theScrollingKeysStillReachTheView() {
        let keys = engine { _, _ in }
        for key in ["up", "down", "left", "right", "pageup", "pagedown", "home", "end"] {
            #expect(!KeyDispatch.handle(chord(key), keys: keys, surface: Keymap()),
                    "\(key) was swallowed, so the document cannot be scrolled")
        }
    }

    /// Insert mode is untouched by any of this: there, every key is a
    /// character and the view gets all of them.
    @Test func insertModeStillPassesEverythingThrough() {
        let keys = engine { _, _ in }
        keys.setMode(.insert)
        for key in ["q", "RET", "TAB", "/"] {
            #expect(!KeyDispatch.handle(chord(key), keys: keys, surface: Keymap()),
                    "\(key) was taken while inserting")
        }
    }

    /// And a bound key still runs, which is the thing the drop must not cost.
    @Test func aBoundKeyStillRunsAfterTheDrop() {
        var ran: [String] = []
        let keys = engine { id, _ in ran.append(id) }
        #expect(KeyDispatch.handle(chord("/"), keys: keys, surface: Keymap()))
        #expect(ran == ["finder.all"])
    }
}
