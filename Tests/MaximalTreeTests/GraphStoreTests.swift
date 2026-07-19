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

    @Test func notifyChildrenChangedInvalidatesCacheAndCursor() throws {
        let (store, context) = makeStore()
        let root = try #require(NodeID("stub://root"))
        context._setChildren([], of: root)
        context._setChildCursor(Cursor("2"), of: root)

        store.notify([.childrenChanged(root)])
        #expect(context.cachedChildren(of: root) == nil)
        #expect(!context.hasMoreChildren(root), "a restarted fetch must not resume a stale cursor")
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
}
