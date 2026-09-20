import AppKit
import SwiftUI
import MaximalTreeKit

/// What you can do to a running terminal.
///
/// Most of these are libghostty's own binding actions, named rather than
/// reimplemented — clearing a screen and resizing a font are the terminal's
/// business and it already knows how. The names are checked against the
/// shipped binary, and one it doesn't recognise is logged rather than being a
/// command that silently does nothing.
@MainActor
enum TerminalActions {
    /// The session a node stands for, if it is still running.
    static func session(for targets: [NodeID]) -> TerminalSession? {
        targets.compactMap { TerminalSessions.shared.session(for: $0) }.first
    }

    /// Whether these targets name a live terminal — which is what every one of
    /// these needs, and what makes them absent everywhere else.
    static func isLiveSession(_ ctx: ActionContext) -> Bool {
        session(for: ctx.targets) != nil
    }

    /// Ask the terminal to do one of its own actions.
    static func perform(_ action: String, on ctx: ActionContext) {
        session(for: ctx.targets)?.view.perform(action: action)
    }

    /// Moving the scrollback — the one thing a terminal claims for itself in
    /// a commanding mode. It swallows every key while you type at it, but
    /// there the app's bindings are what you want, and nothing else can move
    /// its scrollback.
    ///
    /// Actions like any other, so they are listed, rebindable and callable by
    /// name; the keys that run them are declared on the canvas below.
    static let scrolling: [(id: String, title: String, key: String, action: String)] = [
        ("terminal.scrollDown", "Scroll Down", "j", "scroll_page_lines:1"),
        ("terminal.scrollUp", "Scroll Up", "k", "scroll_page_lines:-1"),
        ("terminal.scrollHalfDown", "Half Page Down", "d", "scroll_page_fractional:0.5"),
        ("terminal.scrollHalfUp", "Half Page Up", "u", "scroll_page_fractional:-0.5"),
        ("terminal.scrollTop", "Top of Scrollback", "g g", "scroll_to_top"),
        ("terminal.scrollBottom", "Bottom of Scrollback", "G", "scroll_to_bottom"),
    ]

    /// The keys a terminal claims while it has the keyboard.
    ///
    /// All of it is here rather than under a leader group: clearing a screen,
    /// resizing its text, asking where it is — none of it means anything with
    /// a folder selected, and a leader group is for what works wherever the
    /// keyboard happens to be. A terminal spends most of its life in insert
    /// mode, so these are what `ESC` gets you, which is the same bargain its
    /// scrollback keys already made.
    static var keys: [SurfaceKey] {
        scrolling.map { SurfaceKey($0.key, $0.id) }
            + [SurfaceKey("c", "terminal.clear"),
               SurfaceKey("r", "terminal.restart"),
               SurfaceKey("R", "terminal.reset"),
               // Where it is, as a place you can go, copy, or reveal.
               SurfaceKey("o", "terminal.openDirectory"),
               SurfaceKey("y", "terminal.copyDirectory"),
               SurfaceKey("f", "terminal.revealDirectory"),
               // Another shell in the same directory, which is the one you
               // want often enough to be a single key.
               SurfaceKey("n", "terminal.newHere"),
               // Capital, like every other key that throws something away:
               // never the neighbour of one you were reaching for.
               SurfaceKey("X", "terminal.close"),
               // Text size under `z`, the same place a page keeps its zoom.
               SurfaceKey("z i", "terminal.fontBigger"),
               SurfaceKey("z o", "terminal.fontSmaller"),
               SurfaceKey("z 0", "terminal.fontReset")]
    }

    /// The actions that are a straight hand-off to libghostty.
    ///
    /// Clearing a screen and resizing a font are the terminal's business and
    /// it already knows how; naming its actions beats reimplementing them.
    /// Every name here was checked against the shipped binary — one it does
    /// not recognise is a command that silently does nothing, so the mapping
    /// is stated in one place and pinned by a test.
    static let passthrough: [(id: String, title: String, image: String, action: String)] = [
        ("terminal.clear", "Clear Screen", "eraser", "clear_screen"),
        ("terminal.reset", "Reset Terminal", "arrow.counterclockwise", "reset"),
        ("terminal.copy", "Copy Selection", "doc.on.doc", "copy_to_clipboard"),
        ("terminal.paste", "Paste", "doc.on.clipboard", "paste_from_clipboard"),
        ("terminal.selectAll", "Select All", "selection.pin.in.out", "select_all"),
        ("terminal.fontBigger", "Bigger Text", "textformat.size.larger",
         "increase_font_size:1"),
        ("terminal.fontSmaller", "Smaller Text", "textformat.size.smaller",
         "decrease_font_size:1"),
        ("terminal.fontReset", "Reset Text Size", "textformat.size", "reset_font_size"),
    ]
}

extension TerminalPlugin {
    @MainActor
    func registerSessionActions(with registry: PluginRegistry) {
        for item in TerminalActions.scrolling {
            registry.register(action: Action(
                id: item.id, title: item.title, systemImage: "scroll",
                appliesTo: .custom { TerminalActions.isLiveSession($0) },
                // Not in any menu: forty motions would bury the handful of
                // things that belong there. Searchable, and bound to a key.
                scope: .document, surfaces: [.palette]
            ) { ctx in
                TerminalActions.perform(item.action, on: ctx)
            })
        }

        for item in TerminalActions.passthrough {
            registry.register(action: Action(
                id: item.id, title: item.title, systemImage: item.image,
                appliesTo: .custom { TerminalActions.isLiveSession($0) },
                scope: .document
            ) { ctx in
                TerminalActions.perform(item.action, on: ctx)
            })
        }

        // MARK: Its directory, as a place

        registry.register(action: Action(
            id: "terminal.copyDirectory", title: "Copy Working Directory",
            systemImage: "doc.on.doc",
            appliesTo: .custom { TerminalActions.isLiveSession($0) }, scope: .document
        ) { ctx in
            guard let session = TerminalActions.session(for: ctx.targets) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.directory, forType: .string)
        })

        /// Opens the shell's directory as what it is — a place the FileSystem
        /// plugin owns. The terminal has always known where it is; this is the
        /// way to get there without typing the path again.
        registry.register(action: Action(
            id: "terminal.openDirectory", title: "Open Working Directory",
            systemImage: "folder",
            appliesTo: .custom { TerminalActions.isLiveSession($0) }, scope: .document
        ) { ctx in
            guard let session = TerminalActions.session(for: ctx.targets) else { return }
            ctx.host.openURI(URL(fileURLWithPath: session.directory).absoluteString)
        })

        registry.register(action: Action(
            id: "terminal.revealDirectory", title: "Reveal Working Directory in Finder",
            systemImage: "magnifyingglass",
            appliesTo: .custom { TerminalActions.isLiveSession($0) }, scope: .document
        ) { ctx in
            guard let session = TerminalActions.session(for: ctx.targets) else { return }
            NSWorkspace.shared.activateFileViewerSelecting(
                [URL(fileURLWithPath: session.directory)])
        })

        // MARK: Starting over

        /// A shell that has wedged, or one whose environment has moved on.
        /// Closing and starting again in the same directory is what a person
        /// does by hand; this is that, in one step.
        registry.register(action: Action(
            id: "terminal.restart", title: "Restart Shell",
            systemImage: "arrow.clockwise",
            appliesTo: .custom { TerminalActions.isLiveSession($0) }, scope: .document
        ) { ctx in
            guard let session = TerminalActions.session(for: ctx.targets) else { return }
            let directory = session.directory
            TerminalSessions.shared.close(session.id)
            let fresh = TerminalSessions.shared.create(directory: directory)
            ctx.notify([.childrenChanged(TerminalRef.sessionsID)])
            ctx.host.openURI(fresh.id.uri)
        })
    }
}
