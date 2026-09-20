import Testing
import Foundation
@_spi(Host) @testable import MaximalTreeKit
@testable import MaximalTree

/// A channel's feed in the shape YouTube writes it, with invented videos.
func feedXML(_ channelID: String, title: String, videos: [(id: String, title: String, published: String)]) -> Data {
    let entries = videos.map { video in
        """
         <entry>
          <id>yt:video:\(video.id)</id>
          <yt:videoId>\(video.id)</yt:videoId>
          <yt:channelId>\(channelID)</yt:channelId>
          <title>\(video.title)</title>
          <link rel="alternate" href="https://www.youtube.com/watch?v=\(video.id)"/>
          <published>\(video.published)</published>
          <media:group>
           <media:title>\(video.title)</media:title>
           <media:thumbnail url="https://i4.ytimg.com/vi/\(video.id)/hqdefault.jpg" width="480" height="360"/>
           <media:description>Something about \(video.title) &amp; more</media:description>
          </media:group>
         </entry>
        """
    }.joined(separator: "\n")
    return Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
     <id>yt:channel:\(channelID.dropFirst(2))</id>
     <yt:channelId>\(channelID.dropFirst(2))</yt:channelId>
     <title>\(title)</title>
     <link rel="alternate" href="https://www.youtube.com/channel/\(channelID)"/>
     <published>2007-08-23T00:34:43+00:00</published>
    \(entries)
    </feed>
    """.utf8)
}

private let alpha = "UCaaaaaaaaaaaaaaaaaaaaaa", beta = "UCbbbbbbbbbbbbbbbbbbbbbb"

@Suite struct YouTubeFeedTests {
    @Test func aChannelsFeedReads() throws {
        let data = feedXML(alpha, title: "Alpha &amp; Co", videos: [
            ("old1", "Older", "2026-09-01T10:00:00+00:00"),
            ("new1", "Newer", "2026-09-10T10:00:00+00:00"),
        ])
        let feed = try #require(ChannelFeed.parse(data))
        #expect(feed.channelID == alpha, "the feed's own id was read without its UC")
        #expect(feed.title == "Alpha & Co")
        #expect(feed.videos.map(\.id) == ["new1", "old1"], "newest first")
        #expect(feed.videos.first?.title == "Newer", "an entry's title was taken from somewhere else")
        #expect(feed.videos.first?.thumbnail?.absoluteString == "https://i4.ytimg.com/vi/new1/hqdefault.jpg")
    }

    @Test func whatIsNotAFeedIsNothing() {
        #expect(ChannelFeed.parse(Data("<html>not found</html>".utf8)) == nil)
    }

    // MARK: Naming a channel

    @Test func aChannelIsNamedByIdLinkOrHandle() {
        #expect(ChannelInput(alpha) == .id(alpha))
        #expect(ChannelInput("https://www.youtube.com/channel/\(alpha)/videos") == .id(alpha))
        #expect(ChannelInput("youtube.com/channel/\(alpha)") == .id(alpha))
        #expect(ChannelInput("@someone") == .page(URL(string: "https://www.youtube.com/@someone")!))
        #expect(ChannelInput("https://www.youtube.com/@someone") == .page(URL(string: "https://www.youtube.com/@someone")!))
        #expect(ChannelInput("https://example.com/@someone") == nil, "not YouTube")
        #expect(ChannelInput("  ") == nil)
    }

    @Test func aChannelsPageSaysWhichChannelItIs() {
        let page = #"<html><head><link rel="canonical" href="https://www.youtube.com/channel/\#(beta)"></head>"#
        #expect(ChannelInput.channelID(inPage: page) == beta)
        #expect(ChannelInput.channelID(inPage: #"{"externalId":"\#(alpha)","x":1}"#) == alpha)
        #expect(ChannelInput.channelID(inPage: "<html></html>") == nil)
    }

    // MARK: URIs

    @Test func everyURIReadsBack() {
        let id = UUID()
        for ref in [YouTubeRef.channel(alpha), .video("abc_-1"), .aggregator(id), .feed(id)] {
            #expect(YouTubeRef(uri: ref.uri) == ref)
            #expect(NodeID(ref.uri)?.uri == ref.uri, "not canonical")
        }
        #expect(YouTubeRef(uri: "youtube://aggregator/not-a-uuid") == nil)
        // A name an older build wrote is dropped, which is what heals a
        // library that has one filed under it.
        #expect(YouTubeRef(uri: "youtube://aggregator/\(id.uuidString.lowercased())?name=Old")
                == .aggregator(id))
        #expect(YouTubeRef(uri: "youtube://shorts/x") == nil, "a kind it does not know")
    }
}

/// Answers from fixtures, counting what was asked.
private final class FakeYouTube: @unchecked Sendable {
    var feeds: [String: Data] = [:]
    var pages: [String: String] = [:]
    var failing = false
    private(set) var asked: [String] = []

    func fetch(_ url: URL) throws -> Data {
        asked.append(url.absoluteString)
        if failing { throw URLError(.notConnectedToInternet) }
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "channel_id" })?.value, let feed = feeds[id] {
            return feed
        }
        if let page = pages[url.absoluteString] { return Data(page.utf8) }
        throw URLError(.fileDoesNotExist)
    }
}

private struct FixedBroker: NodeBroker {
    let placed: [String: [String]]
    func node(for uri: String) async -> Node? { nil }
    func children(of uri: String, page: Cursor?) async -> Page<Node> { Page(items: []) }
    func placedChildren(of uri: String) async -> [String] { placed[uri] ?? [] }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@Suite struct YouTubeProviderTests {
    private let fake: FakeYouTube = {
        let fake = FakeYouTube()
        fake.feeds[alpha] = feedXML(alpha, title: "Alpha", videos: [
            ("a1", "A one", "2026-09-01T10:00:00+00:00"), ("a2", "A two", "2026-09-05T10:00:00+00:00"),
        ])
        fake.feeds[beta] = feedXML(beta, title: "Beta", videos: [
            ("b1", "B one", "2026-09-03T10:00:00+00:00"), ("b2", "B two", "2026-09-07T10:00:00+00:00"),
        ])
        return fake
    }()

    private func temporaryYouTubeStore() throws -> YouTubeStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return YouTubeStore(directory: dir)
    }

    private func provider(placed: [String: [String]] = [:], clock: Clock = Clock()) -> YouTubeProvider {
        let fake = fake
        return YouTubeProvider(broker: FixedBroker(placed: placed), innerTube: .offline,
                               freshFor: 60, now: { clock.now }, fetch: { try fake.fetch($0) })
    }

    /// A channel is its name and its tabs; its videos are the tab it is also,
    /// which is what the column shows when it is selected.
    @Test func aChannelIsItsNameAndItsTabs() async throws {
        let provider = provider()
        let channel = YouTubeRef.channel(alpha).nodeID
        let node = try #require(await provider.node(for: channel))
        #expect(node.label == "Alpha")
        #expect(node.identities == [YouTubeRef.tab(alpha, .videos).nodeID])

        let videos = YouTubeRef.tab(alpha, .videos).nodeID
        #expect(await provider.node(for: videos)?.childStyle == .contents)
        #expect(await provider.children(of: videos, page: nil).items.map(\.label) == ["A two", "A one"])
        // And a video listed there knows what it is afterwards.
        #expect(await provider.node(for: YouTubeRef.video("a1").nodeID)?.label == "A one")
    }

    /// The feed is its aggregator's channels, whichever the host says they are
    /// now, merged newest first.
    @Test func aFeedIsItsChannelsVideosNewestFirst() async throws {
        let id = UUID()
        let aggregator = YouTubeRef.aggregator(id)
        let provider = provider(placed: [aggregator.uri: [YouTubeRef.channel(alpha).uri,
                                                          YouTubeRef.channel(beta).uri,
                                                          "file:///not-a-channel"]])
        let page = await provider.children(of: YouTubeRef.feed(id).nodeID, page: nil)
        #expect(page.items.map(\.label) == ["B two", "A two", "B one", "A one"])
        #expect(page.next == nil)
    }

    /// The aggregator takes channels and is also its feed; the feed goes into
    /// the column.
    @Test func anAggregatorTakesChannelsAndIsItsFeed() async throws {
        let id = UUID()
        let node = try #require(await provider().node(for: YouTubeRef.aggregator(id).nodeID))
        #expect(node.accepts == .types([TypeID("youtube.channel")]))
        #expect(node.identities == [YouTubeRef.feed(id).nodeID])
        let feed = try #require(await provider().node(for: YouTubeRef.feed(id).nodeID))
        #expect(feed.childStyle == .contents)
    }

    /// A feed asked for again soon is not fetched again; later, it is. A fetch
    /// that fails keeps what was there.
    @Test func aFeedIsFetchedOnceWhileFreshAndKeptThroughAFailure() async throws {
        let clock = Clock()
        let provider = provider(clock: clock)
        _ = await provider.feed(of: alpha)
        _ = await provider.feed(of: alpha)
        #expect(fake.asked.count == 1)

        clock.now += 120
        fake.failing = true
        #expect(await provider.feed(of: alpha)?.title == "Alpha", "a failed fetch emptied the feed")
        #expect(fake.asked.count == 2)
    }

    @Test func aHandleIsFoundThroughItsPage() async {
        fake.pages["https://www.youtube.com/@beta"] = #"<link rel="canonical" href="https://www.youtube.com/channel/\#(beta)">"#
        let provider = provider()
        #expect(await provider.channelID(for: .page(URL(string: "https://www.youtube.com/@beta")!)) == beta)
        #expect(await provider.channelID(for: .page(URL(string: "https://www.youtube.com/@nobody")!)) == nil)
    }

    /// Renaming a feed changes what it is called, not what it is — so what
    /// was placed in it cannot be left behind under the old name.
    @Test func renamingAFeedChangesItsNameAndNotItsIdentity() async throws {
        let id = UUID()
        let feed = YouTubeRef.aggregator(id).nodeID
        let store = try temporaryYouTubeStore()
        let provider = YouTubeProvider(broker: FixedBroker(placed: [:]), innerTube: .offline,
                                       store: store, fetch: { _ in throw URLError(.badURL) })
        #expect(provider.supports(.rename(feed, to: "Watching")))
        #expect(!provider.supports(.rename(YouTubeRef.channel(alpha).nodeID, to: "New")))

        let changes = try await provider.apply(.rename(feed, to: "Watching"))

        #expect(changes == [.modified(feed), .modified(YouTubeRef.feed(id).nodeID)],
                "a rename that changes identity leaves what was placed in it behind")
        #expect(await provider.node(for: feed)?.label == "Watching")
        #expect(await provider.node(for: YouTubeRef.feed(id).nodeID)?.label == "Watching")
        #expect(store.feedName(id) == "Watching", "the name did not outlive the run")
    }
}

/// Through the app: a feed's channels are placed, and the feed follows them.
@MainActor
@Suite struct YouTubeHostTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(condition())
    }

    @Test func placingAChannelInAFeedShowsItsVideos() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("youtube-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(), workspaceFile: dir.appendingPathComponent("workspaces.json"))
        let registry = model.pluginHost.registry
        let fake = FakeYouTube()
        fake.feeds[alpha] = feedXML(alpha, title: "Alpha", videos: [("a1", "A one", "2026-09-01T10:00:00+00:00")])
        registry.register(provider: YouTubeProvider(broker: registry.broker, innerTube: .offline,
                                                    fetch: { try fake.fetch($0) }))
        model.start()
        registry.hostBroker.install(registry.providers)

        let id = UUID()
        let aggregator = YouTubeRef.aggregator(id).nodeID
        let feed = YouTubeRef.feed(id).nodeID
        let channel = YouTubeRef.channel(alpha).nodeID
        model.store?.ensureNodes([aggregator, channel])
        try await waitUntil { model.host.node(aggregator) != nil && model.host.node(channel) != nil }

        // What the Add Channel action and a drop both do.
        #expect(model.host.canApply(.adopt([channel], into: aggregator, at: nil)))
        #expect(!model.host.canApply(.adopt([feed], into: aggregator, at: nil)), "a feed took something not a channel")
        model.host.apply(.adopt([channel], into: aggregator, at: nil))
        try await waitUntil { model.workspaceStore.placedChildren(of: aggregator.uri) == [channel.uri] }

        model.host.select([aggregator])
        try await waitUntil { model.host.node(feed) != nil }
        #expect(model.contentsContainer == feed)
        model.store?.requestChildren(of: feed)
        try await waitUntil { model.host.cachedChildren(of: feed) == [YouTubeRef.video("a1").nodeID] }
    }
}

/// Renaming a feed in the sidebar, as the reader does it.
@MainActor
@Suite struct YouTubeRenameTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(condition())
    }

    /// Renaming a feed cannot lose its channels, because it does not move it:
    /// its URI is its id, and its name is the plugin's to keep.
    @Test func renamingAFeedLeavesEverythingWhereItIs() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("youtube-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(), workspaceFile: dir.appendingPathComponent("workspaces.json"))
        let registry = model.pluginHost.registry
        let fake = FakeYouTube()
        fake.feeds[alpha] = feedXML(alpha, title: "Alpha", videos: [("a1", "A one", "2026-09-01T10:00:00+00:00")])
        registry.register(provider: YouTubeProvider(broker: registry.broker, innerTube: .offline,
                                                    fetch: { try fake.fetch($0) }))
        model.start()
        registry.hostBroker.install(registry.providers)

        let id = UUID()
        let old = YouTubeRef.aggregator(id).nodeID
        // Mounted in the sidebar, holding a channel — what the actions do.
        model.workspaceStore.place([old.uri], into: model.sidebarRoot, at: nil)
        let channel = YouTubeRef.channel(alpha).nodeID
        model.store?.ensureNodes([old, channel])
        try await waitUntil { model.host.node(old) != nil && model.host.node(channel) != nil }
        model.host.apply(.adopt([channel], into: old, at: nil))
        try await waitUntil { !model.workspaceStore.placedChildren(of: old.uri).isEmpty }

        let before = model.placements

        model.host.apply(.rename(old, to: "YouTube"))
        try await waitUntil { model.host.node(old)?.label == "YouTube" }

        #expect(model.placements == before, "a rename rearranged what was placed")
        #expect(model.workspaceStore.placedChildren(of: old.uri) == [YouTubeRef.channel(alpha).uri])
        #expect(model.placements.children(of: model.sidebarRoot) == [old.uri])
    }

    /// A library an older build left split — the sidebar holding it under one
    /// name, its channels filed under another — is made whole when it loads,
    /// because a stored parent is resolved in place like a stored member.
    @Test func aLibrarySplitByAnOldRenameHeals() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("youtube-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("workspaces.json")
        let workspace = UUID(), feed = UUID()
        let root = Placements.root(of: workspace)
        let named = { (name: String) in
            "youtube://aggregator/\(feed.uuidString.lowercased())?name=\(name)"
        }
        try JSONSerialization.data(withJSONObject: [
            "activeID": workspace.uuidString,
            "workspaces": [["id": workspace.uuidString, "name": "Youtube", "revealedNodes": [],
                            "placements": ["children": [
                                root: [named("YouTube%20Feed")],
                                named("YouTube"): ["youtube://channel/\(alpha)"],
                            ]]]],
        ]).write(to: file)

        let model = AppModel(host: HostContext(), workspaceFile: file)
        let registry = model.pluginHost.registry
        registry.register(provider: YouTubeProvider(broker: registry.broker, innerTube: .offline,
                                                    fetch: { _ in throw URLError(.badURL) }))
        model.start()
        try await waitUntil { model.placements.children.count == 2 }

        let bare = YouTubeRef.aggregator(feed).uri
        #expect(model.placements.children(of: model.sidebarRoot) == [bare])
        #expect(model.workspaceStore.placedChildren(of: bare) == ["youtube://channel/\(alpha)"],
                "the channels stayed under a name nothing points at")
    }
}
