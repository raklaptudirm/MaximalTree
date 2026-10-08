import Foundation
#if canImport(FoundationXML)
import FoundationXML   // XMLParser, outside Apple's Foundation
#endif
import MaximalTreeKit

// The YouTube plugin's view-free core: what its URIs mean, reading a channel's
// feed, and the provider. No WebKit and no AppKit — this file is what the test
// target compiles.

// MARK: - Identities

/// Everything the plugin names.
///
/// A channel and a video are named by YouTube's own ids. A feed — an aggregator
/// of channels — has nothing on YouTube's side, so it gets an id of its own. It
/// is two things, with two URIs that differ only in what they are: the
/// aggregator, which holds channels, and its feed, which lists their videos.
///
/// Its *name* is not in its URI. A collection can carry its name there because
/// everything that refers to one lives in the table a rename rewrites; an
/// aggregator is referred to from two places — the sidebar that holds it, and
/// the entry holding its channels — and anything that writes one of those
/// while the other is mid-rename splits the two apart, leaving a feed whose
/// channels are filed under a name nothing points at. The name lives in the
/// plugin's store, where renaming it is not a change of identity at all.
enum YouTubeRef: Equatable {
    case channel(String)
    /// One of a channel's tabs: `youtube://channel/<id>?tab=shorts`. A tab of
    /// a channel rather than a thing of its own, which is what it is.
    case tab(String, ChannelTab)
    case video(String)
    case playlist(String)
    /// A search, named by what was searched for — so it can be mounted, kept,
    /// and opened again tomorrow.
    case search(String)
    case aggregator(UUID)
    case feed(UUID)

    static let scheme = "youtube"

    init?(uri: String) {
        guard let components = URLComponents(string: uri), components.scheme == Self.scheme,
              let kind = components.host else { return nil }
        let raw = String(components.percentEncodedPath.drop { $0 == "/" })
        guard !raw.isEmpty else { return nil }
        let id = raw.removingPercentEncoding ?? raw
        if kind == "search" { self = .search(id); return }
        guard !id.contains("/") else { return nil }
        switch kind {
        case "channel":
            if let tab = components.queryItems?.first(where: { $0.name == "tab" })?.value {
                guard let tab = ChannelTab(rawValue: tab) else { return nil }
                self = .tab(id, tab)
            } else {
                self = .channel(id)
            }
        case "video": self = .video(id)
        case "playlist": self = .playlist(id)
        // A `?name=` an older build wrote is dropped, which is what makes
        // resolving one canonical: the host rewrites what it stored to this.
        case "aggregator": guard let uuid = UUID(uuidString: id) else { return nil }; self = .aggregator(uuid)
        case "feed": guard let uuid = UUID(uuidString: id) else { return nil }; self = .feed(uuid)
        default: return nil
        }
    }

    var uri: String {
        switch self {
        case .channel(let id): return "youtube://channel/\(id)"
        case .tab(let id, let tab): return "youtube://channel/\(id)?tab=\(tab.rawValue)"
        case .video(let id): return "youtube://video/\(id)"
        case .playlist(let id): return "youtube://playlist/\(id)"
        case .search(let query): return "youtube://search/" + Self.encoded(query)
        case .aggregator(let id): return "youtube://aggregator/\(id.uuidString.lowercased())"
        case .feed(let id): return "youtube://feed/\(id.uuidString.lowercased())"
        }
    }

    var nodeID: NodeID { NodeID(canonical: uri) }

    /// Encoded strictly, so any name reads back exactly and the URI is already
    /// canonical.
    /// Strictly enough that anything — a query with a slash, an ampersand, a
    /// question mark — reads back exactly as it was typed.
    private static func encoded(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Where it is on YouTube, for what has a page there.
    var webURL: URL? {
        switch self {
        case .channel(let id), .tab(let id, _):
            return URL(string: "https://www.youtube.com/channel/\(id)")
        case .video(let id): return URL(string: "https://www.youtube.com/watch?v=\(id)")
        case .playlist(let id): return URL(string: "https://www.youtube.com/playlist?list=\(id)")
        case .search(let query):
            return URL(string: "https://www.youtube.com/results?search_query=" + Self.encoded(query))
        case .aggregator, .feed: return nil
        }
    }
}

// MARK: - A channel's feed

/// What a channel's public feed says: its name and its latest videos, newest
/// first. No key, no account — and only the most recent fifteen or so.
struct ChannelFeed: Equatable, Sendable {
    struct Video: Equatable, Sendable {
        var id: String
        var title: String
        var published: Date
        var thumbnail: URL?
    }

    var channelID: String
    var title: String
    var videos: [Video]

    static func url(for channelID: String) -> URL? {
        URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)")
    }

    /// Read the Atom a channel's feed is written in. Nil if it is not one.
    static func parse(_ data: Data) -> ChannelFeed? {
        let reader = AtomReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = reader
        guard parser.parse(), let channelID = reader.channelID else { return nil }
        return ChannelFeed(channelID: channelID, title: reader.title,
                           videos: reader.videos.sorted { $0.published > $1.published })
    }
}

private final class AtomReader: NSObject, XMLParserDelegate {
    var channelID: String?
    var title = ""
    var videos: [ChannelFeed.Video] = []

    private var inEntry = false
    private var text = ""
    private var entry = (id: "", title: "", published: Date?.none, thumbnail: URL?.none)
    private let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch element {
        case "entry":
            inEntry = true
            entry = ("", "", nil, nil)
        case "media:thumbnail" where inEntry:
            entry.thumbnail = attributes["url"].flatMap(URL.init(string:))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
                qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (element, inEntry) {
        // The feed's own channel id is written without the "UC" every other
        // spelling of it has — in its links, and in each entry.
        case ("yt:channelId", false): channelID = value.hasPrefix("UC") ? value : "UC" + value
        case ("title", false): title = value
        case ("yt:videoId", true): entry.id = value
        case ("title", true): entry.title = value
        case ("published", true): entry.published = dates.date(from: value)
        case ("entry", true):
            inEntry = false
            if !entry.id.isEmpty, let published = entry.published {
                videos.append(.init(id: entry.id, title: entry.title, published: published,
                                    thumbnail: entry.thumbnail))
            }
        default:
            break
        }
        text = ""
    }
}

// MARK: - Finding a channel

/// What someone typed to name a channel: its id, a link to it, or its handle.
enum ChannelInput: Equatable {
    /// The id is right there.
    case id(String)
    /// A page to read the id from — a handle, or a link that is not by id.
    case page(URL)

    /// Nil for what cannot name a channel at all.
    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let id = Self.channelID(in: text) { self = .id(id); return }
        if text.hasPrefix("@"), !text.contains("/"), !text.contains(" ") {
            guard let url = URL(string: "https://www.youtube.com/\(text)") else { return nil }
            self = .page(url)
            return
        }
        let link = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: link), let host = url.host?.lowercased(),
              host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        self = .page(url)
    }

    /// A channel id written anywhere in `text`: in a link by id, or bare.
    static func channelID(in text: String) -> String? {
        guard let match = text.firstMatch(of: /(?:^|channel\/)(UC[A-Za-z0-9_-]{22})(?:$|[\/?#])/) else {
            return nil
        }
        return String(match.1)
    }

    /// The channel a page belongs to, from its canonical link or the id it
    /// carries in its data.
    static func channelID(inPage html: String) -> String? {
        let patterns: [Regex<(Substring, Substring)>] = [
            /<link rel="canonical" href="https:\/\/www\.youtube\.com\/channel\/(UC[A-Za-z0-9_-]{22})"/,
            /"externalId":"(UC[A-Za-z0-9_-]{22})"/,
            /<meta itemprop="identifier" content="(UC[A-Za-z0-9_-]{22})"/,
        ]
        for pattern in patterns {
            if let match = html.firstMatch(of: pattern) { return String(match.1) }
        }
        return nil
    }
}

// MARK: - The provider

/// Channels, their videos, and feeds made of channels.
///
/// A channel lists its latest videos, as contents. A feed's aggregator holds
/// channels, which the host keeps — dropped in, or added by the action — and
/// its feed lists every one of their videos, newest first. Nothing about which
/// channels a feed has is stored here; it is read from the host each time.
final class YouTubeProvider: NodeProvider, MutatingNodeProvider, @unchecked Sendable {
    typealias Fetch = @Sendable (URL) async throws -> Data

    let schemes: Set<String> = [YouTubeRef.scheme]
    private let broker: NodeBroker
    private let innerTube: InnerTube
    private let fetch: Fetch
    private let freshFor: TimeInterval
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var feeds: [String: (feed: ChannelFeed, fetched: Date)] = [:]
    private var channelTabs: [String: [ChannelTab]] = [:]
    /// What listings have said about videos and playlists, kept across runs so
    /// one put in a collection is still a title and a thumbnail offline.
    private let store: YouTubeStore

    init(broker: NodeBroker, innerTube: InnerTube = InnerTube(),
         store: YouTubeStore = .shared, freshFor: TimeInterval = 10 * 60,
         now: @escaping @Sendable () -> Date = Date.init,
         fetch: @escaping Fetch = { try await AnonymousSession.shared.data(
             for: AnonymousSession.request(to: $0)).0 }) {
        self.broker = broker
        self.innerTube = innerTube
        self.store = store
        self.freshFor = freshFor
        self.now = now
        self.fetch = fetch
    }

    func resolve(_ uri: String) -> NodeID? {
        YouTubeRef(uri: uri).map(\.nodeID)
    }

    func node(for id: NodeID) async -> Node? {
        guard let ref = YouTubeRef(uri: id.uri) else { return nil }
        switch ref {
        case .channel(let channelID):
            let title = await feed(of: channelID)?.title
            return Self.channelNode(channelID, title: title)
        case .tab(let channelID, let tab):
            return Node(id: id, type: TypeID("youtube.channel.tab"), label: tab.title,
                        icon: NodeIcon(Self.icon(of: tab), tint: .red),
                        hasChildren: true, childStyle: .contents,
                        identities: [YouTubeRef.channel(channelID).nodeID])
        case .video(let videoID):
            guard let record = store.video(videoID) else {
                return Node(id: id, type: TypeID("youtube.video"), label: videoID,
                            icon: videoIcon(videoID))
            }
            return Node(id: id, type: TypeID("youtube.video"), label: record.title,
                        icon: videoIcon(videoID), subtitle: record.line)
        case .playlist(let playlistID):
            let record = store.playlist(playlistID)
            return Node(id: id, type: TypeID("youtube.playlist"),
                        label: record?.title ?? playlistID,
                        icon: NodeIcon("list.bullet.rectangle", tint: .red),
                        subtitle: record?.line, hasChildren: true, childStyle: .contents)
        case .search(let query):
            return Node(id: id, type: TypeID("youtube.search"), label: query,
                        icon: NodeIcon("magnifyingglass", tint: .red),
                        subtitle: "YouTube", hasChildren: true, childStyle: .contents)
        case .aggregator(let uuid):
            return Node(id: id, type: TypeID("youtube.aggregator"),
                        label: store.feedName(uuid),
                        icon: NodeIcon("rectangle.stack.badge.play", tint: .red),
                        accepts: .types([TypeID("youtube.channel")]),
                        identities: [YouTubeRef.feed(uuid).nodeID])
        case .feed(let uuid):
            return Node(id: id, type: TypeID("youtube.feed"), label: store.feedName(uuid),
                        icon: NodeIcon("play.rectangle.on.rectangle", tint: .red),
                        hasChildren: true, childStyle: .contents)
        }
    }

    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        switch YouTubeRef(uri: id.uri) {
        case .channel(let channelID)?:
            // A channel is what it has: its tabs. Its videos are in the column
            // beside them, because the channel is also that tab — see
            // `node(for:)`.
            return Page(items: await tabs(of: channelID).map { tab in
                Node(id: YouTubeRef.tab(channelID, tab).nodeID,
                     type: TypeID("youtube.channel.tab"), label: tab.title,
                     icon: NodeIcon(Self.icon(of: tab), tint: .red),
                     hasChildren: true, childStyle: .contents)
            })

        case .tab(let channelID, let tab)?:
            // Everything on the tab, a page at a time. For its videos the
            // public feed is the fallback: only the latest fifteen, but it
            // answers whatever YouTube has done to its replies this month.
            if let listing = try? await innerTube.channelTab(channelID, tab, after: cursor?.token),
               !listing.entries.isEmpty {
                remember(tabs: listing.tabs, of: channelID)
                return await page(of: listing)
            }
            guard tab == .videos else { return Page(items: []) }
            return Page(items: await rows(for: (await feed(of: channelID)?.videos ?? [])
                .map(VideoItem.init(rss:))))

        case .playlist(let playlistID)?:
            guard let listing = try? await innerTube.playlist(playlistID, after: cursor?.token)
            else { return Page(items: []) }
            if let title = listing.title {
                store.remember(playlists: [PlaylistItem(id: playlistID, title: title)])
            }
            return await page(of: listing)

        case .search(let query)?:
            guard let listing = try? await innerTube.search(query, after: cursor?.token)
            else { return Page(items: []) }
            return await page(of: listing)
        case .feed(let uuid)?:
            // The channels are the aggregator's, placed by the reader and kept
            // by the host.
            let aggregator = YouTubeRef.aggregator(uuid).uri
            let channels = await broker.placedChildren(of: aggregator)
                .compactMap { uri -> String? in
                    if case .channel(let channelID)? = YouTubeRef(uri: uri) { return channelID }
                    return nil
                }
            // Every channel at once, so a feed of twenty is not twenty round
            // trips in a row; the merge then reads what they left behind.
            await withTaskGroup(of: Void.self) { group in
                for channelID in channels { group.addTask { _ = await self.feed(of: channelID) } }
            }
            // A feed is one page: each channel's feed is the only page it has.
            return await FeedMerge.page(
                sources: channels, after: cursor, size: 500,
                isBefore: { Self.published($0) > Self.published($1) },
                fetch: { channelID, _ in
                    Page(items: await self.rows(for: (await self.feed(of: channelID)?.videos ?? [])
                        .map(VideoItem.init(rss:))))
                })
        default:
            return Page(items: [])
        }
    }

    /// A page as the tree shows it: what the listing held, in its order, with
    /// what it said kept and its thumbnails fetched.
    private func page(of listing: Listing) async -> Page<Node> {
        store.remember(videos: listing.videos, line: Self.line(of:))
        store.remember(playlists: listing.playlists)
        await fetchThumbnails(for: listing.videos.map(\.id))
        let items = listing.entries.map { entry -> Node in
            switch entry {
            case .video(let video): return videoNode(video)
            case .playlist(let playlist): return Self.playlistNode(playlist)
            }
        }
        return Page(items: items, next: listing.continuation.map(Cursor.init))
    }

    private func rows(for videos: [VideoItem]) async -> [Node] {
        store.remember(videos: videos, line: Self.line(of:))
        await fetchThumbnails(for: videos.map(\.id))
        return videos.map(videoNode)
    }

    /// The thumbnails a page needs and does not have, a few at a time.
    ///
    /// Before the page is handed over, so rows arrive with their pictures
    /// rather than acquiring them a beat later — they are a few kilobytes
    /// each, and only ever fetched once.
    private func fetchThumbnails(for ids: [String], atOnce: Int = 6) async {
        let missing = ids.filter { store.icon(for: $0) == nil && YouTubeStore.isVideoID($0) }
        guard !missing.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for id in missing {
                if running == atOnce { await group.next(); running -= 1 }
                group.addTask {
                    guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/default.jpg"),
                          let data = try? await self.fetch(url) else { return }
                    self.store.store(icon: data, for: id)
                }
                running += 1
            }
        }
    }

    private func videoIcon(_ id: String) -> NodeIcon {
        NodeIcon("play.rectangle", tint: .red, imageData: store.icon(for: id))
    }

    /// Which tabs a channel has, asked once and remembered for the run.
    ///
    /// Its reply names them, so listing its videos is also how we learn what
    /// else it has. Unreachable, we still offer Videos, which the public feed
    /// can answer.
    private func tabs(of channelID: String) async -> [ChannelTab] {
        if let known = lock.withLock({ channelTabs[channelID] }) { return known }
        guard let listing = try? await innerTube.channelTab(channelID), !listing.tabs.isEmpty else {
            return [.videos]
        }
        remember(tabs: listing.tabs, of: channelID)
        return listing.tabs
    }

    private func remember(tabs: [ChannelTab], of channelID: String) {
        guard !tabs.isEmpty else { return }
        lock.withLock { channelTabs[channelID] = tabs }
    }

    static func icon(of tab: ChannelTab) -> String {
        switch tab {
        case .videos: return "play.rectangle"
        case .shorts: return "rectangle.portrait"
        case .live: return "dot.radiowaves.left.and.right"
        case .playlists: return "list.bullet.rectangle"
        }
    }

    /// A video's comments, as the inspector shows them.
    func comments(of videoID: String, after cursor: String? = nil) async -> CommentPage {
        (try? await innerTube.comments(of: videoID, after: cursor)) ?? CommentPage()
    }

    // MARK: Nodes

    /// A channel: its tabs where it sits, and its videos in the column beside
    /// them — one thing, seen as what it holds and as what it publishes.
    static func channelNode(_ channelID: String, title: String?) -> Node {
        Node(id: YouTubeRef.channel(channelID).nodeID, type: TypeID("youtube.channel"),
             label: title ?? channelID, icon: NodeIcon("person.crop.square", tint: .red),
             hasChildren: true,
             identities: [YouTubeRef.tab(channelID, .videos).nodeID])
    }

    static func published(_ node: Node) -> Date {
        if case .date(let date)? = node.attributes["published"] { return date }
        return .distantPast
    }

    /// What YouTube draws under a video: its counts, as strings.
    static func line(of video: VideoItem) -> String? {
        let parts = [video.views, video.age, video.duration].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A video as a listing drew it: what it is called, the line under it, and
    /// its thumbnail if one has been fetched.
    func videoNode(_ video: VideoItem) -> Node {
        var attributes = Attributes()
        if let published = video.published { attributes["published"] = .date(published) }
        return Node(id: YouTubeRef.video(video.id).nodeID, type: TypeID("youtube.video"),
                    label: video.title, icon: videoIcon(video.id),
                    attributes: attributes, subtitle: Self.line(of: video))
    }

    static func playlistNode(_ playlist: PlaylistItem) -> Node {
        Node(id: YouTubeRef.playlist(playlist.id).nodeID, type: TypeID("youtube.playlist"),
             label: playlist.title, icon: NodeIcon("list.bullet.rectangle", tint: .red),
             subtitle: playlist.line, hasChildren: true, childStyle: .contents)
    }

    // MARK: Feeds

    /// A channel's feed, fetched at most once in `freshFor`. A failed fetch
    /// keeps what was there before: a network hiccup should not empty a feed.
    func feed(of channelID: String) async -> ChannelFeed? {
        if let cached = lock.withLock({ feeds[channelID] }),
           now().timeIntervalSince(cached.fetched) < freshFor {
            return cached.feed
        }
        guard let url = ChannelFeed.url(for: channelID),
              let data = try? await fetch(url), let feed = ChannelFeed.parse(data) else {
            return lock.withLock { feeds[channelID]?.feed }
        }
        lock.withLock { feeds[channelID] = (feed, now()) }
        store.remember(videos: feed.videos.map(VideoItem.init(rss:)), line: Self.line(of:))
        return feed
    }

    /// The channel someone named, by id — reading its page when what they typed
    /// was a handle or a link.
    func channelID(for input: ChannelInput) async -> String? {
        switch input {
        case .id(let id):
            return id
        case .page(let url):
            guard let data = try? await fetch(url) else { return nil }
            return ChannelInput.channelID(inPage: String(decoding: data, as: UTF8.self))
        }
    }

    // MARK: Mutations

    /// A feed can be renamed.
    func supports(_ mutation: GraphMutation) -> Bool {
        guard case .rename(let id, _) = mutation, case .aggregator? = YouTubeRef(uri: id.uri) else {
            return false
        }
        return true
    }

    /// Renaming a feed changes what it is called and nothing else.
    ///
    /// Not its identity: it keeps its URI, so what was placed in it and what
    /// holds it are untouched, and there is no window in which the two could
    /// disagree. Its feed is told as well, since that is the same thing seen
    /// as what it produces.
    func apply(_ mutation: GraphMutation) async throws -> [NodeChange] {
        guard case .rename(let id, let name) = mutation,
              case .aggregator(let uuid)? = YouTubeRef(uri: id.uri) else { return [] }
        store.remember(feedName: name, for: uuid)
        return [.modified(id), .modified(YouTubeRef.feed(uuid).nodeID)]
    }
}
