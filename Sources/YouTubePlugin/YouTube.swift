import AppKit
import SwiftUI
import WebKit
import MaximalTreeKit

/// YouTube, without an account or a key: channels and their latest videos, read
/// from the public feed each channel publishes, and feeds made of channels.
///
/// A feed is the proving case for placing. Its aggregator takes channels —
/// dropped on it, or added to it here — the host keeps which, and the feed
/// lists all their videos newest first in the contents column.
@objc(YouTubePlugin)
final class YouTubePlugin: NSObject, Plugin {
    override init() { super.init() }

    /// The one provider, so the actions can resolve channels with the same
    /// cache the tree reads from.
    private nonisolated(unsafe) static var provider: YouTubeProvider?

    func register(with registry: PluginRegistry) {
        let provider = YouTubeProvider(broker: registry.broker)
        Self.provider = provider
        registry.register(provider: provider)

        registry.registerCanvas(forType: TypeID("youtube.video")) { id, _ in
            AnyView(YouTubeVideoCanvas(url: YouTubeRef(uri: id.uri)?.webURL))
        }

        // What you searched for before, so the one you keep coming back to is
        // a few keystrokes rather than a retyped query. The finder gathers a
        // list when it opens, so this is the list it can offer — a live
        // YouTube search is the action below.
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
            id: "youtube.search",
            title: "Search YouTube…",
            systemImage: "magnifyingglass",
            scope: .workspace,
            handler: { ctx in
                guard let query = Self.ask("Search YouTube", detail: "What to look for.",
                                           confirm: "Search", placeholder: "swift concurrency"),
                      !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                YouTubeStore.shared.remember(search: query)
                // A search is a place, so it joins the sidebar and can be kept,
                // put in a collection, or come back to tomorrow.
                let uri = YouTubeRef.search(query).uri
                ctx.host.mount(uri)
                ctx.host.openURI(uri)
            }
        ))

        registry.register(action: Action(
            id: "youtube.newFeed",
            title: "New YouTube Feed",
            systemImage: "rectangle.stack.badge.play",
            scope: .workspace,
            handler: { ctx in
                ctx.host.mount(YouTubeRef.aggregator(UUID(), name: "YouTube Feed").uri)
            }
        ))

        registry.register(action: Action(
            id: "youtube.addChannel",
            title: "Add YouTube Channel…",
            systemImage: "person.crop.square.badge.plus",
            scope: .workspace,
            handler: { ctx in
                // Into the feed you are on, if you are on one; else the sidebar.
                let aggregator = ctx.targets.first {
                    if case .aggregator? = YouTubeRef(uri: $0.uri) { return true }
                    return false
                }
                guard let text = Self.ask("Add YouTube Channel",
                                          detail: aggregator == nil
                                              ? "A channel link, its @handle, or its id."
                                              : "A channel link, its @handle, or its id, to add to this feed."),
                      let input = ChannelInput(text) else { return }
                Task { @MainActor in await Self.add(input, into: aggregator, host: ctx.host) }
            }
        ))

        registry.register(action: Action(
            id: "youtube.open",
            title: "Open on YouTube",
            systemImage: "safari",
            appliesTo: .custom { ctx in
                !ctx.targets.isEmpty && ctx.targets.allSatisfy { YouTubeRef(uri: $0.uri)?.webURL != nil }
            },
            scope: .node,
            handler: { ctx in
                for url in ctx.targets.compactMap({ YouTubeRef(uri: $0.uri)?.webURL }) {
                    NSWorkspace.shared.open(url)
                }
            }
        ))
    }

    /// Find the channel, and put it where it was asked for.
    @MainActor
    private static func add(_ input: ChannelInput, into aggregator: NodeID?, host: HostContext) async {
        guard let provider,
              let channelID = await provider.channelID(for: input),
              let feed = await provider.feed(of: channelID) else {
            tell("Couldn't find that channel",
                 detail: "YouTube didn't answer with a channel for it. Check the link or handle and try again.")
            return
        }
        let channel = YouTubeProvider.channelNode(feed.channelID, title: feed.title)
        guard let aggregator else {
            host.mount(channel.id.uri)
            return
        }
        // The host checks what the feed accepts against the channel's record,
        // so it has to have one before it is placed.
        host._ingest(channel)
        host.apply(.adopt([channel.id], into: aggregator, at: nil))
    }

    @MainActor
    private static func ask(_ title: String, detail: String, confirm: String = "Add",
                            placeholder: String = "https://www.youtube.com/@handle") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @MainActor
    private static func tell(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}

// MARK: - Watching

/// A video, played on its own page.
private struct YouTubeVideoCanvas: View {
    let url: URL?

    var body: some View {
        if let url {
            VideoPage(url: url)
        } else {
            ContentUnavailableView("No Video", systemImage: "play.rectangle")
        }
    }
}

private struct VideoPage: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard view.url?.absoluteString.contains(url.query ?? url.path) != true else { return }
        view.load(URLRequest(url: url))
    }
}
