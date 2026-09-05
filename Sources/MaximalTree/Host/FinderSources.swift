import AppKit
import MaximalTreeKit

/// The lists the host itself can search.
///
/// Files, open tabs, workspaces, and every command — the things that exist
/// whatever plugins are loaded. Everything else arrives the same way a canvas
/// or an action does: a plugin registers a `FinderSource`, and it appears in
/// the finder with a key of its own, so "find a note" ships with the plugin
/// that owns notes.
extension AppModel {
    func registerBuiltInFinders(into registry: Registry) {
        registry.register(finder: FinderSource(
            id: "actions", title: "Action", prompt: "Run an action…",
            systemImage: "command",
            // Few, and every one deliberately named — so when a query matches
            // one it is usually the one meant.
            weight: 18
        ) { [weak self] in
            await MainActor.run { self?.actionItems() ?? [] }
        })

        // The context menu, as something you can type at. Not searched by
        // default: these actions are already in "actions", and listing them
        // twice in one result set would be the same command answering itself.
        registry.register(finder: FinderSource(
            id: "node-actions", title: "Act", prompt: "Act on the current node…",
            systemImage: "hand.tap",
            searchedByDefault: false
        ) { [weak self] in
            await MainActor.run { self?.nodeActionItems() ?? [] }
        })

        registry.register(finder: FinderSource(
            id: "buffers", title: "Open", prompt: "Go to an open tab…",
            systemImage: "square.on.square",
            // Fewer still, and you had them open a moment ago.
            weight: 22
        ) { [weak self] in
            await MainActor.run { self?.tabItems() ?? [] }
        })

        registry.register(finder: FinderSource(
            id: "nodes", title: "Sidebar", prompt: "Go to a node…",
            systemImage: "sidebar.left",
            // What is in front of you, so it wins ties against the thousands
            // of files that merely exist.
            weight: 20
        ) { [weak self] in
            await MainActor.run { self?.nodeItems() ?? [] }
        })

        registry.register(finder: FinderSource(
            id: "files", title: "File", prompt: "Find a file…",
            systemImage: "doc.text"
        ) { [weak self] in
            await self?.fileItems() ?? []
        })

        registry.register(finder: FinderSource(
            id: "workspaces", title: "Workspace", prompt: "Switch workspace…",
            systemImage: "square.stack.3d.up",
            // Reached by its own key. Workspace names would otherwise crowd a
            // search meant for the workspace you are already in.
            searchedByDefault: false
        ) { [weak self] in
            await MainActor.run { self?.workspaceItems() ?? [] }
        })
    }

    /// What can be done to the node in front of you.
    ///
    /// The selection, or the focused node when nothing is selected — the same
    /// thing the inspector shows, so the two never disagree about what "the
    /// current node" is.
    ///
    /// Narrowed by scope rather than by predicate. Every app-level operation
    /// applies to a node too, in the sense of not being stopped by it, so
    /// filtering only on applicability would list the whole app again. What
    /// makes an action belong here is that it is *about* the node: acting on
    /// it, or inside it, or on the document it opens.
    private func nodeActionItems() -> [FinderItem] {
        let targets = host.selection.isEmpty
            ? [host.focusedNode].compactMap { $0 }
            : host.selection
        guard !targets.isEmpty else { return [] }
        return applicableActions(for: targets)
            .filter { $0.scope == .node || $0.scope == .container || $0.scope == .document }
            .map { action in
                FinderItem(id: "node-action:\(action.id)", title: action.title,
                           subtitle: action.id,
                           systemImage: action.systemImage ?? "hand.tap",
                           effect: .run(action.id))
            }
    }

    private func actionItems() -> [FinderItem] {
        applicableActions().map { action in
            FinderItem(id: "action:\(action.id)", title: action.title,
                       subtitle: action.id, systemImage: action.systemImage ?? "command",
                       effect: .run(action.id))
        }
    }

    /// The tree as the sidebar is showing it — roots, and whatever is
    /// disclosed beneath them.
    ///
    /// Deliberately what is *on screen* rather than everything reachable:
    /// this is the picker for going to something you can already see, where
    /// the file search is the one for reaching what you can't. Identified by
    /// uri, so a node that is also a file is one row rather than two.
    private func nodeItems() -> [FinderItem] {
        orderedExplorerNodes().compactMap { id in
            guard let node = host.node(id) else { return nil }
            return FinderItem(id: id.uri, title: node.label,
                              subtitle: folder(of: id),
                              systemImage: node.icon?.systemName ?? "doc",
                              effect: .open(id.uri))
        }
    }

    /// The containing folder, so two tabs on files of the same name can be
    /// told apart.
    private func folder(of id: NodeID) -> String? {
        guard let url = URL(string: id.uri), url.isFileURL else { return id.scheme }
        return url.deletingLastPathComponent().lastPathComponent
    }

    /// One entry per *thing* that is open, not per tab showing one.
    ///
    /// A node that answers to another name is that thing — a typst document's
    /// pages are the document, the way a repository is its directory. So two
    /// tabs on two names list once, under the name the thing is known by, and
    /// picking it goes to the tab showing that name if one is open. Listing
    /// both would say there are two documents open, which contradicts what
    /// declaring the identity claimed.
    private func tabItems() -> [FinderItem] {
        let open = navigation.tabs.compactMap { tab -> (tab: UUID, id: NodeID)? in
            guard let id = tab.current, host.node(id) != nil else { return nil }
            return (tab.id, id)
        }
        return FinderIdentities.collapse(open) { host.node($0)?.identities ?? [] }
            .compactMap { entry in
                guard let node = host.node(entry.id) else { return nil }
                let subject = host.node(entry.canonical) ?? node
                return FinderItem(id: "tab:\(entry.tab)", title: subject.label,
                                  subtitle: folder(of: entry.canonical),
                                  systemImage: node.icon?.systemName ?? "square.on.square",
                                  effect: .open(entry.id.uri))
            }
    }

    /// Last-use order, like the switcher it stands in for: the one you were
    /// in before this is at the top, and typing a name still beats reading a
    /// list. The menu bar keeps the arranged order, where the numbers live.
    private func workspaceItems() -> [FinderItem] {
        workspacesByRecency.map { workspace in
            FinderItem(id: "workspace:\(workspace.id)", title: workspace.name,
                       systemImage: "square.stack.3d.up",
                       effect: .run("workspace.select:\(workspace.id)"))
        }
    }

    /// Every file under the mounted roots.
    private func fileItems() async -> [FinderItem] {
        let roots = host.roots
            .compactMap { URL(string: $0.uri) }
            .filter(\.isFileURL)
        guard !roots.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            FinderFiles.items(under: roots)
        }.value
    }

    // MARK: Running what was picked

    /// Do what the picked item says. Both effects are named the way the rest
    /// of the app names things, so this is a lookup rather than a special
    /// case per source.
    func perform(_ item: FinderItem) {
        switch item.effect {
        case .open(let uri):
            guard let id = NodeID(uri) else { return }
            host.select([id])
            store?.open(id)
        case .run(let command):
            // Workspaces are the one thing with no action of its own, since
            // which workspace is part of the id rather than the command.
            if command.hasPrefix("workspace.select:") {
                let raw = String(command.dropFirst("workspace.select:".count))
                if let id = UUID(uuidString: raw) { switchWorkspace(to: id) }
                return
            }
            runCommand(command)
        @unknown default:
            // A newer SDK's effect this build doesn't know how to do.
            return
        }
    }
}


/// One entry per *thing* that is open, not per tab showing one.
///
/// A node that answers to another name is that thing — a typst document's
/// pages are the document, the way a repository is its directory. Two tabs on
/// two names are one entry, under the name the thing is known by, and picking
/// it goes to the tab showing that name when one is open. Listing both would
/// say two documents are open, which is the opposite of what declaring the
/// identity claimed.
///
/// Pure, so the rule can be checked without a window — the same reason
/// `ActionTargets.variants` is.
enum FinderIdentities {
    static func collapse(_ open: [(tab: UUID, id: NodeID)],
                         identities: (NodeID) -> [NodeID])
        -> [(tab: UUID, id: NodeID, canonical: NodeID)] {
        let canonical = open.map { entry in
            (tab: entry.tab, id: entry.id, canonical: identities(entry.id).first ?? entry.id)
        }
        var listed: Set<NodeID> = []
        return canonical.compactMap { entry in
            guard !listed.contains(entry.canonical) else { return nil }
            // Prefer the tab showing the thing under its own name — the
            // document rather than its pages — wherever one is open.
            let preferred = canonical.first { $0.id == entry.canonical } ?? entry
            guard preferred.tab == entry.tab else { return nil }
            listed.insert(entry.canonical)
            return preferred
        }
    }
}
