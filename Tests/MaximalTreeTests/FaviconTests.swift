import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// A site's icon has to outlive the run that fetched it.
@Suite struct FaviconStoreTests {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-favicons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One-pixel PNG: real image data, small enough to ride in a node record.
    private let icon = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM\
        IQAAAABJRU5ErkJggg==
        """)!

    /// The bug: the icon lived only in memory, so a relaunch went back to the
    /// default globe. A second store over the same directory *is* the relaunch.
    @Test func anIconSurvivesARelaunch() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        FaviconStore(directory: dir).store(icon, for: "example.com")

        #expect(FaviconStore(directory: dir).icon(for: "example.com") == icon)
    }

    @Test func anUnknownHostHasNoIcon() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FaviconStore(directory: dir).icon(for: "never-visited.example") == nil)
    }

    @Test func iconsAreLookedUpByHostNotByPage() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FaviconStore(directory: dir)
        store.store(icon, for: "example.com")

        // A different page on the same site is the same site.
        let deep = try #require(URL(string: "https://example.com/a/b?c=d"))
        #expect(store.icon(for: deep) == icon)
    }

    @Test func hostsAreMatchedCaseInsensitively() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FaviconStore(directory: dir)
        store.store(icon, for: "Example.COM")
        #expect(store.icon(for: "example.com") == icon)
    }

    /// Host names reach the file system here, so they're sanitised first.
    @Test func hostsBecomeSafeFileNames() {
        #expect(FaviconStore.key(for: "example.com") == "example.com")
        #expect(FaviconStore.key(for: "[::1]") == "___1_")
        #expect(FaviconStore.key(for: "..") == "..")
        #expect(FaviconStore.key(for: "") == nil)
        #expect(FaviconStore.key(for: String(repeating: "a", count: 300)) == nil)
    }

    @Test func emptyDataIsNotStored() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FaviconStore(directory: dir)
        store.store(Data(), for: "example.com")
        #expect(store.icon(for: "example.com") == nil)
    }
}

/// What the provider serves once an icon is known — the part that makes a
/// restarted app show real icons with no page open and no network.
@Suite struct WebProviderIconTests {
    private let icon = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM\
        IQAAAABJRU5ErkJggg==
        """)!

    private func withTemporaryStore(_ body: (FaviconStore) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-favicons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = FaviconStore.shared
        FaviconStore.shared = FaviconStore(directory: dir)
        defer {
            FaviconStore.shared = previous
            try? FileManager.default.removeItem(at: dir)
        }
        try await body(FaviconStore.shared)
    }

    @Test func aPageNodeCarriesItsSitesIcon() async throws {
        try await withTemporaryStore { store in
            store.store(icon, for: "example.com")
            let id = try #require(NodeID("https://example.com/page"))
            let node = await WebProvider().node(for: id)
            #expect(node?.icon?.imageData == icon)
        }
    }

    /// Until a site's icon is known, the globe stays — and it stays as the
    /// symbol afterwards too, so an icon that fails to decode falls back to it.
    @Test func anUnknownSiteKeepsTheGlobe() async throws {
        try await withTemporaryStore { _ in
            let id = try #require(NodeID("https://unknown.example/page"))
            let node = await WebProvider().node(for: id)
            #expect(node?.icon?.imageData == nil)
            #expect(node?.icon?.systemName == "globe")
        }
    }

    /// Bookmarks are drawn from the provider's listing, so they gain the icon
    /// of a site visited in an earlier run.
    @Test func bookmarksCarryTheirIconsToo() async throws {
        try await withTemporaryStore { store in
            store.store(icon, for: "example.com")

            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("mt-bookmarks-\(UUID().uuidString).json")
            let previous = BookmarkStore.shared
            BookmarkStore.shared = BookmarkStore(fileURL: file)
            defer {
                BookmarkStore.shared = previous
                try? FileManager.default.removeItem(at: file)
            }
            BookmarkStore.shared.add(url: "https://example.com/page", title: "Example")

            let listing = await WebProvider().children(of: WebProvider.bookmarksID, page: nil)
            #expect(listing.items.map(\.icon?.imageData) == [icon])
        }
    }
}
