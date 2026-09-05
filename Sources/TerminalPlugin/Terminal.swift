import SwiftUI
import MaximalTreeKit

/// Terminals as nodes: a container holding every live one, and a node per
/// surface.
///
/// A surface is a running shell, so its node exists exactly as long as it
/// does. Nothing is persisted and nothing is resurrected — a session node
/// from a previous run resolves to nothing, which is the honest answer.
struct TerminalProvider: NodeProvider {
    let schemes: Set<String> = ["terminal"]

    func resolve(_ uri: String) -> NodeID? {
        guard let id = NodeID(uri), id.scheme == "terminal" else { return nil }
        return id
    }

    @MainActor
    func node(for id: NodeID) async -> Node? {
        if id == TerminalRef.sessionsID {
            return Node(id: id, type: TypeID("terminal.sessions"),
                        label: "Terminals",
                        icon: NodeIcon("apple.terminal", tint: .secondary),
                        hasChildren: !TerminalSessions.shared.ordered.isEmpty)
        }
        guard TerminalRef.isSession(id) else { return nil }
        // Not in the store: either this is the first look at a node the
        // workspace remembered from a previous run, or the terminal was
        // closed. The uri carries the directory, so the first case can be put
        // back — no shell starts until it is shown.
        let session = TerminalSessions.shared.session(for: id)
            ?? TerminalRef.directory(of: id).map {
                TerminalSessions.shared.restore(id: id, directory: $0)
            }
        guard let session else { return nil }
        var attributes = Attributes()
        attributes["directory"] = .string(session.directory)
        attributes["started"] = .date(session.created)
        return Node(id: id, type: TypeID("terminal.session"),
                    label: session.label,
                    icon: NodeIcon("apple.terminal", tint: .green),
                    attributes: attributes)
    }

    @MainActor
    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        guard id == TerminalRef.sessionsID else { return Page(items: []) }
        var items: [Node] = []
        for sessionID in TerminalSessions.shared.ordered {
            if let node = await node(for: sessionID) { items.append(node) }
        }
        return Page(items: items)
    }

    @MainActor
    func related(to id: NodeID) async -> [Related] {
        guard let session = TerminalSessions.shared.session(for: id) else { return [] }
        // The shell's directory is a real place the FileSystem plugin owns.
        return [Related(label: "working directory",
                        target: URL(fileURLWithPath: session.directory).absoluteString)]
    }
}

@objc(TerminalPlugin)
final class TerminalPlugin: NSObject, Plugin {
    override init() { super.init() }

    func register(with registry: PluginRegistry) {
        registry.register(provider: TerminalProvider())
        registerSessionActions(with: registry)
        registry.register(inspector: InspectorContribution(
            matches: { $0.type == TypeID("terminal.session") }) { id, host in
                AnyView(TerminalInspector(nodeID: id).environment(host))
        })

        registry.register(canvas: CanvasContribution(
            priority: 0,
            matches: { $0.type == TypeID("terminal.session") }
        ) { id, host in
            TerminalSessions.shared.host = host
            guard let session = TerminalSessions.shared.session(for: id) else {
                return AnyView(ContentUnavailableView(
                    "Terminal Closed", systemImage: "apple.terminal",
                    description: Text("This shell has exited.")))
            }
            return AnyView(TerminalCanvas(session: session)
                .environment(host)
                // A terminal is work from the moment it exists — nothing has
                // to be typed into it first — so its tab is never a preview
                // that the next thing opened can take over. Done here rather
                // than at creation because the tab has to exist to be pinned.
                .onAppear { host.pin(id) })
        })

        // Opening a folder's terminal makes a *new* one every time: two
        // terminals in the same directory are two different things.
        registry.register(action: Action(
            id: "terminal.openHere",
            title: "Open Terminal Here",
            systemImage: "apple.terminal",
            appliesTo: .type(TypeID("file.directory")),
            scope: .container,
            handler: { ctx in
                TerminalPlugin.spawn(from: ctx)
            }
        ))

        // Inherits the directory of whatever you're looking at: another
        // terminal's live cwd, or the folder beside the selected file.
        registry.register(action: Action(
            id: "terminal.new",
            title: "New Terminal",
            systemImage: "apple.terminal",
            shortcut: KeyboardShortcut("t", modifiers: [.command, .control]),
            scope: .workspace,
            handler: { ctx in
                TerminalPlugin.spawn(from: ctx)
            }
        ))

        // The same thing from a terminal's own menu, where "here" is
        // unambiguous: this shell's current directory.
        registry.register(action: Action(
            id: "terminal.newHere",
            title: "New Terminal in This Directory",
            systemImage: "apple.terminal",
            appliesTo: .type(TypeID("terminal.session")),
            scope: .node,
            handler: { ctx in
                TerminalPlugin.spawn(from: ctx)
            }
        ))

        registry.register(action: Action(
            id: "terminal.close",
            title: "Close Terminal",
            systemImage: "xmark.circle",
            appliesTo: .type(TypeID("terminal.session")),
            scope: .node,
            handler: { ctx in
                TerminalSessions.shared.host = ctx.host
                for id in ctx.selection { TerminalSessions.shared.close(id) }
            }
        ))

        registry.register(action: Action(
            id: "terminal.showAll",
            title: "Show Terminals",
            systemImage: "apple.terminal",
            scope: .workspace,
            handler: { ctx in
                TerminalSessions.shared.host = ctx.host
                ctx.host.mount(TerminalRef.sessionsURI)
            }
        ))
    }

    /// Put a new terminal on screen, and tell the host it exists.
    ///
    /// Mounted as a root as well as opened: a shell is a place you come back
    /// to, and one that lives only in a tab is gone the moment the tab is.
    @MainActor
    private static func open(_ session: TerminalSession, with host: HostContext) {
        TerminalSessions.shared.host = host
        host.mount(session.id.uri)
        host.openURI(session.id.uri)
    }

    /// Spawn a terminal where the reader already is — see `TerminalSpawn`.
    @MainActor
    private static func spawn(from ctx: ActionContext) {
        TerminalSessions.shared.host = ctx.host
        // The focused node counts as a target: firing this from the menu bar
        // or the palette selects nothing, but you are still *in* a terminal.
        let targets = ctx.targets.isEmpty ? [ctx.focused].compactMap { $0 } : ctx.targets
        let directory = TerminalSpawn.directory(
            targets: targets,
            sessions: TerminalSessions.shared,
            isDirectory: { ctx.host.node($0)?.type == TypeID("file.directory") })
        open(TerminalSessions.shared.create(directory: directory), with: ctx.host)
    }
}
