import Foundation
import MaximalTreeKit

// The web plugin's view-free core: the provider (pages + the bookmarks tree)
// and the persisted bookmark store. No WebKit here — this file is what the
// test target compiles.

// MARK: - Where the plugin keeps things

/// The directory the plugin's stores live in — and, under the test runner,
/// somewhere else.
///
/// The tests run inside the app, so the defaults are the reader's own files: a
/// test that bookmarked a page rewrote the real bookmarks, and one that cached
/// an icon wrote into the real icons. Nothing a test asserts depends on that
/// data, and none of it should ever touch it. The same bargain `AppModel`
/// strikes for the workspace library.
enum WebStorage {
    static func directory() -> URL {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("maximaltree-web-test-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaximalTree", isDirectory: true)
    }
}

// MARK: - Favicons

/// Favicons that outlive the session that fetched them.
///
/// A site's icon used to live only in the in-memory node record, written by
/// the open page's canvas — so it was right while you browsed and gone the
/// moment the app restarted, leaving every page and bookmark back on the
/// default globe. Icons belong to the *site*, not to a run of the app, so
/// they're cached on disk by host and served by the provider.
///
/// One small file per host rather than a single blob: fetches land at
/// unpredictable times from different pages, and independent writes can't
/// clobber each other.
final class FaviconStore: @unchecked Sendable {
    /// Replaceable so tests can point it at a temporary directory instead of
    /// the real Application Support one.
    nonisolated(unsafe) static var shared = FaviconStore()

    private let lock = NSLock()
    let directory: URL
    /// Hosts already read from (or written to) disk this run, so the sidebar
    /// isn't doing file I/O for every row it draws. `nil` records a host with
    /// no icon, which is just as worth remembering.
    private var cache: [String: Data?] = [:]

    init(directory: URL? = nil) {
        self.directory = directory
            ?? WebStorage.directory().appendingPathComponent("web-favicons", isDirectory: true)
    }

    /// The cached icon for `host`, or nil when we've never got one. Never
    /// fetches: this is called while drawing rows.
    func icon(for host: String) -> Data? {
        guard let key = Self.key(for: host) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[key] { return known }
        let data = try? Data(contentsOf: directory.appendingPathComponent(key))
        cache[key] = data
        return data
    }

    /// The cached icon for a page URL, by its host.
    func icon(for url: URL) -> Data? {
        guard let host = url.host else { return nil }
        return icon(for: host)
    }

    func store(_ data: Data, for host: String) {
        guard let key = Self.key(for: host), !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        cache[key] = data
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(key), options: .atomic)
    }

    /// A host as a file name. Hosts can't contain `/`, but they can be empty,
    /// absurdly long, or (with punycode and IPv6 literals) contain characters
    /// worth not trusting a file system with.
    static func key(for host: String) -> String? {
        let lowered = host.lowercased()
        guard !lowered.isEmpty, lowered.count <= 255 else { return nil }
        let safe = lowered.map { character -> Character in
            character.isLetter || character.isNumber || character == "." || character == "-"
                ? character : "_"
        }
        return String(safe)
    }
}

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
                        hasChildren: !BookmarkStore.shared.all().isEmpty,
                        // Somewhere you go into, not a branch of the tree.
                        // Said outright rather than left to the paging
                        // inference: bookmarks are held in memory and served
                        // in one page, so no cursor would ever say it, and a
                        // list of saved pages is a list however short it is.
                        childStyle: .contents)
        }
        guard let url = URL(string: id.uri) else { return nil }
        // What the page says it is, while it is open. The live session is the
        // truth about a page's title, and this is where that truth is read —
        // a canvas showing the page reports that the record changed, rather
        // than telling the graph what to store. So the sidebar, the tab and
        // the subtitle all get the same answer, whether or not the canvas
        // that noticed is on screen.
        let live = await MainActor.run { WebSessionStore.shared.existingSession(for: id)?.title }
        let label = live.flatMap { $0.isEmpty ? nil : $0 } ?? WebProvider.label(for: url)
        return Node(id: id, type: TypeID("web.page"), label: label,
                    icon: WebProvider.icon(for: url))
    }

    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        guard id == Self.bookmarksID else { return Page(items: []) }
        return Page(items: BookmarkStore.shared.all().compactMap { bookmark in
            guard let pageID = NodeID(bookmark.url) else { return nil }
            return Node(id: pageID, type: TypeID("web.page"),
                        label: bookmark.title,
                        icon: URL(string: bookmark.url).map(WebProvider.icon(for:))
                            ?? NodeIcon("globe", tint: .blue),
                        // What the bespoke list drew on its second line, now
                        // said in the listing so any row can draw it. Cheap:
                        // it is the id, which the row already has.
                        subtitle: bookmark.url)
        })
    }

    /// A page's icon: its site's favicon once we have one, the globe until
    /// then. The globe stays as the symbol either way, so a favicon that fails
    /// to decode falls back to it rather than to nothing.
    static func icon(for url: URL) -> NodeIcon {
        NodeIcon("globe", tint: .blue, imageData: FaviconStore.shared.icon(for: url))
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
    /// Replaceable so tests can point it at a temporary file rather than the
    /// real one — the provider reads this, so driving it any other way tests
    /// the test instead of the code.
    nonisolated(unsafe) static var shared = BookmarkStore()

    private let lock = NSLock()
    private var bookmarks: [Bookmark]
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? WebStorage.directory().appendingPathComponent("web-bookmarks.json")
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
