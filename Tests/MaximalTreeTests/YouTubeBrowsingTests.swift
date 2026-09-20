import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// What the plugin keeps between runs: titles, thumbnails, and what you looked
/// for. Nothing of this goes to YouTube — it is so that what you saved is
/// still a title when you are offline.
@Suite struct YouTubeStoreTests {
    private func temporary() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yt-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func video(_ id: String, _ title: String) -> VideoItem {
        VideoItem(id: id, title: title, views: "2 views", age: "a day ago")
    }

    @Test func whatAListingSaidSurvivesARestart() throws {
        let dir = try temporary()
        let store = YouTubeStore(directory: dir)
        store.remember(videos: [video("v1", "A video")], line: YouTubeProvider.line(of:))
        store.remember(playlists: [PlaylistItem(id: "PL1", title: "A playlist", line: "9 lessons")])

        let reopened = YouTubeStore(directory: dir)
        #expect(reopened.video("v1")?.title == "A video")
        #expect(reopened.video("v1")?.line == "2 views · a day ago")
        #expect(reopened.playlist("PL1")?.title == "A playlist")
    }

    /// A thumbnail is kept as a file, and read back without fetching.
    @Test func aThumbnailIsKeptAndReadBack() throws {
        let dir = try temporary()
        let store = YouTubeStore(directory: dir)
        #expect(store.icon(for: "v1") == nil)
        store.store(icon: Data([0xFF, 0xD8, 0xFF]), for: "v1")
        #expect(store.icon(for: "v1") == Data([0xFF, 0xD8, 0xFF]))
        #expect(YouTubeStore(directory: dir).icon(for: "v1") == Data([0xFF, 0xD8, 0xFF]))
    }

    /// An id is YouTube's, but a file name is ours to be careful with.
    @Test func anIdThatIsNotOneIsNotWrittenToDisk() throws {
        let dir = try temporary()
        let store = YouTubeStore(directory: dir)
        store.store(icon: Data([1]), for: "../../etc/passwd")
        #expect(store.icon(for: "../../etc/passwd") == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .allSatisfy { !$0.contains("passwd") })
    }

    /// The oldest go first, so a year of browsing is not a year of titles.
    @Test func theStoreIsBounded() throws {
        let store = YouTubeStore(directory: try temporary(), videoLimit: 5)
        for i in 0...5 { store.remember(videos: [video("v\(i)", "Video \(i)")], line: { _ in nil }) }

        #expect(store.video("v0") == nil, "the oldest survived a full store")
        #expect(store.video("v5")?.title == "Video 5")
        #expect(store.video("v3")?.title == "Video 3")
    }

    /// Searches are the ones you made, newest first, each once.
    @Test func recentSearchesAreNewestFirstAndEachOnce() throws {
        let store = YouTubeStore(directory: try temporary())
        store.remember(search: "swift")
        store.remember(search: "typst")
        store.remember(search: "  Swift ")
        #expect(store.recentSearches() == ["Swift", "typst"])

        for i in 0..<YouTubeStore.searchLimit { store.remember(search: "query \(i)") }
        #expect(store.recentSearches().count == YouTubeStore.searchLimit)
        store.forgetSearches()
        #expect(store.recentSearches().isEmpty)
    }

    /// And none of it is the reader's own directory while the tests run.
    @Test func theStoreStaysOutOfTheRealLibraryUnderTest() {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        #expect(YouTubeStorage.directory().resolvingSymlinksInPath().path.hasPrefix(temporary))
    }
}

/// Searching, and what a playlist holds.
@Suite struct YouTubeBrowsingTests {
    /// A search: a video, then a playlist, in that order.
    private let searchReply = """
    {"contents":{"itemSectionRenderer":{"contents":[
      {"lockupViewModel":{"contentId":"PL1","contentType":"LOCKUP_CONTENT_TYPE_PLAYLIST",
        "metadata":{"lockupMetadataViewModel":{"title":{"content":"A playlist"},
          "metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[
            {"text":{"content":"A Channel"}}]}]}}}},
        "contentImage":{"collectionThumbnailViewModel":{"primaryThumbnail":{"thumbnailViewModel":
          {"image":{"sources":[{"url":"https://i.ytimg.com/vi/vid9/hq720.jpg","width":360}]}}}}}}},
      {"videoRenderer":{"videoId":"vid1","title":{"runs":[{"text":"A video"}]},
        "shortViewCountText":{"simpleText":"12K views"}}}
    ]}}}
    """

    /// A playlist's own page: its title, and what it holds.
    private let playlistReply = """
    {"metadata":{"playlistMetadataRenderer":{"title":"Everything about Swift"}},
     "contents":{"richGridRenderer":{"contents":[
       {"lockupViewModel":{"contentId":"lesson1","contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
         "metadata":{"lockupMetadataViewModel":{"title":{"content":"Lesson one"}}}}}]}}}
    """

    private final class Fake: @unchecked Sendable {
        var reply = ""
        private(set) var fetched: [String] = []
        let lock = NSLock()

        var transport: InnerTube.Transport { { _ in Data(self.reply.utf8) } }
        /// Thumbnails and feeds, and a record of what was asked for.
        var fetch: YouTubeProvider.Fetch {
            { url in
                self.lock.withLock { self.fetched.append(url.absoluteString) }
                return Data([0xFF, 0xD8, 0xFF])
            }
        }
    }

    private func provider(_ fake: Fake, store: YouTubeStore) -> YouTubeProvider {
        YouTubeProvider(broker: NoBroker(), innerTube: InnerTube(transport: fake.transport),
                        store: store, fetch: fake.fetch)
    }

    private func temporaryStore() throws -> YouTubeStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yt-browse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return YouTubeStore(directory: dir)
    }

    /// A search is a place: it lists what YouTube answered, in that order,
    /// videos and playlists alike.
    @Test func aSearchListsWhatItFound() async throws {
        let fake = Fake()
        fake.reply = searchReply
        let store = try temporaryStore()
        let provider = provider(fake, store: store)
        let search = YouTubeRef.search("swift concurrency").nodeID

        let node = try #require(await provider.node(for: search))
        #expect(node.label == "swift concurrency")
        #expect(node.childStyle == .contents)

        let page = await provider.children(of: search, page: nil)
        #expect(page.items.map(\.id.uri) == [YouTubeRef.playlist("PL1").uri,
                                             YouTubeRef.video("vid1").uri],
                "YouTube's order was rearranged")
        #expect(page.items.first?.label == "A playlist")
        #expect(page.items.first?.subtitle == "A Channel")
    }

    /// A query is not a name: slashes, ampersands and spaces all read back.
    @Test func anyQueryIsAUriThatReadsBack() throws {
        for query in ["swift concurrency", "a/b & c?", "日本語", "100% swift"] {
            let ref = YouTubeRef.search(query)
            #expect(YouTubeRef(uri: ref.uri) == ref)
            #expect(NodeID(ref.uri)?.uri == ref.uri, "not canonical")
        }
    }

    /// A playlist lists what it holds, and is called what it is called — kept,
    /// so its row says so before anything is listed next time.
    @Test func aPlaylistListsWhatItHolds() async throws {
        let fake = Fake()
        fake.reply = playlistReply
        let store = try temporaryStore()
        let provider = provider(fake, store: store)
        let playlist = YouTubeRef.playlist("PL1").nodeID

        let page = await provider.children(of: playlist, page: nil)
        #expect(page.items.map(\.label) == ["Lesson one"])
        #expect(store.playlist("PL1")?.title == "Everything about Swift")
        #expect(await provider.node(for: playlist)?.label == "Everything about Swift")
    }

    /// A page arrives with its thumbnails, fetched once and kept — a row does
    /// not acquire its picture a beat later, and never twice.
    @Test func aPageArrivesWithItsThumbnails() async throws {
        let fake = Fake()
        fake.reply = playlistReply
        let store = try temporaryStore()
        let provider = provider(fake, store: store)

        let page = await provider.children(of: YouTubeRef.playlist("PL1").nodeID, page: nil)
        #expect(page.items.first?.icon?.imageData == Data([0xFF, 0xD8, 0xFF]))
        #expect(fake.fetched == ["https://i.ytimg.com/vi/lesson1/default.jpg"])

        _ = await provider.children(of: YouTubeRef.playlist("PL1").nodeID, page: nil)
        #expect(fake.fetched.count == 1, "a thumbnail already kept was fetched again")
    }

    /// A video put in a collection keeps its title and its picture when
    /// nothing has listed it this run — which is the whole point of keeping
    /// them.
    @Test func aSavedVideoIsStillATitleOffline() async throws {
        let store = try temporaryStore()
        do {
            let fake = Fake()
            fake.reply = playlistReply
            _ = await provider(fake, store: store).children(of: YouTubeRef.playlist("PL1").nodeID, page: nil)
        }
        // A new run, with nothing listed and nothing reachable.
        let offline = YouTubeProvider(broker: NoBroker(), innerTube: .offline, store: store,
                                      fetch: { _ in throw URLError(.notConnectedToInternet) })
        let node = try #require(await offline.node(for: YouTubeRef.video("lesson1").nodeID))
        #expect(node.label == "Lesson one")
        #expect(node.icon?.imageData == Data([0xFF, 0xD8, 0xFF]))
    }

    /// The finder offers the searches you made, so one you return to is not
    /// retyped.
    @MainActor
    @Test func theFinderOffersTheSearchesYouMade() async throws {
        YouTubeStore.shared.remember(search: "typst tutorial")
        defer { YouTubeStore.shared.forgetSearches() }
        let registry = Registry()
        YouTubePlugin().register(with: registry)

        let source = try #require(registry.finders.first { $0.id == "youtube.searches" })
        let items = await source.items()
        #expect(items.map(\.title).contains("typst tutorial"))
        guard case .open(let uri)? = items.first(where: { $0.title == "typst tutorial" })?.effect else {
            Issue.record("expected the search to open"); return
        }
        #expect(YouTubeRef(uri: uri) == .search("typst tutorial"))
    }
}

private struct NoBroker: NodeBroker {
    func node(for uri: String) async -> Node? { nil }
    func children(of uri: String, page: Cursor?) async -> Page<Node> { Page(items: []) }
    func placedChildren(of uri: String) async -> [String] { [] }
}
