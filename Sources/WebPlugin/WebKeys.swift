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
    ///
    /// Everything a page can do is here rather than under a leader group.
    /// These commands need a live page to act on — zooming, bookmarking,
    /// copying the address all mean nothing with a folder selected — and a
    /// leader group is for what works wherever the keyboard happens to be.
    /// So the surface that has the page declares them, and they are bare keys
    /// while you are reading rather than three-key sequences.
    static var keys: [SurfaceKey] {
        scrolling.map { SurfaceKey($0.key, $0.id) }
            + [SurfaceKey("H", "web.back"),
               SurfaceKey("L", "web.forward"),
               SurfaceKey("r", "web.reload"),
               // Repeating a search is what you do most while reading, so it
               // gets a bare key rather than a leader sequence.
               SurfaceKey("n", "web.findNext"),
               SurfaceKey("N", "web.findPrevious"),
               // Going elsewhere, and taking the page with you.
               SurfaceKey("l", "web.openLocation"),
               SurfaceKey("o", "web.openExternal"),
               SurfaceKey("y", "web.copyURL"),
               SurfaceKey("b", "web.bookmark"),
               // Zoom under `z`, the spelling every vim-flavoured browser
               // uses, which keeps the digits and signs free.
               SurfaceKey("z i", "web.zoomIn"),
               SurfaceKey("z o", "web.zoomOut"),
               SurfaceKey("z 0", "web.zoomReset")]
    }

    /// The session a node stands for, if it has one.
    static func session(for targets: [NodeID]) -> WebSession? {
        targets.compactMap { WebSessionStore.shared.existingSession(for: $0) }.first
    }

    /// Reading a page: what you do to it that isn't going somewhere else.
    static func registerReading(with registry: PluginRegistry) {
        let applies = ActionPredicate.custom { session(for: $0.targets) != nil }

        registry.register(action: Action(
            id: "web.findNext", title: "Find Next", systemImage: "chevron.down",
            appliesTo: .custom { ctx in
                guard let session = session(for: ctx.targets) else { return false }
                return !session.searchText.isEmpty
            },
            scope: .document, surfaces: [.palette]
        ) { ctx in
            guard let session = session(for: ctx.targets) else { return }
            session.find(session.searchText, forward: true)
        })

        registry.register(action: Action(
            id: "web.findPrevious", title: "Find Previous", systemImage: "chevron.up",
            appliesTo: .custom { ctx in
                guard let session = session(for: ctx.targets) else { return false }
                return !session.searchText.isEmpty
            },
            scope: .document, surfaces: [.palette]
        ) { ctx in
            guard let session = session(for: ctx.targets) else { return }
            session.find(session.searchText, forward: false)
        })

        for (id, title, image, step) in [
            ("web.zoomIn", "Zoom In", "plus.magnifyingglass", 0.1),
            ("web.zoomOut", "Zoom Out", "minus.magnifyingglass", -0.1),
        ] as [(String, String, String, CGFloat)] {
            registry.register(action: Action(
                id: id, title: title, systemImage: image, appliesTo: applies,
                scope: .document
            ) { ctx in
                session(for: ctx.targets)?.zoom(by: step)
            })
        }

        registry.register(action: Action(
            id: "web.zoomReset", title: "Actual Size", systemImage: "1.magnifyingglass",
            appliesTo: applies, scope: .document
        ) { ctx in
            session(for: ctx.targets)?.resetZoom()
        })

        registry.register(action: Action(
            id: "web.copyURL", title: "Copy Address", systemImage: "doc.on.doc",
            appliesTo: .custom { session(for: $0.targets)?.url != nil }, scope: .document
        ) { ctx in
            guard let url = session(for: ctx.targets)?.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        })
    }

    static func register(with registry: PluginRegistry) {
        registerReading(with: registry)
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
