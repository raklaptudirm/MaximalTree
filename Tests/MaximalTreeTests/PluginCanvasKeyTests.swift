import Testing
import AppKit
import WebKit
@testable import MaximalEditorKit
@testable import MaximalTreeKit
@testable import MaximalTree

/// What a surface claims, and whether the actions behind it exist.
///
/// The page and the terminal used to implement `handleKey` and declare a
/// parallel list for which-key to read; a drift test checked the two agreed,
/// and still missed that `G` arrived lowercased, because it fed the handler
/// the string the declaration promised rather than the one the real path
/// delivers. There is one thing now — a key sequence naming an action — so
/// there is nothing left to drift.
@MainActor
@Suite struct PluginCanvasKeyTests {
    private func registry() -> Registry {
        let registry = Registry()
        TerminalPlugin().register(with: registry)
        return registry
    }

    /// The keys a canvas declares must name actions that exist, or they are
    /// bindings that quietly do nothing.
    @Test func theTerminalsKeysNameRegisteredActions() {
        let registry = registry()
        let ids = Set(registry.actions.map(\.id))
        let canvas = registry.canvases.first { !$0.keys.isEmpty }
        let keys = canvas?.keys ?? []

        #expect(!keys.isEmpty, "the terminal canvas declares no keys")
        for key in keys {
            #expect(ids.contains(key.action),
                    "\(key.sequence) names \(key.action), which is not registered")
        }
    }

    /// It claims the scrollback and nothing else: in a commanding mode the
    /// app's bindings are what you want, and a terminal that swallowed them
    /// would leave no way out of itself.
    @Test func theTerminalClaimsOnlyItsScrollback() {
        let canvas = registry().canvases.first { !$0.keys.isEmpty }
        let sequences = Set((canvas?.keys ?? []).map(\.sequence))
        #expect(sequences == ["j", "k", "d", "u", "g g", "G"])
        // Never the leader, and never a key the app needs to get you out.
        #expect(!sequences.contains("SPC"))
        #expect(!sequences.contains("/"))
        #expect(!sequences.contains("i"))
    }

    /// Each scroll action names one of libghostty's own, checked against the
    /// shipped binary. A name it does not know is a key that does nothing.
    @Test func theTerminalScrollsByNamedGhosttyActions() {
        let mapping = Dictionary(uniqueKeysWithValues:
            TerminalActions.scrolling.map { ($0.key, $0.action) })
        #expect(mapping["j"] == "scroll_page_lines:1")
        #expect(mapping["k"] == "scroll_page_lines:-1")
        #expect(mapping["d"] == "scroll_page_fractional:0.5")
        #expect(mapping["g g"] == "scroll_to_top")
        #expect(mapping["G"] == "scroll_to_bottom")
        #expect(TerminalActions.scrolling.allSatisfy { $0.action.hasPrefix("scroll_") })
    }

    /// Every scroll action needs a live shell, so none of them clutters a
    /// list anywhere else.
    @Test func scrollingNeedsALiveTerminal() throws {
        let host = HostContext()
        let file = try #require(NodeID("file:///tmp/a.txt"))
        host._ingest(Node(id: file, type: "file.file"))
        let ctx = ActionContext(host: host, targets: [file])

        for item in TerminalActions.scrolling {
            let action = try #require(registry().actions.first { $0.id == item.id })
            #expect(!action.appliesTo.matches(ctx),
                    "\(item.id) offered itself for a text file")
        }
    }
}

/// The repository canvas's keys.
///
/// It was the one canvas that could not have keys when the page and the
/// terminal got theirs, because a canvas needs something for `j` to move and a
/// SwiftUI `List` has no selection of its own. It has one now, and it lives
/// outside the view — an action cannot reach a view's `@State`, which is what
/// moving keys into actions forces you to notice.
@MainActor
@Suite struct RepoCanvasKeyTests {
    private func registry() -> Registry {
        let registry = Registry()
        GitPlugin().register(with: registry)
        return registry
    }

    private func model(staged: [String], unstaged: [String]) -> RepoCanvasModel {
        let model = RepoCanvasModel()
        model.setStatusForTesting(GitStatus(
            branch: "main",
            staged: staged.map { .init(code: "M", path: $0) },
            unstaged: unstaged.map { .init(code: "M", path: $0) }))
        return model
    }

    @Test func itsKeysNameRegisteredActions() {
        let registry = registry()
        let ids = Set(registry.actions.map(\.id))
        let canvas = registry.canvases.first { !$0.keys.isEmpty }
        let keys = canvas?.keys ?? []

        #expect(Set(keys.map(\.sequence)) == ["j", "k", "g g", "G", "RET", "s", "x"])
        for key in keys {
            #expect(ids.contains(key.action),
                    "\(key.sequence) names \(key.action), which is not registered")
        }
    }

    /// They are about the row under the cursor, so they only apply to the
    /// repository canvas and nowhere else.
    @Test func theyOnlyApplyToARepository() throws {
        let host = HostContext()
        let file = try #require(NodeID("file:///tmp/a.txt"))
        host._ingest(Node(id: file, type: "file.file"))

        for command in GitActions.canvasCommands {
            let action = try #require(registry().actions.first { $0.id == command.id })
            #expect(!action.appliesTo.matches(ActionContext(host: host, targets: [file])),
                    "\(command.id) offered itself for a text file")
        }
    }

    // MARK: What the commands do to the selection

    /// Staged first, then unstaged — one list to walk, in the order drawn.
    @Test func theKeysWalkBothSectionsAsOneList() {
        let model = model(staged: ["a.txt"], unstaged: ["b.txt", "c.txt"])
        #expect(model.rows.map(\.entry.path) == ["a.txt", "b.txt", "c.txt"])

        model.move(1)
        #expect(model.current?.entry.path == "a.txt")
        #expect(model.current?.staged == true)
        model.move(1)
        #expect(model.current?.entry.path == "b.txt")
        #expect(model.current?.staged == false)
    }

    /// A repeat reaches it, which it could not when the canvas handled its own
    /// keys — `handleKey` was never given a count.
    @Test func aCountRepeatsTheMotion() throws {
        let model = model(staged: [], unstaged: ["a.txt", "b.txt", "c.txt"])
        let down = try #require(GitActions.canvasCommands.first { $0.id == "git.changeDown" })

        down.run(model, 3)
        #expect(model.current?.entry.path == "c.txt")
    }

    @Test func movingStopsAtEitherEnd() {
        let model = model(staged: [], unstaged: ["a.txt", "b.txt"])
        model.moveToEdge(last: true)
        #expect(model.current?.entry.path == "b.txt")
        model.move(1)
        #expect(model.current?.entry.path == "b.txt", "walked off the end")

        model.moveToEdge(last: false)
        model.move(-1)
        #expect(model.current?.entry.path == "a.txt", "walked off the start")
    }

    @Test func movingInACleanRepositoryDoesNothing() {
        let model = model(staged: [], unstaged: [])
        model.move(1)
        model.moveToEdge(last: true)
        #expect(model.current == nil)
    }

    /// A row that goes — staged, discarded — must not leave the keys pointing
    /// at nothing, or the next `j` starts over from the top.
    @Test func theSelectionSurvivesARowLeaving() {
        let model = model(staged: [], unstaged: ["a.txt", "b.txt"])
        model.selected = "Mb.txt"
        model.setStatusForTesting(GitStatus(branch: "main",
                                            staged: [.init(code: "M", path: "b.txt")],
                                            unstaged: [.init(code: "M", path: "a.txt")]))
        #expect(model.current != nil, "the selection was left on a row that is gone")
    }

    /// One model per repository, so two open repos do not share a cursor.
    @Test func eachRepositoryHasItsOwnCursor() throws {
        let a = try #require(GitRef(repo: "/one", kind: .repo).nodeID)
        let b = try #require(GitRef(repo: "/two", kind: .repo).nodeID)
        #expect(GitUIState.shared.canvas(for: a) !== GitUIState.shared.canvas(for: b))
        #expect(GitUIState.shared.canvas(for: a) === GitUIState.shared.canvas(for: a))
    }
}
