import SwiftUI

// The SwiftUI half of the SDK. On macOS it compiles into the one MaximalTreeKit
// framework together with Sources/MaximalTreeCore; Package.swift builds that
// folder alone, with no UI anywhere, as a MaximalTreeKit that is only the core.

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

// MARK: - Plugin + Registry

/// What a plugin contributes to *this* shell: the views, and the keys that only
/// mean something where there is a keyboard.
@MainActor
public protocol ShellRegistry: AnyObject {
    func register(canvas: CanvasContribution)
    func register(inspector: InspectorContribution)
    /// Keys for a surface that is not a canvas. A canvas declares its own on
    /// its contribution, so the drawing canvas and the live keys cannot part.
    func register(surfaceKeys: SurfaceKeys)
}

/// What a plugin registers into at load: both halves, since a plugin in this app
/// is one bundle that does both. One-shot — a plugin declares what it can handle,
/// not what exists. (Handles/`deactivate` come later, for dynamic plugins.)
public protocol PluginRegistry: CoreRegistry, ShellRegistry {}

public extension ShellRegistry {
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
