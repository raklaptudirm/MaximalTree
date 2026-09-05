import Testing
import AppKit
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// What can be done to a running terminal.
@MainActor
@Suite struct TerminalActionTests {
    private func registry() -> Registry {
        let registry = Registry()
        TerminalPlugin().register(with: registry)
        return registry
    }

    private func action(_ id: String) -> Action? {
        registry().actions.first { $0.id == id }
    }

    @Test func theVocabularyIsRegistered() {
        let ids = Set(registry().actions.map(\.id))
        for id in ["terminal.clear", "terminal.reset", "terminal.restart",
                   "terminal.copy", "terminal.paste", "terminal.selectAll",
                   "terminal.fontBigger", "terminal.fontSmaller", "terminal.fontReset",
                   "terminal.copyDirectory", "terminal.openDirectory",
                   "terminal.revealDirectory"] {
            #expect(ids.contains(id), "\(id) is not registered")
        }
    }

    /// All of them need a running shell, and none of them should be offered
    /// anywhere else — a "Clear Screen" on a text file is noise in every list
    /// that reads the registry.
    @Test func noneOfThemApplyWithoutALiveTerminal() throws {
        let host = HostContext()
        let file = try #require(NodeID("file:///tmp/a.txt"))
        host._ingest(Node(id: file, type: "file.file"))
        let ctx = ActionContext(host: host, targets: [file])

        for action in registry().actions where action.id.hasPrefix("terminal.")
            && !["terminal.new", "terminal.newHere", "terminal.openHere",
                 "terminal.showAll", "terminal.close"].contains(action.id) {
            #expect(!action.appliesTo.matches(ctx),
                    "\(action.id) offered itself for a text file")
        }
    }

    /// A session node whose shell has gone is not a live terminal. The node
    /// outlives the process — a workspace remembers it — so this is the
    /// ordinary case after a relaunch, not an edge one.
    @Test func aClosedSessionIsNotLive() throws {
        let host = HostContext()
        let ghost = try #require(NodeID(TerminalRef.sessionURI(id: UUID(),
                                                               directory: "/tmp")))
        #expect(!TerminalActions.isLiveSession(ActionContext(host: host, targets: [ghost])))
        #expect(TerminalActions.session(for: [ghost]) == nil)
    }

    /// The pass-through actions name libghostty's own vocabulary, and a name
    /// it doesn't know is a command that silently does nothing. The names were
    /// checked against the shipped binary; this pins the mapping so a rename
    /// in a version bump shows up here rather than as a dead menu item.
    @Test func eachPassthroughNamesTheGhosttyActionItMeans() {
        let mapping = Dictionary(uniqueKeysWithValues:
            TerminalActions.passthrough.map { ($0.id, $0.action) })

        #expect(mapping["terminal.clear"] == "clear_screen")
        #expect(mapping["terminal.reset"] == "reset")
        #expect(mapping["terminal.copy"] == "copy_to_clipboard")
        #expect(mapping["terminal.paste"] == "paste_from_clipboard")
        #expect(mapping["terminal.selectAll"] == "select_all")
        #expect(mapping["terminal.fontReset"] == "reset_font_size")
        // The font steps carry an amount, which the others must not.
        #expect(mapping["terminal.fontBigger"] == "increase_font_size:1")
        #expect(mapping["terminal.fontSmaller"] == "decrease_font_size:1")

        // Every registered pass-through is in the table, and each maps to a
        // scroll-free ghostty action name.
        let ids = Set(registry().actions.map(\.id))
        for item in TerminalActions.passthrough {
            #expect(ids.contains(item.id), "\(item.id) is in the table but not registered")
            #expect(!item.action.isEmpty)
        }
    }
}
