import Testing
import Foundation
@_spi(Host) @testable import MaximalTreeKit
@testable import MaximalTree

// What passes between the engine and the shell around it.
//
// None of this had a test while it lived inside AppModel: it was simply what
// the window did. Pulled apart, it is an interface, and each crossing of it is
// held here — with a stand-in shell for the engine's side, and the real window
// for the shell's.

/// A shell that only listens, and says it is pointing at whatever it is told.
@MainActor
private final class Listening: HostShell {
    var revealed: [NodeID] = []
    private(set) var heard: [String] = []
    private(set) var modes: [KeyMode] = []

    var revealedNodes: [NodeID] { revealed }
    func keyTargets() -> [NodeID]? { nil }
    func nodeRenamed(from old: NodeID, to new: NodeID) { heard.append("renamed \(old.uri) → \(new.uri)") }
    func leavingWorkspace(_ id: UUID) { heard.append("leaving \(id)") }
    func enteredWorkspace(_ id: UUID, firstVisit: Bool) {
        heard.append("entered \(id)\(firstVisit ? " first" : "")")
    }
    func setKeyMode(_ mode: KeyMode) { modes.append(mode) }
}

/// Lists nothing, and counts how often it is asked to.
private final class Counting: NodeProvider, @unchecked Sendable {
    let schemes: Set<String> = ["count"]
    @MainActor private(set) var listings = 0
    nonisolated func resolve(_ uri: String) -> NodeID? { NodeID(uri) }
    nonisolated func node(for id: NodeID) async -> Node? { Node(id: id, type: "count.item") }
    nonisolated func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        await MainActor.run { listings += 1 }
        return Page(items: [])
    }
}

private func library() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("engine-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("workspaces.json")
}

@MainActor
@Suite struct HostEngineShellTests {
    private func engine(_ shell: Listening, providers: [NodeProvider] = []) throws -> HostEngine {
        let registry = CoreContributions()
        for provider in providers { registry.register(provider: provider) }
        let engine = HostEngine(host: HostContext(), registry: registry,
                                workspaceStore: WorkspaceStore(fileURL: try library()))
        engine.shell = shell
        return engine
    }

    /// On launch the workspace is a first visit: what it saved is all there is.
    @Test func launchingIsAFirstVisit() throws {
        let shell = Listening()
        let engine = try engine(shell)
        engine.start()
        let active = try #require(engine.activeWorkspaceID)
        #expect(shell.heard == ["entered \(active) first"])
    }

    /// Leaving puts the shell's half by; coming back is not a first visit, so
    /// the shell brings back what it put by rather than what was on disk.
    @Test func aWorkspaceLeftAndReturnedToIsNotAFirstVisit() throws {
        let shell = Listening()
        let engine = try engine(shell)
        engine.start()
        let first = try #require(engine.activeWorkspaceID)
        let second = engine.workspaceStore.create(named: "Second").id

        engine.switchWorkspace(to: second)
        engine.switchWorkspace(to: first)

        #expect(shell.heard == [
            "entered \(first) first",
            "leaving \(first)", "entered \(second) first",
            "leaving \(second)", "entered \(first)",
        ])
    }

    @Test func aRenameReachesTheShell() throws {
        let shell = Listening()
        let engine = try engine(shell)
        engine.start()
        let old = try #require(NodeID("count://old")), new = try #require(NodeID("count://new"))

        engine.store?.notify([.renamed(from: old, to: new)])

        #expect(shell.heard.last == "renamed count://old → count://new")
    }

    /// A surface's command can leave the app in a mode; the shell owns the keys.
    @Test func theModeACommandLeavesReachesTheShell() throws {
        let shell = Listening()
        let engine = try engine(shell)
        engine.start()
        engine.store?.setKeyMode(.insert)
        #expect(shell.modes == [.insert])
    }

    /// A refresh asks again for what the shell has opened out, not only the
    /// roots — the roots are the engine's to know, the rest is the window's.
    @Test func aRefreshAsksAgainForWhatTheShellHasOpened() throws {
        let shell = Listening()
        let provider = Counting()
        let engine = try engine(shell, providers: [provider])
        engine.start()
        let opened = try #require(NodeID("count://opened"))
        engine.host._ingest(Node(id: opened, type: "count.item", hasChildren: true))
        engine.host._setChildren([], of: opened)
        shell.revealed = [opened]
        let store = try #require(engine.store)

        engine.refreshVisibleNodes()

        #expect(store.outstanding > 0, "nothing the shell had opened was asked for again")
    }
}

/// The window's half: what it keeps per workspace, and where it gets it from.
@MainActor
@Suite struct AppShellWorkspaceTests {
    /// Opened out as it was left, and with the selection's anchor where it
    /// was — which nothing writes down, so only what the window put by on
    /// leaving can bring it back.
    @Test func theSidebarComesBackAsItWasLeft() throws {
        let model = AppModel(host: HostContext(), workspaceFile: try library())
        model.start()
        let first = try #require(model.activeWorkspaceID)
        let second = model.workspaceStore.create(named: "Second").id
        let opened = try #require(NodeID("count://opened"))

        model.sidebar.expandedNodes = [opened]
        model.sidebar.anchor = opened
        model.switchWorkspace(to: second)
        #expect(model.sidebar.expandedNodes.isEmpty, "the other workspace's tree was opened out")
        model.switchWorkspace(to: first)

        #expect(model.sidebar.expandedNodes == [opened])
        #expect(model.sidebar.anchor == opened, "the anchor was lost on the way")
    }

    /// And on launch, from what was written down — which every disclosure is.
    @Test func theSidebarComesBackOpenedOutAfterARelaunch() throws {
        let file = try library()
        let opened = try #require(NodeID("count://opened"))
        let before = AppModel(host: HostContext(), workspaceFile: file)
        before.start()
        before.sidebar.expandedNodes = [opened]

        let after = AppModel(host: HostContext(), workspaceFile: file)
        after.start()

        #expect(after.sidebar.expandedNodes == [opened])
    }

    /// The node it shows has a new name; the sidebar's record of it follows.
    @Test func aRenamedNodeStaysOpenedOut() throws {
        let model = AppModel(host: HostContext(), workspaceFile: try library())
        model.start()
        let old = try #require(NodeID("count://old")), new = try #require(NodeID("count://new"))
        model.sidebar.expandedNodes = [old]

        model.store?.notify([.renamed(from: old, to: new)])

        #expect(model.sidebar.expandedNodes == [new])
    }
}
