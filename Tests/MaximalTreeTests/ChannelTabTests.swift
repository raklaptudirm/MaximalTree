import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

// Replies in the shapes YouTube answers in — the nesting is theirs, the
// channel, the shorts and the comments are invented.

/// A channel's videos tab, which also names every tab the channel has.
private let videosTab = """
{"contents":{"twoColumnBrowseResultsRenderer":{"tabs":[
  {"tabRenderer":{"title":"Home"}},
  {"tabRenderer":{"title":"Videos","content":{"richGridRenderer":{"contents":[
    {"richItemRenderer":{"content":{"lockupViewModel":{
      "contentId":"vid1","contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
      "metadata":{"lockupMetadataViewModel":{"title":{"content":"A video"}}}}}}}
  ]}}}},
  {"tabRenderer":{"title":"Shorts"}},
  {"tabRenderer":{"title":"Courses"}},
  {"tabRenderer":{"title":"Playlists"}},
  {"tabRenderer":{"title":"Posts"}}]}}}
"""

/// The shorts tab, which lists them a third way again.
private let shortsTab = """
{"contents":{"twoColumnBrowseResultsRenderer":{"tabs":[{"tabRenderer":{"title":"Shorts",
  "content":{"richGridRenderer":{"contents":[
    {"richItemRenderer":{"content":{"shortsLockupViewModel":{
      "entityId":"shorts-shelf-item-short1",
      "onTap":{"innertubeCommand":{"reelWatchEndpoint":{"videoId":"short1"}}},
      "overlayMetadata":{"primaryText":{"content":"A short"},
                         "secondaryText":{"content":"3.4K views"}},
      "thumbnailViewModel":{"image":{"sources":[
        {"url":"https://i.ytimg.com/vi/short1/hq720.jpg","width":720}]}}}}}}
  ]}}}}]}}}
"""

/// A video's page, which says where its comments are rather than carrying them.
private let videoPage = """
{"contents":{"twoColumnWatchNextResults":{
  "secondaryResults":{"secondaryResults":{"results":[
    {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":
      {"token":"MORE_RELATED_VIDEOS"}}}}]}},
  "results":{"results":{"contents":[
    {"itemSectionRenderer":{"sectionIdentifier":"related-item-section","contents":[
      {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":
        {"token":"NOT_THE_COMMENTS"}}}}]}},
    {"itemSectionRenderer":{"sectionIdentifier":"comment-item-section","contents":[
      {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":
        {"token":"COMMENTS"}}}}]}}]}}}}}
"""

/// The comments themselves, which arrive as entities in a batch of updates.
private let commentsPage = """
{"frameworkUpdates":{"entityBatchUpdate":{"mutations":[
  {"payload":{"commentEntityPayload":{
    "properties":{"commentId":"c1","content":{"content":"The first thing anyone said."},
                  "publishedTime":"4 days ago","replyLevel":0},
    "author":{"displayName":"@someone","channelId":"UCzzzzzzzzzzzzzzzzzzzzzz"},
    "toolbar":{"likeCountNotliked":"5","replyCount":"1"}}}},
  {"payload":{"commentEntityPayload":{
    "properties":{"commentId":"c2","content":{"content":"A reply to the first."},
                  "publishedTime":"3 days ago","replyLevel":1},
    "author":{"displayName":"@another"},
    "toolbar":{"likeCountNotliked":"0","replyCount":"0"}}}},
  {"payload":{"commentEntityPayload":{
    "properties":{"commentId":"c3","content":{"content":"The second thing."},
                  "publishedTime":"2 days ago","replyLevel":0},
    "author":{"displayName":"@third"},
    "toolbar":{"likeCountNotliked":"0","replyCount":"0"}}}}]}},
 "onResponseReceivedEndpoints":[{"reloadContinuationItemsCommand":{"continuationItems":[
   {"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":
     {"token":"MORE_COMMENTS"}}}}]}}]}
"""

/// Answers by what was asked for, and keeps the requests.
private final class Replies: @unchecked Sendable {
    var byParams: [String: String] = [:]
    var byToken: [String: String] = [:]
    var forVideo: String?
    var failing = false
    private(set) var asked: [String] = []
    private let lock = NSLock()

    var transport: InnerTube.Transport {
        { request in
            if self.failing { throw URLError(.notConnectedToInternet) }
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
                as? [String: Any] ?? [:]
            let endpoint = request.url?.lastPathComponent ?? ""
            self.lock.withLock { self.asked.append(endpoint) }
            if let token = body["continuation"] as? String {
                guard let reply = self.byToken[token] else { throw URLError(.badServerResponse) }
                return Data(reply.utf8)
            }
            if body["videoId"] != nil, let reply = self.forVideo { return Data(reply.utf8) }
            guard let params = body["params"] as? String, let reply = self.byParams[params]
            else { throw URLError(.badServerResponse) }
            return Data(reply.utf8)
        }
    }
}

private struct NoBroker2: NodeBroker {
    func node(for uri: String) async -> Node? { nil }
    func children(of uri: String, page: Cursor?) async -> Page<Node> { Page(items: []) }
    func placedChildren(of uri: String) async -> [String] { [] }
}

@Suite struct ChannelTabTests {
    private let channel = "UCaaaaaaaaaaaaaaaaaaaaaa"

    private func provider(_ replies: Replies) throws -> YouTubeProvider {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tabs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return YouTubeProvider(broker: NoBroker2(),
                               innerTube: InnerTube(transport: replies.transport),
                               store: YouTubeStore(directory: dir),
                               fetch: { _ in Data([0xFF, 0xD8, 0xFF]) })
    }

    private func replies() -> Replies {
        let replies = Replies()
        replies.byParams[ChannelTab.videos.params] = videosTab
        replies.byParams[ChannelTab.shorts.params] = shortsTab
        return replies
    }

    /// A channel is its tabs — the ones it actually has, named as YouTube
    /// names them, and nothing it does not.
    @Test func aChannelIsTheTabsItHas() async throws {
        let replies = replies()
        let provider = try provider(replies)
        let id = YouTubeRef.channel(channel).nodeID

        let page = await provider.children(of: id, page: nil)
        #expect(page.items.map(\.label) == ["Videos", "Shorts", "Playlists"],
                "a tab it does not have, or one with nothing to list, was offered")
        #expect(page.items.allSatisfy { $0.childStyle == .contents })
    }

    /// Asked once: the reply that lists its videos is also the one that names
    /// its tabs.
    @Test func itsTabsAreAskedForOnce() async throws {
        let replies = replies()
        let provider = try provider(replies)
        let id = YouTubeRef.channel(channel).nodeID
        _ = await provider.children(of: id, page: nil)
        let asked = replies.asked.count
        _ = await provider.children(of: id, page: nil)
        #expect(replies.asked.count == asked)
    }

    /// The channel is also its videos, so selecting it lists them in the
    /// column while its tabs are what it opens to.
    @Test func aChannelIsAlsoItsVideos() async throws {
        let provider = try provider(replies())
        let node = try #require(await provider.node(for: YouTubeRef.channel(channel).nodeID))
        #expect(node.childStyle != .contents, "a channel that opens to nothing")
        #expect(node.identities == [YouTubeRef.tab(channel, .videos).nodeID])

        let videos = try #require(await provider.node(for: YouTubeRef.tab(channel, .videos).nodeID))
        #expect(videos.childStyle == .contents)
        #expect(videos.label == "Videos")
    }

    /// Shorts are listed a third way again, and read the same as anything else.
    @Test func shortsAreVideosToo() async throws {
        let provider = try provider(replies())
        let page = await provider.children(of: YouTubeRef.tab(channel, .shorts).nodeID, page: nil)
        #expect(page.items.map(\.label) == ["A short"])
        #expect(page.items.first?.id.uri == YouTubeRef.video("short1").uri)
        #expect(page.items.first?.subtitle == "3.4K views")
    }

    /// A tab URI is a tab of a channel, which is what it says.
    @Test func aTabReadsBackAsATabOfItsChannel() {
        for tab in ChannelTab.allCases {
            let ref = YouTubeRef.tab(channel, tab)
            #expect(YouTubeRef(uri: ref.uri) == ref)
            #expect(NodeID(ref.uri)?.uri == ref.uri)
        }
        #expect(YouTubeRef(uri: "youtube://channel/\(channel)") == .channel(channel))
        #expect(YouTubeRef(uri: "youtube://channel/\(channel)?tab=posts") == nil,
                "a tab it cannot list")
    }

    /// Unreachable, a channel still offers the one tab its public feed can
    /// answer — and that tab still lists.
    @Test func withoutTheApiThereIsStillTheFeed() async throws {
        let replies = replies()
        replies.failing = true
        let provider = YouTubeProvider(broker: NoBroker2(),
                                       innerTube: InnerTube(transport: replies.transport),
                                       store: YouTubeStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())),
                                       fetch: { _ in
                                           feedXML("UCaaaaaaaaaaaaaaaaaaaaaa", title: "Alpha",
                                                   videos: [("a1", "A one", "2026-09-01T10:00:00+00:00")])
                                       })
        let tabs = await provider.children(of: YouTubeRef.channel(channel).nodeID, page: nil)
        #expect(tabs.items.map(\.label) == ["Videos"])
        let videos = await provider.children(of: YouTubeRef.tab(channel, .videos).nodeID, page: nil)
        #expect(videos.items.map(\.label) == ["A one"])
        let shorts = await provider.children(of: YouTubeRef.tab(channel, .shorts).nodeID, page: nil)
        #expect(shorts.items.isEmpty, "the feed answered for a tab it knows nothing about")
    }
}

@Suite struct CommentTests {
    private func replies() -> Replies {
        let replies = Replies()
        replies.forVideo = videoPage
        replies.byToken["COMMENTS"] = commentsPage
        return replies
    }

    /// The first page takes two requests: the video's page says where its
    /// comments are, and that token asks for them.
    @Test func aVideosCommentsTakeTwoRequests() async throws {
        let replies = replies()
        let page = try await InnerTube(transport: replies.transport).comments(of: "vid1")

        #expect(replies.asked == ["next", "next"])
        #expect(page.comments.map(\.id) == ["c1", "c3"], "a reply was listed as a comment")
        let first = try #require(page.comments.first)
        #expect(first.author == "@someone")
        #expect(first.text == "The first thing anyone said.")
        #expect(first.published == "4 days ago")
        #expect(first.likes == "5")
        #expect(first.replies == "1")
        #expect(page.comments.last?.likes == nil, "nothing is not something to say")
        #expect(page.continuation == "MORE_COMMENTS")
    }

    /// Later pages are one request, by the token.
    @Test func thePageAfterIsOneRequest() async throws {
        let replies = replies()
        replies.byToken["MORE_COMMENTS"] = commentsPage
        let page = try await InnerTube(transport: replies.transport)
            .comments(of: "vid1", after: "MORE_COMMENTS")
        #expect(replies.asked == ["next"])
        #expect(page.comments.count == 2)
    }

    /// A video with comments turned off says nothing rather than failing.
    @Test func aVideoWithNoCommentsIsEmpty() async throws {
        let replies = Replies()
        replies.forVideo = #"{"contents":{"twoColumnWatchNextResults":{}}}"#
        let page = try await InnerTube(transport: replies.transport).comments(of: "vid1")
        #expect(page == CommentPage())
        #expect(replies.asked == ["next"], "it asked for comments that were not there")
    }
}
