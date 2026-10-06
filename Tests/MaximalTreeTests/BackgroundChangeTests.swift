import Testing
import Foundation
@_spi(Host) @testable import MaximalTreeKit
@testable import MaximalTree

// What a change the reader didn't make is allowed to do.
//
// Both of these were races: they passed or failed depending on whether a
// background Task happened to finish first, and splitting the SDK into two
// modules shifted the timing enough to lose them most of the time. So these
// tests don't wait on timing. They hold a fetch open until they choose to
// release it, and they apply changes synchronously, which makes each ordering a
// thing the test decides rather than one it hopes for.

/// Holds attribute fetches open until the test lets them go, in whatever order
/// it wants.
@MainActor
private final class Gate {
    private(set) var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func releaseOldest() { if !waiting.isEmpty { waiting.removeFirst().resume() } }
    func releaseNewest() { if !waiting.isEmpty { waiting.removeLast().resume() } }
    /// Let everything go, so no fetch is left parked when a test ends early.
    func releaseAll() { while !waiting.isEmpty { waiting.removeFirst().resume() } }
}

/// A provider whose attribute fetches park at the gate, and answer with which
/// fetch they were — so a test can tell a fresh answer from a stale one.
private final class GatedProvider: NodeProvider, @unchecked Sendable {
    let schemes: Set<String> = ["gate"]
    let gate: Gate
    @MainActor private(set) var fetches = 0

    init(gate: Gate) { self.gate = gate }

    nonisolated func resolve(_ uri: String) -> NodeID? { NodeID(uri) }
    nonisolated func node(for id: NodeID) async -> Node? { Node(id: id, type: "gate.item") }
    nonisolated func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        Page(items: [])
    }
    nonisolated func attributes(of id: NodeID) async -> Attributes {
        let fetch = await MainActor.run { () -> Int in fetches += 1; return fetches }
        await gate.wait()
        var attributes = Attributes()
        attributes["detail"] = .string("fetch \(fetch)")
        return attributes
    }
}

@MainActor
@Suite struct BackgroundChangeTests {
    private func id(_ uri: String) -> NodeID { NodeID(uri)! }

    /// Both halves handed back and held: `backend` is weak.
    private func store(_ provider: NodeProvider) -> (GraphStore, HostContext) {
        let context = HostContext()
        let registry = Registry()
        registry.register(provider: provider)
        let store = GraphStore(context: context, registry: registry, nav: NavigationModel())
        context.backend = store
        return (store, context)
    }

    /// Polls until `condition` holds, failing with `message` if it never does.
    private func waitUntil(_ message: Comment, _ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), message)
    }

    // MARK: The selection is the reader's

    /// Select several things, and let something change elsewhere. They stay
    /// selected: the next action is about to act on them.
    @Test func aBackgroundChangeLeavesAMultiSelectionAlone() {
        let (store, context) = store(GatedProvider(gate: Gate()))
        let a = id("gate://a"), b = id("gate://b"), c = id("gate://c")
        for node in [a, b, c] { context._ingest(Node(id: node, type: "gate.item")) }
        store.open(a)
        store.select([b, c])

        store.notify([.modified(a), .childrenChanged(id("gate://elsewhere"))])

        #expect(context.selection == [b, c],
                "a change nobody made put the selection back on the open node")
    }

    /// A selected group or feed is what the contents column is showing, and
    /// nothing is open for it at all.
    @Test func aBackgroundChangeLeavesASelectionWithNothingOpenAlone() {
        let (store, context) = store(GatedProvider(gate: Gate()))
        let feed = id("gate://feed")
        context._ingest(Node(id: feed, type: "gate.item"))
        store.select([feed])

        store.notify([.modified(feed)])

        #expect(context.selection == [feed], "the selection was emptied")
    }

    /// A rename is followed, not reset — which is what the reset used to be
    /// standing in for, and never needed to.
    @Test func aRenamedSelectionFollowsTheRename() {
        let (store, context) = store(GatedProvider(gate: Gate()))
        let a = id("gate://a"), b = id("gate://b"), moved = id("gate://b2")
        for node in [a, b] { context._ingest(Node(id: node, type: "gate.item")) }
        store.open(a)
        store.select([b])

        store.notify([.renamed(from: b, to: moved)])

        #expect(context.selection == [moved])
    }

    /// And when nothing the selection held survived, it falls back to what the
    /// pane is showing rather than to nothing.
    @Test func aSelectionThatWasRemovedFallsBackToTheOpenNode() {
        let (store, context) = store(GatedProvider(gate: Gate()))
        let a = id("gate://a"), b = id("gate://b")
        for node in [a, b] { context._ingest(Node(id: node, type: "gate.item")) }
        store.open(a)
        store.select([b])

        store.notify([.removed(b)])

        #expect(context.selection == [a])
    }

    // MARK: A refresh is a new listing

    /// Refreshed while the first fetch is still out: the refresh is a promise
    /// to ask again, and the fetch in flight must not swallow it.
    @Test func refreshingMidFetchAsksAgain() async throws {
        let gate = Gate()
        let provider = GatedProvider(gate: gate)
        let (store, context) = store(provider)
        let parent = id("gate://parent"), child = id("gate://a")
        context._ingest(Node(id: parent, type: "gate.item", hasChildren: true))
        context._ingest(Node(id: child, type: "gate.item"))
        context._setChildren([child], of: parent)

        context.loadAttributes(of: child)
        try await waitUntil("the first fetch never started") { gate.waiting.count == 1 }

        store.refreshChildren(of: [parent])
        context.loadAttributes(of: child)
        // Parked, not merely counted: the count moves before the fetch reaches
        // the gate, which is the same gap that made the old test a race.
        try await waitUntil("the refresh did not let it ask again") { gate.waiting.count == 2 }
        #expect(provider.fetches == 2)

        gate.releaseAll()
    }

    /// And the answer that finally counts is the one asked for after the
    /// refresh. The first fetch describes a listing that is gone; landing late
    /// does not make it true.
    @Test func aStaleAnswerDoesNotOverwriteAFreshOne() async throws {
        let gate = Gate()
        let provider = GatedProvider(gate: gate)
        let (store, context) = store(provider)
        let parent = id("gate://parent"), child = id("gate://a")
        context._ingest(Node(id: parent, type: "gate.item", hasChildren: true))
        context._ingest(Node(id: child, type: "gate.item"))
        context._setChildren([child], of: parent)

        context.loadAttributes(of: child)
        try await waitUntil("the first fetch never started") { gate.waiting.count == 1 }
        store.refreshChildren(of: [parent])
        context.loadAttributes(of: child)
        try await waitUntil("the second fetch never started") { gate.waiting.count == 2 }
        guard gate.waiting.count == 2 else { gate.releaseAll(); return }

        gate.releaseNewest()
        try await waitUntil("the fresh answer never landed") { context.node(child)?.detail == "fetch 2" }

        gate.releaseOldest()
        try await Task.sleep(for: .milliseconds(50))
        #expect(context.node(child)?.detail == "fetch 2", "the stale answer overwrote the fresh one")
    }
}
