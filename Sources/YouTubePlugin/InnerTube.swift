import Foundation

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

    /// A channel's videos, newest first — or the next page of them.
    ///
    /// `params` is YouTube's own spelling of "the videos tab"; opaque, and the
    /// same for every channel.
    func channelVideos(_ channelID: String, after continuation: String? = nil) async throws -> Listing {
        let body: [String: Any] = continuation.map { ["continuation": $0] }
            ?? ["browseId": channelID, "params": "EgZ2aWRlb3PyBgQKAjoA"]
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

// MARK: - What comes back

/// A page of what a listing holds.
struct Listing: Equatable, Sendable {
    var videos: [VideoItem] = []
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
        var seen: Set<String> = []
        for renderer in json.all("videoRenderer") {
            if let video = VideoItem(renderer: renderer), seen.insert(video.id).inserted {
                videos.append(video)
            }
        }
        for lockup in json.all("lockupViewModel") {
            if let video = VideoItem(lockup: lockup), seen.insert(video.id).inserted {
                videos.append(video)
            }
        }
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
        case let bool as Bool:
            self = .bool(bool)
        case let number as NSNumber:
            self = .number(number.doubleValue)
        default:
            self = .null
        }
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
        var found: [JSONValue] = []
        func descend(_ value: JSONValue, _ depth: Int) {
            guard found.count < limit, depth < 24 else { return }
            switch value {
            case .object(let fields):
                for (name, field) in fields {
                    if name == key { found.append(field) }
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
