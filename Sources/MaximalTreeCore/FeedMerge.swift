import Foundation

/// Several paged sources, each already in order, merged into one paged listing
/// in that order — an aggregator's feed of its channels' videos.
///
/// The order is the caller's: a date-ordered merge is one plugin's idea of a
/// feed, so the host never merges anything itself. What this does is the part
/// that is easy to get wrong. Each source pages on its own, so an item is only
/// given out once every source that could still hold something earlier has
/// shown far enough to prove it does not. A source's next page is fetched when
/// its buffer runs out, before it is compared, never after.
///
/// The cursor records, per source, the page it was reading and how far into
/// it — not the items, which a cursor cannot carry. Resuming fetches that page
/// again, so a source's pages have to be the same when asked twice. A source
/// that was not there when the cursor was made starts from its beginning.
public enum FeedMerge {
    /// The page of the merged feed after `cursor`: at most `size` items.
    ///
    /// - Parameters:
    ///   - sources: an id for each source, in the order ties are broken by.
    ///   - isBefore: whether the first item comes before the second.
    ///   - fetch: a page of one source, after its own cursor.
    public static func page<Item: Sendable>(
        sources: [String],
        after cursor: Cursor?,
        size: Int,
        isBefore: (Item, Item) -> Bool,
        fetch: (String, Cursor?) async -> Page<Item>
    ) async -> Page<Item> {
        let resumed = cursor.flatMap(State.init(cursor:))?.positions ?? [:]
        var readers: [Reader<Item>] = []
        var seen: Set<String> = []
        for source in sources where seen.insert(source).inserted {
            let position = resumed[source] ?? Position(page: nil, offset: 0, done: false)
            var reader = Reader<Item>(source: source, position: position)
            if !position.done {
                let page = await fetch(source, position.page)
                reader.items = page.items
                reader.next = page.next
                await reader.refill(fetch)
            }
            readers.append(reader)
        }

        var items: [Item] = []
        while items.count < max(size, 0) {
            // The earliest head; on a tie, the source listed first.
            var earliest: Int?
            for i in readers.indices where !readers[i].position.done {
                guard let current = earliest else { earliest = i; continue }
                if isBefore(readers[i].head, readers[current].head) { earliest = i }
            }
            guard let i = earliest else { break }
            items.append(readers[i].head)
            readers[i].position.offset += 1
            await readers[i].refill(fetch)
        }

        guard readers.contains(where: { !$0.position.done }) else { return Page(items: items) }
        let state = State(positions: Dictionary(uniqueKeysWithValues: readers.map { ($0.source, $0.position) }))
        return Page(items: items, next: state.cursor)
    }

    /// Where one source is: the cursor of the page being read (nil for its
    /// first), how many of that page's items were given out, and whether there
    /// is nothing left.
    struct Position: Codable, Equatable {
        var page: Cursor?
        var offset: Int
        var done: Bool
    }

    private struct Reader<Item: Sendable> {
        let source: String
        var position: Position
        var items: [Item] = []
        var next: Cursor?

        var head: Item { items[position.offset] }

        /// Move on to the next page while this one is used up, so the head is
        /// always a real item — or the source is done.
        mutating func refill(_ fetch: (String, Cursor?) async -> Page<Item>) async {
            while !position.done && position.offset >= items.count {
                guard let cursor = next else { position.done = true; return }
                let page = await fetch(source, cursor)
                position = Position(page: cursor, offset: 0, done: false)
                items = page.items
                next = page.next
            }
        }
    }

    struct State: Codable, Equatable {
        var positions: [String: Position]

        init(positions: [String: Position]) { self.positions = positions }

        init?(cursor: Cursor) {
            guard let data = cursor.token.data(using: .utf8),
                  let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
            self = state
        }

        var cursor: Cursor {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = (try? encoder.encode(self)) ?? Data()
            return Cursor(String(decoding: data, as: UTF8.self))
        }
    }
}
