import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession, outside Apple's Foundation
#endif

// YouTube's own web client talks to a private JSON API — InnerTube — and this
// is the part of it a reader needs: searching, and listing what a channel
// holds past the fifteen its public feed offers. No key, no account, and as
// little about you as the request can carry.

// MARK: - Saying as little as possible

/// The session every YouTube request goes through.
///
/// What a request cannot carry cannot identify you. So: no cookies, kept or
/// sent, which is what YouTube's visitor id rides in; no disk cache, which
/// would leave what you watched on disk; no credentials. Each request stands
/// alone, and nothing links it to the last.
///
/// The parts we do send are the parts everyone sends. `en`/`US` rather than
/// your own locale, because a locale narrows a crowd; a plain desktop browser
/// agent, matching the client version we claim, because a request that looks
/// unlike a browser is the one that gets asked to prove it is human. What is
/// left — your address, and the fact that a request happened — is not ours to
/// hide. A VPN or Tor is the answer to that, and the system proxy settings
/// this session already honours are where it plugs in.
enum AnonymousSession {
    nonisolated(unsafe) static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [:]
        return URLSession(configuration: config)
    }()

    /// A request with nothing of yours on it.
    static func request(to url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue(InnerTube.Client.web.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }
}

// MARK: - The client

struct InnerTube: Sendable {
    /// How a request reaches YouTube. The real session in the app; fixtures in
    /// the tests, which never touch the network.
    typealias Transport = @Sendable (URLRequest) async throws -> Data

    /// What the request says it is. YouTube serves different shapes to
    /// different clients, and the web client's is the one we read.
    struct Client: Sendable {
        var name: String
        var version: String
        var userAgent: String

        static let web = Client(
            name: "WEB",
            // Dated, and YouTube eventually stops serving an old one. Override
            // it without a build: `defaults write com.maximaltree.app
            // youtube.clientVersion 2.2026….00.00`.
            version: UserDefaults.standard.string(forKey: "youtube.clientVersion")
                ?? "2.20240814.00.00",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36")
    }

    var client: Client = .web
    var transport: Transport = { request in
        try await AnonymousSession.shared.data(for: request).0
    }

    /// One that never reaches YouTube, so a test exercises the public-feed
    /// path without the network deciding what it finds.
    static let offline = InnerTube(transport: { _ in throw URLError(.notConnectedToInternet) })

    /// Videos matching a query — or the next page of them.
    func search(_ query: String, after continuation: String? = nil) async throws -> Listing {
        let body: [String: Any] = continuation.map { ["continuation": $0] } ?? ["query": query]
        return Listing(try await post("search", body))
    }

    /// One of a channel's tabs — or the next page of it.
    func channelTab(_ channelID: String, _ tab: ChannelTab = .videos,
                    after continuation: String? = nil) async throws -> Listing {
        let body: [String: Any] = continuation.map { ["continuation": $0] }
            ?? ["browseId": channelID, "params": tab.params]
        return Listing(try await post("browse", body))
    }

    /// A video's comments, newest-ish first as YouTube sorts them.
    ///
    /// Two requests for the first page: a video's page says where its comments
    /// are rather than carrying them, so the token it gives is what actually
    /// asks for them. Later pages are one request, like everything else.
    func comments(of videoID: String, after continuation: String? = nil) async throws -> CommentPage {
        var token = continuation
        if token == nil {
            let page = try await post("next", ["videoId": videoID])
            token = page.all("itemSectionRenderer")
                .first { $0["sectionIdentifier"].string == "comment-item-section" }?
                .all("continuationCommand").first?["token"].string
        }
        guard let token else { return CommentPage() }
        return CommentPage(try await post("next", ["continuation": token]))
    }

    /// What a playlist holds, in its own order — or the next page of it.
    ///
    /// `VL` is YouTube's prefix for browsing a playlist rather than playing it.
    func playlist(_ playlistID: String, after continuation: String? = nil) async throws -> Listing {
        let body: [String: Any] = continuation.map { ["continuation": $0] }
            ?? ["browseId": playlistID.hasPrefix("VL") ? playlistID : "VL" + playlistID]
        return Listing(try await post("browse", body))
    }

    private func post(_ endpoint: String, _ body: [String: Any]) async throws -> JSONValue {
        guard let url = URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)") else {
            throw URLError(.badURL)
        }
        var request = AnonymousSession.request(to: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.name, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        var payload = body
        payload["context"] = ["client": ["clientName": client.name, "clientVersion": client.version,
                                         "hl": "en", "gl": "US"]]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return JSONValue(try await transport(request))
    }
}

/// The tabs a channel can have that hold things worth listing.
///
/// `params` is YouTube's own spelling of each; opaque, and the same for every
/// channel.
enum ChannelTab: String, CaseIterable, Sendable {
    case videos, shorts, live, playlists

    var title: String {
        switch self {
        case .videos: return "Videos"
        case .shorts: return "Shorts"
        case .live: return "Live"
        case .playlists: return "Playlists"
        }
    }

    var params: String {
        switch self {
        case .videos: return "EgZ2aWRlb3PyBgQKAjoA"
        case .shorts: return "EgZzaG9ydHPyBgUKA5oBAA"
        case .live: return "EgdzdHJlYW1z8gYECgJ6AA"
        case .playlists: return "EglwbGF5bGlzdHPyBgQKAkIA"
        }
    }

    /// What the reply calls it, which is how a channel says which it has.
    static func named(_ title: String) -> ChannelTab? {
        allCases.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
    }
}

// MARK: - What comes back

/// A page of what a listing holds.
struct Listing: Equatable, Sendable {
    /// What a listing holds, in the order it was given.
    enum Entry: Equatable, Sendable {
        case video(VideoItem)
        case playlist(PlaylistItem)
    }

    var entries: [Entry] = []
    /// The tabs the channel this came from has, when the reply names them.
    var tabs: [ChannelTab] = []
    var videos: [VideoItem] { entries.compactMap { if case .video(let v) = $0 { return v } else { return nil } } }
    var playlists: [PlaylistItem] { entries.compactMap { if case .playlist(let p) = $0 { return p } else { return nil } } }
    /// What the thing being listed is called, when the reply says.
    var title: String?
    /// YouTube's word for "the rest of it", which becomes our `Cursor`.
    var continuation: String?

    /// Nothing read: a reply in a shape this does not know.
    init() {}

    /// Read whatever videos a reply holds, wherever it holds them.
    ///
    /// By searching the reply rather than walking a fixed path, because those
    /// paths move: a search still answers in `videoRenderer`s, while a
    /// channel's videos tab has already moved to the newer view models, and
    /// both arrived nested differently again under a continuation.
    init(_ json: JSONValue) {
        // One walk, so what YouTube interleaved stays interleaved: a search
        // puts a playlist between two videos, and rearranging that would be
        // answering a different search.
        var seen: Set<String> = []
        for (kind, item) in json.all(["videoRenderer", "lockupViewModel", "shortsLockupViewModel"]) {
            if kind == "shortsLockupViewModel" {
                if let short = VideoItem(shorts: item), seen.insert(short.id).inserted {
                    entries.append(.video(short))
                }
                continue
            }
            if kind == "videoRenderer", let video = VideoItem(renderer: item),
               seen.insert(video.id).inserted {
                entries.append(.video(video))
            } else if kind == "lockupViewModel" {
                if let video = VideoItem(lockup: item), seen.insert(video.id).inserted {
                    entries.append(.video(video))
                } else if let playlist = PlaylistItem(lockup: item),
                          seen.insert(playlist.id).inserted {
                    entries.append(.playlist(playlist))
                }
            }
        }
        title = json["metadata"]["playlistMetadataRenderer"]["title"].string
            ?? json["metadata"]["channelMetadataRenderer"]["title"].string
        tabs = json.all("tabRenderer").compactMap { $0["title"].string }
            .compactMap(ChannelTab.named)
        // The "load more" token, which is the one attached to a continuation
        // item — not the several a reply carries for its filter chips.
        continuation = json.all("continuationItemRenderer")
            .compactMap { $0.all("continuationCommand").first?["token"].string }
            .last
    }
}

/// A video as a listing describes it: enough for a row, and nothing fetched.
///
/// The counts and ages are the strings YouTube drew — "40K views", "4 days
/// ago" — not numbers. That is all a listing carries, and turning "4 days ago"
/// into a date would invent a precision it does not have. The public feed is
/// where exact dates come from.
struct VideoItem: Equatable, Sendable {
    var id: String
    var title: String
    var channel: String?
    var channelID: String?
    var views: String?
    var age: String?
    var duration: String?
    var thumbnail: URL?
    /// Exactly when, which only the public feed knows — the private API draws
    /// "4 days ago". What the merged feed orders by.
    var published: Date?

    init(id: String, title: String, channel: String? = nil, channelID: String? = nil,
         views: String? = nil, age: String? = nil, duration: String? = nil,
         thumbnail: URL? = nil, published: Date? = nil) {
        self.id = id
        self.title = title
        self.channel = channel
        self.channelID = channelID
        self.views = views
        self.age = age
        self.duration = duration
        self.thumbnail = thumbnail
        self.published = published
    }

    /// The older shape, which search still answers in.
    init?(renderer: JSONValue) {
        guard let id = renderer["videoId"].string, !id.isEmpty else { return nil }
        self.id = id
        title = renderer["title"].text ?? id
        channel = renderer["ownerText"].text ?? renderer["longBylineText"].text
        channelID = renderer["ownerText"]["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string
        views = renderer["shortViewCountText"].text
        age = renderer["publishedTimeText"].text
        duration = renderer["lengthText"].text
        thumbnail = renderer["thumbnail"].thumbnail
    }

    /// A short, which is a video listed a third way again.
    init?(shorts lockup: JSONValue) {
        let reel = lockup.all("reelWatchEndpoint").first?["videoId"].string
        let entity = lockup["entityId"].string?
            .replacingOccurrences(of: "shorts-shelf-item-", with: "")
        guard let id = reel ?? entity, !id.isEmpty else { return nil }
        self.id = id
        title = lockup["overlayMetadata"]["primaryText"].text ?? id
        views = lockup["overlayMetadata"]["secondaryText"].text
        thumbnail = lockup["thumbnailViewModel"].thumbnail
    }

    /// The newer shape, which a channel's videos tab has moved to.
    init?(lockup: JSONValue) {
        guard lockup["contentType"].string == "LOCKUP_CONTENT_TYPE_VIDEO",
              let id = lockup["contentId"].string, !id.isEmpty else { return nil }
        self.id = id
        let metadata = lockup["metadata"]["lockupMetadataViewModel"]
        title = metadata["title"].text ?? id
        // "40K views" and "4 days ago" arrive as parts of one drawn line.
        let parts = metadata["metadata"]["contentMetadataViewModel"]["metadataRows"]
            .array.flatMap { $0["metadataParts"].array.compactMap { $0["text"].text } }
        views = parts.first { $0.contains("view") }
        age = parts.first { $0.contains("ago") }
        duration = lockup["contentImage"].all("thumbnailBadgeViewModel")
            .compactMap { $0["text"].string }.first
        thumbnail = lockup["contentImage"].thumbnail
    }
}

extension VideoItem {
    /// From the public feed, which knows exactly when but not how many views.
    init(rss video: ChannelFeed.Video) {
        self.init(id: video.id, title: video.title,
                  age: video.published.formatted(date: .abbreviated, time: .omitted),
                  thumbnail: video.thumbnail, published: video.published)
    }
}

extension PlaylistItem {
    init(id: String, title: String, line: String? = nil) {
        self.id = id
        self.title = title
        self.line = line
        self.thumbnail = nil
    }
}

/// A playlist as a listing describes it.
struct PlaylistItem: Equatable, Sendable {
    var id: String
    var title: String
    /// Who made it and how much is in it, as drawn: "Some Channel · 19 lessons".
    var line: String?
    var thumbnail: URL?

    init?(lockup: JSONValue) {
        guard lockup["contentType"].string == "LOCKUP_CONTENT_TYPE_PLAYLIST",
              let id = lockup["contentId"].string, !id.isEmpty else { return nil }
        self.id = id
        let metadata = lockup["metadata"]["lockupMetadataViewModel"]
        title = metadata["title"].text ?? id
        let owner = metadata["metadata"]["contentMetadataViewModel"]["metadataRows"]
            .array.flatMap { $0["metadataParts"].array.compactMap { $0["text"].text } }.first
        let count = lockup.all("thumbnailBadgeViewModel").compactMap { $0["text"].string }.first
        let parts = [owner, count].compactMap { $0 }
        line = parts.isEmpty ? nil : parts.joined(separator: " · ")
        thumbnail = lockup["contentImage"].thumbnail
    }
}

/// A page of a video's comments.
struct CommentPage: Equatable, Sendable {
    var comments: [CommentItem] = []
    var continuation: String?

    init() {}

    init(_ json: JSONValue) {
        // The comments arrive as entities in a batch of updates, away from the
        // renderers that refer to them — so they are taken from where they
        // are, not walked to.
        var seen: Set<String> = []
        comments = json.all("commentEntityPayload").compactMap(CommentItem.init(payload:))
            .filter { seen.insert($0.id).inserted }
        continuation = json.all("continuationItemRenderer")
            .compactMap { $0.all("continuationCommand").first?["token"].string }
            .last
    }
}

/// One comment, as it is drawn.
struct CommentItem: Equatable, Sendable, Identifiable {
    var id: String
    var author: String
    var text: String
    var published: String?
    var likes: String?
    var replies: String?

    init?(payload: JSONValue) {
        let properties = payload["properties"]
        guard let id = properties["commentId"].string, !id.isEmpty,
              // Replies belong under the comment they answer, which is not
              // something a list of comments shows.
              (properties["replyLevel"].number ?? 0) == 0 else { return nil }
        self.id = id
        author = payload["author"]["displayName"].string ?? ""
        text = properties["content"]["content"].string ?? ""
        published = properties["publishedTime"].string
        likes = payload["toolbar"]["likeCountNotliked"].string.flatMap { $0 == "0" ? nil : $0 }
        replies = payload["toolbar"]["replyCount"].string.flatMap { $0 == "0" ? nil : $0 }
    }
}

// MARK: - Reading the reply

/// A JSON reply, read rather than decoded.
///
/// A reply is a megabyte of renderers whose shapes change — twice already in
/// the two places this reads. Decoding it wholesale would be a model of
/// YouTube's internals that breaks on their schedule; this takes the few
/// fields it needs and is indifferent to the rest.
enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(_ data: Data) {
        self = (try? JSONSerialization.jsonObject(with: data)).map(JSONValue.init(any:)) ?? .null
    }

    init(any: Any) {
        switch any {
        case let dictionary as [String: Any]:
            self = .object(dictionary.mapValues { JSONValue(any: $0) })
        case let array as [Any]:
            self = .array(array.map { JSONValue(any: $0) })
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // Before `Bool`, and asking the number itself what it is: 0 and 1
            // bridge to Bool happily, so matching that first read every reply
            // level, index and count of one as true or false.
            self = Self.isFlag(number) ? .bool(number.boolValue) : .number(number.doubleValue)
        // Where nothing bridges to NSNumber, JSONSerialization's own values
        // arrive as themselves — and then a Bool is only ever a JSON flag.
        case let flag as Bool:
            self = .bool(flag)
        case let integer as Int:
            self = .number(Double(integer))
        case let real as Double:
            self = .number(real)
        default:
            self = .null
        }
    }

    /// Whether a parsed number is really `true` or `false`. On Apple platforms
    /// a JSON flag is the CFBoolean singleton; elsewhere it is made as a `char`
    /// — which no JSON number ever is.
    private static func isFlag(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
        CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        String(cString: number.objCType) == "c"
        #endif
    }

    subscript(key: String) -> JSONValue {
        if case .object(let fields) = self, let value = fields[key] { return value }
        return .null
    }

    subscript(index: Int) -> JSONValue {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return .null
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var array: [JSONValue] {
        if case .array(let items) = self { return items }
        return []
    }

    /// Every value under this one filed against `key`, however deep.
    func all(_ key: String, limit: Int = 500) -> [JSONValue] {
        all([key], limit: limit).map(\.value)
    }

    /// Every value filed against any of `keys`, in the order they appear.
    ///
    /// One walk rather than one per key, because the order a reply puts things
    /// in is part of the answer. Array order is the reply's; a field order
    /// within an object is not preserved by any JSON reader, so the names are
    /// taken in a fixed order rather than whichever the hash gives today.
    func all(_ keys: Set<String>, limit: Int = 500) -> [(key: String, value: JSONValue)] {
        var found: [(key: String, value: JSONValue)] = []
        func descend(_ value: JSONValue, _ depth: Int) {
            guard found.count < limit, depth < 24 else { return }
            switch value {
            case .object(let fields):
                for (name, field) in fields.sorted(by: { $0.key < $1.key }) {
                    if keys.contains(name) { found.append((name, field)) }
                    descend(field, depth + 1)
                }
            case .array(let items):
                for item in items { descend(item, depth + 1) }
            default:
                break
            }
        }
        descend(self, 0)
        return found
    }

    /// Text, in the three ways YouTube writes it.
    var text: String? {
        if let simple = self["simpleText"].string { return simple }
        if let content = self["content"].string { return content }
        let runs = self["runs"].array.compactMap { $0["text"].string }
        if !runs.isEmpty { return runs.joined() }
        return string
    }

    /// The largest thumbnail offered.
    var thumbnail: URL? {
        let sources = all("thumbnails").flatMap(\.array) + all("sources").flatMap(\.array)
        let best = sources.max { ($0["width"].number ?? 0) < ($1["width"].number ?? 0) }
        return best?["url"].string.flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }
    }

    fileprivate var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}
