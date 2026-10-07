import Foundation
import MaximalTreeKit

/// How a workspace's sidebar was written before placements: an ordered tree
/// of roots and folders. Read, to migrate a library written by an older
/// build, and never written.
enum RootEntry: Equatable {
    case root(String)          // a root's canonical uri
    case folder(RootFolder)
}

/// A named, nestable group of entries, as an older build wrote it.
struct RootFolder: Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var entries: [RootEntry] = []
    var isExpanded: Bool = true
}

/// The older sidebar, whole.
struct RootLayout: Codable, Equatable {
    var entries: [RootEntry] = []

    /// The same sidebar as collections, the shape the last builds before
    /// placements kept it in: the top level under the workspace's id, and each
    /// folder under its own.
    func records(workspace: UUID, named name: String) -> [CollectionRecord] {
        var records: [CollectionRecord] = []
        func members(of entries: [RootEntry]) -> [String] {
            entries.map { entry in
                switch entry {
                case .root(let uri):
                    return uri
                case .folder(let folder):
                    records.append(CollectionRecord(id: folder.id, name: folder.name,
                                                    members: members(of: folder.entries)))
                    return CollectionRef.uri(for: folder.id)
                }
            }
        }
        return [CollectionRecord(id: workspace, name: name, members: members(of: entries))] + records
    }

    /// The folders that were open.
    var openFolders: [UUID] {
        func open(_ entries: [RootEntry]) -> [UUID] {
            entries.flatMap { entry -> [UUID] in
                guard case .folder(let folder) = entry else { return [] }
                return (folder.isExpanded ? [folder.id] : []) + open(folder.entries)
            }
        }
        return open(entries)
    }
}

/// One named set of root nodes — the unit the user switches between. Host-owned and
/// persisted; providers are entirely unaware of workspaces.
struct Workspace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// What was put inside what — the sidebar, and anything else something was
    /// dropped into. See `Placements`.
    var placements: Placements
    /// Which nodes are revealed (disclosed) in the sidebar, as uris. Users
    /// reasonably expect a relaunch to put the tree back rather than collapse
    /// everything. Stored as uris because a NodeID only exists once its
    /// provider has resolved one.
    var revealedNodes: [String] = []

    /// The shape an older build wrote, until it is migrated. Present only when
    /// the file had no placements; never written.
    var legacyLayout: RootLayout?
    /// The groups a build from just before placements recorded as closed.
    /// Read with `legacyLayout`, and gone with it.
    var legacyCollapsedGroups: [String]?

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

    /// The entry in `placements` the sidebar is drawn from.
    var root: String { Placements.root(of: id) }

    /// What the sidebar mounts, in order.
    var rootURIs: [String] { placements.leaves(from: root) }

    init(id: UUID = UUID(), name: String, rootURIs: [String] = [], revealedNodes: [String] = []) {
        self.id = id
        self.name = name
        self.placements = Placements(root: Placements.root(of: id), children: rootURIs)
        self.revealedNodes = revealedNodes
    }

    // Decodes the current shape (`placements`), or an older one to migrate:
    // `layout`, or a pre-folders `rootURIs`, whose entries become loose roots.
    private enum CodingKeys: String, CodingKey {
        case id, name, placements, layout, rootURIs, revealedNodes, collapsedGroups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        revealedNodes = try container.decodeIfPresent([String].self, forKey: .revealedNodes) ?? []
        if let placements = try container.decodeIfPresent(Placements.self, forKey: .placements) {
            self.placements = placements
            return
        }
        placements = Placements()
        if let layout = try container.decodeIfPresent(RootLayout.self, forKey: .layout) {
            legacyLayout = layout
        } else {
            let uris = try container.decodeIfPresent([String].self, forKey: .rootURIs) ?? []
            legacyLayout = RootLayout(entries: uris.map(RootEntry.root))
        }
        legacyCollapsedGroups = try container.decodeIfPresent([String].self, forKey: .collapsedGroups)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(placements, forKey: .placements)
        try container.encode(revealedNodes, forKey: .revealedNodes)
    }
}

extension RootEntry: Codable {
    // {"type":"root","uri":…} / {"type":"folder","folder":…}.
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
    // The current shape (`entries`) or a pre-nesting folder (`rootURIs`).
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
final class WorkspaceStore: PlacementHost {
    let fileURL: URL
    private(set) var library: WorkspaceLibrary

    /// True only when no persisted state existed at all (very first launch). The
    /// caller may seed the initial workspace with provider defaults; a workspace the
    /// user deliberately emptied stays empty.
    let wasFreshlyCreated: Bool

    var active: Workspace {
        library.workspaces.first { $0.id == library.activeID } ?? library.workspaces[0]
    }

    /// What happened to a library that was there but couldn't be read: where
    /// it was moved to, untouched, and why. Nil when it read fine or wasn't
    /// there. The owner says so to the reader — see `UserDataFile`.
    let unreadable: (keptAt: URL?, reason: String)?

    /// False when the library couldn't be read *and* couldn't be moved out of
    /// the way. It is still at its own path, and nothing may be saved over it.
    private let mayWrite: Bool

    /// Called when a save didn't happen — a full disk, a folder that went
    /// read-only — once per run of failures rather than on every change, so a
    /// reader working through it hears about it once.
    @ObservationIgnored var onSaveFailed: ((Error) -> Void)?

    /// The last save that failed, until one succeeds. Kept rather than only
    /// announced because the first save happens in `init`, before anyone can
    /// have subscribed: whoever opens the store reads this to hear about it.
    @ObservationIgnored private(set) var saveError: (any Error)?

    /// Called when the active workspace's placements change, however they
    /// changed, with every parent whose placed children are now different —
    /// so the owner can bring the mounted roots, the group rows and the
    /// listings of those parents up to date from one place.
    @ObservationIgnored var onActiveTreeChanged: ((Set<String>) -> Void)?

    /// - Parameter fileURL: Overridable for tests; defaults to Application Support.
    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.defaultURL()
        self.fileURL = url

        // A library that is there but unreadable — a newer build's format, a
        // branch with a different schema — used to fall through to a fresh one,
        // which the `persist()` below then wrote straight over it. It is moved
        // aside instead, and the fresh library is written where it was.
        var unreadable: (keptAt: URL?, reason: String)?
        switch UserDataFile.read(WorkspaceLibrary.self, from: url) {
        case .read(let lib) where !lib.workspaces.isEmpty:
            self.library = lib
            self.wasFreshlyCreated = false
        case .unreadable(let keptAt, let reason):
            unreadable = (keptAt, reason)
            let main = Workspace(name: "Main")
            self.library = WorkspaceLibrary(workspaces: [main], activeID: main.id)
            self.wasFreshlyCreated = true
        case .read, .missing:
            if let migrated = Self.migrateLegacy(besides: url) {
                // Pre-workspaces builds stored a single root set in workspace.json.
                self.library = WorkspaceLibrary(workspaces: [migrated], activeID: migrated.id)
                self.wasFreshlyCreated = false
            } else {
                let main = Workspace(name: "Main")
                self.library = WorkspaceLibrary(workspaces: [main], activeID: main.id)
                self.wasFreshlyCreated = true
            }
        }
        self.unreadable = unreadable
        // Only an unreadable file that couldn't be moved stops saving.
        self.mayWrite = unreadable.map { $0.keptAt != nil } ?? true

        // Heal a dangling activeID rather than trusting the file.
        if !library.workspaces.contains(where: { $0.id == library.activeID }) {
            library.activeID = library.workspaces[0].id
        }
        migrateToPlacements()
        healRecency()
        persist()
    }

    // MARK: Migration

    /// Give every workspace written by an older build its placements, once.
    ///
    /// From the collections beside it, if it was written by a build that kept
    /// its groups there; else from the layout it was written with. Whatever
    /// its expansion said about groups is carried over, under the names the
    /// groups now carry in their URIs.
    ///
    /// Collections were shared between workspaces, and placements are not: a
    /// group two workspaces reached is copied into each, and every copy after
    /// the first is given an identity of its own, or renaming it in one would
    /// rename it in both.
    private func migrateToPlacements() {
        let records = Self.legacyCollections(besides: fileURL)
        var claimed: Set<UUID> = []
        for i in library.workspaces.indices {
            var workspace = library.workspaces[i]
            if let layout = workspace.legacyLayout {
                backUpBeforePlacements()
                var open: Set<UUID>
                if records[workspace.id] != nil {
                    workspace.placements = Placements.migrating(records, workspace: workspace.id)
                    let closed = Set((workspace.legacyCollapsedGroups ?? []).compactMap(CollectionRef.id(from:)))
                    open = workspace.legacyCollapsedGroups == nil ? []
                        : Set(workspace.placements.collections(from: workspace.root)
                                .compactMap { CollectionRef.id(from: $0.uri) }).subtracting(closed)
                } else {
                    let folders = Dictionary(uniqueKeysWithValues:
                        layout.records(workspace: workspace.id, named: workspace.name).map { ($0.id, $0) })
                    workspace.placements = Placements.migrating(folders, workspace: workspace.id)
                    open = Set(layout.openFolders)
                }
                // Expansion named groups by id alone; they are named now.
                open.formUnion(workspace.revealedNodes.compactMap(CollectionRef.id(from:)))
                let placements = workspace.placements
                workspace.revealedNodes = workspace.revealedNodes
                    .filter { CollectionRef.id(from: $0) == nil }
                    + open.compactMap { placements.collection($0) }
                workspace.revealedNodes.sort()
                workspace.legacyLayout = nil
                workspace.legacyCollapsedGroups = nil
            }
            for (uri, _) in workspace.placements.collections(from: workspace.root) {
                guard let id = CollectionRef.id(from: uri), !claimed.insert(id).inserted,
                      let name = CollectionRef.name(from: uri) else { continue }
                let fresh = CollectionRef.uri(for: UUID(), named: name)
                workspace.placements.remap(from: uri, to: fresh)
                workspace.revealedNodes = workspace.revealedNodes.map { $0 == uri ? fresh : $0 }
            }
            library.workspaces[i] = workspace
        }
    }

    /// The collections an older build kept beside the library, if any.
    private static func legacyCollections(besides url: URL) -> [UUID: CollectionRecord] {
        let file = url.deletingLastPathComponent().appendingPathComponent("collections.json")
        guard let data = try? Data(contentsOf: file),
              let records = try? JSONDecoder().decode([CollectionRecord].self, from: data)
        else { return [:] }
        return Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Copies of the library and the collections as they were, kept once,
    /// before anything is written in the new shape. Nothing reads
    /// `collections.json` after this, and it is left where it is.
    private func backUpBeforePlacements() {
        let dir = fileURL.deletingLastPathComponent()
        let files = FileManager.default
        for (name, backup) in [("workspaces.json", "workspaces.pre-placements.json"),
                               ("collections.json", "collections.pre-placements.json")] {
            let from = dir.appendingPathComponent(name), to = dir.appendingPathComponent(backup)
            guard files.fileExists(atPath: from.path), !files.fileExists(atPath: to.path) else { continue }
            try? files.copyItem(at: from, to: to)
        }
    }

    // MARK: Roots of the active workspace

    /// Everything mounted in the active workspace, resolved. Read-only — see
    /// `restoreRoots` for the launch path.
    func resolvedRoots(using providers: [NodeProvider]) -> [NodeID] {
        Self.resolve(active.rootURIs, using: providers)
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
        changeActive(undoAs: nil) { placements, root in
            for parent in [root] + placements.collections(from: root).map(\.uri) {
                var members: [String] = []
                for member in placements.children(of: parent) {
                    if Placements.isCollection(member) {
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
                placements.setChildren(members, of: parent)
            }
            // A stored *parent* is resolved in place too. A provider can spell
            // an identity differently than it was written — an older URI, or a
            // name that used to be part of it — and what was placed inside it
            // would otherwise stay filed under a name nothing points at any
            // more, which reads as an aggregator that lost its channels.
            for key in placements.children.keys where key != root && !Placements.isCollection(key) {
                guard let scheme = NodeID(key)?.scheme,
                      let provider = providers.first(where: { $0.schemes.contains(scheme) }),
                      let resolved = provider.resolve(key), resolved.uri != key else { continue }
                placements.remap(from: key, to: resolved.uri)
            }
        }
        let roots = resolvedRoots(using: providers)
        liveRoots = Set(roots.map(\.uri))
        return roots
    }

    /// The roots this store last saw live, so a reconcile can tell something
    /// unmounted from something that was never mountable.
    ///
    /// The difference is the whole point. A member whose plugin is not loaded
    /// is never among the live roots, and pruning everything missing from them
    /// is how the sidebar used to lose it — silently, the next time anything
    /// else was mounted.
    @ObservationIgnored private var liveRoots: Set<String> = []

    /// Bring the active workspace in line with the live root set, after
    /// something mounted or unmounted outside the sidebar.
    ///
    /// What was live and no longer is leaves every group here. What is live and
    /// placed nowhere joins `group` — the one holding what you were looking at,
    /// so it lands beside its siblings — else the top level. Groups stay, empty
    /// or not: they are there on purpose.
    func reconcileRoots(_ roots: [NodeID], placingNewInto group: UUID? = nil) {
        let desired = roots.map(\.uri)
        let gone = liveRoots.subtracting(desired)
        liveRoots = Set(desired)
        let destination = uri(of: group)
        changeActive(undoAs: nil) { placements, root in
            if !gone.isEmpty {
                for parent in [root] + placements.collections(from: root).map(\.uri) {
                    placements.release(Array(gone), from: parent)
                }
            }
            let placed = Set(placements.leaves(from: root))
            let additions = desired.filter { !placed.contains($0) }
            if !additions.isEmpty { placements.adopt(additions, into: destination ?? root) }
        }
    }

    // MARK: Groups in the active workspace

    /// The URI a group of the active sidebar goes by now — nil is the top
    /// level. Nil for a group the sidebar does not show.
    ///
    /// Groups are passed around by id because the id outlives a rename, and a
    /// drag that started before one should still land.
    func uri(of group: UUID?) -> String? {
        guard let group, group != active.id else { return active.root }
        return active.placements.collections(from: active.root)
            .first { CollectionRef.id(from: $0.uri) == group }?.uri
    }

    /// A new, empty group inside `parent`, or at the top level.
    @discardableResult
    func createGroup(named name: String, in parent: UUID? = nil) -> UUID {
        let destination = uri(of: parent) ?? active.root
        var made = ""
        changeActive(undoAs: "New Group") { placements, _ in
            made = placements.createCollection(named: name, in: destination)
        }
        return CollectionRef.id(from: made) ?? active.id
    }

    /// Rename a group. Its old URI and its new one, for whoever has to follow
    /// the change — it is the same change a renamed file makes.
    @discardableResult
    func renameGroup(_ id: UUID, to name: String) -> (from: String, to: String)? {
        guard id != active.id, let old = uri(of: id) else { return nil }
        var new: String?
        changeActive(undoAs: "Rename") { placements, _ in new = placements.rename(old, to: name) }
        guard let new, new != old else { return nil }
        mutateActive { $0.revealedNodes = $0.revealedNodes.map { $0 == old ? new : $0 }.sorted() }
        return (old, new)
    }

    /// Move things from one place in the sidebar to another: out of `source`
    /// and into `destination` (nil is the top level for both) at `index`.
    ///
    /// Within one place this is a reorder, and the position counts from before
    /// the item leaves — so dropping on the strip above C lands before C.
    func move(_ uris: [String], from source: UUID?, to destination: UUID?, at index: Int?) {
        guard let from = uri(of: source), let to = uri(of: destination), !uris.isEmpty else { return }
        changeActive(undoAs: "Move") { placements, _ in
            guard !placements.formsCycle(adopting: uris, into: to) else { return }
            if from != to { placements.release(uris, from: from) }
            placements.adopt(uris, into: to, at: index)
        }
    }

    /// Put things into `destination` as well, leaving them where they already
    /// are — what membership allows, and what holding Option while dragging
    /// asks for.
    func add(_ uris: [String], to destination: UUID?, at index: Int?) {
        guard let to = uri(of: destination) else { return }
        place(uris, into: to, at: index)
    }

    /// Delete a group. What it held takes its place wherever it was — nothing
    /// in a group is lost with the group.
    func deleteGroup(_ id: UUID) {
        guard id != active.id, let group = uri(of: id) else { return }
        changeActive(undoAs: "Delete Group") { placements, _ in placements.delete(group) }
    }

    /// Take things out of one place in the sidebar — `group`, or the top level.
    ///
    /// Anything also somewhere else stays there, and stays mounted. A group
    /// that now lives nowhere is gone, with any group inside it that nothing
    /// else holds: a collection exists only in the sidebar, so removing it
    /// from the last place it is shown is deleting it.
    func remove(_ uris: [String], from group: UUID?) {
        guard let from = uri(of: group) else { return }
        unplace(uris, from: from)
    }

    // MARK: Placing, in any node

    func placedChildren(of parent: String) -> [String] {
        active.placements.children(of: parent)
    }

    /// Put these inside `parent` in the active workspace — a group, or any
    /// node that takes drops.
    @discardableResult
    func place(_ uris: [String], into parent: String, at index: Int?) -> Bool {
        var placed = false
        changeActive(undoAs: "Place") { placements, _ in placed = placements.adopt(uris, into: parent, at: index) }
        return placed
    }

    /// Take these out of `parent`. A collection that is now shown nowhere goes
    /// with them.
    func unplace(_ uris: [String], from parent: String) {
        changeActive(undoAs: "Remove") { placements, root in
            placements.release(uris, from: parent)
            placements.collectGarbage(root: root)
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
        active.placements.collections(from: active.root)
            .first { active.placements.children(of: $0.uri).contains(uri) }
            .flatMap { CollectionRef.id(from: $0.uri) }
    }

    // MARK: Changes reported elsewhere

    /// Follow a rename into every workspace — as something placed, and as
    /// somewhere things were placed.
    func remap(from old: String, to new: String) {
        changeEvery { $0.remap(from: old, to: new) }
    }

    /// Something deleted, not merely unreachable, leaves every workspace, and
    /// takes what was placed inside it along.
    func removeEverywhere(_ uri: String) {
        changeEvery { placements in placements.remove(uri) }
    }

    /// What a collection holds, from whichever workspace has it. Nil if none
    /// does: an old name, or a collection deleted since.
    func members(of collection: String) -> [String]? {
        for workspace in library.workspaces {
            let placements = workspace.placements
            if placements.children[collection] != nil
                || !placements.holders(of: collection).isEmpty {
                return placements.children(of: collection)
            }
        }
        return nil
    }

    // MARK: Library management

    @discardableResult
    func create(named name: String) -> Workspace {
        let workspace = Workspace(name: name)
        library.workspaces.append(workspace)
        persist()
        return workspace
    }

    /// A workspace for something passing through: listed and switchable like
    /// any other, but never written down.
    func createEphemeral(named name: String, rootURIs: [String]) -> Workspace {
        var workspace = Workspace(name: name, rootURIs: rootURIs)
        workspace.isEphemeral = true
        library.workspaces.append(workspace)
        return workspace
    }

    /// Keep an ephemeral workspace: from here on it is a workspace like any
    /// other, and survives the app being closed.
    func keep(_ id: UUID) {
        guard let i = library.workspaces.firstIndex(where: { $0.id == id }),
              library.workspaces[i].isEphemeral else { return }
        library.workspaces[i].isEphemeral = false
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = library.workspaces.firstIndex(where: { $0.id == id }) else { return }
        library.workspaces[i].name = name
        persist()
    }

    /// Deleting only forgets a root list — the nodes themselves are untouched.
    /// Refuses to delete the last workspace; deleting the active one activates
    /// the first remaining.
    func delete(_ id: UUID) {
        guard library.workspaces.count > 1,
              let i = library.workspaces.firstIndex(where: { $0.id == id }) else { return }
        library.workspaces.remove(at: i)
        library.recentIDs.removeAll { $0 == id }
        // A workspace that is gone takes what you could have undone in it.
        history.forget(id)
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

    // MARK: Putting things back

    /// What the reader can undo — see `UndoHistory` for what that covers and
    /// why it stops where it does.
    let history = UndoHistory()

    var canUndo: Bool { history.canUndo(in: active.id) }
    var canRedo: Bool { history.canRedo(in: active.id) }

    @discardableResult
    func undo() -> String? {
        step { [history] entry, workspace, current in
            history.rememberRedo(entry.label, current, in: workspace)
        } taking: { [history] workspace in
            history.takeUndo(in: workspace)
        }
    }

    @discardableResult
    func redo() -> String? {
        step { [history] entry, workspace, current in
            history.rememberUndo(entry.label, current, in: workspace)
        } taking: { [history] workspace in
            history.takeRedo(in: workspace)
        }
    }

    /// One direction or the other: take the last entry, put what is there now
    /// on the opposite side, and write the entry back.
    private func step(keeping keep: (UndoHistory.Entry, UUID, Placements) -> Void,
                      taking take: (UUID) -> UndoHistory.Entry?) -> String? {
        guard let i = library.workspaces.firstIndex(where: { $0.id == active.id }),
              let entry = take(active.id) else { return nil }
        let current = library.workspaces[i].placements
        keep(entry, active.id, current)
        write(entry.placements, at: i, replacing: current)
        return entry.label
    }

    // MARK: Persistence

    /// Change the active workspace's placements, writing and telling the owner
    /// only if anything actually changed.
    ///
    /// `undoAs` is what the change is called where it was made, and nil says
    /// this is not a change the reader asked for — the table being healed on
    /// load, or following what the graph mounted. Those are the app keeping up
    /// with the world, and offering to undo them would be offering to undo
    /// something they never did.
    private func changeActive(undoAs label: String?,
                              _ change: (inout Placements, String) -> Void) {
        guard let i = library.workspaces.firstIndex(where: { $0.id == library.activeID })
        else { return }
        let before = library.workspaces[i].placements
        var placements = before
        change(&placements, library.workspaces[i].root)
        guard placements != before else { return }
        if let label { history.record(label, before: before, in: active.id) }
        write(placements, at: i, replacing: before)
    }

    /// The write itself, without any question of who asked for it — which is
    /// what undo and redo need, since putting something back is not a new
    /// change to be undone.
    private func write(_ placements: Placements, at index: Int, replacing before: Placements) {
        library.workspaces[index].placements = placements
        persist()
        onActiveTreeChanged?(Self.changedParents(from: before, to: placements))
    }

    private static func changedParents(from before: Placements, to after: Placements) -> Set<String> {
        Set(before.children.keys).union(after.children.keys)
            .filter { before.children[$0] != after.children[$0] }
    }

    /// The same, in every workspace.
    private func changeEvery(_ change: (inout Placements) -> Void) {
        var activeChanged: Set<String>?, anyChanged = false
        for i in library.workspaces.indices {
            let before = library.workspaces[i].placements
            var placements = before
            change(&placements)
            guard placements != before else { continue }
            library.workspaces[i].placements = placements
            anyChanged = true
            if library.workspaces[i].id == library.activeID {
                activeChanged = Self.changedParents(from: before, to: placements)
            }
        }
        if anyChanged { persist() }
        if let activeChanged { onActiveTreeChanged?(activeChanged) }
    }

    /// Change the active workspace's own settings — not its placements.
    private func mutateActive(_ change: (inout Workspace) -> Void) {
        guard let i = library.workspaces.firstIndex(where: { $0.id == library.activeID })
        else { return }
        change(&library.workspaces[i])
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
        guard mayWrite else { return }
        do {
            try UserDataFile.write(stored, to: fileURL)
            saveError = nil
        } catch {
            let first = saveError == nil
            saveError = error
            if first { onSaveFailed?(error) }
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
