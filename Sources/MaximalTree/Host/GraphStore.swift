import Foundation
import MaximalTreeKit

/// Concrete registry the host hands to each plugin's `register(with:)`. Collects
/// contributions into lookup tables the shell and store consume.
@MainActor
final class Registry: PluginRegistry {
    private(set) var providers: [NodeProvider] = []
    private(set) var canvases: [CanvasContribution] = []
    private(set) var inspectors: [InspectorContribution] = []
    private(set) var childContributions: [ChildContribution] = []
    private(set) var actions: [Action] = []
    private(set) var finders: [FinderSource] = []
    private(set) var surfaceKeys: [SurfaceKeys] = []

    /// Handed to plugins during registration; populated once every plugin has loaded.
    let hostBroker = HostBroker()
    var broker: NodeBroker { hostBroker }

    /// The plugin currently being loaded, so its contributions can be
    /// attributed without every plugin having to name itself. Nil while the
    /// host registers its own actions — those belong to no plugin.
    var registeringOwner: String?
    /// Which plugin owns each uri scheme, so a menu can lead with the section
    /// belonging to the node in front of the reader.
    private(set) var ownersByScheme: [String: String] = [:]

    func register(provider: NodeProvider) {
        providers.append(provider)
        if let registeringOwner {
            for scheme in provider.schemes { ownersByScheme[scheme] = registeringOwner }
        }
    }
    func register(canvas: CanvasContribution) { canvases.append(canvas) }
    func register(finder: FinderSource) { finders.append(finder) }
    func register(surfaceKeys keys: SurfaceKeys) { surfaceKeys.append(keys) }
    func register(inspector: InspectorContribution) { inspectors.append(inspector) }
    func register(children: ChildContribution) { childContributions.append(children) }
    /// One action per id. A later registration replaces an earlier one.
    ///
    /// Two plugins can legitimately need the same vocabulary — every canvas
    /// that shows an editor declares the editor's keys, and the actions behind
    /// them have to exist whichever of those plugins happens to be loaded. So
    /// each asks, and the registry keeps one. Appending instead put the same
    /// command in the finder twice, and a guard inside the *asking* code would
    /// have to be per-registry to be correct, which is knowledge it doesn't
    /// have.
    func register(action: Action) {
        var action = action
        action.owner = registeringOwner
        if let existing = actions.firstIndex(where: { $0.id == action.id }) {
            actions[existing] = action
        } else {
            actions.append(action)
        }
        commands[action.id] = action.command
    }

    /// Every registered body by id, an action's included — so "what happens
    /// when this id is invoked" has one answer whether or not the operation
    /// was ever given a title.
    private(set) var commands: [String: AnyCommand] = [:]

    func register(command: AnyCommand) { commands[command.id] = command }

    func command(_ id: String) -> AnyCommand? { commands[id] }

    /// The plugin that provides `id`'s nodes, if a plugin does.
    func owner(of id: NodeID?) -> String? {
        guard let scheme = id?.scheme else { return nil }
        return ownersByScheme[scheme]
    }
}

/// Where what the reader put inside a node is kept: the workspaces.
///
/// Placing is the host's, whoever's node it is. A provider owns its node and
/// the children it lists itself; what was dropped into it was never the
/// provider's to keep, and every node that takes drops would otherwise keep
/// them its own way.
@MainActor
protocol PlacementHost: AnyObject {
    /// What was put inside `parent`, in order.
    func placedChildren(of parent: String) -> [String]
    /// Put these inside `parent`. Whether it was done.
    @discardableResult
    func place(_ uris: [String], into parent: String, at index: Int?) -> Bool
    func unplace(_ uris: [String], from parent: String)
}

/// The host's graph store: owns provider routing, the async load path, and drives
/// the observable `HostContext`. Implements `GraphBackend` so all plugin-triggered
/// reads/commands funnel through one object.
@MainActor
final class GraphStore: GraphBackend {
    let context: HostContext
    let nav: NavigationModel
    let registry: Registry

    // In-flight de-duplication. Kept here (not on HostContext) precisely because
    // GraphStore is not @Observable — touching it during a SwiftUI body is safe.
    private var childrenInFlight: Set<NodeID> = []
    private var attributesInFlight: Set<NodeID> = []
    /// Nodes whose expensive attributes have already been asked for — see
    /// `requestAttributes(of:)`.
    private var enrichedNodes: Set<NodeID> = []
    private var relatedInFlight: Set<NodeID> = []

    /// One consuming task per mounted root whose provider streams external
    /// changes. Synced against the root set at every mount/unmount/switch.
    private var changeStreams: [NodeID: Task<Void, Never>] = [:]

    /// Fired after the root set changes (mount/unmount) so the owner can persist the
    /// workspace. Lives here because mounting isn't only a UI affordance — plugins
    /// mount too (e.g. "Open as Git Repository"), and those must persist as well.
    var onRootsChanged: (() -> Void)?

    /// Fired for every `.renamed` change so host-side UI state keyed by NodeID
    /// (sidebar expansion) can follow the node.
    var onNodeRenamed: ((NodeID, NodeID) -> Void)?

    /// Fired for every `.removed` change, so anything holding a reference to
    /// the node — a collection — can let go of it.
    var onNodeRemoved: ((NodeID) -> Void)?

    /// Runs an action by id. Set by the owner, because dispatch needs the
    /// selection variants and the applicability rules that live up there.
    var onPerformAction: ((String, Int) -> Void)?
    var onRunCommand: (@MainActor (String, Any) async throws -> Any)?

    /// Where placed children live. With none, nothing can be placed, and every
    /// node's children are its provider's.
    weak var placements: PlacementHost?

    init(context: HostContext, registry: Registry, nav: NavigationModel) {
        self.context = context
        self.registry = registry
        self.nav = nav
        context.backend = self
    }

    /// Highest-priority canvas whose matcher accepts the node.
    func canvas(for node: Node) -> CanvasContribution? {
        registry.canvases.filter { $0.matches(node) }.max { $0.priority < $1.priority }
    }

    /// All matching inspector sections, most-specific (highest priority) first.
    /// Inspector sections for a node *and* for everything else it is, each
    /// paired with the identity it should be rendered for — the FileSystem
    /// section of a git repo has to be handed the directory's id, not the
    /// repo's, or it will describe a node it can't read.
    func inspectors(for node: Node) -> [(contribution: InspectorContribution, id: NodeID)] {
        var sections = registry.inspectors
            .filter { $0.matches(node) }
            .sorted { $0.priority > $1.priority }
            .map { (contribution: $0, id: node.id) }

        for identity in node.identities {
            guard let other = context.node(identity) else { continue }
            sections += registry.inspectors
                .filter { $0.matches(other) }
                .sorted { $0.priority > $1.priority }
                .map { (contribution: $0, id: identity) }
        }
        return sections
    }

    var actions: [Action] { registry.actions }
    var finders: [FinderSource] { registry.finders }
    var surfaceKeys: [SurfaceKeys] { registry.surfaceKeys }

    private func provider(for id: NodeID) -> NodeProvider? {
        guard let scheme = id.scheme else { return nil }
        return registry.providers.first { $0.schemes.contains(scheme) }
    }

    private func provider(forURI uri: String) -> NodeProvider? {
        guard let id = NodeID(uri), let scheme = id.scheme else { return nil }
        return registry.providers.first { $0.schemes.contains(scheme) }
    }

    // MARK: Commands

    // The plugin-facing `open` navigates the active tab; all navigation flows
    // through `didNavigate()` so focus/selection and the tab model stay in sync.
    // Phony nodes (see `NodeAnchor`) resolve to their real target first: the
    // target's canvas opens — one shared buffer — and focus, selection, and the
    // inspector all follow the real node; the fragment posts for the canvas to
    // jump to.
    func open(_ id: NodeID) {
        withResolved(id) { target, fragment in
            // Opening reuses the preview tab, or starts one — the explorer
            // behaviour of every editor. `newTab` remains the explicit
            // "keep this" path.
            self.nav.openInPreview(target)
            self.finishAnchoredNavigation(phony: id, target: target, fragment: fragment)
        }
    }

    /// A plugin asked to keep the tab showing this node.
    func pin(_ id: NodeID) { nav.pinTabs(showing: id) }

    func select(_ ids: [NodeID]) { context._setSelection(ids) }

    /// Resolve `id` through its anchor chain (phony → real), then run `body`.
    /// Synchronous when the node is cached — the common case, since anything
    /// clickable was ingested — one async fetch otherwise (e.g. `openURI`).
    private func withResolved(_ id: NodeID,
                              _ body: @escaping @MainActor (NodeID, String?) -> Void) {
        func resolve(from node: Node?) -> (NodeID, String?) {
            var target = id
            var fragment: String?
            var node = node
            var hops = 0
            while let anchor = node?.anchor, hops < 4 {
                target = anchor.node
                if fragment == nil { fragment = anchor.fragment }  // clicked node's wins
                node = context.node(target)
                hops += 1
            }
            return (target, fragment)
        }

        if let node = context.node(id) {
            let (target, fragment) = resolve(from: node)
            body(target, fragment)
        } else if let p = provider(for: id) {
            Task { @MainActor in
                let node = await p.node(for: id)
                if let node { self.context._ingest(self.decorate(node)) }
                let (target, fragment) = resolve(from: node)
                body(target, fragment)
            }
        } else {
            body(id, nil)
        }
    }

    private func finishAnchoredNavigation(phony: NodeID, target: NodeID, fragment: String?) {
        didNavigate()   // focus + selection land on the real target
        if phony != target, let fragment {
            context._postFragment(.init(target: target, fragment: fragment))
        }
    }

    // MARK: Host-only navigation (not in GraphBackend; driven by the UI)

    func back() { nav.back(); didNavigate() }
    func forward() { nav.forward(); didNavigate() }

    func newTab(with id: NodeID?) {
        guard let id else { nav.newTab(with: nil); didNavigate(); return }
        withResolved(id) { target, fragment in
            self.nav.newTab(with: target)
            self.finishAnchoredNavigation(phony: id, target: target, fragment: fragment)
        }
    }
    func closeTab(_ tabID: NavigationModel.Tab.ID) { nav.closeTab(tabID); didNavigate() }
    func selectTab(_ i: Int) { nav.selectTab(i); didNavigate() }
    func splitActivePane(horizontal: Bool) { nav.splitActivePane(horizontal: horizontal); didNavigate() }
    func closeActivePane() { nav.closeActivePane(); didNavigate() }
    func activatePane(_ id: UUID) { nav.activatePane(id); didNavigate() }
    @discardableResult
    func movePane(_ direction: PaneDirection) -> UUID? {
        let moved = nav.movePane(direction)
        if moved != nil { didNavigate() }
        return moved
    }
    func cyclePane(by offset: Int) { nav.cyclePane(by: offset); didNavigate() }

    private func didNavigate() {
        // Any navigation invalidates a pending phony-node jump; an anchored open
        // re-posts its fragment right after this.
        context._postFragment(nil)
        let current = nav.current
        context._setFocus(current)
        context._setSelection(current.map { [$0] } ?? [])
        if let current, context.node(current) == nil { ingestNode(current) }
    }

    func mount(_ uri: String) {
        guard let p = provider(forURI: uri), let id = p.resolve(uri) else { return }
        var roots = context.roots
        guard !roots.contains(id) else { return }
        roots.append(id)
        context._setRoots(roots)
        ingestNode(id)
        syncChangeStreams()
        onRootsChanged?()
    }

    /// Host-only: take a root out of the sidebar. The node itself is untouched —
    /// this is the inverse of `mount`, not a delete.
    func unmount(_ id: NodeID) {
        var roots = context.roots
        guard roots.contains(id) else { return }
        roots.removeAll { $0 == id }
        context._setRoots(roots)
        syncChangeStreams()
        onRootsChanged?()
    }

    func openURI(_ uri: String) {
        guard let p = provider(forURI: uri), let id = p.resolve(uri) else { return }
        open(id)
    }

    func openURIBeside(_ uri: String) {
        guard let p = provider(forURI: uri), let id = p.resolve(uri) else { return }
        nav.openBeside(id)
        didNavigate()
    }

    // MARK: Writes

    func canApply(_ mutation: GraphMutation) -> Bool {
        guard admits(mutation) else { return false }
        if Self.isPlacement(mutation) { return placements != nil }
        return mutatingProvider(for: mutation)?.supports(mutation) ?? false
    }

    func apply(_ mutation: GraphMutation) {
        guard admits(mutation) else { return }
        // Placing is the host's: no provider is asked, the node's own included.
        // It hears of it the way everything else does — its listing changed.
        switch mutation {
        case .adopt(let ids, let parent, let index):
            guard let placements, placements.place(ids.map(\.uri), into: parent.uri, at: index)
            else { return }
            process([.childrenChanged(parent), .modified(parent)])
            return
        case .release(let ids, let parent):
            guard let placements else { return }
            placements.unplace(ids.map(\.uri), from: parent.uri)
            process([.childrenChanged(parent), .modified(parent)])
            return
        default:
            break
        }
        guard let provider = mutatingProvider(for: mutation), provider.supports(mutation) else { return }
        Task { @MainActor in
            do {
                let changes = try await provider.apply(mutation)
                process(changes)
            } catch {
                NSLog("[MaximalTree] mutation failed: \(error.localizedDescription)")
            }
        }
    }

    /// Start the sidebar's inline rename on `id` — but only when the owning
    /// provider would actually honor the resulting `.rename`, so the text field
    /// never appears on nodes that can't be renamed. The probe uses the current
    /// label: providers gate `.rename` support on the node, not the new name.
    func beginRename(_ id: NodeID) {
        let name = context.node(id)?.label ?? id.uri
        guard canApply(.rename(id, to: name)) else { return }
        context._setPendingRename(id)
    }

    /// Plugin-initiated change reports (actions, content saves) flow into the same
    /// funnel as mutation results — one code path keeps the cache truthful.
    func notify(_ changes: [NodeChange]) { process(changes) }

    /// Changes observed *outside* the app, from a provider's change stream.
    /// The same funnel as `notify`, plus the nudge that sends an open canvas
    /// back to its file — our own writes must not trigger that.
    func notifyExternal(_ changes: [NodeChange]) { process(changes, external: true) }

    /// Apply reported changes to caches + navigation, then re-sync focus to
    /// whatever the active tab now points at. The single funnel: mutation
    /// results, plugin `notify`s, and external change streams all land here.
    /// - Parameter external: whether these came from a change *stream* — an
    ///   edit made outside the app — rather than from our own writes. Only
    ///   those tell an open canvas to go and look at its file again.
    private func process(_ changes: [NodeChange], external: Bool = false) {
        for change in changes {
            switch change {
            case .renamed(let from, let to):
                onNodeRenamed?(from, to)
                nav.remap(from: from, to: to)
                context._remap(from: from, to: to)
                context._invalidateChildren(of: to)   // descendant URIs changed
                ingestNode(to)
            case .removed(let id):
                // A removed *root* has to leave the workspace too, or it comes
                // back on the next launch having been closed on this one.
                let wasRoot = context.roots.contains(id)
                onNodeRemoved?(id)
                nav.remove(id)
                context._remove(id)
                if wasRoot { onRootsChanged?() }
            case .childrenChanged(let parent):
                context._invalidateChildren(of: parent)
            case .modified(let id):
                ingestNode(id)          // same identity; refresh the record in place
                if external { context._postExternalEdit(ExternalEdit.Notice(node: id)) }
            @unknown default:
                break
            }
        }
        let current = nav.current
        context._setFocus(current)
        context._setSelection(current.map { [$0] } ?? [])
        if let current, context.node(current) == nil { ingestNode(current) }
    }

    /// The host's own conditions on a mutation, checked before any provider.
    ///
    /// Only placing has any: the node has to take drops at all, and what it
    /// takes. And a cycle is the host's problem — the sidebar is what would
    /// walk into it for ever.
    private func admits(_ mutation: GraphMutation) -> Bool {
        if case .release(_, let parent) = mutation { return context.node(parent)?.accepts != nil }
        guard case .adopt(let ids, let destination, _) = mutation else { return true }
        guard !ids.isEmpty,
              let accepts = context.node(destination)?.accepts,
              ids.allSatisfy({ context.node($0).map { accepts.admits($0.type) } ?? false })
        else { return false }
        return !Self.formsCycle(adopting: ids, into: destination,
                                children: { [context] in context.children(of: $0) })
    }

    /// Whether adopting these into `destination` would make something its own
    /// ancestor — adopting a node into itself, or into anything already inside
    /// it.
    ///
    /// Walks the children the host has loaded, which is all it can see. A
    /// cycle through a subtree nobody has opened is not caught here; the
    /// sidebar's own walk stops at a repeated ancestor, so it can be drawn,
    /// just not formed knowingly.
    static func formsCycle(adopting ids: [NodeID], into destination: NodeID,
                           children: (NodeID) -> [NodeID]) -> Bool {
        var pending = ids
        var seen: Set<NodeID> = []
        while let next = pending.popLast() {
            if next == destination { return true }
            guard seen.insert(next).inserted else { continue }
            pending.append(contentsOf: children(next))
        }
        return false
    }

    private func mutatingProvider(for mutation: GraphMutation) -> MutatingNodeProvider? {
        let anchor: NodeID?
        switch mutation {
        case .rename(let id, _): anchor = id
        case .delete(let ids): anchor = ids.first
        case .move(let ids, _): anchor = ids.first
        case .create(let parent, _, _): anchor = parent
        case .adopt, .release: anchor = nil   // the host's; see `apply`
        @unknown default: anchor = nil
        }
        guard let anchor else { return nil }
        return provider(for: anchor) as? MutatingNodeProvider
    }

    private static func isPlacement(_ mutation: GraphMutation) -> Bool {
        switch mutation {
        case .adopt, .release: return true
        default: return false
        }
    }

    func setRoots(_ ids: [NodeID]) {
        context._setRoots(ids)
        for id in ids { ingestNode(id) }
        syncChangeStreams()
    }

    /// Swap the whole root set for a workspace switch: tabs, history, focus, and
    /// selection all reset. Deliberately does NOT fire `onRootsChanged` — a switch
    /// restores persisted state, it doesn't create any. (Node caches are kept: they
    /// are keyed by identity and stay valid across workspaces.)
    func switchRoots(_ ids: [NodeID]) {
        nav.reset()
        setRoots(ids)
        didNavigate()
    }

    /// Put a workspace's tabs back after switching to it, then re-sync focus
    /// and selection to whatever those tabs point at.
    func restoreNavigation(_ snapshot: NavigationModel.Snapshot) {
        nav.restore(snapshot)
        didNavigate()
    }

    // MARK: External change streams

    /// Start watching newly mounted roots and stop watching unmounted ones.
    /// External batches flow into `process` — the same funnel as `notify`, so
    /// an edit by another app refreshes the app exactly like our own writes.
    private func syncChangeStreams() {
        let desired = Set(context.roots)
        for (root, task) in changeStreams where !desired.contains(root) {
            task.cancel()
            changeStreams[root] = nil
        }
        for root in desired where changeStreams[root] == nil {
            guard let provider = provider(for: root) as? ChangeStreamingProvider,
                  let stream = provider.changes(under: root) else { continue }
            changeStreams[root] = Task { @MainActor [weak self] in
                for await changes in stream {
                    guard !Task.isCancelled else { break }
                    self?.notifyExternal(changes)
                }
            }
        }
    }

    // MARK: Async loads

    /// A leaf that some plugin contributes children to is, effectively, not a leaf:
    /// flip `hasChildren` so the sidebar offers a disclosure. Applied at every
    /// ingest point.
    ///
    /// And a node that takes drops has children exactly when something was put
    /// in it — which its provider cannot know, since the host keeps that.
    private func decorate(_ node: Node) -> Node {
        var node = node
        if node.accepts != nil, let placements {
            node.hasChildren = !placements.placedChildren(of: node.id.uri).isEmpty
        }
        guard !node.hasChildren,
              registry.childContributions.contains(where: { $0.matches(node) })
        else { return node }
        node.hasChildren = true
        return node
    }

    /// What was put inside a node, as nodes: each resolved by whoever owns it.
    private func placedNodes(_ uris: [String]) async -> [Node] {
        var nodes: [Node] = []
        for uri in uris {
            if let p = provider(forURI: uri), let id = p.resolve(uri), let node = await p.node(for: id) {
                nodes.append(node)
            } else if let placeholder = Self.unavailable(uri) {
                nodes.append(placeholder)
            }
        }
        return nodes
    }

    /// Something placed that did not resolve, shown rather than dropped.
    ///
    /// Its plugin may simply not be loaded, and an entry silently deleted for
    /// that is far worse than one that is briefly inert. Its own id, not a
    /// stand-in's: when the plugin loads, the same row becomes the real thing.
    static func unavailable(_ uri: String) -> Node? {
        guard let id = NodeID(uri) else { return nil }
        let name = CollectionRef.name(from: uri)
            ?? uri.split(separator: "/").last.map(String.init) ?? uri
        return Node(id: id, type: TypeID("placed.unavailable"),
                    label: name.removingPercentEncoding ?? name,
                    icon: NodeIcon("questionmark.circle", tint: .gray))
    }

    private var nodesInFlight: Set<NodeID> = []

    /// Fetch the records of nodes nothing has listed — the groups, which the
    /// sidebar draws from its own tree rather than from a listing, so without
    /// this they would be drawn by their raw URI instead of their name.
    func ensureNodes(_ ids: [NodeID]) {
        for id in ids where context.node(id) == nil && !nodesInFlight.contains(id) {
            guard let p = provider(for: id) else { continue }
            nodesInFlight.insert(id)
            Task { @MainActor in
                if let n = await p.node(for: id) { ingest(n) }
                nodesInFlight.remove(id)
            }
        }
    }

    private func ingestNode(_ id: NodeID) {
        guard let p = provider(for: id) else { return }
        Task { @MainActor in
            if let n = await p.node(for: id) { ingest(n) }
        }
    }

    /// Cache a node, and the records of everything else it is.
    ///
    /// Without those, an action's predicate asking "is this a directory?"
    /// about an identity it was handed would find nothing to answer with.
    /// Identities are not followed recursively: a node says what it also is,
    /// and that is where it stops.
    private func ingest(_ node: Node) {
        context._ingest(decorate(node))
        for identity in node.identities where context.node(identity) == nil {
            guard let provider = provider(for: identity) else { continue }
            Task { @MainActor in
                if let other = await provider.node(for: identity) {
                    context._ingest(decorate(other))
                }
            }
        }
    }

    func requestChildren(of id: NodeID) {
        // Fetch when never loaded, or refetch when marked stale — the stale
        // listing stays on screen until the fresh one swaps in.
        guard context.cachedChildren(of: id) == nil || context._isChildrenStale(id),
              !childrenInFlight.contains(id),
              let p = provider(for: id) else { return }
        childrenInFlight.insert(id)
        Task { @MainActor in
            var subject = context.node(id)
            if subject == nil { subject = (await p.node(for: id)).map(decorate) }

            // A node that takes drops lists what was dropped into it; the
            // provider is not asked.
            let page: Page<Node>
            if subject?.accepts != nil, let placements {
                page = Page(items: await placedNodes(placements.placedChildren(of: id.uri)))
            } else {
                page = await p.children(of: id, page: nil)
            }
            var items = page.items.map(decorate)

            // Merge in children contributed by other plugins, after the owner's.
            if let node = subject {
                for contribution in registry.childContributions where contribution.matches(node) {
                    items += await contribution.children(id).map(decorate)
                }
            }

            for n in items { context._ingest(n) }
            context._setChildren(items.map(\.id), of: id)
            context._setChildCursor(page.next, of: id)
            childrenInFlight.remove(id)
        }
    }

    /// Ask for these nodes' children again.
    ///
    /// Marked stale rather than cleared, so the listing already on screen stays
    /// until the new one arrives — a refresh should never blink the tree.
    ///
    /// Only nodes whose children have actually been loaded. Requesting children
    /// for a node nobody has opened would fetch the tree a level at a time in
    /// the background, which is the opposite of what this is for.
    func refreshChildren(of ids: some Sequence<NodeID>) {
        for id in ids where context.cachedChildren(of: id) != nil {
            for child in context.cachedChildren(of: id) ?? [] {
                enrichedNodes.remove(child)
            }
            context._invalidateChildren(of: id)
            requestChildren(of: id)
        }
    }

    /// Fetch the next page of children and append. Only runs when the provider
    /// reported a cursor on the previous page.
    func requestMoreChildren(of id: NodeID) {
        guard let cursor = context.cachedChildCursor(of: id),
              !childrenInFlight.contains(id),
              let p = provider(for: id) else { return }
        childrenInFlight.insert(id)
        Task { @MainActor in
            let page = await p.children(of: id, page: cursor)
            let items = page.items.map(decorate)
            for n in items { context._ingest(n) }
            // Later provider pages append at the end — after any contributed
            // children. Ordering blip accepted; paginated + contributed rarely mix.
            let existing = context.cachedChildren(of: id) ?? []
            context._setChildren(existing + items.map(\.id), of: id)
            context._setChildCursor(page.next, of: id)
            childrenInFlight.remove(id)
        }
    }

    /// Fetch the attributes a listing did not carry, and merge them in.
    ///
    /// Merged rather than replaced: what the listing knew is still true, and a
    /// provider answering this should be free to return only the part that
    /// cost something.
    ///
    /// Asked once per node. A row asks every time it scrolls back into view,
    /// so without that this would re-run a `git show` per commit per scroll.
    /// Refreshing a listing clears the record, since new children may be new
    /// nodes anyway.
    func requestAttributes(of id: NodeID) {
        guard !enrichedNodes.contains(id), !attributesInFlight.contains(id),
              let p = provider(for: id) else { return }
        attributesInFlight.insert(id)
        Task { @MainActor in
            let extra = await p.attributes(of: id)
            attributesInFlight.remove(id)
            enrichedNodes.insert(id)
            guard var node = context.node(id), !extra.isEmpty else { return }
            node.attributes.merge(extra)
            context._ingest(node)
        }
    }

    /// A surface's action reporting the mode its command left behind.
    var onSetKeyMode: ((KeyMode) -> Void)?

    func setKeyMode(_ mode: KeyMode) { onSetKeyMode?(mode) }

    /// A plugin driving the app by name — the same path a key takes.
    func perform(actionID: String, count: Int) {
        onPerformAction?(actionID, count)
    }

    /// A caller that wants the answer, and will handle the failure.
    func run(command id: String, input: Any) async throws -> Any {
        guard let onRunCommand else { throw CommandError.noSuchCommand(command: id) }
        return try await onRunCommand(id, input)
    }

    func requestRelated(of id: NodeID) {
        guard context.cachedRelated(of: id) == nil,
              !relatedInFlight.contains(id),
              let p = provider(for: id) else { return }
        relatedInFlight.insert(id)
        Task { @MainActor in
            let r = await p.related(to: id)
            context._setRelated(r, of: id)
            relatedInFlight.remove(id)
        }
    }
}
