import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

@Suite struct WebProviderTests {
    @Test func addressInputNormalizesLikeABrowser() {
        #expect(WebProvider.normalize("https://example.com/x") == "https://example.com/x")
        #expect(WebProvider.normalize("example.com") == "https://example.com")
        #expect(WebProvider.normalize("  example.com  ") == "https://example.com")
        #expect(WebProvider.normalize("swift result builders")
            .hasPrefix("https://duckduckgo.com/?q="))
    }

    @Test func labelsAreHostsWithoutWWW() throws {
        #expect(WebProvider.label(for: try #require(URL(string: "https://www.example.com/a/b")))
                == "example.com")
        #expect(WebProvider.label(for: try #require(URL(string: "https://news.site.org")))
                == "news.site.org")
    }

    @Test func resolveOwnsPagesAndBookmarksOnly() {
        let provider = WebProvider()
        #expect(provider.resolve("https://example.com")?.uri == "https://example.com")
        #expect(provider.resolve("example.com")?.uri == "https://example.com")
        #expect(provider.resolve("web://bookmarks") == WebProvider.bookmarksID)
        #expect(provider.resolve("ftp://example.com") == nil)
    }

    @Test func bookmarksRootServesStoreEntriesAsPageNodes() async throws {
        // The shared store backs the provider; use a unique URL to avoid clashes.
        let url = "https://test-\(UUID().uuidString).example.com"
        BookmarkStore.shared.add(url: url, title: "Test Page")
        defer { BookmarkStore.shared.remove(url: url) }

        let page = await WebProvider().children(of: WebProvider.bookmarksID, page: nil)
        let node = try #require(page.items.first { $0.id.uri == url })
        #expect(node.type == TypeID("web.page"))
        #expect(node.label == "Test Page")
        // The second line the retired bookmarks canvas drew, now in the
        // listing where any row can draw it.
        #expect(node.subtitle == url)
    }

    /// Bookmarks are somewhere you go into, so the column lists them and the
    /// pane shows whichever one you land on.
    ///
    /// Said outright rather than left to the paging inference: they are held
    /// in memory and served in one page, so no cursor would ever say it.
    @Test func theBookmarksRootIsContents() async throws {
        let node = try #require(await WebProvider().node(for: WebProvider.bookmarksID))
        #expect(node.childStyle == .contents)
    }

    /// The bespoke list had a button to remove one. The action it was calling
    /// applies to whatever is targeted, and the column targets its highlighted
    /// row — so retiring the list keeps the affordance and gains it a place in
    /// the palette, the menus, and a binding.
    @MainActor
    @Test func removingABookmarkIsAnActionOnTheRow() throws {
        let url = "https://test-\(UUID().uuidString).example.com"
        BookmarkStore.shared.add(url: url, title: "Test Page")
        defer { BookmarkStore.shared.remove(url: url) }

        let registry = Registry()
        WebPlugin().register(with: registry)
        let action = try #require(registry.actions.first { $0.id == "web.unbookmark" })
        let host = HostContext()
        let target = try #require(NodeID(url))
        #expect(action.appliesTo.matches(ActionContext(host: host, targets: [target])))
    }
}

@Suite struct BookmarkStoreTests {
    private func tempStore() -> BookmarkStore {
        BookmarkStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bookmarks-\(UUID().uuidString).json"))
    }

    @Test func addIsIdempotentPerURLAndRetitles() {
        let store = tempStore()
        store.add(url: "https://a.example", title: "First")
        store.add(url: "https://a.example", title: "Renamed")
        #expect(store.all().count == 1)
        #expect(store.all().first?.title == "Renamed")
    }

    @Test func urlsCanonicalizeBeforeComparison() {
        let store = tempStore()
        store.add(url: "HTTPS://a.example/path/", title: "T")
        #expect(store.contains("https://a.example/path"))
        store.remove(url: "https://a.example/path/")
        #expect(store.all().isEmpty)
    }

    @Test func newestBookmarksComeFirstAndPersist() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bookmarks-\(UUID().uuidString).json")
        let store = BookmarkStore(fileURL: file)
        store.add(url: "https://old.example", title: "Old")
        store.add(url: "https://new.example", title: "New")
        #expect(store.all().map(\.title) == ["New", "Old"])

        // A fresh store over the same file sees the same data.
        let reloaded = BookmarkStore(fileURL: file)
        #expect(reloaded.all().map(\.title) == ["New", "Old"])
    }
}
