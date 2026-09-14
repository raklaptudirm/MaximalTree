import Foundation
import MaximalTreeKit

/// One item in the sidebar's organization: a root, or a folder that holds more
/// entries (folders nest). Pure host-side display; providers and the graph core
/// never see it.
enum RootEntry: Equatable, Identifiable {
    case root(String)          // a root's canonical uri
    case folder(RootFolder)

    var rootURIs: [String] {
        switch self {
        case .root(let uri): return [uri]
        case .folder(let folder): return folder.rootURIs
        }
    }

    /// Stable across reorders, so ForEach animates rather than rebuilds.
    var id: String {
        switch self {
        case .root(let uri): return "r:\(uri)"
        case .folder(let folder): return "f:\(folder.id.uuidString)"
        }
    }
}

/// A named, nestable group of entries in the sidebar.
struct RootFolder: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var entries: [RootEntry] = []
    var isExpanded: Bool = true

    var rootURIs: [String] { entries.flatMap(\.rootURIs) }
}

/// How a workspace's roots are grouped for display: an ordered tree of entries.
/// This is the source of truth for the sidebar; the flat root set the graph core
/// consumes (`context.roots`) is *derived* from it, so folders never leak below
/// the host UI.
struct RootLayout: Codable, Equatable {
    var entries: [RootEntry] = []

    /// Every root uri, in display order (a folder's roots inline where it sits).
    var rootURIs: [String] { entries.flatMap(\.rootURIs) }

    /// A flat layout with every root loose — the shape a pre-folders workspace
    /// migrates into.
    init(looseRoots uris: [String] = []) {
        entries = uris.map(RootEntry.root)
    }

    // MARK: Recursive tree operations (pure, testable)

    static func folderID(containing uri: String, in entries: [RootEntry]) -> UUID? {
        for case .folder(let folder) in entries {
            if folder.entries.contains(where: {
                if case .root(let u) = $0 { return u == uri } else { return false }
            }) { return folder.id }
            if let nested = folderID(containing: uri, in: folder.entries) { return nested }
        }
        return nil
    }

    /// Every group in the tree, depth-tagged — for the "Move to Collection" menu.
    static func folderList(_ entries: [RootEntry], depth: Int = 0)
        -> [(folder: RootFolder, depth: Int)] {
        var result: [(RootFolder, Int)] = []
        for case .folder(let folder) in entries {
            result.append((folder, depth))
            result += folderList(folder.entries, depth: depth + 1)
        }
        return result
    }
}

/// One named set of root nodes — the unit the user switches between. Host-owned and
/// persisted; providers are entirely unaware of workspaces.
struct Workspace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var layout: RootLayout
    /// Which nodes are revealed (disclosed) in the sidebar, as uris. Folder
    /// expansion has always persisted here inside `layout`; node expansion is
    /// the same kind of state — where the user left the tree open — and users
    /// reasonably expect a relaunch to put it back rather than collapse
    /// everything. Stored as uris because a NodeID only exists once its
    /// provider has resolved one.
    var revealedNodes: [String] = []
    /// The groups that are closed, as collection URIs.
    ///
    /// Closed rather than open, because a group is open unless someone closed
    /// it. Here rather than on the collection: whether a group is open is how
    /// this workspace's sidebar looks, and a collection can appear in more than
    /// one.
    var collapsedGroups: [String]? = nil

    /// Made on the spot for a file that belongs to nowhere else, and not
    /// written to the library.
    ///
    /// A file opened from the Finder that no workspace mounts still wants the
    /// whole app around it — a sidebar, tabs, the keys — so it gets a
    /// workspace rather than a window of its own. It just isn't one you asked
    /// for, so it doesn't outlive the session unless you keep it. Deliberately
    /// outside `CodingKeys`: an ephemeral workspace is never encoded, and one
    /// read back from disk is by definition a real one.
    var isEphemeral: Bool = false

    /// Convenience for the flat root set (what older code and `resolvedRoots` want).
    var rootURIs: [String] { layout.rootURIs }

    init(id: UUID = UUID(), name: String, layout: RootLayout = RootLayout(),
         revealedNodes: [String] = []) {
        self.id = id
        self.name = name
        self.layout = layout
        self.revealedNodes = revealedNodes
    }

    init(id: UUID = UUID(), name: String, rootURIs: [String]) {
        self.init(id: id, name: name, layout: RootLayout(looseRoots: rootURIs))
    }

    // Decodes the current shape (`layout`) or a pre-folders workspace (`rootURIs`),
    // so an existing library keeps loading — everything becomes loose roots.
    private enum CodingKeys: String, CodingKey {
        case id, name, layout, rootURIs, revealedNodes, collapsedGroups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        if let layout = try container.decodeIfPresent(RootLayout.self, forKey: .layout) {
            self.layout = layout
        } else {
            let uris = try container.decodeIfPresent([String].self, forKey: .rootURIs) ?? []
            self.layout = RootLayout(looseRoots: uris)
        }
        revealedNodes = try container.decodeIfPresent([String].self, forKey: .revealedNodes) ?? []
        collapsedGroups = try container.decodeIfPresent([String].self, forKey: .collapsedGroups)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(layout, forKey: .layout)
        try container.encode(revealedNodes, forKey: .revealedNodes)
        try container.encodeIfPresent(collapsedGroups, forKey: .collapsedGroups)
    }
}

extension RootEntry: Codable {
    // Explicit, stable JSON: {"type":"root","uri":…} / {"type":"folder","folder":…}.
    private enum CodingKeys: String, CodingKey { case type, uri, folder }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "folder": self = .folder(try container.decode(RootFolder.self, forKey: .folder))
        default:       self = .root(try container.decode(String.self, forKey: .uri))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .root(let uri):
            try container.encode("root", forKey: .type)
            try container.encode(uri, forKey: .uri)
        case .folder(let folder):
            try container.encode("folder", forKey: .type)
            try container.encode(folder, forKey: .folder)
        }
    }
}

extension RootFolder {
    // Decode the current shape (`entries`) or a pre-nesting folder (`rootURIs`),
    // so a library written before folders nested keeps loading.
    private enum CodingKeys: String, CodingKey { case id, name, entries, rootURIs, isExpanded }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        if let entries = try container.decodeIfPresent([RootEntry].self, forKey: .entries) {
            self.entries = entries
        } else {
            let uris = try container.decodeIfPresent([String].self, forKey: .rootURIs) ?? []
            self.entries = uris.map(RootEntry.root)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(entries, forKey: .entries)
        try container.encode(isExpanded, forKey: .isExpanded)
    }
}

/// Everything persisted: all workspaces, which one is active, and the order
/// they were last used in.
///
/// `workspaces` is the order the user arranged and the menu numbers (⌘⌥1 has
/// to mean the same workspace tomorrow); `recentIDs` is the order they were
/// visited in, most recent first, which is what cycling walks. Two orders
/// because one can't be both stable and last-use at once.
struct WorkspaceLibrary: Codable {
    var workspaces: [Workspace]
    var activeID: UUID?
    var recentIDs: [UUID] = []

    init(workspaces: [Workspace], activeID: UUID?, recentIDs: [UUID] = []) {
        self.workspaces = workspaces
        self.activeID = activeID
        self.recentIDs = recentIDs
    }

    // Written by hand so a library saved before recency existed still loads —
    // the synthesized decoder wants every key, default value or not.
    private enum CodingKeys: String, CodingKey { case workspaces, activeID, recentIDs }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        activeID = try container.decodeIfPresent(UUID.self, forKey: .activeID)
        recentIDs = try container.decodeIfPresent([UUID].self, forKey: .recentIDs) ?? []
    }
}

/// The app-managed workspace library (not document-based — a deliberate early
/// decision). Invariant: at least one workspace always exists, and `activeID` always
/// points at one of them.
///
/// Restore resolves each stored root URI back to a live NodeID; roots that no longer
/// resolve are dropped rather than crashing (a root can be renamed/removed while the
/// app is closed — the across-a-launch version of the rename problem).
@MainActor
@Observable
final class WorkspaceStore {
    private let fileURL: URL
    private(set) var library: WorkspaceLibrary

    /// True only when no persisted state existed at all (very first launch). The
    /// caller may seed the initial workspace with provider defaults; a workspace the
    /// user deliberately emptied stays empty.
    let wasFreshlyCreated: Bool

    var active: Workspace {
        library.workspaces.first { $0.id == library.activeID } ?? library.workspaces[0]
    }

    /// Where the groups actually live — see `GroupFold`.
    let collections: CollectionStore

    /// - Parameter fileURL: Overridable for tests; defaults to Application Support.
    /// - Parameter collections: The collections the groups are kept in. By
    ///   default those beside the workspace file, so a store opened on a
    ///   temporary file never touches the reader's own.
    init(fileURL: URL? = nil, collections: CollectionStore? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url
        self.collections = collections ?? CollectionStore(
            url: url.deletingLastPathComponent().appendingPathComponent("collections.json"))

        if let data = try? Data(contentsOf: url),
           let lib = try? JSONDecoder().decode(WorkspaceLibrary.self, from: data),
           !lib.workspaces.isEmpty {
            self.library = lib
            self.wasFreshlyCreated = false
        } else if let migrated = Self.migrateLegacy(besides: url) {
            // Pre-workspaces builds stored a single root set in workspace.json.
            self.library = WorkspaceLibrary(workspaces: [migrated], activeID: migrated.id)
            self.wasFreshlyCreated = false
        } else {
            let main = Workspace(name: "Main")
            self.library = WorkspaceLibrary(workspaces: [main], activeID: main.id)
            self.wasFreshlyCreated = true
        }

        // Heal a dangling activeID rather than trusting the file.
        if !library.workspaces.contains(where: { $0.id == library.activeID }) {
            library.activeID = library.workspaces[0].id
        }
        foldGroupsIntoCollections()
        healRecency()
        persist()
        // A change made to the collections elsewhere — a file renamed under a
        // group, something deleted — has to reach the sidebar that draws them.
        self.collections.onChange = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.reprojectAll() else { return }
                    self.persist()
                    self.onActiveTreeChanged?()
                }
            }
        }
    }

    // MARK: Groups, as collections

    /// Turn every workspace's folders into collections, once.
    ///
    /// A workspace whose top-level collection already exists has been done
    /// already. One that has none has not — which is also what happens if the
    /// collections are ever lost, and then the layout still written beside
    /// them rebuilds them rather than leaving an empty sidebar.
    private func foldGroupsIntoCollections() {
        let existing = collections.byID
        for i in library.workspaces.indices where existing[library.workspaces[i].id] == nil {
            let workspace = library.workspaces[i]
            backUpLibraryOnce()
            collections.replace(
                upserting: GroupFold.collections(from: workspace.layout.entries,
                                                 workspace: workspace.id, named: workspace.name),
                removing: [])
            library.workspaces[i].collapsedGroups = GroupFold.collapsed(in: workspace.layout.entries)
        }
        // A group was open unless someone closed it; a node is closed unless
        // someone opened it. Groups are nodes now, so the ones that were open
        // join the open nodes — once, after which there is no separate list.
        for i in library.workspaces.indices {
            guard let closed = library.workspaces[i].collapsedGroups else { continue }
            let id = library.workspaces[i].id
            let open = reachable(from: id, in: collections.byID).subtracting([id])
                .map(CollectionRef.uri(for:)).filter { !closed.contains($0) }
            library.workspaces[i].revealedNodes =
                Set(library.workspaces[i].revealedNodes).union(open).sorted()
            library.workspaces[i].collapsedGroups = nil
        }
        reprojectAll()
    }

    /// A copy of the library as it was before any of this, kept once.
    ///
    /// The layout is still written beside the collections, so this is not the
    /// only way back. It is the one that does not depend on this code being
    /// right.
    private func backUpLibraryOnce() {
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("workspaces.pre-collections.json")
        let files = FileManager.default
        guard files.fileExists(atPath: fileURL.path), !files.fileExists(atPath: backup.path)
        else { return }
        try? files.copyItem(at: fileURL, to: backup)
    }

    /// Redraw one workspace's layout from its collections. Whether it changed.
    @discardableResult
    private func reproject(at i: Int) -> Bool {
        let workspace = library.workspaces[i]
        let records = collections.byID
        guard records[workspace.id] != nil else { return false }
        // Open or closed is the node expansion now, groups included. Written
        // into the mirrored layout anyway, so a build from before reads a
        // sidebar opened the same way.
        let groups = reachable(from: workspace.id, in: records).subtracting([workspace.id])
        let collapsed = Set(groups.map(CollectionRef.uri(for:)))
            .subtracting(workspace.revealedNodes)
        let entries = GroupFold.layout(workspace: workspace.id, records: records,
                                       collapsed: collapsed)
        guard entries != workspace.layout.entries else { return false }
        library.workspaces[i].layout.entries = entries
        return true
    }

    /// Called when the active workspace's sidebar tree changes, however it
    /// changed — so the owner can bring the mounted roots and the group rows'
    /// records up to date from one place.
    var onActiveTreeChanged: (() -> Void)?

    @discardableResult
    private func reprojectActive() -> Bool {
        guard let i = library.workspaces.firstIndex(where: { $0.id == library.activeID })
        else { return false }
        return reproject(at: i)
    }

    private func treeChanged() {
        let changed = reprojectActive()
        persist()
        if changed { onActiveTreeChanged?() }
    }

    @discardableResult
    private func reprojectAll() -> Bool {
        var changed = false
        for i in library.workspaces.indices where reproject(at: i) { changed = true }
        return changed
    }

    /// Every collection a workspace's sidebar is made of.
    private func reachable(from workspace: UUID,
                           in records: [UUID: CollectionRecord]) -> Set<UUID> {
        var seen: Set<UUID> = []
        var pending = [workspace]
        while let id = pending.popLast() {
            guard seen.insert(id).inserted, let record = records[id] else { continue }
            pending += record.members.compactMap(CollectionRef.id(from:))
        }
        return seen
    }

    private func reachable(fromAllBut excluded: UUID) -> Set<UUID> {
        let records = collections.byID
        return library.workspaces.filter { $0.id != excluded }
            .reduce(into: Set<UUID>()) { $0.formUnion(reachable(from: $1.id, in: records)) }
    }

    // MARK: Roots of the active workspace

    /// Everything mounted in the active workspace, resolved: the members that
    /// are not groups, reachable from its top level. Read-only — see
    /// `restoreRoots` for the launch path.
    func resolvedRoots(using providers: [NodeProvider]) -> [NodeID] {
        reprojectActive()
        return Self.resolve(GroupFold.roots(workspace: active.id, records: collections.byID),
                            using: providers)
    }

    /// Members with no provider are left out: nothing can load them, and the
    /// roots are what the graph actually loads.
    private static func resolve(_ uris: [String], using providers: [NodeProvider]) -> [NodeID] {
        uris.compactMap { uri in
            guard let scheme = NodeID(uri)?.scheme,
                  let provider = providers.first(where: { $0.schemes.contains(scheme) })
            else { return nil }
            return provider.resolve(uri)
        }
    }

    /// Restore the active workspace's roots at launch (and on workspace switch).
    ///
    /// Resolves every stored member **in place**: a provider may spell an
    /// identity differently than it was stored, and that must not read as "the
    /// old root vanished, here's a new one" — which used to take it out of its
    /// group and put it back loose at the end. Rewriting keeps its place. A
    /// member whose plugin is not loaded is kept; only one its own provider
    /// will not resolve is dropped.
    @discardableResult
    func restoreRoots(using providers: [NodeProvider]) -> [NodeID] {
        let records = collections.byID
        var rewritten: [CollectionRecord] = []
        for id in reachable(from: active.id, in: records) {
            guard var record = records[id] else { continue }
            var members: [String] = []
            for member in record.members {
                if let child = CollectionRef.id(from: member), records[child] != nil {
                    members.append(member)                                    // a group
                    continue
                }
                guard let scheme = NodeID(member)?.scheme else { continue }   // malformed
                guard let provider = providers.first(where: { $0.schemes.contains(scheme) }) else {
                    members.append(member)                                    // plugin not loaded
                    continue
                }
                guard let resolved = provider.resolve(member) else { continue }
                if !members.contains(resolved.uri) { members.append(resolved.uri) }
            }
            if members != record.members {
                record.members = members
                rewritten.append(record)
            }
        }
        if !rewritten.isEmpty {
            collections.replace(upserting: rewritten, removing: [], transient: active.isEphemeral)
        }
        let roots = resolvedRoots(using: providers)
        liveRoots = Set(roots.map(\.uri))
        treeChanged()
        return roots
    }

    /// The roots this store last saw live, so a reconcile can tell something
    /// unmounted from something that was never mountable.
    ///
    /// The difference is the whole point. A member whose plugin is not loaded
    /// is never among the live roots, and pruning everything missing from them
    /// is how the sidebar used to lose it — silently, the next time anything
    /// else was mounted.
    private var liveRoots: Set<String> = []

    /// Bring the active workspace in line with the live root set, after
    /// something mounted or unmounted outside the sidebar.
    ///
    /// What was live and no longer is leaves every group here. What is live and
    /// placed nowhere joins `group` — the one holding what you were looking at,
    /// so it lands beside its siblings — else the top level. Groups stay, empty
    /// or not: they are there on purpose.
    func reconcileRoots(_ roots: [NodeID], placingNewInto group: UUID? = nil) {
        let desired = roots.map(\.uri)
        let desiredSet = Set(desired)
        var records = collections.byID
        let tree = reachable(from: active.id, in: records)
        var updated: [UUID: CollectionRecord] = [:]

        let gone = liveRoots.subtracting(desiredSet)
        if !gone.isEmpty {
            for id in tree {
                guard var record = records[id] else { continue }
                let kept = record.members.filter { !gone.contains($0) }
                guard kept != record.members else { continue }
                record.members = kept
                records[id] = record
                updated[id] = record
            }
        }
        let placed = Set(GroupFold.roots(workspace: active.id, records: records))
        let additions = desired.filter { !placed.contains($0) }
        let destination = group.flatMap { tree.contains($0) ? $0 : nil } ?? active.id
        if !additions.isEmpty, var holder = records[destination] {
            holder.members = CollectionRules.adopt(additions, into: holder.members, at: nil)
            updated[destination] = holder
        }
        liveRoots = desiredSet
        if !updated.isEmpty {
            collections.replace(upserting: Array(updated.values), removing: [],
                                transient: active.isEphemeral)
        }
        treeChanged()
    }

    // MARK: Groups in the active workspace

    /// A new, empty group inside `parent`, or at the top level.
    @discardableResult
    func createGroup(named name: String, in parent: UUID? = nil) -> UUID {
        let records = collections.byID
        let tree = reachable(from: active.id, in: records)
        let destination = parent.flatMap { tree.contains($0) ? $0 : nil } ?? active.id
        guard var holder = records[destination] else { return active.id }
        let group = CollectionRecord(id: UUID(), name: name, members: [])
        holder.members.append(group.uri)
        collections.replace(upserting: [group, holder], removing: [], transient: active.isEphemeral)
        treeChanged()
        return group.id
    }

    /// Move things from one place in the sidebar to another: out of `source`
    /// and into `destination` (nil is the top level for both) at `index`.
    ///
    /// Within one place this is a reorder, and the position counts from before
    /// the item leaves — so dropping on the strip above C lands before C. The
    /// old layout removed first and inserted after, which put anything moved
    /// downward one place past where it was aimed.
    func move(_ uris: [String], from source: UUID?, to destination: UUID?, at index: Int?) {
        let records = collections.byID
        let tree = reachable(from: active.id, in: records)
        let from = source ?? active.id, to = destination ?? active.id
        guard !uris.isEmpty, tree.contains(from), tree.contains(to),
              !formsCycle(moving: uris, into: to, records: records) else { return }
        var updated: [UUID: CollectionRecord] = [:]
        if from != to, var holder = records[from] {
            holder.members = CollectionRules.release(uris, from: holder.members)
            updated[from] = holder
        }
        if var holder = updated[to] ?? records[to] {
            holder.members = CollectionRules.adopt(uris, into: holder.members, at: index)
            updated[to] = holder
        }
        collections.replace(upserting: Array(updated.values), removing: [],
                            transient: active.isEphemeral)
        treeChanged()
    }

    /// Put things into `destination` as well, leaving them where they already
    /// are — what membership allows, and what holding Option while dragging
    /// asks for.
    func add(_ uris: [String], to destination: UUID?, at index: Int?) {
        let records = collections.byID
        let to = destination ?? active.id
        guard !uris.isEmpty, reachable(from: active.id, in: records).contains(to),
              !formsCycle(moving: uris, into: to, records: records),
              var holder = records[to] else { return }
        holder.members = CollectionRules.adopt(uris, into: holder.members, at: index)
        collections.replace(upserting: [holder], removing: [], transient: active.isEphemeral)
        treeChanged()
    }

    /// Delete a group. What it held takes its place wherever it was — nothing
    /// in a group is lost with the group.
    func deleteGroup(_ id: UUID) {
        guard id != active.id else { return }
        collections.delete(id)
        treeChanged()
    }

    /// Take things out of one place in the sidebar — `group`, or the top level.
    ///
    /// Anything also somewhere else stays there, and stays mounted. A group
    /// that now lives nowhere is deleted, and so is any group inside it that
    /// nothing else holds: a collection exists only in sidebars, so for one
    /// that is in no sidebar, removing it is deleting it. Left behind it would
    /// be a record nothing can ever reach again.
    ///
    /// Only what this removal orphaned. A collection unreachable for some other
    /// reason — left by an older build — is not this operation's to judge.
    func remove(_ uris: [String], from group: UUID?) {
        let from = group ?? active.id
        var records = collections.byID
        guard reachable(from: active.id, in: records).contains(from),
              var holder = records[from] else { return }
        holder.members = CollectionRules.release(uris, from: holder.members)
        records[from] = holder

        let candidates = uris.compactMap(CollectionRef.id(from:))
            .reduce(into: Set<UUID>()) { $0.formUnion(reachable(from: $1, in: records)) }
        let stillShown = library.workspaces
            .reduce(into: Set<UUID>()) { $0.formUnion(reachable(from: $1.id, in: records)) }
        collections.replace(upserting: [holder], removing: candidates.subtracting(stillShown),
                            transient: active.isEphemeral)
        treeChanged()
    }

    /// Whether putting these into `destination` would put a group inside
    /// itself — the one arrangement the sidebar cannot draw.
    private func formsCycle(moving uris: [String], into destination: UUID,
                            records: [UUID: CollectionRecord]) -> Bool {
        uris.compactMap(CollectionRef.id(from:)).contains { group in
            reachable(from: group, in: records).contains(destination)
        }
    }

    /// Record which nodes are revealed in the active workspace's sidebar —
    /// groups among them. Sorted so the persisted file doesn't churn on set
    /// reordering.
    func setRevealedNodes(_ uris: [String]) {
        let sorted = uris.sorted()
        guard active.revealedNodes != sorted else { return }
        mutateActive { $0.revealedNodes = sorted }
    }

    /// The group directly holding `uri`, if anything but the top level does.
    func groupContaining(_ uri: String) -> UUID? {
        reprojectActive()
        return RootLayout.folderID(containing: uri, in: active.layout.entries)
    }

    // MARK: Library management

    @discardableResult
    func create(named name: String) -> Workspace {
        let workspace = Workspace(name: name)
        library.workspaces.append(workspace)
        collections.replace(upserting: GroupFold.collections(from: [], workspace: workspace.id,
                                                             named: name),
                            removing: [])
        persist()
        return workspace
    }

    /// A workspace for something passing through: listed and switchable like
    /// any other, but never written down.
    func createEphemeral(named name: String, rootURIs: [String]) -> Workspace {
        var workspace = Workspace(name: name, rootURIs: rootURIs)
        workspace.isEphemeral = true
        library.workspaces.append(workspace)
        // In memory only, like the workspace: written down if it is kept.
        collections.replace(upserting: GroupFold.collections(from: workspace.layout.entries,
                                                             workspace: workspace.id, named: name),
                            removing: [], transient: true)
        return workspace
    }

    /// Keep an ephemeral workspace: from here on it is a workspace like any
    /// other, and survives the app being closed.
    func keep(_ id: UUID) {
        guard let i = library.workspaces.firstIndex(where: { $0.id == id }),
              library.workspaces[i].isEphemeral else { return }
        library.workspaces[i].isEphemeral = false
        collections.makePermanent(reachable(from: id, in: collections.byID))
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = library.workspaces.firstIndex(where: { $0.id == id }) else { return }
        library.workspaces[i].name = name
        if var top = collections.record(id) {
            top.name = name
            collections.replace(upserting: [top], removing: [])
        }
        persist()
    }

    /// Deleting only forgets a root list — the nodes themselves are untouched.
    /// Refuses to delete the last workspace; deleting the active one activates
    /// the first remaining.
    func delete(_ id: UUID) {
        guard library.workspaces.count > 1,
              let i = library.workspaces.firstIndex(where: { $0.id == id }) else { return }
        // Its groups go with it, except any another workspace still shows.
        let doomed = reachable(from: id, in: collections.byID)
            .subtracting(reachable(fromAllBut: id))
        collections.replace(upserting: [], removing: doomed)
        library.workspaces.remove(at: i)
        library.recentIDs.removeAll { $0 == id }
        // The most recently used one, which is where you were before here.
        if library.activeID == id { library.activeID = byRecency[0].id }
        persist()
    }

    func setActive(_ id: UUID) {
        guard library.workspaces.contains(where: { $0.id == id }) else { return }
        library.activeID = id
        promote(id)
        persist()
    }

    // MARK: Last-use order

    /// The workspaces in last-use order, the active one first.
    ///
    /// This is what cycling walks, and why `SPC w n` twice puts you back: the
    /// one you leave becomes second, so the next step is the way you came.
    /// Alt-tab's bargain — the two you are working between stay one keystroke
    /// apart, and the rest sort themselves by how recently they mattered.
    var byRecency: [Workspace] {
        let ordered = library.recentIDs.compactMap { id in
            library.workspaces.first { $0.id == id }
        }
        let known = Set(library.recentIDs)
        return ordered + library.workspaces.filter { !known.contains($0.id) }
    }

    /// Move a workspace to the front of the last-use order.
    private func promote(_ id: UUID) {
        library.recentIDs.removeAll { $0 == id }
        library.recentIDs.insert(id, at: 0)
    }

    /// Make the recency list say exactly what exists, active first — for a
    /// library written before recency, one edited elsewhere, or one whose
    /// ephemeral workspaces went away with the last session.
    private func healRecency() {
        let live = Set(library.workspaces.map(\.id))
        library.recentIDs = library.recentIDs.filter { live.contains($0) }
        let known = Set(library.recentIDs)
        library.recentIDs += library.workspaces.map(\.id).filter { !known.contains($0) }
        if let active = library.activeID { promote(active) }
    }

    // MARK: Persistence

    /// Change the active workspace's own settings — not its groups, which are
    /// written as collections by the operations above.
    ///
    /// Redrawn from the collections before and after: the layout in memory is
    /// only as fresh as its last redraw, and the mirror written beside it has
    /// to match what is actually there.
    private func mutateActive(_ change: (inout Workspace) -> Void) {
        guard let i = library.workspaces.firstIndex(where: { $0.id == library.activeID })
        else { return }
        reproject(at: i)
        change(&library.workspaces[i])
        reproject(at: i)
        persist()
    }

    /// Writes the library, minus anything ephemeral.
    ///
    /// Which is how an ephemeral workspace goes away on its own: nothing
    /// deletes it, it was simply never written down. The active id follows the
    /// same rule — pointing the stored library at a workspace that won't be
    /// there on the next launch would leave it with no active workspace at all.
    private func persist() {
        var stored = library
        stored.workspaces = library.workspaces.filter { !$0.isEphemeral }
        guard !stored.workspaces.isEmpty else { return }
        let kept = Set(stored.workspaces.map(\.id))
        stored.recentIDs = library.recentIDs.filter { kept.contains($0) }
        if !stored.workspaces.contains(where: { $0.id == stored.activeID }) {
            stored.activeID = stored.workspaces[0].id
        }
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func defaultURL() -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaximalTree", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspaces.json")
    }

    /// The pre-workspaces format: a single `{name, rootURIs}` in workspace.json
    /// next to where the library now lives.
    private static func migrateLegacy(besides url: URL) -> Workspace? {
        struct Legacy: Codable {
            var name: String
            var rootURIs: [String]
        }
        let legacyURL = url.deletingLastPathComponent().appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode(Legacy.self, from: data) else { return nil }
        let name = legacy.name == "Untitled" ? "Main" : legacy.name
        return Workspace(name: name, rootURIs: legacy.rootURIs)
    }
}
