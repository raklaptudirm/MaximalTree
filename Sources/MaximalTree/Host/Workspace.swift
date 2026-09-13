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

/// A lightweight reference to an entry, for drag-and-drop and moves: a root by
/// its uri, a folder by its id.
enum EntryRef: Hashable {
    case root(String)
    case folder(UUID)

    /// A stable drag token, `root:<uri>` / `folder:<uuid>`.
    var token: String {
        switch self {
        case .root(let uri): return "root:\(uri)"
        case .folder(let id): return "folder:\(id.uuidString)"
        }
    }

    init?(token: String) {
        if let uri = token.dropPrefix("root:") { self = .root(uri) }
        else if let raw = token.dropPrefix("folder:"), let id = UUID(uuidString: raw) {
            self = .folder(id)
        } else { return nil }
    }

    func matches(_ entry: RootEntry) -> Bool {
        switch (self, entry) {
        case (.root(let a), .root(let b)): return a == b
        case (.folder(let a), .folder(let b)): return a == b.id
        default: return false
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
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

    /// Drop root entries whose uri isn't in `keeping`, at any depth. Folders are
    /// kept even when they empty out — they're intentional containers.
    static func prune(_ entries: inout [RootEntry], keeping: Set<String>) {
        entries = entries.compactMap { entry in
            switch entry {
            case .root(let uri):
                return keeping.contains(uri) ? entry : nil
            case .folder(var folder):
                prune(&folder.entries, keeping: keeping)
                return .folder(folder)
            }
        }
    }

    /// Insert `items` into `folder` (nil = this level) at `index` (nil = end).
    /// Returns whether the destination folder was found.
    @discardableResult
    static func insert(_ items: [RootEntry], into entries: inout [RootEntry],
                       folder folderID: UUID?, at index: Int?) -> Bool {
        guard let folderID else {
            let at = min(index ?? entries.count, entries.count)
            entries.insert(contentsOf: items, at: max(0, at))
            return true
        }
        for i in entries.indices {
            if case .folder(var folder) = entries[i] {
                if folder.id == folderID {
                    let at = min(index ?? folder.entries.count, folder.entries.count)
                    folder.entries.insert(contentsOf: items, at: max(0, at))
                    entries[i] = .folder(folder)
                    return true
                }
                if insert(items, into: &folder.entries, folder: folderID, at: index) {
                    entries[i] = .folder(folder)
                    return true
                }
            }
        }
        return false
    }

    /// Remove every entry matching `refs` at any depth; return them (for reinsert).
    static func remove(_ refs: Set<EntryRef>, from entries: inout [RootEntry]) -> [RootEntry] {
        var removed: [RootEntry] = []
        entries = entries.compactMap { entry in
            if refs.contains(where: { $0.matches(entry) }) {
                removed.append(entry)
                return nil
            }
            if case .folder(var folder) = entry {
                removed.append(contentsOf: remove(refs, from: &folder.entries))
                return .folder(folder)
            }
            return entry
        }
        return removed
    }

    /// Replace the folder `id` with its own entries, wherever it sits.
    static func deleteFolder(_ id: UUID, in entries: inout [RootEntry]) {
        var result: [RootEntry] = []
        for entry in entries {
            if case .folder(var folder) = entry {
                if folder.id == id {
                    result.append(contentsOf: folder.entries)   // spill contents in place
                    continue
                }
                deleteFolder(id, in: &folder.entries)
                result.append(.folder(folder))
            } else {
                result.append(entry)
            }
        }
        entries = result
    }

    static func mutateFolder(_ id: UUID, in entries: inout [RootEntry],
                             _ change: (inout RootFolder) -> Void) {
        for i in entries.indices {
            if case .folder(var folder) = entries[i] {
                if folder.id == id {
                    change(&folder)
                    entries[i] = .folder(folder)
                    return
                }
                mutateFolder(id, in: &folder.entries, change)
                entries[i] = .folder(folder)
            }
        }
    }

    static func folderID(containing uri: String, in entries: [RootEntry]) -> UUID? {
        for case .folder(let folder) in entries {
            if folder.entries.contains(where: {
                if case .root(let u) = $0 { return u == uri } else { return false }
            }) { return folder.id }
            if let nested = folderID(containing: uri, in: folder.entries) { return nested }
        }
        return nil
    }

    /// Whether `folderID`'s subtree contains `target` (a descendant folder) —
    /// the cycle check for moves.
    static func folder(_ folderID: UUID, contains target: UUID,
                       in entries: [RootEntry]) -> Bool {
        for case .folder(let folder) in entries {
            if folder.id == folderID {
                return descendantFolderIDs(of: folder).contains(target)
            }
            if self.folder(folderID, contains: target, in: folder.entries) { return true }
        }
        return false
    }

    private static func descendantFolderIDs(of folder: RootFolder) -> Set<UUID> {
        var ids: Set<UUID> = []
        for case .folder(let child) in folder.entries {
            ids.insert(child.id)
            ids.formUnion(descendantFolderIDs(of: child))
        }
        return ids
    }

    /// Resolve every root through its owning provider, rewriting entries whose
    /// canonical spelling changed and collecting the live ids in display order.
    ///
    /// Dropped: roots the owning provider says are gone, and malformed uris.
    /// **Kept**: roots whose scheme has no provider — a plugin that isn't loaded
    /// right now can't testify that its roots are gone, and silently deleting a
    /// user's sidebar entry is far worse than showing one that's briefly inert.
    static func resolveInPlace(_ entries: inout [RootEntry],
                               using providers: [NodeProvider],
                               into ids: inout [NodeID]) {
        var result: [RootEntry] = []
        for entry in entries {
            switch entry {
            case .root(let uri):
                guard let scheme = NodeID(uri)?.scheme else { continue }
                guard let provider = providers.first(where: { $0.schemes.contains(scheme) })
                else {
                    result.append(entry)
                    continue
                }
                guard let resolved = provider.resolve(uri) else { continue }
                result.append(.root(resolved.uri))
                ids.append(resolved)
            case .folder(var folder):
                resolveInPlace(&folder.entries, using: providers, into: &ids)
                result.append(.folder(folder))
            }
        }
        entries = result
    }

    /// Every folder in the tree, depth-tagged — for the "Move to Folder" menu.
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
    var collapsedGroups: [String] = []

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
        collapsedGroups = try container.decodeIfPresent([String].self, forKey: .collapsedGroups) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(layout, forKey: .layout)
        try container.encode(revealedNodes, forKey: .revealedNodes)
        try container.encode(collapsedGroups, forKey: .collapsedGroups)
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
        let entries = GroupFold.layout(workspace: workspace.id, records: records,
                                       collapsed: Set(workspace.collapsedGroups))
        guard entries != workspace.layout.entries else { return false }
        library.workspaces[i].layout.entries = entries
        return true
    }

    @discardableResult
    private func reprojectAll() -> Bool {
        var changed = false
        for i in library.workspaces.indices where reproject(at: i) { changed = true }
        return changed
    }

    /// Write a workspace's layout back into its collections.
    ///
    /// Groups this change took out of the sidebar are deleted — unless another
    /// workspace still shows them, since collections are shared between
    /// workspaces and one sidebar forgetting a group is not the others doing so.
    private func writeThrough(_ i: Int, previous: [RootEntry]) {
        let workspace = library.workspaces[i]
        let incoming = GroupFold.collections(from: workspace.layout.entries,
                                             workspace: workspace.id, named: workspace.name)
        let before = Set(GroupFold.collections(from: previous, workspace: workspace.id,
                                               named: workspace.name).map(\.id))
        let orphaned = before.subtracting(incoming.map(\.id))
            .subtracting(reachable(fromAllBut: workspace.id))
        collections.replace(upserting: incoming, removing: orphaned,
                            transient: workspace.isEphemeral)
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

    /// Resolve the active workspace's stored roots to live NodeIDs, dropping any
    /// that no longer resolve. Read-only — see `restoreRoots` for the launch path.
    func resolvedRoots(using providers: [NodeProvider]) -> [NodeID] {
        if let i = library.workspaces.firstIndex(where: { $0.id == library.activeID }) {
            reproject(at: i)
        }
        var entries = active.layout.entries
        var ids: [NodeID] = []
        RootLayout.resolveInPlace(&entries, using: providers, into: &ids)
        return ids
    }

    /// Restore the active workspace's roots at launch (and on workspace switch).
    ///
    /// Resolves every stored root **in place**: a provider may spell an identity
    /// differently than we stored it (they build ids with `NodeID(canonical:)`
    /// but resolve through the normalizing initializer), and that must not read
    /// as "the old root vanished, here's a new one" — that used to prune the
    /// entry out of its folder and re-append it loose at the end, which looks
    /// exactly like the root disappearing. Rewriting keeps its place; only roots
    /// the owning provider reports gone are dropped.
    @discardableResult
    func restoreRoots(using providers: [NodeProvider]) -> [NodeID] {
        var ids: [NodeID] = []
        mutateActive { workspace in
            RootLayout.resolveInPlace(&workspace.layout.entries, using: providers, into: &ids)
        }
        return ids
    }

    /// Reconcile the active workspace's layout with the live root set (called on
    /// every mount/unmount). Existing organization is preserved: entries whose
    /// root vanished are pruned (empty folders kept — they're intentional), and
    /// roots not yet placed are appended — into `folderID` when given (the
    /// current node's folder, so a new root lands beside its siblings), else
    /// loose at the end.
    func reconcileRoots(_ roots: [NodeID], placingNewInto folderID: UUID? = nil) {
        let desired = roots.map(\.uri)
        let desiredSet = Set(desired)
        mutateActive { workspace in
            RootLayout.prune(&workspace.layout.entries, keeping: desiredSet)
            let placed = Set(workspace.layout.rootURIs)
            let additions = desired.filter { !placed.contains($0) }.map(RootEntry.root)
            guard !additions.isEmpty else { return }
            _ = RootLayout.insert(additions, into: &workspace.layout.entries,
                                  folder: folderID, at: nil)
        }
    }

    // MARK: Folder management (active workspace)

    @discardableResult
    func createFolder(named name: String, in parent: UUID? = nil) -> UUID {
        let folder = RootFolder(name: name)
        mutateActive {
            _ = RootLayout.insert([.folder(folder)], into: &$0.layout.entries,
                                  folder: parent, at: nil)
        }
        return folder.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        mutateActive { RootLayout.mutateFolder(id, in: &$0.layout.entries) { $0.name = name } }
    }

    /// Record which nodes are revealed in the active workspace's sidebar.
    /// Sorted so the persisted file doesn't churn on set reordering.
    func setRevealedNodes(_ uris: [String]) {
        let sorted = uris.sorted()
        guard active.revealedNodes != sorted else { return }
        mutateActive { $0.revealedNodes = sorted }
    }

    func setFolderExpanded(_ id: UUID, _ expanded: Bool) {
        mutateActive { RootLayout.mutateFolder(id, in: &$0.layout.entries) { $0.isExpanded = expanded } }
    }

    /// Delete a folder but keep its contents — they spill out where the folder
    /// sat (nested folders included), so nothing is lost with its container.
    func deleteFolder(_ id: UUID) {
        mutateActive { RootLayout.deleteFolder(id, in: &$0.layout.entries) }
    }

    /// Move roots (by uri) into `folderID` (nil = top level) at the end.
    func moveRoots(_ uris: [String], toFolder folderID: UUID?) {
        moveEntries(uris.map(EntryRef.root), toFolder: folderID, at: nil)
    }

    /// Reparent/reorder entries: pull `refs` out of wherever they sit and drop
    /// them into `folderID` (nil = top level) at `index` (nil = end), preserving
    /// `refs` order. Refuses to move a folder into itself or its own descendant.
    func moveEntries(_ refs: [EntryRef], toFolder folderID: UUID?, at index: Int?) {
        guard !refs.isEmpty else { return }
        mutateActive { workspace in
            // Cycle guard: a folder can't land inside itself or its subtree.
            let movedFolderIDs = refs.compactMap { ref -> UUID? in
                if case .folder(let id) = ref { return id } else { return nil }
            }
            if let folderID {
                for movedID in movedFolderIDs {
                    if movedID == folderID
                        || RootLayout.folder(movedID, contains: folderID,
                                             in: workspace.layout.entries) {
                        return
                    }
                }
            }
            let removed = RootLayout.remove(Set(refs), from: &workspace.layout.entries)
            // Reorder the removed entries to match the requested ref order.
            let ordered = refs.compactMap { ref in removed.first { ref.matches($0) } }
            _ = RootLayout.insert(ordered, into: &workspace.layout.entries,
                                  folder: folderID, at: index)
        }
    }

    /// The folder currently holding `uri`, if any (searches nested folders).
    func folderID(containing uri: String) -> UUID? {
        RootLayout.folderID(containing: uri, in: active.layout.entries)
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

    /// Change the active workspace, with its groups kept in its collections.
    ///
    /// Every group operation above is a pure function over a layout, and they
    /// are left exactly as they were: this starts from the collections, lets
    /// the operation work, and writes the result back.
    ///
    /// *Starts from the collections* is the part that matters. The layout in
    /// memory is only as fresh as the last redraw, and something else — a file
    /// renamed inside a group — can change the collections in between. An
    /// operation working on the stale copy would write it back and quietly
    /// undo that change.
    private func mutateActive(_ change: (inout Workspace) -> Void) {
        guard let i = library.workspaces.firstIndex(where: { $0.id == library.activeID })
        else { return }
        reproject(at: i)
        let previous = library.workspaces[i].layout.entries
        change(&library.workspaces[i])
        let current = library.workspaces[i].layout.entries
        if current != previous {
            library.workspaces[i].collapsedGroups = GroupFold.collapsed(in: current)
            writeThrough(i, previous: previous)
        }
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
