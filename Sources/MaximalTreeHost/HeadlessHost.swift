import Foundation
@_spi(Host) import MaximalTreeKit

/// The host with no window, as something to ask questions of: what is under a
/// node, what a node is, what can be done to it — and doing it.
///
/// A `HostEngine` with nothing around it, and the door a command-line tool or
/// a server comes in by. Every answer waits for the engine to finish what the
/// question set off: a listing is fetched by a task, an action may take its
/// turn in the queue, and a caller with no screen to watch has to be handed
/// the result rather than told to look again.
@MainActor
public final class HeadlessHost {
    /// Why a question couldn't be answered, in a sentence for whoever asked.
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    private let engine: HostEngine
    public var host: HostContext { engine.host }

    /// - Parameters:
    ///   - library: where this host keeps its workspaces. Not the app's: two
    ///     hosts writing one library would each save over the other's changes.
    ///   - plugins: registers the plugins' core halves. A list in the caller,
    ///     not a scan — a host like this loads no bundles, and on some
    ///     platforms none can be loaded at all.
    public init(library: URL, plugins: @MainActor (CoreRegistry) -> Void) {
        let registry = CoreContributions()
        engine = HostEngine(host: HostContext(), registry: registry,
                            workspaceStore: WorkspaceStore(fileURL: library))
        plugins(registry)
        // What PluginHost does once the bundles are in: every provider is now
        // registered, so the broker they share can route between them.
        registry.hostBroker.install(registry.providers)
        engine.start()
    }

    /// What this host has to say that nobody asked — a library it couldn't
    /// read, a save that failed — taken, so it isn't said twice.
    public func takeNotices() async -> [String] {
        var said: [String] = []
        while let failure = engine.dispatch.failure {
            said.append("\(failure.title): \(failure.message)")
            engine.dispatch.dismissFailure()
            // The next one is put up a turn later: give it the turn.
            await Task.yield()
            await nextTurn()
        }
        return said
    }

    // MARK: Asking

    /// The node `uri` names, fetched if it isn't known yet.
    public func node(_ uri: String) async throws -> Node {
        let id = try resolve(uri)
        if host.node(id) == nil {
            engine.store?.ensureNodes([id])
            await settle()
        }
        guard let node = host.node(id) else { throw Failure("Nothing is at \(uri).") }
        return node
    }

    /// What is under `uri`: its first page, or every page with `all`.
    public func children(of uri: String, all: Bool = false) async throws -> [Node] {
        let parent = try await node(uri)
        _ = host.children(of: parent.id)       // asks, if it never has
        await settle()
        while all, host.hasMoreChildren(parent.id) {
            engine.store?.requestMoreChildren(of: parent.id)
            await settle()
        }
        return (host.cachedChildren(of: parent.id) ?? []).map {
            host.node($0) ?? Node(id: $0, type: "unknown")
        }
    }

    /// Whether there is more under `uri` than has been listed.
    public func hasMore(under uri: String) throws -> Bool {
        host.hasMoreChildren(try resolve(uri))
    }

    /// The actions that apply to `uri` — the same answer a menu gets.
    public func actions(for uri: String) async throws -> [Action] {
        let node = try await node(uri)
        return engine.dispatch.applicableActions(for: [node.id])
    }

    /// The nodes this host has mounted.
    public var roots: [NodeID] { host.roots }

    /// Every workspace by name, and which is the active one.
    public var workspaces: [(name: String, active: Bool)] {
        engine.workspaces.map { ($0.name, $0.id == engine.activeWorkspaceID) }
    }

    // MARK: Doing

    /// Run `actionID` on `uri`, and wait for it to finish. Throws what the
    /// action said went wrong, or that it doesn't apply.
    public func run(_ actionID: String, on uri: String) async throws {
        let node = try await node(uri)
        guard let action = engine.dispatch.action(actionID) else {
            throw Failure("No action is called \(actionID).")
        }
        guard engine.dispatch.canRun(action, targets: [node.id]) else {
            throw Failure("\(action.title) doesn't apply to \(node.label).")
        }
        // Whatever was said before this is not this action's failure.
        _ = await takeNotices()
        engine.dispatch.perform(action, targets: [node.id])
        await settle()
        if let failure = engine.dispatch.failure {
            engine.dispatch.dismissFailure()
            throw Failure(failure.message)
        }
    }

    /// Put `uri` among this host's roots.
    public func mount(_ uri: String) async throws {
        _ = try resolve(uri)
        engine.store?.mount(uri)
        await settle()
    }

    // MARK: Waiting

    /// Until nothing the engine set off is still out — no fetch, no write, no
    /// command — and then a turn more, for what it defers to the next one.
    public func settle() async {
        let deadline = ContinuousClock.now + .seconds(60)
        while (engine.store?.outstanding ?? 0) > 0 || engine.dispatch.running > 0,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await nextTurn()
    }

    private func nextTurn() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    private func resolve(_ uri: String) throws -> NodeID {
        guard let id = engine.store?.resolve(uri) else {
            throw Failure("Nothing here serves \(uri).")
        }
        return id
    }
}
