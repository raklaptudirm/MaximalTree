import Foundation
import SwiftUI
import AppKit
import WebKit
import MaximalTreeKit

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

    /// Favicon PNGs by host, fetched once per host per run.
    @ObservationIgnored private var favicons: [String: Data?] = [:]

    /// The session for `id` if it already has one, without making one.
    ///
    /// An action's predicate must not create a web view as a side effect of
    /// asking whether it applies: the finder asks about every action every
    /// time it is opened, and that would start a browser session for each page
    /// in the list.
    func existingSession(for id: NodeID) -> WebSession? { sessions[id] }

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

    /// The favicon for `host`: the one we already have, else
    /// `https://host/favicon.ico`, fetched once per host per run.
    /// Nil (cached) when the host has none — the globe fallback stays.
    ///
    /// A successful fetch is written through to `FaviconStore`, which is what
    /// makes the icon survive a relaunch: the provider serves it from there
    /// with no page open and no network.
    func favicon(for host: String) async -> Data? {
        if let cached = favicons[host] { return cached }
        if let stored = FaviconStore.shared.icon(for: host) {
            favicons[host] = stored
            return stored
        }
        favicons[host] = .some(nil)   // one fetch per host, even on failure
        guard let url = URL(string: "https://\(host)/favicon.ico") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              NSImage(data: data) != nil   // must actually decode
        else { return nil }
        favicons[host] = data
        FaviconStore.shared.store(data, for: host)
        return data
    }
}

// MARK: - Session

/// Wraps a `WKWebView` and mirrors its navigation state into observable
/// properties (KVO under the hood) so SwiftUI surfaces update as pages load.
/// Also the web view's delegates: popups open in place, and load failures
/// surface as an observable message instead of a silently blank view.
@MainActor
@Observable
final class WebSession: NSObject {
    let webView: WKWebView

    var url: URL?
    var title: String = ""
    var progress: Double = 0
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    /// The last navigation failure, cleared when a new load starts.
    var loadError: String?

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(homeURL: URL?) {
        webView = WKWebView(frame: .zero)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observe()
        if let homeURL { webView.load(URLRequest(url: homeURL)) }
    }

    /// Load address-bar input (a URL or a search) into this session.
    func load(_ input: String) {
        guard let url = URL(string: WebProvider.normalize(input)) else { return }
        webView.load(URLRequest(url: url))
    }

    /// What was last searched for, and how it went.
    ///
    /// Kept on the session rather than in the inspector's view state: the
    /// search outlives the view, and an action has to be able to reach it.
    var searchText = ""
    var searchFoundNothing = false

    /// Find the next match, wrapping at the end the way a browser does.
    func find(_ text: String, forward: Bool = true) {
        searchText = text
        guard !text.isEmpty else {
            searchFoundNothing = false
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(text, configuration: configuration) { [weak self] result in
            MainActor.assumeIsolated { self?.searchFoundNothing = !result.matchFound }
        }
    }

    /// How big the page is drawn, clamped: past these the page stops being
    /// readable in either direction.
    func zoom(by step: CGFloat) {
        webView.pageZoom = min(max(webView.pageZoom + step, 0.5), 3.0)
    }

    func resetZoom() { webView.pageZoom = 1 }

    /// How big the page is drawn, as a percentage — which is how a browser
    /// says it and how anyone reading it thinks of it.
    var zoomPercent: Int { Int((webView.pageZoom * 100).rounded()) }

    /// Whether the page came over a connection that was actually secure.
    var isSecure: Bool { webView.hasOnlySecureContent }

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

extension WebSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        // Cancellations (a new load superseding, a policy handoff) aren't failures.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled),
              !(nsError.domain == "WebKitErrorDomain" && nsError.code == 102)
        else { return }
        loadError = nsError.localizedDescription
    }
}

extension WebSession: WKUIDelegate {
    /// Pages that target new windows (popups, `target="_blank"`) load in place —
    /// one node, one view. Returning nil tells WebKit we handled it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

// MARK: - UI state

/// The channel for controls that live outside the canvas (the Open Location
/// action) to reach it.
@MainActor
@Observable
final class WebUIState {
    static let shared = WebUIState()
    /// Set by "Open Location…" — the canvas for this node presents its prompt.
    var locationPromptTarget: NodeID?
}

// MARK: - Plugin

@objc(WebPlugin)
final class WebPlugin: NSObject, Plugin {
    override init() { super.init() }

    func register(with registry: PluginRegistry) {
        registry.register(provider: WebProvider())
        WebKeys.register(with: registry)

        registry.register(canvas: CanvasContribution(
            priority: 0,
            matches: { $0.type == TypeID("web.page") },
            // Declared on the contribution so the canvas that draws is the
            // canvas whose keys apply.
            keys: WebKeys.keys,
            make: { id, host in AnyView(WebCanvas(nodeID: id).environment(host)) }
        ))
        registry.register(inspector: InspectorContribution(
            matches: { $0.type == TypeID("web.page") },
            make: { id, host in AnyView(WebInspector(nodeID: id).environment(host)) }
        ))

        // Opening a page is a mount: the start page joins the sidebar as a root,
        // and the address bar / ⌘L take it anywhere from there.
        // Bookmarks are a list worth searching, so the finder can offer them
        // beside files and everything else — the plugin that owns them says so.
        registry.register(finder: FinderSource(
            id: "web.bookmarks", title: "Bookmark", prompt: "Open a bookmark…",
            systemImage: "bookmark", weight: 14
        ) {
            BookmarkStore.shared.all().map { bookmark in
                FinderItem(id: "bookmark:\(bookmark.url)",
                           title: bookmark.title.isEmpty ? bookmark.url : bookmark.title,
                           subtitle: URL(string: bookmark.url)?.host(),
                           systemImage: "bookmark",
                           effect: .open(bookmark.url))
            }
        })

        registry.register(action: Action(
            id: "web.newPage",
            title: "New Web Page",
            systemImage: "globe",
            shortcut: KeyboardShortcut("n", modifiers: [.command, .shift]),
            scope: .workspace,
            run: { ctx in
                ctx.mount(WebProvider.homepage)
                ctx.host.openURI(WebProvider.homepage)
            }
        ))

        registry.register(action: Action(
            id: "web.openLocation",
            title: "Open Location…",
            systemImage: "link",
            appliesTo: .type(TypeID("web.page")),
            shortcut: KeyboardShortcut("l", modifiers: .command),
            scope: .workspace,
            run: { ctx in
                guard let id = ctx.selection.first ?? ctx.focused else { return }
                WebUIState.shared.locationPromptTarget = id
            }
        ))

        // Bookmarks: real nodes under web://bookmarks, persisted across runs.
        registry.register(action: Action(
            id: "web.bookmark",
            title: "Bookmark This Page",
            systemImage: "star",
            appliesTo: .type(TypeID("web.page")),
            shortcut: KeyboardShortcut("d", modifiers: .command),
            scope: .document,
            run: { ctx in
                guard let session = Self.session(in: ctx),
                      let url = session.url else { return }
                let title = session.title.isEmpty
                    ? WebProvider.label(for: url) : session.title
                BookmarkStore.shared.add(url: url.absoluteString, title: title)
                ctx.notify([.modified(WebProvider.bookmarksID),
                                 .childrenChanged(WebProvider.bookmarksID)])
            }
        ))
        registry.register(action: Action(
            id: "web.unbookmark",
            title: "Remove Bookmark",
            systemImage: "star.slash",
            appliesTo: .custom { ctx in
                guard let id = ctx.targets.first else { return false }
                return BookmarkStore.shared.contains(id.uri)
            },
            scope: .document,
            run: { ctx in
                for id in ctx.targets { BookmarkStore.shared.remove(url: id.uri) }
                ctx.notify([.modified(WebProvider.bookmarksID),
                                 .childrenChanged(WebProvider.bookmarksID)])
            }
        ))
        registry.register(action: Action(
            id: "web.showBookmarks",
            title: "Show Bookmarks",
            systemImage: "star.fill",
            scope: .workspace,
            run: { ctx in
                ctx.mount(WebProvider.bookmarksURI)
                ctx.host.openURI(WebProvider.bookmarksURI)
            }
        ))

        // Navigation acts on the live session, so — like the typst buffer ops —
        // it reaches the session through the shared store. Back/forward stay
        // unshortcut to avoid colliding with the host's history nav (⌘[ / ⌘]).
        registry.register(action: Action(
            id: "web.back",
            title: "Web: Back",
            systemImage: "chevron.left",
            appliesTo: .custom { Self.session(in: $0)?.canGoBack ?? false },
            scope: .document,
            run: { ctx in Self.session(in: ctx)?.goBack() }
        ))
        registry.register(action: Action(
            id: "web.forward",
            title: "Web: Forward",
            systemImage: "chevron.right",
            appliesTo: .custom { Self.session(in: $0)?.canGoForward ?? false },
            scope: .document,
            run: { ctx in Self.session(in: ctx)?.goForward() }
        ))
        registry.register(action: Action(
            id: "web.reload",
            title: "Reload Page",
            systemImage: "arrow.clockwise",
            appliesTo: .type(TypeID("web.page")),
            shortcut: KeyboardShortcut("r", modifiers: .command),
            scope: .document,
            run: { ctx in Self.session(in: ctx)?.reload() }
        ))
        registry.register(action: Action(
            id: "web.openExternal",
            title: "Open in Default Browser",
            systemImage: "arrow.up.forward.app",
            appliesTo: .type(TypeID("web.page")),
            scope: .document,
            run: { ctx in
                guard let url = Self.session(in: ctx)?.url
                        ?? ctx.selection.first.flatMap({ URL(string: $0.uri) }) else { return }
                NSWorkspace.shared.open(url)
            }
        ))
    }

    /// The live session for the web node an action targets (selection first,
    /// then focus). Never *creates* one for a page that isn't open.
    ///
    /// It used to, despite saying otherwise: `session(for:)` makes a session
    /// on first use, and this is called from predicates. Asking whether an
    /// action applies would start a browser session, and the finder asks about
    /// every action every time it opens.
    @MainActor
    private static func session(in ctx: ActionContext) -> WebSession? {
        guard let id = ctx.selection.first ?? ctx.focused,
              id.scheme == "http" || id.scheme == "https" else { return nil }
        return WebSessionStore.shared.existingSession(for: id)
    }
}
