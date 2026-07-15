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

/// A plugin's views for one node type. `canvas` is the center-pane escape hatch
/// (arbitrary SwiftUI). `inspector` is the right-pane controls. `AnyView` erasure
/// is the deliberate cost of a heterogeneous registry keyed by `TypeID`.
@MainActor
public struct TypeRenderer {
    public let typeID: TypeID
    public let canvas: (NodeID, HostContext) -> AnyView
    public let inspector: (NodeID, HostContext) -> AnyView

    public init(
        typeID: TypeID,
        canvas: @escaping (NodeID, HostContext) -> AnyView,
        inspector: @escaping (NodeID, HostContext) -> AnyView
    ) {
        self.typeID = typeID
        self.canvas = canvas
        self.inspector = inspector
    }
}

// MARK: - Plugin + Registry

/// What a plugin registers into at load. One-shot: a plugin declares what it can
/// handle, not what exists. (Handles/`deactivate` come later, for dynamic plugins.)
@MainActor
public protocol PluginRegistry: AnyObject {
    func register(provider: NodeProvider)
    func register(renderer: TypeRenderer)
    func register(action: Action)
}

/// The entry point every plugin implements. In step 1 these are compiled into the
/// host; in step 2 the same type is the `NSPrincipalClass` of a loaded `.bundle`.
public protocol Plugin: AnyObject {
    init()
    @MainActor func register(with registry: PluginRegistry)
}
