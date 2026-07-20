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
