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
            ctx.host.notify([.childrenChanged(TerminalRef.sessionsID)])
            ctx.host.openURI(fresh.id.uri)
        })
    }
}
