import Foundation
import MaximalTreeKit

/// The web's half that needs no window: pages and bookmarks as nodes, the
/// bookmarks as a list to search, and what can be done to them without a
/// page open — mounting one, showing the bookmarks, removing one.
///
/// What a host with no window registers, and the first thing the Mac plugin
/// does. Everything that reaches into a live page — back, reload, bookmarking
/// it under the title it gives itself — is the shell's, since only a shell has
/// a page open.
public enum WebCore {
    /// The core half alone: pages named after their URLs, since nothing here
    /// has a page open.
    @MainActor
    public static func register(with registry: CoreRegistry) {
        register(with: registry, provider: WebProvider())
    }

    /// With a provider a shell has told where its open pages are.
    @MainActor
    static func register(with registry: CoreRegistry, provider: WebProvider) {
        registry.register(provider: provider)
        BookmarkStore.shared.report(to: registry.notices)

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

        // Opening a page is a mount: the start page joins the sidebar as a root,
        // and the address bar / ⌘L take it anywhere from there.
        registry.register(action: Action(
            id: "web.newPage",
            title: "New Web Page",
            systemImage: "globe",
            shortcut: KeyChord("n", command: true, shift: true),
            scope: .workspace,
            run: { ctx in
                ctx.mount(WebProvider.homepage)
                ctx.host.openURI(WebProvider.homepage)
            }
        ))

        // Bookmarks: real nodes under web://bookmarks, persisted across runs.
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
    }
}
