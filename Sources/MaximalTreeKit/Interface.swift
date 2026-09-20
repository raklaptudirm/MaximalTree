import SwiftUI

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
    public let shortcut: KeyboardShortcut?
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

    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        appliesTo: ActionPredicate = .always,
        shortcut: KeyboardShortcut? = nil,
        scope: ActionScope = .node,
        surfaces: ActionSurfaces? = nil,
        handler: @escaping @MainActor (ActionContext) -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.appliesTo = appliesTo
        self.shortcut = shortcut
        self.scope = scope
        self.surfaces = surfaces ?? scope.defaultSurfaces
        self.command = AnyCommand.handler(id: id, handler)
    }
}

// MARK: - Keys

/// One key sequence a surface claims, and the action it runs.
///
/// The sequence is written in the app's own notation — `j`, `g g`, `C-d` — and
/// the action is an id from the one registry, a plugin's or the host's. Keys
/// are therefore rebindable, listable, and callable by name, which is what
/// they were not while a canvas implemented them in a `switch`.
///
/// Bare keys only: the leader is the app's namespace, and a surface shadowing
/// `SPC g c` could not be explained to anyone.
public struct SurfaceKey: Sendable {
    public let sequence: String
    public let action: String

    public init(_ sequence: String, _ action: String) {
        self.sequence = sequence
        self.action = action
    }
}

/// Keys claimed by a surface that is not a canvas.
///
/// A canvas declares its keys on its `CanvasContribution`, so that the canvas
/// which draws is the canvas whose keys apply — with a matcher of its own the
/// two could disagree, and a key would run something belonging to a canvas you
/// are not looking at. The sidebar and the inspector have no contribution to
/// hang keys on, so they say which surface they mean.
public struct SurfaceKeys: Sendable {
    public enum Surface: Sendable, Equatable {
        case sidebar
        /// The column listing what is inside the sidebar's selection.
        case contents
        case inspector
    }

    public let surface: Surface
    public let keys: [SurfaceKey]

    public init(_ surface: Surface, _ keys: [SurfaceKey]) {
        self.surface = surface
        self.keys = keys
    }
}

// MARK: - Rendering

/// A plugin's canvas for the nodes it can draw. Renderers are resolved by **matcher
/// + priority**, not by node ownership — so a plugin can render node types produced
/// by a *different* plugin's provider (e.g. a text editor drawing filesystem files),
/// and a more specific renderer can override a general one. The host picks the single
/// highest-priority contribution whose `matches` returns true for the focused node.
///
/// `AnyView` erasure at the boundary is the cost of a heterogeneous registry.
///
/// `make` runs on the main actor during view updates, so it must be cheap —
/// construct views, never do I/O or heavy computation. Slow, movable work
/// (file reads, engine warmup, first-use caches) belongs in `prepare`: the host
/// awaits it *off* the main actor before calling `make`, showing a loading
/// indicator if it takes long. `prepare` reruns on every node switch, so it
/// should be idempotent and near-instant once warm.
@MainActor
public struct CanvasContribution {
    public let priority: Int
    public let matches: (Node) -> Bool
    public let prepare: (@Sendable (NodeID) async -> Void)?
    public let make: (NodeID, HostContext) -> AnyView

    /// The keys this canvas claims while it has the keyboard.
    ///
    /// Declared here rather than registered separately so that the canvas
    /// which draws is the canvas whose keys apply. Given a matcher of their
    /// own the two could disagree — a `.typ` file drawn by the typst canvas
    /// while the plain editor's keys were live — and nothing would say so.
    public let keys: [SurfaceKey]

    public init(
        priority: Int = 0,
        matches: @escaping (Node) -> Bool,
        prepare: (@Sendable (NodeID) async -> Void)? = nil,
        keys: [SurfaceKey] = [],
        make: @escaping (NodeID, HostContext) -> AnyView
    ) {
        self.priority = priority
        self.matches = matches
        self.prepare = prepare
        self.keys = keys
        self.make = make
    }
}

/// A plugin's inspector section. Unlike the canvas, **all** matching inspector
/// contributions are shown, stacked by descending priority — so a file's metadata
/// section and an editor's settings section can coexist for the same node.
@MainActor
public struct InspectorContribution {
    public let priority: Int
    public let matches: (Node) -> Bool
    public let make: (NodeID, HostContext) -> AnyView

    public init(
        priority: Int = 0,
        matches: @escaping (Node) -> Bool,
        make: @escaping (NodeID, HostContext) -> AnyView
    ) {
        self.priority = priority
        self.matches = matches
        self.make = make
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

// MARK: - Plugin + Registry

/// What a plugin registers into at load. One-shot: a plugin declares what it can
/// handle, not what exists. (Handles/`deactivate` come later, for dynamic plugins.)
@MainActor
public protocol PluginRegistry: AnyObject {
    /// Ask other plugins' providers for nodes. Store it on your provider if you need
    /// to compose foreign nodes: `register(provider: MyProvider(broker: registry.broker))`.
    var broker: NodeBroker { get }

    func register(provider: NodeProvider)
    func register(canvas: CanvasContribution)
    func register(inspector: InspectorContribution)
    func register(children: ChildContribution)
    func register(action: Action)
    /// A command that isn't offered anywhere — invoked by id, by a key or by a
    /// canvas, but never listed. An `Action` is one of these plus the title,
    /// icon and predicate a surface needs to draw it; plenty of operations
    /// need none of that and shouldn't have to invent them.
    func register(command: AnyCommand)
    /// A list the finder can search — see `FinderSource`.
    func register(finder: FinderSource)
    /// Keys for a surface that is not a canvas. A canvas declares its own on
    /// its contribution, so the drawing canvas and the live keys cannot part.
    func register(surfaceKeys: SurfaceKeys)
}

public extension PluginRegistry {
    /// Register a command written as a type, which is how they are written.
    @MainActor
    func register(_ command: some Command) { register(command: command.erased()) }

    /// Convenience for the common "render exactly this type" case.
    func registerCanvas(
        forType typeID: TypeID, priority: Int = 0,
        prepare: (@Sendable (NodeID) async -> Void)? = nil,
        make: @escaping (NodeID, HostContext) -> AnyView
    ) {
        register(canvas: CanvasContribution(priority: priority,
                                            matches: { $0.type == typeID },
                                            prepare: prepare, make: make))
    }

    func registerInspector(
        forType typeID: TypeID, priority: Int = 0,
        make: @escaping (NodeID, HostContext) -> AnyView
    ) {
        register(inspector: InspectorContribution(priority: priority,
                                                  matches: { $0.type == typeID }, make: make))
    }
}

/// The entry point every plugin implements. In step 1 these are compiled into the
/// host; in step 2 the same type is the `NSPrincipalClass` of a loaded `.bundle`.
public protocol Plugin: AnyObject {
    init()
    @MainActor func register(with registry: PluginRegistry)
}
