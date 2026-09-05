import Foundation
import Observation

/// The single, observable object plugins hold to read graph state and drive the
/// host. Concrete (not a protocol) and living in the SDK so plugin SwiftUI can
/// `@Environment(HostContext.self)` and observe it by reference. The host keeps the
/// real store and drives this through `GraphBackend`; plugins never touch internals.
///
/// The cache dictionaries below are the observable source of truth for the UI. The
/// backend fills them asynchronously; reading `children(of:)`/`related(of:)` during
/// a SwiftUI body kicks off a load (via the backend) and returns what's cached so
/// far, so the view re-renders when the data lands.
@MainActor
@Observable
public final class HostContext {
    /// Top-level entries of the current workspace (the forest's roots).
    public internal(set) var roots: [NodeID] = []
    /// The node whose renderer currently owns the canvas + inspector.
    public internal(set) var focusedNode: NodeID?
    /// Current selection in the explorer (drives action applicability).
    public internal(set) var selection: [NodeID] = []
    /// Posted when a *phony* node (see `NodeAnchor`) was opened: the host
    /// navigated to `target`, and target's canvas should jump to `fragment`.
    /// Canvases observe this (`.onChange`) and act when `target` is their node.
    /// The nonce makes repeat jumps to the same fragment observable.
    public internal(set) var activeFragment: NodeFragment?
    /// Zen mode: the host is showing the canvas alone — no sidebar, inspector,
    /// tab strip, or toolbar. Canvases should shed their own chrome too
    /// (headers, status rows, anything that isn't the content).
    public internal(set) var isZenMode = false
    /// Posted when an open node's bytes changed outside the app — another
    /// editor saving, a branch switch, a sync client. Canvases showing that
    /// node observe this and reconcile against the file (see `ExternalEdit`);
    /// nobody else has to care.
    public internal(set) var externalEdit: ExternalEdit.Notice?
    /// The node the sidebar is inline-renaming right now, nil when none. Set via
    /// `beginRename(_:)` — the host validates support first — and cleared by the
    /// shell when the edit commits or cancels. Plugins trigger the rename UI;
    /// they never draw it.
    public internal(set) var pendingRename: NodeID?

    // Observable caches, filled by the backend.
    internal var nodes: [NodeID: Node] = [:]
    internal var childrenByParent: [NodeID: [NodeID]] = [:]
    /// Parents whose cached listing is outdated but still being served while
    /// the refetch runs (stale-while-revalidate). Dropping the cache instead
    /// blanks every expanded subtree for a frame — the UI reads as a blink.
    internal var staleChildren: Set<NodeID> = []
    internal var relatedByNode: [NodeID: [Related]] = [:]
    /// Cursor for the *next* page of a node's children, when the provider reported
    /// one. Presence means "there's more to load".
    internal var childCursors: [NodeID: Cursor] = [:]

    /// Set by the host when it constructs the store. Weak to avoid a retain cycle.
    public weak var backend: GraphBackend?

    public init() {}

    /// A phony-node jump request — see `activeFragment`.
    public struct NodeFragment: Equatable, Sendable {
        public let target: NodeID
        public let fragment: String
        public let nonce: UUID

        public init(target: NodeID, fragment: String) {
            self.target = target
            self.fragment = fragment
            self.nonce = UUID()
        }
    }

    // MARK: Reads (safe to call from a view body)

    public func node(_ id: NodeID) -> Node? { nodes[id] }

    /// Cached children, requesting a load if we've never fetched them — or a
    /// refetch if the cache is stale. Stale data keeps being served meanwhile,
    /// so an update never blanks what's on screen.
    public func children(of id: NodeID) -> [NodeID] {
        if childrenByParent[id] == nil || staleChildren.contains(id) {
            backend?.requestChildren(of: id)
        }
        return childrenByParent[id] ?? []
    }

    /// The keyboard mode the app is in.
    ///
    /// One mode, app-wide: in a commanding mode a key names an action, and in
    /// insert mode it is text for whatever has focus. A surface's action that
    /// starts typing — the editor's `i` or `o`, a visual `c` — says so by
    /// setting this, because there is one mode and it is not the surface's to
    /// keep a copy of.
    public private(set) var keyMode: KeyMode = .normal

    /// Host-only: the modal layer reporting where it got to.
    public func _setKeyMode(_ mode: KeyMode) { keyMode = mode }

    /// Ask the app to change mode.
    public func setKeyMode(_ mode: KeyMode) { backend?.setKeyMode(mode) }

    /// Run any of the app's operations by name.
    ///
    /// Every operation is an action, the host's own included — moving in the
    /// tree, splitting a pane, switching workspace — so this is the whole of
    /// what the app can do, addressable by id. A plugin can drive the app the
    /// same way a key does, and does not have to be told which operations came
    /// from the host and which from another plugin.
    ///
    /// Does nothing when the id is unknown or the action does not apply right
    /// now, so a caller need not guard either.
    public func perform(_ actionID: String, count: Int = 1) {
        backend?.perform(actionID: actionID, count: count)
    }

    /// Cached forward links, requesting a load if we've never fetched them.
    public func related(of id: NodeID) -> [Related] {
        if relatedByNode[id] == nil { backend?.requestRelated(of: id) }
        return relatedByNode[id] ?? []
    }

    /// Whether the provider reported more children beyond what's cached.
    public func hasMoreChildren(_ id: NodeID) -> Bool { childCursors[id] != nil }

    /// Fetch the next page of `id`'s children and append it to the cached list.
    /// No-op when there is no further page or a fetch is already in flight.
    public func loadMoreChildren(of id: NodeID) { backend?.requestMoreChildren(of: id) }

    /// Peek at the caches without triggering a load. For the host/backend, which
    /// needs to ask "already fetched?" without kicking off another request.
    public func cachedChildren(of id: NodeID) -> [NodeID]? { childrenByParent[id] }
    public func cachedRelated(of id: NodeID) -> [Related]? { relatedByNode[id] }
    public func cachedChildCursor(of id: NodeID) -> Cursor? { childCursors[id] }

    // MARK: Commands (routed to the host)

    public func open(_ id: NodeID) { backend?.open(id) }
    public func select(_ ids: [NodeID]) { backend?.select(ids) }
    public func mount(_ uri: String) { backend?.mount(uri) }
    /// Resolve a raw URI (e.g. a `Related.target`) and focus it, without mounting
    /// it as a root. This is how the inspector follows a reference.
    public func openURI(_ uri: String) { backend?.openURI(uri) }

    /// Perform a write. Fire-and-forget: the host runs it and updates caches/nav from
    /// the reported changes; failures are logged. Check `canApply` first for UI state.
    public func apply(_ mutation: GraphMutation) { backend?.apply(mutation) }

    /// Whether the owning provider can perform `mutation` right now (for enabling UI).
    public func canApply(_ mutation: GraphMutation) -> Bool { backend?.canApply(mutation) ?? false }

    /// Ask the host to start its inline-rename UI on `id` (the sidebar text
    /// field). No-op when the owning provider doesn't support `.rename` for the
    /// node. This is the plugin-facing trigger for the *host's* rename
    /// affordance — one UI, any renamable node, whoever owns it.
    public func beginRename(_ id: NodeID) { backend?.beginRename(id) }

    /// Keep the tab showing this node.
    ///
    /// A pinned tab isn't reused: the next thing opened starts its own tab
    /// instead of replacing it. Editing is the usual reason — that's what
    /// separates "I glanced at this" from "I'm working here" — but it isn't
    /// the only one. A terminal is work from the moment it exists, whether or
    /// not anything has been typed into it.
    ///
    /// Cheap and idempotent: call it on every keystroke if that's simplest.
    public func pin(_ id: NodeID) { backend?.pin(id) }

    /// Report changes that happened outside the mutation path — an action created a
    /// file, an editor saved bytes, a provider observed an external edit. The host
    /// updates its caches and navigation exactly as it does for `apply(_:)` results.
    /// This is how a plugin keeps the host truthful about side effects it caused.
    public func notify(_ changes: [NodeChange]) { backend?.notify(changes) }

    // MARK: Backend-facing mutation (host only)

    public func _ingest(_ node: Node) { nodes[node.id] = node }
    public func _setChildren(_ ids: [NodeID], of parent: NodeID) {
        childrenByParent[parent] = ids
        staleChildren.remove(parent)
    }
    public func _setRelated(_ r: [Related], of id: NodeID) { relatedByNode[id] = r }
    public func _setRoots(_ ids: [NodeID]) { roots = ids }
    public func _setFocus(_ id: NodeID?) { focusedNode = id }
    public func _setSelection(_ ids: [NodeID]) { selection = ids }
    public func _postFragment(_ fragment: NodeFragment?) { activeFragment = fragment }
    public func _setZenMode(_ zen: Bool) { isZenMode = zen }
    public func _setPendingRename(_ id: NodeID?) { pendingRename = id }
    public func _postExternalEdit(_ notice: ExternalEdit.Notice?) { externalEdit = notice }

    /// Rewrite every cached reference to `old` as `new` after a rename. Note this is
    /// shallow: for a directory rename, descendant URIs also change, so the caller
    /// should also invalidate the renamed node's children (they refetch under the new
    /// path). Files (the common case) have no descendants and remap exactly.
    public func _remap(from old: NodeID, to new: NodeID) {
        if let node = nodes.removeValue(forKey: old) { nodes[new] = node }
        if let kids = childrenByParent.removeValue(forKey: old) { childrenByParent[new] = kids }
        if staleChildren.remove(old) != nil { staleChildren.insert(new) }
        if let cursor = childCursors.removeValue(forKey: old) { childCursors[new] = cursor }
        for (parent, kids) in childrenByParent where kids.contains(old) {
            childrenByParent[parent] = kids.map { $0 == old ? new : $0 }
        }
        if let related = relatedByNode.removeValue(forKey: old) { relatedByNode[new] = related }
        roots = roots.map { $0 == old ? new : $0 }
        if focusedNode == old { focusedNode = new }
        selection = selection.map { $0 == old ? new : $0 }
        if pendingRename == old { pendingRename = new }
    }

    /// Drop a node that no longer exists from every cache and from open state.
    public func _remove(_ id: NodeID) {
        nodes[id] = nil
        childrenByParent[id] = nil
        relatedByNode[id] = nil
        childCursors[id] = nil
        staleChildren.remove(id)
        for (parent, kids) in childrenByParent where kids.contains(id) {
            childrenByParent[parent] = kids.filter { $0 != id }
        }
        roots = roots.filter { $0 != id }
        if focusedNode == id { focusedNode = nil }
        selection = selection.filter { $0 != id }
        if pendingRename == id { pendingRename = nil }
    }

    /// Mark a node's children outdated so the next access refetches. The stale
    /// listing keeps being served until the fresh one lands and swaps in place
    /// — never drop what's on screen. Clears the pagination cursor; the
    /// refetch restarts from the first page. (A never-fetched parent has
    /// nothing to keep; it simply fetches on next access.)
    public func _invalidateChildren(of id: NodeID) {
        if childrenByParent[id] != nil { staleChildren.insert(id) }
        childCursors[id] = nil
    }

    /// Whether a cached listing is awaiting its refetch (backend-facing).
    public func _isChildrenStale(_ id: NodeID) -> Bool { staleChildren.contains(id) }

    public func _setChildCursor(_ cursor: Cursor?, of id: NodeID) { childCursors[id] = cursor }
}

/// Implemented by the host's graph store. Everything the plugin API can trigger
/// funnels through here, which is the seam that would later back onto XPC if any
/// plugin ever needed to run out-of-process.
@MainActor
public protocol GraphBackend: AnyObject {
    func open(_ id: NodeID)
    func select(_ ids: [NodeID])
    func mount(_ uri: String)
    func openURI(_ uri: String)
    func apply(_ mutation: GraphMutation)
    func canApply(_ mutation: GraphMutation) -> Bool
    func beginRename(_ id: NodeID)
    func notify(_ changes: [NodeChange])
    func pin(_ id: NodeID)
    func requestChildren(of id: NodeID)
    func requestMoreChildren(of id: NodeID)
    func requestRelated(of id: NodeID)
    func perform(actionID: String, count: Int)
    func setKeyMode(_ mode: KeyMode)
}
