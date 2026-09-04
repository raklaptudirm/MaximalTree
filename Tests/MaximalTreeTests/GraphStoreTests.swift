import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// Vends 4 children in pages of 2, and marks nodes it re-serves so `.modified`
/// re-ingestion is observable.
private struct PagingProvider: NodeProvider {
    let schemes: Set<String> = ["stub"]

    func resolve(_ uri: String) -> NodeID? { NodeID(uri) }

    func node(for id: NodeID) async -> Node? {
        var attrs = Attributes()
        attrs["refetched"] = .bool(true)
        return Node(id: id, type: "stub.item", attributes: attrs)
    }

    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        let start = cursor.flatMap { Int($0.token) } ?? 0
        let items = (start..<(start + 2)).compactMap { i -> Node? in
            NodeID("stub://item/\(i)").map { Node(id: $0, type: "stub.item") }
        }
        return Page(items: items, next: start + 2 < 4 ? Cursor("\(start + 2)") : nil)
    }
}

/// A directory that changes underneath the app: it serves whatever
/// `contents` currently says, and counts how often it was asked.
@MainActor
private final class ShiftingProvider: NodeProvider {
    let schemes: Set<String> = ["shift"]
    var contents: [String] = ["a", "b"]
    var listings = 0

    nonisolated func resolve(_ uri: String) -> NodeID? { NodeID(uri) }
    nonisolated func node(for id: NodeID) async -> Node? { Node(id: id, type: "shift.item") }

    nonisolated func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        await MainActor.run {
            listings += 1
            return Page(items: contents.compactMap { name in
                NodeID("shift://\(name)").map { Node(id: $0, type: "shift.item") }
            }, next: nil)
        }
    }
}

@MainActor
@Suite struct GraphStoreTests {
    private func makeStore() -> (GraphStore, HostContext) {
        let context = HostContext()
        let registry = Registry()
        registry.register(provider: PagingProvider())
        let store = GraphStore(context: context, registry: registry, nav: NavigationModel())
        return (store, context)
    }

    /// Polls the main actor until `condition` holds (the store's loads are Tasks).
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(condition())
    }

    @Test func childrenPaginateAndAppend() async throws {
        let (store, context) = makeStore()
        let root = try #require(NodeID("stub://root"))

        store.requestChildren(of: root)
        try await waitUntil { context.cachedChildren(of: root) != nil }
        #expect(context.cachedChildren(of: root)?.count == 2)
        #expect(context.hasMoreChildren(root))

        context.loadMoreChildren(of: root)   // through the public plugin-facing API
        try await waitUntil { context.cachedChildren(of: root)?.count == 4 }
        #expect(!context.hasMoreChildren(root), "cursor exhausted after the last page")

        // No cursor left: a further request must be a no-op, not a crash or refetch.
        context.loadMoreChildren(of: root)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(context.cachedChildren(of: root)?.count == 4)
    }

    @Test func notifyRemovalIsImmediate() throws {
        let (store, context) = makeStore()
        let id = try #require(NodeID("stub://item/9"))
        context._ingest(Node(id: id, type: "stub.item"))

        store.notify([.removed(id)])
        #expect(context.node(id) == nil)
    }

    /// Stale-while-revalidate: an update marks the listing outdated and
    /// refetches, but the stale rows keep being served until the fresh ones
    /// swap in — dropping them blanked every expanded subtree for a frame
    /// (the sidebar blink).
    @Test func notifyChildrenChangedRefetchesWithoutBlankingTheListing() async throws {
        let (store, context) = makeStore()
        let root = try #require(NodeID("stub://root"))

        store.requestChildren(of: root)
        try await waitUntil { context.cachedChildren(of: root) != nil }
        let before = try #require(context.cachedChildren(of: root))
        #expect(before.count == 2)

        store.notify([.childrenChanged(root)])
        // The very next read — the frame the update lands on — still serves
        // the stale listing, and never an empty one.
        #expect(context.children(of: root) == before,
                "the listing blanked on invalidation")
        #expect(!context.hasMoreChildren(root), "a restarted fetch must not resume a stale cursor")

        // The read above also kicked the refetch; the fresh page swaps in
        // (and restores the provider's pagination cursor).
        try await waitUntil { context.hasMoreChildren(root) }
        #expect(context.cachedChildren(of: root)?.count == 2)
        #expect(!context._isChildrenStale(root))
    }

    @Test func notifyModifiedRefetchesNodeInPlace() async throws {
        let (store, context) = makeStore()
        let id = try #require(NodeID("stub://item/1"))
        context._ingest(Node(id: id, type: "stub.item"))   // no "refetched" attribute

        store.notify([.modified(id)])
        try await waitUntil {
            if case .bool(true)? = context.node(id)?.attributes["refetched"] { return true }
            return false
        }
    }
}

/// A provider that renames only nodes whose URI ends in "/renamable" — enough
/// to watch the host gate its rename UI on provider support.
private struct SelectivelyMutableProvider: NodeProvider, MutatingNodeProvider {
    let schemes: Set<String> = ["mut"]
    func resolve(_ uri: String) -> NodeID? { NodeID(uri) }
    func node(for id: NodeID) async -> Node? { Node(id: id, type: "mut.item") }
    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> { Page(items: []) }

    func supports(_ mutation: GraphMutation) -> Bool {
        if case .rename(let id, _) = mutation { return id.uri.hasSuffix("/renamable") }
        return false
    }
    func apply(_ mutation: GraphMutation) async throws -> [NodeChange] { [] }
}

@MainActor
@Suite struct RenameGatingTests {
    private func makeStore() -> (GraphStore, HostContext) {
        let context = HostContext()
        let registry = Registry()
        registry.register(provider: SelectivelyMutableProvider())
        let store = GraphStore(context: context, registry: registry, nav: NavigationModel())
        return (store, context)
    }

    /// The sidebar's text field appears only for nodes whose provider would
    /// honor the rename — `beginRename` is the single gate.
    @Test func beginRenameRequiresProviderSupport() throws {
        let (store, context) = makeStore()
        let yes = try #require(NodeID("mut://x/renamable"))
        let no = try #require(NodeID("mut://x/readonly"))

        store.beginRename(no)
        #expect(context.pendingRename == nil)

        store.beginRename(yes)
        #expect(context.pendingRename == yes)
    }

    /// A rename that lands while the field is open (an external one, say) must
    /// follow the node; a removal must dismiss the edit.
    @Test func pendingRenameTracksRemapAndRemoval() throws {
        let (store, context) = makeStore()
        let id = try #require(NodeID("mut://x/renamable"))
        let moved = try #require(NodeID("mut://y/renamable"))

        store.beginRename(id)
        context._remap(from: id, to: moved)
        #expect(context.pendingRename == moved)

        context._remove(moved)
        #expect(context.pendingRename == nil)
    }
}

/// A streaming provider whose stream the test drives by hand, plus a flag
/// proving the host terminated it on unmount.
private final class StreamingStubProvider: NodeProvider, ChangeStreamingProvider,
                                           @unchecked Sendable {
    let schemes: Set<String> = ["stub"]
    let continuationBox = Box()

    final class Box: @unchecked Sendable {
        var continuation: AsyncStream<[NodeChange]>.Continuation?
        var terminated = false
    }

    func resolve(_ uri: String) -> NodeID? { NodeID(uri) }
    func node(for id: NodeID) async -> Node? { Node(id: id, type: "stub.item") }
    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> { Page(items: []) }

    func changes(under root: NodeID) -> AsyncStream<[NodeChange]>? {
        AsyncStream { continuation in
            continuationBox.continuation = continuation
            continuation.onTermination = { [box = continuationBox] _ in
                box.terminated = true
            }
        }
    }
}

@MainActor
@Suite struct ChangeStreamTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(condition())
    }

    @Test func externalChangesFlowIntoTheFunnelAndStopOnUnmount() async throws {
        let context = HostContext()
        let registry = Registry()
        let provider = StreamingStubProvider()
        registry.register(provider: provider)
        let store = GraphStore(context: context, registry: registry, nav: NavigationModel())

        store.mount("stub://root")
        let root = try #require(NodeID("stub://root"))
        try await waitUntil { provider.continuationBox.continuation != nil }

        // An external batch invalidates the cache like a plugin notify would:
        // the listing goes stale (kept on screen), not blank.
        context._setChildren([], of: root)
        provider.continuationBox.continuation?.yield([.childrenChanged(root)])
        try await waitUntil { context._isChildrenStale(root) }
        #expect(context.cachedChildren(of: root) != nil, "stale must still be served")

        // Unmounting cancels the consuming task, which terminates the stream.
        store.unmount(root)
        try await waitUntil { provider.continuationBox.terminated }
    }

    /// A root that is removed has to leave the workspace as well, or closing
    /// it on one run brings it back on the next.
    @Test func removingARootReportsThatRootsChanged() async throws {
        let context = HostContext()
        let registry = Registry()
        registry.register(provider: PagingProvider())
        let store = GraphStore(context: context, registry: registry, nav: NavigationModel())
        var changes = 0
        store.onRootsChanged = { changes += 1 }

        store.mount("stub://root")
        let root = try #require(NodeID("stub://root"))
        let afterMount = changes

        store.notify([.removed(root)])

        #expect(!context.roots.contains(root))
        #expect(changes > afterMount, "the workspace was never told the root went away")
    }

    @Test func nonStreamingRootsAreSimplyNotWatched() throws {
        let context = HostContext()
        let registry = Registry()
        registry.register(provider: PagingProvider())   // not a streaming provider
        let store = GraphStore(context: context, registry: registry, nav: NavigationModel())
        store.mount("stub://root")   // must not crash or leak a task
        #expect(context.roots.count == 1)
    }
}

@MainActor
@Suite struct PhonyNodeTests {
    private func makeStore() -> (GraphStore, HostContext, NavigationModel) {
        let context = HostContext()
        let registry = Registry()
        registry.register(provider: PagingProvider())
        let nav = NavigationModel()
        let store = GraphStore(context: context, registry: registry, nav: nav)
        return (store, context, nav)
    }

    private func phony(_ uri: String, target: NodeID, fragment: String?) throws -> Node {
        Node(id: try #require(NodeID(uri)), type: "stub.phony",
             anchor: NodeAnchor(node: target, fragment: fragment))
    }

    @Test func openingPhonyNodeResolvesEverythingToTheRealTarget() throws {
        let (store, context, nav) = makeStore()
        let real = try #require(NodeID("stub://doc"))
        context._ingest(Node(id: real, type: "stub.item"))
        let section = try phony("stub://doc/sec", target: real, fragment: "line=12")
        context._ingest(section)

        store.open(section.id)
        #expect(nav.current == real, "the canvas is the real node's — one buffer")
        #expect(context.focusedNode == real)
        #expect(context.selection == [real], "selection + inspector follow the real node")
        #expect(context.activeFragment?.target == real)
        #expect(context.activeFragment?.fragment == "line=12")
    }

    @Test func plainNavigationClearsThePendingFragment() throws {
        let (store, context, _) = makeStore()
        let real = try #require(NodeID("stub://doc"))
        context._ingest(Node(id: real, type: "stub.item"))
        let section = try phony("stub://doc/sec", target: real, fragment: "line=3")
        context._ingest(section)

        store.open(section.id)
        #expect(context.activeFragment != nil)
        store.open(real)   // direct open: no stale jump may replay
        #expect(context.activeFragment == nil)
    }

    @Test func anchorChainsResolveWithClickedFragmentWinning() throws {
        let (store, context, nav) = makeStore()
        let real = try #require(NodeID("stub://doc"))
        context._ingest(Node(id: real, type: "stub.item"))
        let outer = try phony("stub://doc/outer", target: real, fragment: "line=1")
        context._ingest(outer)
        let inner = try phony("stub://doc/inner", target: outer.id, fragment: "line=9")
        context._ingest(inner)

        store.open(inner.id)
        #expect(nav.current == real)
        #expect(context.activeFragment?.fragment == "line=9",
                "the clicked node's fragment wins over intermediate anchors")
    }

    @Test func uncachedPhonyNodeResolvesViaProviderFetch() async throws {
        // PagingProvider serves plain nodes; a phony one must round-trip through
        // the async fetch path (openURI-style opens).
        let (store, context, nav) = makeStore()
        let real = try #require(NodeID("stub://doc"))
        context._ingest(Node(id: real, type: "stub.item"))
        let id = try #require(NodeID("stub://item/5"))

        store.open(id)   // not cached: resolves through provider.node(for:)
        for _ in 0..<200 where nav.current == nil {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(nav.current == id, "non-phony nodes open as themselves")
        #expect(context.activeFragment == nil)
    }
}

@MainActor
@Suite struct ChildContributionTests {
    private func makeStore() -> (GraphStore, HostContext) {
        let context = HostContext()
        let registry = Registry()
        registry.register(provider: PagingProvider())
        // Another plugin contributes an extra child under every stub.item node.
        registry.register(children: ChildContribution(
            matches: { $0.type == TypeID("stub.item") },
            children: { id in
                guard let extra = NodeID("\(id.uri)/contributed") else { return [] }
                return [Node(id: extra, type: "other.extra", label: "contributed")]
            }
        ))
        let store = GraphStore(context: context, registry: registry, nav: NavigationModel())
        return (store, context)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(condition())
    }

    @Test func matchingLeavesGainDisclosure() async throws {
        let (store, context) = makeStore()
        let root = try #require(NodeID("stub://root"))
        store.requestChildren(of: root)
        try await waitUntil { context.cachedChildren(of: root) != nil }

        // Provider vends stub.item as leaves; the contribution makes them expandable.
        let child = try #require(context.cachedChildren(of: root)?.first)
        #expect(context.node(child)?.hasChildren == true)
    }

    @Test func contributedChildrenAppendAfterOwners() async throws {
        let (store, context) = makeStore()
        let item = try #require(NodeID("stub://item/0"))
        context._ingest(Node(id: item, type: "stub.item"))

        store.requestChildren(of: item)
        try await waitUntil { context.cachedChildren(of: item) != nil }

        let children = try #require(context.cachedChildren(of: item))
        // PagingProvider vends 2 children for any node; the contribution appends 1.
        #expect(children.count == 3)
        #expect(children.last?.uri.hasSuffix("/contributed") == true)
        #expect(context.node(children.last!)?.type == TypeID("other.extra"))
    }

    /// The point of refreshing: a listing the app already has is asked for
    /// again, and the new answer replaces the old.
    @Test func refreshingReasksForChildrenAlreadyLoaded() async throws {
        let context = HostContext()
        let registry = Registry()
        let provider = ShiftingProvider()
        registry.register(provider: provider)
        let store = GraphStore(context: context, registry: registry, nav: NavigationModel())
        let root = try #require(NodeID("shift://root"))

        store.requestChildren(of: root)
        try await waitUntil { context.cachedChildren(of: root)?.count == 2 }
        #expect(provider.listings == 1)

        // Something else changes the directory.
        provider.contents = ["a", "b", "c"]

        store.refreshChildren(of: [root])
        try await waitUntil { context.cachedChildren(of: root)?.count == 3 }
        #expect(provider.listings == 2)
    }

    /// Refreshing must not turn into a background crawl of the whole tree: a
    /// node nobody has opened is not fetched just because it was named.
    @Test func refreshingIgnoresNodesNeverLoaded() async throws {
        let context = HostContext()
        let registry = Registry()
        let provider = ShiftingProvider()
        registry.register(provider: provider)
        let store = GraphStore(context: context, registry: registry, nav: NavigationModel())
        let unopened = try #require(NodeID("shift://never-opened"))

        store.refreshChildren(of: [unopened])
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(provider.listings == 0)
        #expect(context.cachedChildren(of: unopened) == nil)
    }

    /// A refresh replaces the listing, it doesn't blank it: the tree must not
    /// collapse to empty for the moment the provider takes to answer.
    @Test func theOldListingStaysUntilTheNewOneArrives() async throws {
        let context = HostContext()
        let registry = Registry()
        let provider = ShiftingProvider()
        registry.register(provider: provider)
        let store = GraphStore(context: context, registry: registry, nav: NavigationModel())
        let root = try #require(NodeID("shift://root"))

        store.requestChildren(of: root)
        try await waitUntil { context.cachedChildren(of: root)?.count == 2 }

        store.refreshChildren(of: [root])
        // Read straight after asking, before the provider can have answered.
        #expect(context.cachedChildren(of: root)?.count == 2)
    }
}
