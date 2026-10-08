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
        let provider = YouTubeCore.registerProvider(with: registry)
        Self.provider = provider

        registry.registerCanvas(forType: TypeID("youtube.video")) { id, _ in
            AnyView(YouTubeVideoCanvas(url: YouTubeRef(uri: id.uri)?.webURL))
        }

        // What people said about it, beside it rather than under it — the
        // canvas is the video, and comments are something you glance at.
        registry.registerInspector(forType: TypeID("youtube.video")) { id, _ in
            AnyView(CommentsSection(video: id, comments: { video, after in
                await Self.provider?.comments(of: video, after: after) ?? CommentPage()
            }))
        }

        registry.register(action: Action(
            id: "youtube.search",
            title: "Search YouTube…",
            systemImage: "magnifyingglass",
            scope: .workspace,
            run: { ctx in
                guard let query = Self.ask("Search YouTube", detail: "What to look for.",
                                           confirm: "Search", placeholder: "swift concurrency")
                else { return }
                YouTubeCore.search(query, in: ctx)
            }
        ))

        registry.register(action: Action(
            id: "youtube.addChannel",
            title: "Add YouTube Channel…",
            systemImage: "person.crop.square.badge.plus",
            scope: .workspace,
            run: { ctx in
                // Into the feed you are on, if you are on one; else the sidebar.
                let aggregator = YouTubeCore.aggregator(in: ctx.targets)
                guard let text = Self.ask("Add YouTube Channel",
                                          detail: aggregator == nil
                                              ? "A channel link, its @handle, or its id."
                                              : "A channel link, its @handle, or its id, to add to this feed."),
                      let input = ChannelInput(text) else { return }
                Task { @MainActor in
                    guard let provider = Self.provider,
                          await YouTubeCore.add(input, into: aggregator, in: ctx, using: provider)
                    else {
                        Self.tell("Couldn't find that channel",
                                  detail: "YouTube didn't answer with a channel for it. "
                                      + "Check the link or handle and try again.")
                        return
                    }
                }
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
            run: { ctx in
                for url in ctx.targets.compactMap({ YouTubeRef(uri: $0.uri)?.webURL }) {
                    NSWorkspace.shared.open(url)
                }
            }
        ))
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

// MARK: - What people said

/// A video's comments, fetched when the inspector shows them and not before.
private struct CommentsSection: View {
    let video: NodeID
    let comments: @Sendable (String, String?) async -> CommentPage

    @State private var loaded: [CommentItem] = []
    @State private var continuation: String?
    @State private var loading = true

    var body: some View {
        Section("Comments") {
            if loading && loaded.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else if loaded.isEmpty {
                Text("None to show.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(loaded) { comment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comment.author).font(.caption.weight(.medium))
                        Text(comment.text).font(.callout).textSelection(.enabled)
                        if let line = Self.line(of: comment) {
                            Text(line).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                if continuation != nil {
                    Button("Show More") { Task { await load() } }
                        .buttonStyle(.link)
                        .disabled(loading)
                }
            }
        }
        .task(id: video) {
            loaded = []
            continuation = nil
            await load()
        }
    }

    private static func line(of comment: CommentItem) -> String? {
        let parts = [comment.published,
                     comment.likes.map { "\($0) likes" },
                     comment.replies.map { "\($0) replies" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load() async {
        guard let id = YouTubeRef(uri: video.uri), case .video(let videoID) = id else {
            loading = false
            return
        }
        loading = true
        let page = await comments(videoID, continuation)
        loaded += page.comments
        continuation = page.continuation
        loading = false
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
