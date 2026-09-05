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
        // The inspector claims nothing yet, and says so rather than serving
        // the sidebar's keys.
        #expect(model.surfaceKeymap(for: .inspector, showing: nil)
                    .lookup([KeyChord("j")]) == .unbound)
    }

    /// A pane showing something else is a different question, and a rename
    /// makes a new node — which is how a file that becomes a `.typ`, and so
    /// changes which canvas draws it, also changes this.
    @Test func aPaneShowingAnotherNodeRebuildsIt() throws {
        let model = try makeModel()
        let pane = UUID()
        let a = try #require(NodeID("file:///tmp/a.txt"))
        let b = try #require(NodeID("file:///tmp/b.typ"))

        _ = model.surfaceKeymap(for: .pane(pane), showing: a)
        let after = model.surfaceKeymapBuilds
        _ = model.surfaceKeymap(for: .pane(pane), showing: a)
        #expect(model.surfaceKeymapBuilds == after, "the same node rebuilt it")

        _ = model.surfaceKeymap(for: .pane(pane), showing: b)
        #expect(model.surfaceKeymapBuilds == after + 1, "a different node did not")
    }
}
