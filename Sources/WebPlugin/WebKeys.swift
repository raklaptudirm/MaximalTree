import AppKit
import WebKit
import MaximalTreeKit

/// The page's own keys, as actions.
///
/// Scrolling goes through JavaScript because macOS `WKWebView` keeps its
/// scroll view to itself — and because `window.scrollBy` respects the page's
/// inner scrollers and its scroll-behaviour, where nudging a scroll view
/// would not.
///
/// These were a `WKWebView` subclass implementing `handleKey`, which is why
/// the subclass existed at all. Now the core resolves the key and runs the
/// action, so a plain web view will do and the keys are rebindable, listable
/// and callable by name like everything else.
@MainActor
enum WebKeys {
    /// A line, and most of a screen — the amounts every vim-flavoured browser
    /// extension settled on.
    private static let line = 64
    private static let halfPage = "window.innerHeight / 2"

    /// id, title, the key that runs it, and what it does to the page.
    static let scrolling: [(id: String, title: String, key: String, script: String)] = [
        ("web.scrollDown", "Scroll Down", "j", "window.scrollBy(0, \(line))"),
        ("web.scrollUp", "Scroll Up", "k", "window.scrollBy(0, -\(line))"),
        ("web.halfPageDown", "Half Page Down", "d", "window.scrollBy(0, \(halfPage))"),
        ("web.halfPageUp", "Half Page Up", "u", "window.scrollBy(0, -(\(halfPage)))"),
        ("web.top", "Top of Page", "g g", "window.scrollTo(0, 0)"),
        ("web.bottom", "Bottom of Page", "G", "window.scrollTo(0, document.body.scrollHeight)"),
    ]

    /// The keys the page claims, for its canvas contribution to declare.
    static var keys: [SurfaceKey] {
        scrolling.map { SurfaceKey($0.key, $0.id) }
            + [SurfaceKey("H", "web.back"),
               SurfaceKey("L", "web.forward"),
               SurfaceKey("r", "web.reload")]
    }

    /// The session a node stands for, if it has one.
    static func session(for targets: [NodeID]) -> WebSession? {
        targets.compactMap { WebSessionStore.shared.existingSession(for: $0) }.first
    }

    static func register(with registry: PluginRegistry) {
        for item in scrolling {
            registry.register(action: Action(
                id: item.id, title: item.title, systemImage: "scroll",
                appliesTo: .custom { session(for: $0.targets) != nil },
                // Searchable and bindable, but not in a menu: a page's
                // scrolling is not something anyone goes to the menu bar for.
                scope: .document, surfaces: [.palette]
            ) { ctx in
                session(for: ctx.targets)?.webView.evaluateJavaScript(item.script)
            })
        }
    }
}
