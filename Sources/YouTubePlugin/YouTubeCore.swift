import Foundation
import MaximalTreeKit

// The YouTube plugin's view-free core: what its URIs mean, reading a channel's
// feed, and the provider. No WebKit and no AppKit — this file is what the test
// target compiles.

// MARK: - Identities

/// Everything the plugin names.
///
/// A channel and a video are named by YouTube's own ids. A feed — an aggregator
/// of channels — has nothing on YouTube's side, so it is named the way a
/// collection is: an id of its own, and its name in the URI. It is two things,
/// with two URIs that differ only in what they are: the aggregator, which holds
/// channels, and its feed, which lists their videos.
enum YouTubeRef: Equatable {
    case channel(String)
    case video(String)
    case aggregator(UUID, name: String)
    case feed(UUID, name: String)

    static let scheme = "youtube"

    init?(uri: String) {
        guard let components = URLComponents(string: uri), components.scheme == Self.scheme,
              let kind = components.host else { return nil }
        let id = String(components.path.drop { $0 == "/" })
        guard !id.isEmpty, !id.contains("/") else { return nil }
        let name = components.queryItems?.first { $0.name == "name" }?.value ?? ""
        switch kind {
        case "channel": self = .channel(id)
        case "video": self = .video(id)
        case "aggregator": guard let uuid = UUID(uuidString: id) else { return nil }; self = .aggregator(uuid, name: name)
        case "feed": guard let uuid = UUID(uuidString: id) else { return nil }; self = .feed(uuid, name: name)
        default: return nil
        }
    }

    var uri: String {
        switch self {
        case .channel(let id): return "youtube://channel/\(id)"
        case .video(let id): return "youtube://video/\(id)"
        case .aggregator(let id, let name): return Self.named("aggregator", id, name)
        case .feed(let id, let name): return Self.named("feed", id, name)
        }
    }

    var nodeID: NodeID { NodeID(canonical: uri) }

    /// Encoded strictly, so any name reads back exactly and the URI is already
    /// canonical.
    private static func named(_ kind: String, _ id: UUID, _ name: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?/")
        return "youtube://\(kind)/\(id.uuidString.lowercased())?name="
            + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }

    /// Where it is on YouTube, for what has a page there.
    var webURL: URL? {
        switch self {
        case .channel(let id): return URL(string: "https://www.youtube.com/channel/\(id)")
        case .video(let id): return URL(string: "https://www.youtube.com/watch?v=\(id)")
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
    private let fetch: Fetch
    private let freshFor: TimeInterval
    private let now: @Sendable () -> Date

    private let lock = NSLock()
    private var feeds: [String: (feed: ChannelFeed, fetched: Date)] = [:]
    private var videos: [String: (video: ChannelFeed.Video, channel: String)] = [:]

    init(broker: NodeBroker, freshFor: TimeInterval = 10 * 60,
         now: @escaping @Sendable () -> Date = Date.init,
         fetch: @escaping Fetch = { try await URLSession.shared.data(from: $0).0 }) {
        self.broker = broker
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
        case .video(let videoID):
            guard let known = lock.withLock({ videos[videoID] }) else {
                return Node(id: id, type: TypeID("youtube.video"), label: videoID,
                            icon: NodeIcon("play.rectangle", tint: .red))
            }
            return Self.videoNode(known.video)
        case .aggregator(let uuid, let name):
            return Node(id: id, type: TypeID("youtube.aggregator"),
                        label: name.isEmpty ? "YouTube Feed" : name,
                        icon: NodeIcon("rectangle.stack.badge.play", tint: .red),
                        accepts: .types([TypeID("youtube.channel")]),
                        identities: [YouTubeRef.feed(uuid, name: name).nodeID])
        case .feed(_, let name):
            return Node(id: id, type: TypeID("youtube.feed"),
                        label: name.isEmpty ? "YouTube Feed" : name,
                        icon: NodeIcon("play.rectangle.on.rectangle", tint: .red),
                        hasChildren: true, childStyle: .contents)
        }
    }

    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        switch YouTubeRef(uri: id.uri) {
        case .channel(let channelID)?:
            return Page(items: (await feed(of: channelID)?.videos ?? []).map(Self.videoNode))
        case .feed(let uuid, let name)?:
            // The channels are the aggregator's, placed by the reader and kept
            // by the host.
            let aggregator = YouTubeRef.aggregator(uuid, name: name).uri
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
                    Page(items: (await self.feed(of: channelID)?.videos ?? []).map(Self.videoNode))
                })
        default:
            return Page(items: [])
        }
    }

    // MARK: Nodes

    static func channelNode(_ channelID: String, title: String?) -> Node {
        Node(id: YouTubeRef.channel(channelID).nodeID, type: TypeID("youtube.channel"),
             label: title ?? channelID, icon: NodeIcon("person.crop.square", tint: .red),
             hasChildren: true, childStyle: .contents)
    }

    static func published(_ node: Node) -> Date {
        if case .date(let date)? = node.attributes["published"] { return date }
        return .distantPast
    }

    static func videoNode(_ video: ChannelFeed.Video) -> Node {
        var attributes = Attributes()
        attributes["published"] = .date(video.published)
        return Node(id: YouTubeRef.video(video.id).nodeID, type: TypeID("youtube.video"),
                    label: video.title, icon: NodeIcon("play.rectangle", tint: .red),
                    attributes: attributes,
                    subtitle: video.published.formatted(date: .abbreviated, time: .omitted))
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
        lock.withLock {
            feeds[channelID] = (feed, now())
            for video in feed.videos { videos[video.id] = (video, channelID) }
        }
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

    /// A feed can be renamed — its name is in its URI, so that is a rename in
    /// the graph's sense, for the aggregator and its feed both.
    func supports(_ mutation: GraphMutation) -> Bool {
        guard case .rename(let id, _) = mutation, case .aggregator? = YouTubeRef(uri: id.uri) else {
            return false
        }
        return true
    }

    func apply(_ mutation: GraphMutation) async throws -> [NodeChange] {
        guard case .rename(let id, let name) = mutation,
              case .aggregator(let uuid, let old)? = YouTubeRef(uri: id.uri), name != old else { return [] }
        return [
            .renamed(from: id, to: YouTubeRef.aggregator(uuid, name: name).nodeID),
            .renamed(from: YouTubeRef.feed(uuid, name: old).nodeID,
                     to: YouTubeRef.feed(uuid, name: name).nodeID),
        ]
    }
}
