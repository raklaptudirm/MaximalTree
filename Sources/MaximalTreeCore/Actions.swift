import Foundation

// MARK: - Actions

/// The context handed to an action when it fires.
@MainActor
public struct ActionContext {
    public let host: HostContext

    /// The nodes this invocation acts on. Defaults to the host's current selection
    /// (menu bar, palette), but a context menu targets the rows it was opened on —
    /// which may not be the selection at all.
    public let targets: [NodeID]

    /// How many times this was asked for.
    ///
    /// Keys can carry a repeat — `5 j` walks five rows — and an action is what
    /// a key runs, so the count has to reach the handler. Actions that cannot
    /// sensibly repeat ignore it, which is why it defaults to 1 and is never
    /// zero: a handler can use it without checking.
    public let count: Int

    public init(host: HostContext, targets: [NodeID]? = nil, count: Int = 1) {
        self.host = host
        self.targets = targets ?? host.selection
        self.count = max(count, 1)
    }

    /// The nodes being acted on. Alias of `targets`, which reads naturally in handlers.
    public var selection: [NodeID] { targets }

    /// The same context, acting on the nodes an invocation actually named.
    ///
    /// A menu hands over what is selected and this changes nothing. A script,
    /// a keymap, or one plugin calling another names its own, and this is what
    /// makes that argument count rather than be quietly ignored.
    public func acting(on nodes: NodeTargets) -> ActionContext {
        ActionContext(host: host, targets: nodes.nodes, count: nodes.count)
    }

    // MARK: Changing things
    //
    // Writing is something an action does. A canvas reads, navigates, and
    // reports what it has seen; it does not reach into the graph, because an
    // operation that only exists inside one canvas is invisible to the palette,
    // to a key, to a script, and to anything that would put it back. These are
    // here rather than on `HostContext` so that stays true by the compiler
    // rather than by agreement — see `@_spi(Host)` there.

    /// Perform a write. Fire-and-forget: the host runs it and updates its
    /// caches and navigation from what the provider reports.
    public func apply(_ mutation: GraphMutation) { host.apply(mutation) }

    /// Whether the owning provider can perform `mutation` right now — for
    /// deciding whether to offer it at all.
    public func canApply(_ mutation: GraphMutation) -> Bool { host.canApply(mutation) }

    /// Add a root to the workspace.
    public func mount(_ uri: String) { host.mount(uri) }

    /// Start the host's inline-rename on a node — one rename affordance, any
    /// renamable node, whoever owns it.
    public func beginRename(_ id: NodeID) { host.beginRename(id) }

    /// Put a node's record into the host's cache before anything is asked
    /// about it — for a node the app has just learned of and nothing has
    /// listed yet, so a check against its record has something to read.
    public func ingest(_ node: Node) { host._ingest(node) }

    /// Report changes made outside the mutation path, so the host updates
    /// exactly as it does for its own writes. Also available to a canvas: a
    /// report carries no authority, since the host answers it by re-reading
    /// from whoever owns the node.
    public func notify(_ changes: [NodeChange]) { host.notify(changes) }
    public var focused: NodeID? { host.focusedNode }
    public var selectedNodes: [Node] { targets.compactMap { host.node($0) } }
}

/// Decides whether an action applies to the current selection. One registry of
/// actions feeds the menu bar, the command palette, and the context menu; each
/// surface filters by this predicate.
public enum ActionPredicate {
    case always
    case type(TypeID)
    case custom(@MainActor (ActionContext) -> Bool)

    @MainActor
    public func matches(_ ctx: ActionContext) -> Bool {
        switch self {
        case .always: return true
        case .type(let t): return !ctx.selectedNodes.isEmpty && ctx.selectedNodes.allSatisfy { $0.type == t }
        case .custom(let f): return f(ctx)
        }
    }
}

/// Where an action is offered.
///
/// One registry feeds every surface, which is what makes a plugin's commands
/// reachable from everywhere at once — and also what turns a right-click into
/// a list of everything the app can do. A surface set is the action saying
/// where it actually belongs.
public struct ActionSurfaces: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Right-clicking nodes in the explorer.
    public static let contextMenu = ActionSurfaces(rawValue: 1 << 0)
    public static let menuBar = ActionSurfaces(rawValue: 1 << 1)
    public static let palette = ActionSurfaces(rawValue: 1 << 2)
    public static let inspector = ActionSurfaces(rawValue: 1 << 3)

    public static let everywhere: ActionSurfaces =
        [.contextMenu, .menuBar, .palette, .inspector]
}

/// What an action acts on, relative to the node in front of you.
///
/// This is the ordering principle for every surface: the closer an action sits
/// to what the reader is pointing at, the earlier it appears. It also decides
/// where an action shows up by default — a command that acts on the whole app
/// has no business on the context menu of one file.
public enum ActionScope: Int, Sendable, Comparable, CaseIterable {
    /// Acts on the target nodes themselves — rename, delete, copy path.
    case node = 0
    /// Acts *inside* the target, treating it as a container — new file here.
    case container = 1
    /// Acts on the document currently open — export it, reload it, bookmark it.
    case document = 2
    /// Acts on the app or the workspace — open a new page, refresh an index.
    case workspace = 3

    public static func < (a: ActionScope, b: ActionScope) -> Bool {
        a.rawValue < b.rawValue
    }

    /// Where an action of this scope belongs unless it says otherwise.
    ///
    /// Node and container actions are *about* the thing you right-clicked, so
    /// they belong on its menu. Document and workspace actions are not: firing
    /// "Export as PDF" from the context menu of an unrelated file reads as
    /// though it applies to that file, and it doesn't.
    public var defaultSurfaces: ActionSurfaces {
        switch self {
        case .node, .container: return .everywhere
        case .document: return [.menuBar, .palette, .inspector]
        case .workspace: return [.menuBar, .palette]
        }
    }
}

/// A named, invokable command contributed by a plugin. Actions are the app's
/// primary manipulation surface — canvases stay minimal and content-only, while
/// actions reach every host surface at once: the menu bar (with `shortcut`, when
/// set), the command palette, the context menu, and the inspector.
public struct Action: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String?
    public let appliesTo: ActionPredicate
    /// Menu-bar key equivalent. Only the menu bar renders it (that's what makes
    /// it window-wide); other surfaces list the action without one.
    public let shortcut: KeyChord?
    /// What this acts on relative to the current node — orders every surface.
    public let scope: ActionScope
    /// Where it's offered. Defaults to what the scope implies.
    public let surfaces: ActionSurfaces
    /// Which plugin contributed this, used to group the surfaces. Stamped by
    /// the host at registration; plugins leave it alone.
    public var owner: String?
    /// The body, with its types packed away — what a key, the palette, or
    /// another plugin reaches when it invokes this by id.
    public let command: AnyCommand

    /// An action whose body takes the nodes it was invoked on and may fail.
    ///
    /// A body that waits for something picks the asynchronous overload on its
    /// own, and the host puts it on the queue; one that doesn't runs where it
    /// was invoked, as a key's action always has. Either way a failure reaches
    /// the reader instead of being swallowed at the end of a closure.
    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        appliesTo: ActionPredicate = .always,
        shortcut: KeyChord? = nil,
        scope: ActionScope = .node,
        surfaces: ActionSurfaces? = nil,
        run: @escaping @MainActor (ActionContext) throws -> Void
    ) {
        self.init(id: id, title: title, systemImage: systemImage, appliesTo: appliesTo,
                  shortcut: shortcut, scope: scope, surfaces: surfaces,
                  command: AnyCommand.running(id: id, run))
    }

    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        appliesTo: ActionPredicate = .always,
        shortcut: KeyChord? = nil,
        scope: ActionScope = .node,
        surfaces: ActionSurfaces? = nil,
        run: @escaping @MainActor (ActionContext) async throws -> Void
    ) {
        self.init(id: id, title: title, systemImage: systemImage, appliesTo: appliesTo,
                  shortcut: shortcut, scope: scope, surfaces: surfaces,
                  command: AnyCommand.running(id: id, run))
    }

    /// An action over a command written as a type — the form for anything
    /// whose argument is more than the nodes it was invoked on.
    @MainActor
    public init(
        _ command: some Command,
        title: String,
        systemImage: String? = nil,
        appliesTo: ActionPredicate = .always,
        shortcut: KeyChord? = nil,
        scope: ActionScope = .node,
        surfaces: ActionSurfaces? = nil
    ) {
        self.init(id: type(of: command).id, title: title, systemImage: systemImage,
                  appliesTo: appliesTo, shortcut: shortcut, scope: scope,
                  surfaces: surfaces, command: command.erased())
    }

    private init(id: String, title: String, systemImage: String?,
                 appliesTo: ActionPredicate, shortcut: KeyChord?,
                 scope: ActionScope, surfaces: ActionSurfaces?, command: AnyCommand) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.appliesTo = appliesTo
        self.shortcut = shortcut
        self.scope = scope
        self.surfaces = surfaces ?? scope.defaultSurfaces
        self.command = command
    }
}

// MARK: - Child contributions

/// Lets a plugin add children to nodes owned by *another* provider — the same
/// cross-plugin idea as renderer contributions, applied to the tree itself. The
/// host appends contributed children after the owning provider's, and treats
/// matching leaf nodes as expandable so the sidebar shows a disclosure.
///
/// E.g. the Typst plugin contributes a document's sections and tasks as children
/// of `.typ` file nodes that the FileSystem provider owns.
public struct ChildContribution: Sendable {
    public let matches: @Sendable (Node) -> Bool
    public let children: @Sendable (NodeID) async -> [Node]

    public init(
        matches: @escaping @Sendable (Node) -> Bool,
        children: @escaping @Sendable (NodeID) async -> [Node]
    ) {
        self.matches = matches
        self.children = children
    }
}

// MARK: - Registry

/// What a plugin contributes that has nothing to do with drawing: where nodes
/// come from, what can be done to them, and what can be searched.
///
/// Separate from `ShellRegistry` because these are the halves that will one day
/// live in different places — this one wherever the graph is served, the other
/// in whatever is displaying it. A plugin that serves nodes and never draws
/// anything needs only this.
@MainActor
public protocol CoreRegistry: AnyObject {
    /// Ask other plugins' providers for nodes. Store it on your provider if you need
    /// to compose foreign nodes: `register(provider: MyProvider(broker: registry.broker))`.
    var broker: NodeBroker { get }
    /// Where to tell the reader something no command failed to do — a file of
    /// theirs that couldn't be read, a save that didn't happen. Hold on to it:
    /// most of what there is to say is said later than `register(with:)`.
    var notices: Notices { get }

    func register(provider: NodeProvider)
    func register(children: ChildContribution)
    func register(action: Action)
    /// A command that isn't offered anywhere — invoked by id, by a key or by a
    /// canvas, but never listed. An `Action` is one of these plus the title,
    /// icon and predicate a surface needs to draw it; plenty of operations
    /// need none of that and shouldn't have to invent them.
    func register(command: AnyCommand)
    /// A list the finder can search — see `FinderSource`.
    func register(finder: FinderSource)
}

public extension CoreRegistry {
    /// Register a command written as a type, which is how they are written.
    func register(_ command: some Command) { register(command: command.erased()) }
}
