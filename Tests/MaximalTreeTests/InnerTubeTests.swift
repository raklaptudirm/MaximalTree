import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

// Replies in the shapes YouTube actually answers in — the nesting is theirs,
// the videos are invented.

/// What a search answers: the older renderers, a filter chip's token, and the
/// "load more" token at the end of the section.
private let searchReply = """
{"contents":{"twoColumnSearchResultsRenderer":{"primaryContents":{"sectionListRenderer":{"contents":[
  {"itemSectionRenderer":{"contents":[
    {"videoRenderer":{"videoId":"vid1","title":{"runs":[{"text":"A first video"}]},
      "ownerText":{"runs":[{"text":"A Channel","navigationEndpoint":{"browseEndpoint":
        {"browseId":"UCaaaaaaaaaaaaaaaaaaaaaa"}}}]},
      "shortViewCountText":{"simpleText":"12K views"},
      "publishedTimeText":{"simpleText":"2 days ago"},
      "lengthText":{"simpleText":"10:12"},
      "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/vid1/default.jpg","width":120},
        {"url":"https://i.ytimg.com/vi/vid1/hq720.jpg","width":720}]}}},
    {"videoRenderer":{"videoId":"vid2","title":{"runs":[{"text":"A second video"}]}}},
    {"shelfRenderer":{"title":{"simpleText":"People also watched"}}}
  ]}},
  {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"MORE"}}}}
]}}}},
"header":{"searchHeaderRenderer":{"chipBar":{"chipCloudRenderer":{"chips":[
  {"chipCloudChipRenderer":{"navigationEndpoint":{"continuationCommand":{"token":"CHIP"}}}}]}}}}}
"""

/// What a channel's videos tab answers: the newer view models.
private let channelReply = """
{"contents":{"twoColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"title":"Home"}},
  {"tabRenderer":{"title":"Videos","content":{"richGridRenderer":{"contents":[
    {"richItemRenderer":{"content":{"lockupViewModel":{
      "contentId":"lock1","contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
      "metadata":{"lockupMetadataViewModel":{"title":{"content":"Something new"},
        "metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[
          {"text":{"content":"40K views"}},{"text":{"content":"4 days ago"}}]}]}}}},
      "contentImage":{"thumbnailViewModel":{"image":{"sources":[
          {"url":"https://i.ytimg.com/vi/lock1/hq720.jpg","width":720,"height":404},
          {"url":"https://i.ytimg.com/vi/lock1/small.jpg","width":360,"height":202}]},
        "overlays":[{"thumbnailBottomOverlayViewModel":{"badges":[
          {"thumbnailBadgeViewModel":{"text":"7:17"}}]}}]}}}}}},
    {"richItemRenderer":{"content":{"lockupViewModel":{
      "contentId":"PLplaylist","contentType":"LOCKUP_CONTENT_TYPE_PLAYLIST",
      "metadata":{"lockupMetadataViewModel":{"title":{"content":"A playlist"}}}}}}},
    {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"MORE"}}}}
  ]}}}}]}}}
"""

@Suite struct InnerTubeTests {
    /// Answers the fixture, and keeps every request it was given.
    private final class Recorder: @unchecked Sendable {
        var reply: String
        var failing = false
        private(set) var requests: [URLRequest] = []
        init(_ reply: String) { self.reply = reply }

        var transport: InnerTube.Transport {
            { request in
                self.requests.append(request)
                if self.failing { throw URLError(.notConnectedToInternet) }
                return Data(self.reply.utf8)
            }
        }

        var body: [String: Any] {
            (try? JSONSerialization.jsonObject(with: requests.last?.httpBody ?? Data()))
                as? [String: Any] ?? [:]
        }
    }

    @Test func aSearchIsReadFromTheOlderShape() async throws {
        let recorder = Recorder(searchReply)
        let listing = try await InnerTube(transport: recorder.transport).search("anything")

        #expect(listing.videos.map(\.id) == ["vid1", "vid2"])
        let first = try #require(listing.videos.first)
        #expect(first.title == "A first video")
        #expect(first.channel == "A Channel")
        #expect(first.channelID == "UCaaaaaaaaaaaaaaaaaaaaaa")
        #expect(first.views == "12K views")
        #expect(first.age == "2 days ago")
        #expect(first.duration == "10:12")
        #expect(first.thumbnail?.absoluteString == "https://i.ytimg.com/vi/vid1/hq720.jpg",
                "the largest thumbnail offered")
        #expect(listing.videos.last?.title == "A second video", "a sparse renderer is still a row")
    }

    /// A channel's videos come back as view models now, with the numbers drawn
    /// as one line — and what is not a video is not a row.
    @Test func aChannelsVideosAreReadFromTheNewerShape() async throws {
        let recorder = Recorder(channelReply)
        let listing = try await InnerTube(transport: recorder.transport)
            .channelTab("UCaaaaaaaaaaaaaaaaaaaaaa")

        #expect(listing.videos.map(\.id) == ["lock1"], "a playlist was listed as a video")
        let video = try #require(listing.videos.first)
        #expect(video.title == "Something new")
        #expect(video.views == "40K views")
        #expect(video.age == "4 days ago")
        #expect(video.duration == "7:17")
        #expect(video.thumbnail?.absoluteString == "https://i.ytimg.com/vi/lock1/hq720.jpg")
    }

    /// The token for the next page is the one on the continuation item — not a
    /// filter chip's, which a reply also carries.
    @Test func theNextPageIsTheContinuationItemsToken() async throws {
        let recorder = Recorder(searchReply)
        let listing = try await InnerTube(transport: recorder.transport).search("anything")
        #expect(listing.continuation == "MORE")
    }

    /// Asking for the next page sends the token back, and nothing else: the
    /// query is in the token.
    @Test func thePageAfterIsAskedForByItsTokenAlone() async throws {
        let recorder = Recorder(searchReply)
        _ = try await InnerTube(transport: recorder.transport).search("anything", after: "MORE")
        #expect(recorder.body["continuation"] as? String == "MORE")
        #expect(recorder.body["query"] == nil)
    }

    /// A reply in a shape it cannot read is an empty listing, not a crash and
    /// not a throw — the fallback then answers.
    @Test func aReplyItCannotReadIsEmpty() async throws {
        let recorder = Recorder(#"{"responseContext":{},"contents":{"somethingNew":{}}}"#)
        let listing = try await InnerTube(transport: recorder.transport).search("anything")
        #expect(listing == Listing())
    }

    /// A reply that draws the same video both ways — the shapes overlap while
    /// YouTube migrates — is one row, not two.
    @Test func aVideoAnsweredInBothShapesIsOneRow() async throws {
        let both = """
        {"contents":{"itemSectionRenderer":{"contents":[
          {"videoRenderer":{"videoId":"same","title":{"runs":[{"text":"Once"}]}}},
          {"lockupViewModel":{"contentId":"same","contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
            "metadata":{"lockupMetadataViewModel":{"title":{"content":"Once again"}}}}}]}}}
        """
        let listing = try await InnerTube(transport: Recorder(both).transport).search("anything")
        #expect(listing.videos.map(\.title) == ["Once"])
    }

    /// Nothing in a reply is a flag unless YouTube wrote one. A count of one,
    /// an index of zero, a reply level: all numbers, which bridge to Bool
    /// eagerly enough to read every one of them as true.
    @Test func zeroAndOneAreNumbers() async throws {
        let reply = """
        {"contents":{"itemSectionRenderer":{"contents":[
          {"videoRenderer":{"videoId":"v","title":{"runs":[{"text":"T"}]},
            "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/v/a.jpg","width":1},
                                       {"url":"https://i.ytimg.com/vi/v/b.jpg","width":0}]}}}]}}}
        """
        let listing = try await InnerTube(transport: Recorder(reply).transport).search("x")
        #expect(listing.videos.first?.thumbnail?.absoluteString == "https://i.ytimg.com/vi/v/a.jpg",
                "widths of 0 and 1 were read as flags, so neither was bigger")
    }

    // MARK: Anonymity

    /// A request carries nothing that would say who asked.
    @Test func aRequestCarriesNothingOfYours() async throws {
        let recorder = Recorder(searchReply)
        _ = try await InnerTube(transport: recorder.transport).search("anything")
        let request = try #require(recorder.requests.last)

        #expect(request.httpShouldHandleCookies == false, "a cookie would be a visitor id")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla") == true)

        let context = (recorder.body["context"] as? [String: Any])?["client"] as? [String: Any]
        #expect(context?["hl"] as? String == "en", "your own language narrows the crowd")
        #expect(context?["gl"] as? String == "US")
        #expect(recorder.body["visitorData"] == nil, "a visitor id links one request to the next")
        let sent = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(!sent.contains("clickTracking"), "YouTube's own tracking was handed back to it")
    }

    /// And the session keeps nothing between requests.
    @Test func theSessionRemembersNothing() {
        let config = AnonymousSession.shared.configuration
        #expect(config.httpCookieStorage == nil)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.urlCache == nil, "what you watched would be left on disk")
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }
}

// MARK: - A channel, through the provider

@Suite struct ChannelListingTests {
    /// Answers by what was asked for: the first page to a request with no
    /// token, and a later page only to a request carrying its token — so a
    /// page that arrives is proof the token was sent.
    private final class Replies: @unchecked Sendable {
        var byToken: [String: String]
        var failing = false
        private(set) var tokens: [String?] = []
        init(first: String, then later: [String: String] = [:]) {
            byToken = later
            byToken[""] = first
        }

        var transport: InnerTube.Transport {
            { request in
                if self.failing { throw URLError(.notConnectedToInternet) }
                let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
                    as? [String: Any]
                let token = body?["continuation"] as? String
                self.tokens.append(token)
                guard let reply = self.byToken[token ?? ""] else { throw URLError(.badServerResponse) }
                return Data(reply.utf8)
            }
        }
    }

    private let channel = "UCaaaaaaaaaaaaaaaaaaaaaa"

    private func provider(_ replies: Replies, feed: Data? = nil) -> YouTubeProvider {
        YouTubeProvider(broker: EmptyBroker(),
                        innerTube: InnerTube(transport: replies.transport),
                        fetch: { _ in
                            guard let feed else { throw URLError(.fileDoesNotExist) }
                            return feed
                        })
    }

    /// Everything the channel has, a page at a time — past the fifteen the
    /// public feed stops at.
    @Test func aChannelListsWhatItHasAPageAtATime() async throws {
        let second = channelReply.replacingOccurrences(of: "lock1", with: "lock2")
            .replacingOccurrences(of: #""token":"MORE""#, with: #""token":"YET_MORE""#)
        let replies = Replies(first: channelReply, then: ["MORE": second])
        let provider = provider(replies)
        let id = YouTubeRef.tab(channel, .videos).nodeID

        let first = await provider.children(of: id, page: nil)
        #expect(first.items.map(\.label) == ["Something new", "A playlist"],
                "a tab lists what is on it, playlists included")
        #expect(first.items.first?.subtitle == "40K views · 4 days ago · 7:17")
        let cursor = try #require(first.next)
        #expect(cursor.token == "MORE")

        let next = await provider.children(of: id, page: cursor)
        #expect(next.items.map(\.id.uri).first == YouTubeRef.video("lock2").uri)
        #expect(next.next?.token == "YET_MORE")
        #expect(replies.tokens == [nil, "MORE"], "the page after was asked for by its token")
    }

    /// When the private API will not answer — a shape it cannot read, a bot
    /// check, no network — the public feed still does.
    @Test func whenTheApiWillNotAnswerThePublicFeedDoes() async throws {
        let replies = Replies(first: channelReply)
        replies.failing = true
        let feed = feedXML(channel, title: "Alpha", videos: [("a1", "A one", "2026-09-01T10:00:00+00:00")])
        let listing = await provider(replies, feed: feed)
            .children(of: YouTubeRef.tab(channel, .videos).nodeID, page: nil)
        #expect(listing.items.map(\.label) == ["A one"])
        #expect(listing.next == nil, "the feed is one page and says so")
    }

    /// A video seen in a listing keeps its title afterwards, so one put in a
    /// collection is not drawn as its id.
    @Test func aVideoSeenInAListingKeepsItsTitle() async throws {
        let provider = provider(Replies(first: channelReply))
        _ = await provider.children(of: YouTubeRef.tab(channel, .videos).nodeID, page: nil)
        let node = await provider.node(for: YouTubeRef.video("lock1").nodeID)
        #expect(node?.label == "Something new")
        #expect(node?.subtitle == "40K views · 4 days ago · 7:17")
    }
}

private struct EmptyBroker: NodeBroker {
    func node(for uri: String) async -> Node? { nil }
    func children(of uri: String, page: Cursor?) async -> Page<Node> { Page(items: []) }
    func placedChildren(of uri: String) async -> [String] { [] }
}
