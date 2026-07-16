import SwiftUI

// MARK: - Actions

/// The context handed to an action when it fires.
@MainActor
public struct ActionContext {
    public let host: HostContext
    public init(host: HostContext) { self.host = host }

    public var selection: [NodeID] { host.selection }
    public var focused: NodeID? { host.focusedNode }
    public var selectedNodes: [Node] { selection.compactMap { host.node($0) } }
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

/// A named, invokable command contributed by a plugin.
public struct Action: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String?
    public let appliesTo: ActionPredicate
    public let handler: @MainActor (ActionContext) -> Void

    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        appliesTo: ActionPredicate = .always,
        handler: @escaping @MainActor (ActionContext) -> Void
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.appliesTo = appliesTo
        self.handler = handler
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
@MainActor
public struct CanvasContribution {
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
    func register(action: Action)
}

public extension PluginRegistry {
    /// Convenience for the common "render exactly this type" case.
    func registerCanvas(
        forType typeID: TypeID, priority: Int = 0,
        make: @escaping (NodeID, HostContext) -> AnyView
    ) {
        register(canvas: CanvasContribution(priority: priority,
                                            matches: { $0.type == typeID }, make: make))
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
