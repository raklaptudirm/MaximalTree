import Testing
import Foundation
@_spi(Host) @testable import MaximalTreeKit
@testable import MaximalTree

/// A source already in order, paged `size` at a time, counting how often it
/// was asked.
private final class Source: @unchecked Sendable {
    let items: [Int]
    let size: Int
    private(set) var fetches = 0
    init(_ items: [Int], pagedBy size: Int) { self.items = items; self.size = size }

    func page(after cursor: Cursor?) -> Page<Int> {
        fetches += 1
        let start = cursor.flatMap { Int($0.token) } ?? 0
        let end = min(start + size, items.count)
        return Page(items: Array(items[start..<end]), next: end < items.count ? Cursor(String(end)) : nil)
    }
}

@Suite struct FeedMergeTests {
    private func merge(_ sources: [String: Source], order: [String], after cursor: Cursor?,
                       size: Int) async -> Page<Int> {
        await FeedMerge.page(sources: order, after: cursor, size: size, isBefore: { $0 < $1 },
                             fetch: { id, cursor in sources[id]!.page(after: cursor) })
    }

    /// Every page, walked to the end — through the cursor as it is written
    /// down, not as it was made.
    private func walk(_ sources: [String: Source], order: [String], size: Int) async throws -> [[Int]] {
        var pages: [[Int]] = [], cursor: Cursor?
        repeat {
            let page = await merge(sources, order: order, after: cursor, size: size)
            pages.append(page.items)
            cursor = try page.next.map { try JSONDecoder().decode(Cursor.self, from: JSONEncoder().encode($0)) }
        } while cursor != nil && pages.count < 50
        return pages
    }

    /// Sources that page differently — one empty, one ending on a page
    /// boundary, one a page at a time — merge into the one order, in full
    /// pages until the last.
    @Test func sourcesPagingDifferentlyMergeIntoOneOrder() async throws {
        let sources = ["a": Source([1, 4, 7, 10], pagedBy: 2), "b": Source([2, 3, 8], pagedBy: 1),
                       "c": Source([], pagedBy: 5), "d": Source([5, 6, 9, 11, 12], pagedBy: 3)]
        let pages = try await walk(sources, order: ["a", "b", "c", "d"], size: 3)

        #expect(pages.flatMap { $0 } == Array(1...12))
        #expect(pages.dropLast().allSatisfy { $0.count == 3 })
    }

    /// Nothing is given out while a source that has not shown its next page
    /// could still hold something earlier. A source whose page is used up is
    /// asked for the next before it is compared.
    @Test func nothingIsGivenOutAheadOfAPageNotYetSeen() async {
        let sources = ["late": Source([10, 11, 12], pagedBy: 3), "early": Source([1, 2], pagedBy: 1)]
        let page = await merge(sources, order: ["late", "early"], after: nil, size: 3)
        #expect(page.items == [1, 2, 10])
    }

    @Test func tiesGoToTheSourceListedFirst() async {
        let tagged = ["x": [(1, "x")], "y": [(1, "y")]]
        for order in [["x", "y"], ["y", "x"]] {
            let page = await FeedMerge.page(
                sources: order, after: nil, size: 2, isBefore: { $0.0 < $1.0 },
                fetch: { id, _ in Page(items: tagged[id]!.map { ($0.0, $0.1) }) })
            #expect(page.items.map(\.1) == order)
        }
    }

    /// A source with nothing left is not asked again on the next page.
    @Test func aFinishedSourceIsNotAskedAgain() async {
        let short = Source([1], pagedBy: 1), long = Source([2, 3, 4, 5], pagedBy: 1)
        let sources = ["short": short, "long": long]
        let first = await merge(sources, order: ["short", "long"], after: nil, size: 2)
        let asked = short.fetches
        _ = await merge(sources, order: ["short", "long"], after: first.next, size: 2)
        #expect(short.fetches == asked)
    }

    /// A channel added between pages starts from its beginning.
    @Test func aSourceAddedBetweenPagesStartsFromTheBeginning() async {
        let sources = ["a": Source([1, 3, 5], pagedBy: 1), "b": Source([2, 4], pagedBy: 1)]
        let first = await merge(sources, order: ["a"], after: nil, size: 1)
        let second = await merge(sources, order: ["a", "b"], after: first.next, size: 3)
        #expect(first.items == [1])
        #expect(second.items == [2, 3, 4])
    }

    /// The same source twice — something placed twice by a hand-edited file —
    /// is read once.
    @Test func aSourceNamedTwiceIsReadOnce() async {
        let sources = ["a": Source([1, 2], pagedBy: 1)]
        let page = await merge(sources, order: ["a", "a"], after: nil, size: 5)
        #expect(page.items == [1, 2])
        #expect(page.next == nil)
    }

    @Test func nothingToMergeIsAnEmptyLastPage() async {
        let page = await merge([:], order: [], after: nil, size: 3)
        #expect(page.items.isEmpty && page.next == nil)
    }
}

// MARK: - An aggregator, end to end

/// Channels, each listing its videos newest first, a page of two at a time.
/// A video's label is its age, so a smaller number is newer.
private struct ChannelProvider: NodeProvider {
    let schemes: Set<String> = ["ch"]
    static let videos: [String: [Int]] = ["ch://a": [1, 4, 6], "ch://b": [2, 3, 7], "ch://c": [0, 5]]

    func resolve(_ uri: String) -> NodeID? { NodeID(uri) }
    func node(for id: NodeID) async -> Node? {
        Node(id: id, type: id.uri.hasPrefix("ch://") && !id.uri.contains("/v") ? "channel" : "video",
             hasChildren: true)
    }
    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        let all = Self.videos[id.uri] ?? []
        let start = cursor.flatMap { Int($0.token) } ?? 0
        let end = min(start + 2, all.count)
        return Page(items: all[start..<end].map { Node(id: NodeID("\(id.uri)/v\($0)")!, type: "video", label: String($0)) },
                    next: end < all.count ? Cursor(String(end)) : nil)
    }
}

/// An aggregator that takes channels, and is also its feed.
private struct AggregatorProvider: NodeProvider {
    let schemes: Set<String> = ["agg", "feed"]
    let broker: NodeBroker

    func resolve(_ uri: String) -> NodeID? { NodeID(uri) }
    func node(for id: NodeID) async -> Node? {
        if id.uri.hasPrefix("feed://") {
            return Node(id: id, type: "feed", hasChildren: true, childStyle: .contents)
        }
        return Node(id: id, type: "aggregator", accepts: .types(["channel"]),
                    identities: [NodeID("feed://" + id.uri.dropFirst("agg://".count))!])
    }
    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        guard id.uri.hasPrefix("feed://") else { return Page(items: []) }
        let channels = await broker.placedChildren(of: "agg://" + id.uri.dropFirst("feed://".count))
        return await FeedMerge.page(sources: channels, after: cursor, size: 3,
                                    isBefore: { Int($0.label)! < Int($1.label)! },
                                    fetch: { await broker.children(of: $0, page: $1) })
    }
}

@MainActor
@Suite struct AggregatorFeedTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(condition())
    }

    private func makeModel() throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("feed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(), workspaceFile: dir.appendingPathComponent("workspaces.json"))
        let registry = model.pluginHost.registry
        registry.register(provider: ChannelProvider())
        registry.register(provider: AggregatorProvider(broker: registry.hostBroker))
        model.start()
        // Under test no plugins are loaded, which is what would install these.
        registry.hostBroker.install(registry.providers)
        return model
    }

    private func labels(_ model: AppModel, _ id: NodeID) -> [String]? {
        model.host.cachedChildren(of: id)?.compactMap { model.host.node($0)?.label }
    }

    /// The aggregator is its channels where it sits, and its feed in the
    /// column: every channel's videos, newest first, a page at a time — and a
    /// channel placed in it shows up in the feed.
    @Test func anAggregatorsFeedIsItsChannelsMerged() async throws {
        let model = try makeModel()
        let aggregator = NodeID("agg://watch")!, feed = NodeID("feed://watch")!
        model.workspaceStore.place(["ch://a", "ch://b"], into: aggregator.uri, at: nil)
        model.store?.ensureNodes([aggregator])
        try await waitUntil { model.host.node(feed) != nil }

        model.host.select([aggregator])
        #expect(model.contentsContainer == feed, "the column is not showing the feed")

        model.store?.requestChildren(of: feed)
        try await waitUntil { labels(model, feed) == ["1", "2", "3"] }
        model.store?.requestMoreChildren(of: feed)
        try await waitUntil { labels(model, feed) == ["1", "2", "3", "4", "6", "7"] }
        #expect(!model.host.hasMoreChildren(feed))

        model.workspaceStore.place(["ch://c"], into: aggregator.uri, at: nil)
        try await waitUntil { labels(model, feed) == ["0", "1", "2"] }
    }

    /// Only a declared contents identity takes the column — a node whose other
    /// identity is merely a place is not asking for one.
    @Test func anIdentityThatIsAPlaceDoesNotTakeTheColumn() throws {
        let model = try makeModel()
        let node = NodeID("stub://project")!, dir = NodeID("stub://dir")!
        model.host._ingest(Node(id: node, type: "project", identities: [dir]))
        model.host._ingest(Node(id: dir, type: "dir", hasChildren: true))
        // Large enough to page, which on its own would make it contents.
        model.host._setChildCursor(Cursor("2"), of: dir)
        #expect(model.host.childStyle(of: dir) == .contents)
        model.host.select([node])
        #expect(model.contentsContainer == nil)
    }
}
