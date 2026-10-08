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
/// What the graph is: every node record the app has seen, and what it knows about
/// their children.
///
/// One half of what a plugin holds — the half that is the same wherever the graph
/// is served from. Nothing here is about what this window is doing with it.
@MainActor
@Observable
public final class GraphState {
    /// Top-level entries of the current workspace (the forest's roots).
    public internal(set) var roots: [NodeID] = []

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
    /// Nodes that have paged at least once.
    ///
    /// Separate from the cursor because it answers a different question. The
    /// cursor says whether there is *more* and goes away with the last page;
    /// this says the listing was long enough to arrive in pieces, which
    /// reaching the end of it does not undo. Read the cursor for it and a node
    /// stops being contents the moment you get to the bottom — the column
    /// closing under the reader who scrolled there.
    internal var paginatedNodes: Set<NodeID> = []

    public init() {}
}

/// What this shell is doing with the graph: where the keyboard is, what is
/// selected, what it is showing.
///
/// The other half, and the one that stays behind when the graph moves. None of it
/// is shared: two devices looking at the same nodes have their own selection,
/// their own focus, their own idea of how much chrome to draw.
@MainActor
@Observable
public final class ShellState {
    /// The node whose renderer currently owns the canvas + inspector.
    public internal(set) var focusedNode: NodeID?
    /// Current selection in the explorer (drives action applicability).
    public internal(set) var selection: [NodeID] = []
    /// Posted when a *phony* node (see `NodeAnchor`) was opened: the host
    /// navigated to `target`, and target's canvas should jump to `fragment`.
    /// Canvases observe this (`.onChange`) and act when `target` is their node.
    /// The nonce makes repeat jumps to the same fragment observable.
    public internal(set) var activeFragment: HostContext.NodeFragment?
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
    /// The keyboard mode the app is in — see `HostContext.keyMode`.
    public internal(set) var keyMode: KeyMode = .normal

    public init() {}
}

@MainActor
@Observable
public final class HostContext {
    /// The two halves this stands in front of. Reading through the façade is
    /// the same as reading them directly — SwiftUI tracks the property that was
    /// actually touched — so a plugin never has to know which half it wanted.
    public let graph: GraphState
    public let shell: ShellState

    public var roots: [NodeID] { graph.roots }
    public var focusedNode: NodeID? { shell.focusedNode }
    public var selection: [NodeID] { shell.selection }
    public var activeFragment: NodeFragment? { shell.activeFragment }
    public var isZenMode: Bool { shell.isZenMode }
    public var externalEdit: ExternalEdit.Notice? { shell.externalEdit }
    public var pendingRename: NodeID? { shell.pendingRename }

    /// Set by the host when it constructs the store. Weak to avoid a retain cycle.
    public weak var backend: GraphBackend?

    public init(graph: GraphState = GraphState(), shell: ShellState = ShellState()) {
        self.graph = graph
        self.shell = shell
    }

    /// A phony-node jump request — see `shell.activeFragment`.
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

    public func node(_ id: NodeID) -> Node? { graph.nodes[id] }

    /// Cached children, requesting a load if we've never fetched them — or a
    /// refetch if the cache is stale. Stale data keeps being served meanwhile,
    /// so an update never blanks what's on screen.
    public func children(of id: NodeID) -> [NodeID] {
        if graph.childrenByParent[id] == nil || graph.staleChildren.contains(id) {
            backend?.requestChildren(of: id)
        }
        return graph.childrenByParent[id] ?? []
    }

    /// The keyboard mode the app is in.
    ///
    /// One mode, app-wide: in a commanding mode a key names an action, and in
    /// insert mode it is text for whatever has focus. A surface's action that
    /// starts typing — the editor's `i` or `o`, a visual `c` — says so by
    /// setting this, because there is one mode and it is not the surface's to
    /// keep a copy of.
    public var keyMode: KeyMode { shell.keyMode }

    /// Host-only: the modal layer reporting where it got to.
    @_spi(Host) public func _setKeyMode(_ mode: KeyMode) { shell.keyMode = mode }

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
    /// Run a command and wait for what it answers.
    ///
    /// The other door. `perform(_:count:)` is what a key or a menu goes
    /// through: there is nothing to hand back, and a failure is the host's to
    /// put in front of the reader, who pressed a key rather than asking anyone
    /// a question. This one is for a caller that wants the answer — and a
    /// caller that wants the answer takes the failure with it.
    @MainActor
    public func perform<C: Command>(_ command: C.Type, _ input: C.Input) async throws -> C.Output {
        guard let backend else { throw CommandError.noSuchCommand(command: C.id) }
        let answer = try await backend.run(command: C.id, input: input)
        guard let answer = answer as? C.Output else {
            throw CommandError.wrongAnswer(command: C.id)
        }
        return answer
    }

    public func perform(_ actionID: String, count: Int = 1) {
        backend?.perform(actionID: actionID, count: count)
    }

    /// Cached forward links, requesting a load if we've never fetched them.
    public func related(of id: NodeID) -> [Related] {
        if graph.relatedByNode[id] == nil { backend?.requestRelated(of: id) }
        return graph.relatedByNode[id] ?? []
    }

    /// Whether the provider reported more children beyond what's cached.
    public func hasMoreChildren(_ id: NodeID) -> Bool { graph.childCursors[id] != nil }

    /// How to reach a node's children: places to expand into, or contents to
    /// go into.
    ///
    /// The provider's word wherever it gave one, and otherwise inferred from
    /// paging — a provider that hands back a cursor has already said its
    /// children are more than a tree should hold. The inference cannot fire
    /// until a first page has arrived, which is exactly when a node that needs
    /// the answer sooner should state it.
    public func childStyle(of id: NodeID) -> ChildStyle {
        if let stated = graph.nodes[id]?.childStyle { return stated }
        return graph.paginatedNodes.contains(id) ? .contents : .places
    }

    /// Whether the tree should offer to open this node in place.
    ///
    /// Having children is not enough: contents are reached by going into them,
    /// so a node holding a library gets no triangle however many children it
    /// has. Here rather than in the sidebar's own closure so the rule can be
    /// checked without an app around it.
    public func isExpandable(_ id: NodeID) -> Bool {
        node(id)?.hasChildren == true && childStyle(of: id) == .places
    }

    /// Fetch the next page of `id`'s children and append it to the cached list.
    /// No-op when there is no further page or a fetch is already in flight.
    public func loadMoreChildren(of id: NodeID) { backend?.requestMoreChildren(of: id) }

    /// Ask for the attributes a listing was too cheap to carry.
    ///
    /// The heavier half of a row: a commit's diff stat, a file's size, a
    /// video's runtime — one query each, which is fine for the twenty rows on
    /// screen and ruinous for the five thousand in the listing. So the listing
    /// arrives without them and whatever is actually looked at asks.
    ///
    /// Safe to call on every appearance: already asked is a no-op, and the
    /// answer merges into the node, so a view need only read it back.
    public func loadAttributes(of id: NodeID) { backend?.requestAttributes(of: id) }

    /// Peek at the caches without triggering a load. For the host/backend, which
    /// needs to ask "already fetched?" without kicking off another request.
    public func cachedChildren(of id: NodeID) -> [NodeID]? { graph.childrenByParent[id] }
    public func cachedRelated(of id: NodeID) -> [Related]? { graph.relatedByNode[id] }
    public func cachedChildCursor(of id: NodeID) -> Cursor? { graph.childCursors[id] }

    // MARK: Commands (routed to the host)

    public func open(_ id: NodeID) { backend?.open(id) }
    public func select(_ ids: [NodeID]) { backend?.select(ids) }
    @_spi(Host) public func mount(_ uri: String) { backend?.mount(uri) }
    /// Resolve a raw URI (e.g. a `Related.target`) and focus it, without mounting
    /// it as a root. This is how the inspector follows a reference.
    public func openURI(_ uri: String) { backend?.openURI(uri) }

    /// Show this in a neighbouring pane, without going to it.
    ///
    /// For two views of one thing side by side — a document's source and its
    /// pages. Reuses a pane already showing it, then any neighbour, and only
    /// splits when there is nowhere else to put it. The keyboard stays where
    /// it was: asking to see a thing is not asking to go to it.
    public func openURIBeside(_ uri: String) { backend?.openURIBeside(uri) }

    /// Perform a write. Fire-and-forget: the host runs it and updates caches/nav from
    /// the reported changes; failures are logged. Check `canApply` first for UI state.
    @_spi(Host) public func apply(_ mutation: GraphMutation) { backend?.apply(mutation) }

    /// What a language knows about the file at `url` — completions, what a
    /// symbol is, where it was defined — from whichever plugin registered a
    /// service for it. Nil when none did.
    public func languageService(for url: URL) -> LanguageService? {
        backend?.languageService(for: url)
    }

    /// Whether the owning provider can perform `mutation` right now (for enabling UI).
    public func canApply(_ mutation: GraphMutation) -> Bool { backend?.canApply(mutation) ?? false }

    /// Ask the host to start its inline-rename UI on `id` (the sidebar text
    /// field). No-op when the owning provider doesn't support `.rename` for the
    /// node. This is the plugin-facing trigger for the *host's* rename
    /// affordance — one UI, any renamable node, whoever owns it.
    @_spi(Host) public func beginRename(_ id: NodeID) { backend?.beginRename(id) }

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

    @_spi(Host) public func _ingest(_ node: Node) { graph.nodes[node.id] = node }
    @_spi(Host) public func _setChildren(_ ids: [NodeID], of parent: NodeID) {
        graph.childrenByParent[parent] = ids
        graph.staleChildren.remove(parent)
    }
    @_spi(Host) public func _setRelated(_ r: [Related], of id: NodeID) { graph.relatedByNode[id] = r }
    @_spi(Host) public func _setRoots(_ ids: [NodeID]) { graph.roots = ids }
    @_spi(Host) public func _setFocus(_ id: NodeID?) { shell.focusedNode = id }
    @_spi(Host) public func _setSelection(_ ids: [NodeID]) { shell.selection = ids }
    @_spi(Host) public func _postFragment(_ fragment: NodeFragment?) { shell.activeFragment = fragment }
    @_spi(Host) public func _setZenMode(_ zen: Bool) { shell.isZenMode = zen }
    @_spi(Host) public func _setPendingRename(_ id: NodeID?) { shell.pendingRename = id }
    @_spi(Host) public func _postExternalEdit(_ notice: ExternalEdit.Notice?) { shell.externalEdit = notice }

    /// Rewrite every cached reference to `old` as `new` after a rename. Note this is
    /// shallow: for a directory rename, descendant URIs also change, so the caller
    /// should also invalidate the renamed node's children (they refetch under the new
    /// path). Files (the common case) have no descendants and remap exactly.
    @_spi(Host) public func _remap(from old: NodeID, to new: NodeID) {
        if let node = graph.nodes.removeValue(forKey: old) { graph.nodes[new] = node }
        if let kids = graph.childrenByParent.removeValue(forKey: old) { graph.childrenByParent[new] = kids }
        if graph.staleChildren.remove(old) != nil { graph.staleChildren.insert(new) }
        if let cursor = graph.childCursors.removeValue(forKey: old) { graph.childCursors[new] = cursor }
        if graph.paginatedNodes.remove(old) != nil { graph.paginatedNodes.insert(new) }
        for (parent, kids) in graph.childrenByParent where kids.contains(old) {
            graph.childrenByParent[parent] = kids.map { $0 == old ? new : $0 }
        }
        if let related = graph.relatedByNode.removeValue(forKey: old) { graph.relatedByNode[new] = related }
        graph.roots = graph.roots.map { $0 == old ? new : $0 }
        if shell.focusedNode == old { shell.focusedNode = new }
        shell.selection = shell.selection.map { $0 == old ? new : $0 }
        if shell.pendingRename == old { shell.pendingRename = new }
    }

    /// Drop a node that no longer exists from every cache and from open state.
    @_spi(Host) public func _remove(_ id: NodeID) {
        graph.nodes[id] = nil
        graph.childrenByParent[id] = nil
        graph.relatedByNode[id] = nil
        graph.childCursors[id] = nil
        graph.paginatedNodes.remove(id)
        graph.staleChildren.remove(id)
        for (parent, kids) in graph.childrenByParent where kids.contains(id) {
            graph.childrenByParent[parent] = kids.filter { $0 != id }
        }
        graph.roots = graph.roots.filter { $0 != id }
        if shell.focusedNode == id { shell.focusedNode = nil }
        shell.selection = shell.selection.filter { $0 != id }
        if shell.pendingRename == id { shell.pendingRename = nil }
    }

    /// Mark a node's children outdated so the next access refetches. The stale
    /// listing keeps being served until the fresh one lands and swaps in place
    /// — never drop what's on screen. Clears the pagination cursor; the
    /// refetch restarts from the first page. (A never-fetched parent has
    /// nothing to keep; it simply fetches on next access.)
    @_spi(Host) public func _invalidateChildren(of id: NodeID) {
        if graph.childrenByParent[id] != nil { graph.staleChildren.insert(id) }
        graph.childCursors[id] = nil
    }

    /// Whether a cached listing is awaiting its refetch (backend-facing).
    @_spi(Host) public func _isChildrenStale(_ id: NodeID) -> Bool { graph.staleChildren.contains(id) }

    @_spi(Host) public func _setChildCursor(_ cursor: Cursor?, of id: NodeID) {
        graph.childCursors[id] = cursor
        // Only ever set. A page that reports no successor is the end of the
        // listing, not evidence that it never paged.
        if cursor != nil { graph.paginatedNodes.insert(id) }
    }
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
    func openURIBeside(_ uri: String)
    func apply(_ mutation: GraphMutation)
    func canApply(_ mutation: GraphMutation) -> Bool
    func beginRename(_ id: NodeID)
    func notify(_ changes: [NodeChange])
    func pin(_ id: NodeID)
    func requestChildren(of id: NodeID)
    func requestMoreChildren(of id: NodeID)
    func requestAttributes(of id: NodeID)
    func requestRelated(of id: NodeID)
    func perform(actionID: String, count: Int)
    @MainActor func run(command id: String, input: Any) async throws -> Any
    func setKeyMode(_ mode: KeyMode)
    /// What a language knows about the file at `url`, if anything does.
    func languageService(for url: URL) -> LanguageService?
}

public extension GraphBackend {
    func languageService(for url: URL) -> LanguageService? { nil }
}
