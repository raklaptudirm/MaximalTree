import Foundation
import MaximalTreeKit

// The web plugin's view-free core: the provider (pages + the bookmarks tree)
// and the persisted bookmark store. No WebKit here — this file is what the
// test target compiles.

// MARK: - Provider

/// Serves `http(s)` pages as nodes — a page's identity *is* its URL, which
/// already canonicalizes into a `NodeID` — plus the plugin's own small `web://`
/// namespace (today: the bookmarks root, whose children are real page nodes).
/// Pages are leaves: links are followed inside the live view, not modeled.
struct WebProvider: NodeProvider {
    let schemes: Set<String> = ["http", "https", "web"]

    static let bookmarksURI = "web://bookmarks"
    static var bookmarksID: NodeID { NodeID(canonical: bookmarksURI) }

    func resolve(_ uri: String) -> NodeID? {
        if uri == Self.bookmarksURI { return Self.bookmarksID }
        guard let id = NodeID(WebProvider.normalize(uri)),
              id.scheme == "http" || id.scheme == "https" else { return nil }
        return id
    }

    func node(for id: NodeID) async -> Node? {
        if id == Self.bookmarksID {
            return Node(id: id, type: TypeID("web.bookmarks"),
                        label: "Bookmarks",
                        icon: NodeIcon("star.fill", tint: .yellow),
                        hasChildren: !BookmarkStore.shared.all().isEmpty)
        }
        guard let url = URL(string: id.uri) else { return nil }
        return Node(id: id, type: TypeID("web.page"),
                    label: WebProvider.label(for: url),
                    icon: NodeIcon("globe", tint: .blue))
    }

    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        guard id == Self.bookmarksID else { return Page(items: []) }
        return Page(items: BookmarkStore.shared.all().compactMap { bookmark in
            guard let pageID = NodeID(bookmark.url) else { return nil }
            return Node(id: pageID, type: TypeID("web.page"),
                        label: bookmark.title,
                        icon: NodeIcon("globe", tint: .blue))
        })
    }

    /// The start page a fresh browser node opens at.
    static let homepage = "https://duckduckgo.com"

    /// Turn address-bar input into a loadable URL: a bare domain gains `https://`,
    /// anything word-like becomes a DuckDuckGo search — the same forgiveness a
    /// real address bar offers.
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") { return trimmed }
        if trimmed.contains(".") && !trimmed.contains(" ") { return "https://" + trimmed }
        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return "https://duckduckgo.com/?q=\(query)"
    }

    /// A short label for the sidebar/subtitle: the host, dropping a leading `www.`.
    static func label(for url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Bookmarks

struct Bookmark: Codable, Equatable, Sendable {
    let url: String       // canonical NodeID uri
    var title: String
    let added: Date
}

/// Persisted bookmarks, ordered by recency of addition. Thread-safe (providers
/// call from off-main, actions from main); storage is one small JSON file in
/// Application Support.
final class BookmarkStore: @unchecked Sendable {
    static let shared = BookmarkStore()

    private let lock = NSLock()
    private var bookmarks: [Bookmark]
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaximalTree/web-bookmarks.json")
        bookmarks = (try? Data(contentsOf: self.fileURL))
            .flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []
    }

    func all() -> [Bookmark] {
        lock.lock()
        defer { lock.unlock() }
        return bookmarks
    }

    func contains(_ url: String) -> Bool {
        guard let canonical = NodeID(url)?.uri else { return false }
        lock.lock()
        defer { lock.unlock() }
        return bookmarks.contains { $0.url == canonical }
    }

    /// Add (or retitle) a bookmark. Newest first; idempotent per URL.
    func add(url: String, title: String) {
        guard let canonical = NodeID(url)?.uri else { return }
        lock.lock()
        defer { lock.unlock() }
        if let index = bookmarks.firstIndex(where: { $0.url == canonical }) {
            bookmarks[index].title = title
        } else {
            bookmarks.insert(Bookmark(url: canonical, title: title, added: Date()), at: 0)
        }
        persist()
    }

    func remove(url: String) {
        guard let canonical = NodeID(url)?.uri else { return }
        lock.lock()
        defer { lock.unlock() }
        bookmarks.removeAll { $0.url == canonical }
        persist()
    }

    /// Caller must hold `lock`.
    private func persist() {
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
