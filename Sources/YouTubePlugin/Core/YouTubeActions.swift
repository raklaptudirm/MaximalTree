import Foundation
import MaximalTreeKit

/// YouTube's half that needs no window: channels, videos, searches and feeds as
/// nodes, the searches you made as a list to find again, and what is done once
/// the reader has said what they want — a search run, a channel found and put
/// somewhere.
///
/// What a host with no window registers, and the first thing the Mac plugin
/// does. Asking the reader — what to search for, which channel — is the
/// shell's, and so are the player and the comments beside it.
public enum YouTubeCore {
    @MainActor
    public static func register(with registry: CoreRegistry) {
        registerProvider(with: registry)
    }

    /// The same, handing the provider back, so a shell's actions and inspector
    /// resolve channels with the same cache the tree reads from.
    @MainActor @discardableResult
    static func registerProvider(with registry: CoreRegistry) -> YouTubeProvider {
        let provider = YouTubeProvider(broker: registry.broker)
        registry.register(provider: provider)
        YouTubeStore.shared.report(to: registry.notices)

        // What you searched for before, so the one you keep coming back to is
        // a few keystrokes rather than a retyped query. The finder gathers a
        // list when it opens, so this is the list it can offer — a live
        // YouTube search is the search action.
        registry.register(finder: FinderSource(
            id: "youtube.searches", title: "YouTube", prompt: "A search you made before…",
            systemImage: "magnifyingglass", weight: 12
        ) {
            YouTubeStore.shared.recentSearches().map { query in
                FinderItem(id: "youtube:\(query)", title: query, subtitle: "YouTube",
                           systemImage: "magnifyingglass",
                           effect: .open(YouTubeRef.search(query).uri))
            }
        })

        registry.register(action: Action(
            id: "youtube.newFeed",
            title: "New YouTube Feed",
            systemImage: "rectangle.stack.badge.play",
            scope: .workspace,
            run: { ctx in
                ctx.mount(YouTubeRef.aggregator(UUID()).uri)
            }
        ))
        return provider
    }

    /// Search for `query`, once the reader has said what it is. A search is a
    /// place, so it joins the sidebar and can be kept, put in a collection, or
    /// come back to tomorrow. Nothing, for a query that is only space.
    @MainActor
    static func search(_ query: String, in ctx: ActionContext) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        YouTubeStore.shared.remember(search: query)
        let uri = YouTubeRef.search(query).uri
        ctx.mount(uri)
        ctx.host.openURI(uri)
    }

    /// The feed an action is aimed at, if it is aimed at one.
    static func aggregator(in targets: [NodeID]) -> NodeID? {
        targets.first {
            if case .aggregator? = YouTubeRef(uri: $0.uri) { return true }
            return false
        }
    }

    /// Find the channel, and put it where it was asked for: into `aggregator`,
    /// or the sidebar. False when YouTube had no channel for it.
    @MainActor
    static func add(_ input: ChannelInput, into aggregator: NodeID?,
                    in ctx: ActionContext, using provider: YouTubeProvider) async -> Bool {
        guard let channelID = await provider.channelID(for: input),
              let feed = await provider.feed(of: channelID) else { return false }
        let channel = YouTubeProvider.channelNode(feed.channelID, title: feed.title)
        guard let aggregator else {
            ctx.mount(channel.id.uri)
            return true
        }
        // The host checks what the feed accepts against the channel's record,
        // so it has to have one before it is placed.
        ctx.ingest(channel)
        ctx.apply(.adopt([channel.id], into: aggregator, at: nil))
        return true
    }
}
