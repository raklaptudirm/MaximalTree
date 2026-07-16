import Foundation
import MaximalTreeKit

/// The host's `NodeBroker`: routes a foreign URI to whichever provider owns its
/// scheme, exactly like `GraphStore` does for its own lookups.
///
/// Chicken-and-egg: plugins need the broker *while registering* (to hand to their
/// providers), but the provider list only exists once every plugin has registered. So
/// the broker is handed out empty and `install(_:)` fills it in after `loadAll()`.
/// The lock is what makes that safe — providers call in from detached tasks off the
/// main actor, while registration happens on it.
final class HostBroker: NodeBroker, @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [any NodeProvider] = []

    func install(_ providers: [any NodeProvider]) {
        lock.lock()
        defer { lock.unlock() }
        self.providers = providers
    }

    private func provider(for id: NodeID) -> (any NodeProvider)? {
        guard let scheme = id.scheme else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return providers.first { $0.schemes.contains(scheme) }
    }

    func node(for uri: String) async -> Node? {
        guard let id = NodeID(uri), let provider = provider(for: id) else { return nil }
        return await provider.node(for: id)
    }

    func children(of uri: String, page: Cursor?) async -> Page<Node> {
        guard let id = NodeID(uri), let provider = provider(for: id) else { return Page(items: []) }
        return await provider.children(of: id, page: page)
    }
}
