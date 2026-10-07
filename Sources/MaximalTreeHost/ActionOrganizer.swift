import Foundation
import MaximalTreeKit

/// One section of a menu: the actions one plugin contributes, in order.
struct ActionGroup: Identifiable {
    /// The contributing plugin's name, or nil for the app's own actions —
    /// those read as the menu's top, not as somebody's section.
    let title: String?
    let actions: [Action]

    var id: String { title ?? "" }
}

/// Turns the flat action registry into what a surface should actually show.
///
/// Every action reaching every surface is what made the right-click menu a
/// list of everything the app can do. Two rules fix that, and they're the same
/// two rules the user reads off the screen:
///
/// 1. **Surface** — an action appears only where it belongs (see
///    `ActionScope.defaultSurfaces`).
/// 2. **Distance from what you're pointing at** — sections are ordered by the
///    most node-specific action they hold, and within a section actions run
///    from node-scoped outwards.
///
/// Grouping is by contributing plugin, so a menu reads as "the things this
/// file's own plugin can do", then everyone else's.
enum ActionOrganizer {
    /// - Parameter preferredOwner: the plugin owning the node in front of the
    ///   reader. Its section leads the plugins', because its actions are the
    ///   ones about *this* node rather than about nodes in general.
    static func groups(_ actions: [Action], for surface: ActionSurfaces,
                       preferredOwner: String? = nil) -> [ActionGroup] {
        let visible = actions.filter { !$0.surfaces.isDisjoint(with: surface) }
        guard !visible.isEmpty else { return [] }

        var byOwner: [String?: [Action]] = [:]
        var order: [String?] = []
        for action in visible {
            if byOwner[action.owner] == nil { order.append(action.owner) }
            byOwner[action.owner, default: []].append(action)
        }

        return order
            .map { owner in
                // Stable within a scope: registration order is deliberate
                // ("New File" before "New Folder"), so only the scope sorts.
                let sorted = byOwner[owner]!.enumerated()
                    .sorted { a, b in
                        a.element.scope == b.element.scope
                            ? a.offset < b.offset
                            : a.element.scope < b.element.scope
                    }
                    .map(\.element)
                return ActionGroup(title: owner, actions: sorted)
            }
            .sorted { a, b in
                let scopeA = a.actions.first?.scope ?? .workspace
                let scopeB = b.actions.first?.scope ?? .workspace
                if scopeA != scopeB { return scopeA < scopeB }
                let rankA = rank(a.title, preferredOwner: preferredOwner)
                let rankB = rank(b.title, preferredOwner: preferredOwner)
                if rankA != rankB { return rankA < rankB }
                return (a.title ?? "") < (b.title ?? "")
            }
    }

    /// The app's own actions lead — they're the generic vocabulary every node
    /// answers to (rename, delete), and a menu that opens with them reads the
    /// way the platform's do. Then the node's own plugin, then the rest.
    private static func rank(_ owner: String?, preferredOwner: String?) -> Int {
        if owner == nil { return 0 }
        if let preferredOwner, owner == preferredOwner { return 1 }
        return 2
    }
}
