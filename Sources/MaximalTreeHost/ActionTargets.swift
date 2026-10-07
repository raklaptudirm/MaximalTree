import Foundation
import MaximalTreeKit

/// Which nodes an action should actually be handed.
///
/// A node can be several things at once (see `Node.identities`), and an action
/// usually only understands one of them: the FileSystem plugin's "Move to
/// Trash" tests for `file://` nodes and would refuse a `git://` repo, even
/// though that repo *is* a directory.
///
/// So an action isn't offered a single target list but a few: the nodes as
/// clicked, and the same nodes seen as each identity they claim. The first
/// list the action accepts is the one it runs against — which is also the one
/// that will make sense to it.
enum ActionTargets {
    /// The target lists to try, most literal first.
    ///
    /// - Parameter identities: a node's other identities, in the order it
    ///   declared them.
    static func variants(for targets: [NodeID],
                         identities: (NodeID) -> [NodeID]) -> [[NodeID]] {
        guard !targets.isEmpty else { return [targets] }
        var variants = [targets]

        // Grouped by scheme rather than by position: a selection of several
        // repos should be offered to the file actions as several directories,
        // in one list, not one action invocation per node.
        var schemes: [String] = []
        var byScheme: [String: [NodeID: NodeID]] = [:]
        for target in targets {
            for identity in identities(target) {
                guard let scheme = identity.scheme else { continue }
                if byScheme[scheme] == nil { schemes.append(scheme) }
                // First declared wins: a node claiming two identities of the
                // same kind means the first is its primary.
                if byScheme[scheme]?[target] == nil {
                    byScheme[scheme, default: [:]][target] = identity
                }
            }
        }

        for scheme in schemes {
            guard let mapping = byScheme[scheme] else { continue }
            let mapped = targets.map { mapping[$0] ?? $0 }
            // Every target has to be expressible as this identity, or the
            // action would silently act on a mixture of kinds.
            guard mapped.allSatisfy({ $0.scheme == scheme }) else { continue }
            if !variants.contains(mapped) { variants.append(mapped) }
        }
        return variants
    }
}
