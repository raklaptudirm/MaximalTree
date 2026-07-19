import Foundation
import SwiftUI
import AppKit
import WebKit
import MaximalTreeKit

// MARK: - Provider

/// Serves `http(s)` pages as nodes. A web node's identity *is* its URL — no custom
/// scheme, since a URL already canonicalizes into a `NodeID` (lowercased scheme,
/// one trailing slash). Pages are leaves: links are followed inside the live view,
/// not modeled as children.
struct WebProvider: NodeProvider {
    let schemes: Set<String> = ["http", "https"]

    func resolve(_ uri: String) -> NodeID? { NodeID(WebProvider.normalize(uri)) }

    func node(for id: NodeID) async -> Node? {
        guard let url = URL(string: id.uri) else { return nil }
        return Node(id: id, type: TypeID("web.page"),
                    label: WebProvider.label(for: url),
                    icon: NodeIcon("globe", tint: .blue))
    }

    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> { Page(items: []) }

    /// The start page a fresh browser node opens at.
    static let homepage = "https://duckduckgo.com"

    /// Turn address-bar input into a loadable URL: a bare domain gains `https://`,
    /// anything word-like becomes a DuckDuckGo search — the same forgiveness a
    /// real address bar offers.
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") { return trimmed }
        if trimmed.contains(".") && !trimmed.contains(" ") { return "https://" + trimmed }
        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return "https://duckduckgo.com/?q=\(query)"
    }

    /// A short label for the sidebar/subtitle: the host, dropping a leading `www.`.
    static func label(for url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - Session store

/// One live browsing session per web node — the channel that lets the inspector
/// and Actions drive the `WKWebView` while the canvas stays content-only (the
/// same pattern as the typst plugin's `TypstUIState`). Sessions persist across
/// navigation so returning to a node keeps its page and history; a small cap
/// keeps stray tabs from piling up web views.
@MainActor
@Observable
final class WebSessionStore {
    static let shared = WebSessionStore()

    private var sessions: [NodeID: WebSession] = [:]
    private var order: [NodeID] = []
    private let limit = 8

    /// The session for `id`, created (and pointed at `id`'s URL) on first use.
    func session(for id: NodeID) -> WebSession {
        if let existing = sessions[id] {
            return existing
        }
        let session = WebSession(homeURL: URL(string: id.uri))
        sessions[id] = session
        order.append(id)
        if order.count > limit, let evicted = order.first {
            order.removeFirst()
            sessions.removeValue(forKey: evicted)
        }
        return session
    }
}

/// Wraps a `WKWebView` and mirrors its navigation state into observable
/// properties (KVO under the hood) so SwiftUI surfaces update as pages load.
@MainActor
@Observable
final class WebSession {
    let webView: WKWebView

    var url: URL?
    var title: String = ""
    var progress: Double = 0
    var isLoading = false
    var canGoBack = false
    var canGoForward = false

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(homeURL: URL?) {
        webView = WKWebView(frame: .zero)
        observe()
        if let homeURL { webView.load(URLRequest(url: homeURL)) }
    }

    /// Load address-bar input (a URL or a search) into this session.
    func load(_ input: String) {
        guard let url = URL(string: WebProvider.normalize(input)) else { return }
        webView.load(URLRequest(url: url))
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    private func observe() {
        observations = [
            webView.observe(\.url, options: [.initial]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.url = view.url }
            },
            webView.observe(\.title, options: [.initial]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title ?? "" }
            },
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.progress = view.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.initial]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.initial]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
        ]
    }
}

// MARK: - Plugin

@objc(WebPlugin)
final class WebPlugin: NSObject, Plugin {
    override init() { super.init() }

    func register(with registry: PluginRegistry) {
        registry.register(provider: WebProvider())

        registry.register(canvas: CanvasContribution(
            priority: 0,
            matches: { $0.type == TypeID("web.page") },
            make: { id, host in AnyView(WebCanvas(nodeID: id).environment(host)) }
        ))
        registry.register(inspector: InspectorContribution(
            matches: { $0.type == TypeID("web.page") },
            make: { id, host in AnyView(WebInspector(nodeID: id).environment(host)) }
        ))

        // Opening a page is a mount: the start page joins the sidebar as a root,
        // and the address bar takes it anywhere from there.
        registry.register(action: Action(
            id: "web.newPage",
            title: "New Web Page",
            systemImage: "globe",
            shortcut: KeyboardShortcut("n", modifiers: [.command, .shift]),
            handler: { ctx in ctx.host.mount(WebProvider.homepage) }
        ))

        // Navigation acts on the live session, so — like the typst buffer ops —
        // it can't be a pure data action; it reaches the session through the
        // shared store. Reload carries a shortcut; back/forward stay unshortcut
        // to avoid colliding with the host's history navigation (⌘[ / ⌘]).
        registry.register(action: Action(
            id: "web.back",
            title: "Web: Back",
            systemImage: "chevron.left",
            appliesTo: .custom { Self.session(in: $0)?.canGoBack ?? false },
            handler: { ctx in Self.session(in: ctx)?.goBack() }
        ))
        registry.register(action: Action(
            id: "web.forward",
            title: "Web: Forward",
            systemImage: "chevron.right",
            appliesTo: .custom { Self.session(in: $0)?.canGoForward ?? false },
            handler: { ctx in Self.session(in: ctx)?.goForward() }
        ))
        registry.register(action: Action(
            id: "web.reload",
            title: "Reload Page",
            systemImage: "arrow.clockwise",
            appliesTo: .type(TypeID("web.page")),
            shortcut: KeyboardShortcut("r", modifiers: .command),
            handler: { ctx in Self.session(in: ctx)?.reload() }
        ))
        registry.register(action: Action(
            id: "web.openExternal",
            title: "Open in Default Browser",
            systemImage: "arrow.up.forward.app",
            appliesTo: .type(TypeID("web.page")),
            handler: { ctx in
                guard let url = Self.session(in: ctx)?.url
                        ?? ctx.selection.first.flatMap({ URL(string: $0.uri) }) else { return }
                NSWorkspace.shared.open(url)
            }
        ))
    }

    /// The live session for the web node an action targets (selection first,
    /// then focus).
    @MainActor
    private static func session(in ctx: ActionContext) -> WebSession? {
        guard let id = ctx.selection.first ?? ctx.focused,
              id.scheme == "http" || id.scheme == "https" else { return nil }
        return WebSessionStore.shared.session(for: id)
    }
}
