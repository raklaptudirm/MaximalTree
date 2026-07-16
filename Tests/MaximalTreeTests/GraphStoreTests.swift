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
