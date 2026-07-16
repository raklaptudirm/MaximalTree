import Foundation
import MaximalTreeKit

/// Concrete registry the host hands to each plugin's `register(with:)`. Collects
/// contributions into lookup tables the shell and store consume.
@MainActor
final class Registry: PluginRegistry {
    private(set) var providers: [NodeProvider] = []
    private(set) var canvases: [CanvasContribution] = []
    private(set) var inspectors: [InspectorContribution] = []
    private(set) var actions: [Action] = []

    /// Handed to plugins during registration; populated once every plugin has loaded.
    let hostBroker = HostBroker()
    var broker: NodeBroker { hostBroker }

    func register(provider: NodeProvider) { providers.append(provider) }
    func register(canvas: CanvasContribution) { canvases.append(canvas) }
    func register(inspector: InspectorContribution) { inspectors.append(inspector) }
    func register(action: Action) { actions.append(action) }
}

/// The host's graph store: owns provider routing, the async load path, and drives
/// the observable `HostContext`. Implements `GraphBackend` so all plugin-triggered
/// reads/commands funnel through one object.
@MainActor
final class GraphStore: GraphBackend {
    let context: HostContext
    let nav: NavigationModel
    private let registry: Registry

    // In-flight de-duplication. Kept here (not on HostContext) precisely because
    // GraphStore is not @Observable — touching it during a SwiftUI body is safe.
    private var childrenInFlight: Set<NodeID> = []
    private var relatedInFlight: Set<NodeID> = []

    /// Fired after the root set changes (mount/unmount) so the owner can persist the
    /// workspace. Lives here because mounting isn't only a UI affordance — plugins
    /// mount too (e.g. "Open as Git Repository"), and those must persist as well.
    var onRootsChanged: (() -> Void)?

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
    func inspectors(for node: Node) -> [InspectorContribution] {
        registry.inspectors.filter { $0.matches(node) }.sorted { $0.priority > $1.priority }
    }

    var actions: [Action] { registry.actions }

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
    func open(_ id: NodeID) { nav.navigate(to: id); didNavigate() }

    func select(_ ids: [NodeID]) { context._setSelection(ids) }

    // MARK: Host-only navigation (not in GraphBackend; driven by the UI)

    func back() { nav.back(); didNavigate() }
    func forward() { nav.forward(); didNavigate() }
    func newTab(with id: NodeID?) { nav.newTab(with: id); didNavigate() }
    func closeTab(_ tabID: NavigationModel.Tab.ID) { nav.closeTab(tabID); didNavigate() }
    func selectTab(_ i: Int) { nav.selectTab(i); didNavigate() }

    private func didNavigate() {
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
        onRootsChanged?()
    }

    /// Host-only: take a root out of the sidebar. The node itself is untouched —
    /// this is the inverse of `mount`, not a delete.
    func unmount(_ id: NodeID) {
        var roots = context.roots
        guard roots.contains(id) else { return }
        roots.removeAll { $0 == id }
        context._setRoots(roots)
        onRootsChanged?()
    }

    func openURI(_ uri: String) {
        guard let p = provider(forURI: uri), let id = p.resolve(uri) else { return }
        open(id)
    }

    // MARK: Writes

    func canApply(_ mutation: GraphMutation) -> Bool {
        mutatingProvider(for: mutation)?.supports(mutation) ?? false
    }

    func apply(_ mutation: GraphMutation) {
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

    /// Plugin-initiated change reports (actions, content saves) flow into the same
    /// funnel as mutation results — one code path keeps the cache truthful.
    func notify(_ changes: [NodeChange]) { process(changes) }

    /// Apply reported changes to caches + navigation, then re-sync focus to whatever
    /// the active tab now points at. This is the single funnel that future external
    /// change-feed events will also flow through.
    private func process(_ changes: [NodeChange]) {
        for change in changes {
            switch change {
            case .renamed(let from, let to):
                nav.remap(from: from, to: to)
                context._remap(from: from, to: to)
                context._invalidateChildren(of: to)   // descendant URIs changed
                ingestNode(to)
            case .removed(let id):
                nav.remove(id)
                context._remove(id)
            case .childrenChanged(let parent):
                context._invalidateChildren(of: parent)
            case .modified(let id):
                ingestNode(id)          // same identity; refresh the record in place
            @unknown default:
                break
            }
        }
        let current = nav.current
        context._setFocus(current)
        context._setSelection(current.map { [$0] } ?? [])
        if let current, context.node(current) == nil { ingestNode(current) }
    }

    private func mutatingProvider(for mutation: GraphMutation) -> MutatingNodeProvider? {
        let anchor: NodeID?
        switch mutation {
        case .rename(let id, _): anchor = id
        case .delete(let ids): anchor = ids.first
        @unknown default: anchor = nil
        }
        guard let anchor else { return nil }
        return provider(for: anchor) as? MutatingNodeProvider
    }

    func setRoots(_ ids: [NodeID]) {
        context._setRoots(ids)
        for id in ids { ingestNode(id) }
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

    // MARK: Async loads

    private func ingestNode(_ id: NodeID) {
        guard let p = provider(for: id) else { return }
        Task { @MainActor in
            if let n = await p.node(for: id) { context._ingest(n) }
        }
    }

    func requestChildren(of id: NodeID) {
        guard context.cachedChildren(of: id) == nil,
              !childrenInFlight.contains(id),
              let p = provider(for: id) else { return }
        childrenInFlight.insert(id)
        Task { @MainActor in
            let page = await p.children(of: id, page: nil)
            for n in page.items { context._ingest(n) }
            context._setChildren(page.items.map(\.id), of: id)
            context._setChildCursor(page.next, of: id)
            childrenInFlight.remove(id)
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
            for n in page.items { context._ingest(n) }
            let existing = context.cachedChildren(of: id) ?? []
            context._setChildren(existing + page.items.map(\.id), of: id)
            context._setChildCursor(page.next, of: id)
            childrenInFlight.remove(id)
        }
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
