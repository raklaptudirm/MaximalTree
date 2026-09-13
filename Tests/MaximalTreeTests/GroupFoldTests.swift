import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// Groups as collections, and back.
///
/// The round trip is the test that matters. Whatever the sidebar looked like
/// before, it has to look exactly like that after its groups become
/// collections — the same folders, in the same order, holding the same roots,
/// open and closed the same way.
@Suite struct GroupFoldTests {
    private let workspace = UUID()

    /// Today's shape at its most involved: loose roots around folders, a
    /// folder inside a folder, an empty folder, and one closed.
    /// Built once per test: folder ids are part of what is compared, and a
    /// computed property would mint new ones on every read.
    private let layout: [RootEntry] = {
        let inner = RootFolder(id: UUID(), name: "Inner",
                               entries: [.root("file:///work/b")], isExpanded: false)
        let outer = RootFolder(id: UUID(), name: "Outer",
                               entries: [.root("file:///work/a"), .folder(inner)],
                               isExpanded: true)
        let empty = RootFolder(id: UUID(), name: "Empty", entries: [], isExpanded: true)
        return [.root("file:///top"), .folder(outer), .folder(empty), .root("git:///repo")]
    }()

    private func index(_ records: [CollectionRecord]) -> [UUID: CollectionRecord] {
        Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    @Test func aLayoutSurvivesBecomingCollections() {
        let records = GroupFold.collections(from: layout, workspace: workspace, named: "Main")
        let back = GroupFold.layout(workspace: workspace, records: index(records),
                                    collapsed: Set(GroupFold.collapsed(in: layout)))
        #expect(back == layout)
    }

    /// The flat set the rest of the graph sees is unchanged too.
    @Test func theMountedRootsAreUnchanged() {
        let records = GroupFold.collections(from: layout, workspace: workspace, named: "Main")
        #expect(GroupFold.roots(workspace: workspace, records: index(records))
                == layout.flatMap(\.rootURIs))
    }

    /// No identities invented: the top level is the workspace, and each folder
    /// keeps its id — so migrating twice changes nothing.
    @Test func migratingTwiceGivesTheSameCollections() {
        let once = GroupFold.collections(from: layout, workspace: workspace, named: "Main")
        let twice = GroupFold.collections(from: layout, workspace: workspace, named: "Main")
        #expect(once == twice)
        #expect(once.first?.id == workspace)
    }

    /// An empty folder is still a group. They have always been kept on
    /// purpose, and a migration that dropped them would be the first thing
    /// anyone noticed.
    @Test func anEmptyFolderIsStillThere() {
        let records = GroupFold.collections(from: layout, workspace: workspace, named: "Main")
        #expect(records.contains { $0.name == "Empty" && $0.members.isEmpty })
    }

    /// A group is open unless someone closed it, so only the closed are named.
    @Test func onlyClosedFoldersAreRecorded() {
        let closed = GroupFold.collapsed(in: layout)
        #expect(closed.count == 1)
    }

    /// Nothing to migrate is nothing: an empty workspace is one empty
    /// collection, not an error.
    @Test func anEmptyWorkspaceIsOneEmptyCollection() {
        let records = GroupFold.collections(from: [], workspace: workspace, named: "Main")
        #expect(records == [CollectionRecord(id: workspace, name: "Main", members: [])])
        #expect(GroupFold.layout(workspace: workspace, records: index(records), collapsed: []) == [])
    }

    /// A collection inside itself — which the host refuses to make, but which
    /// a hand-edited file can still describe — is drawn once, not for ever.
    @Test func aCollectionInsideItselfStops() {
        let loop = UUID()
        let records = [
            CollectionRecord(id: workspace, name: "Main", members: [CollectionRef.uri(for: loop)]),
            CollectionRecord(id: loop, name: "Loop",
                             members: ["file:///x", CollectionRef.uri(for: loop)]),
        ]
        let drawn = GroupFold.layout(workspace: workspace, records: index(records), collapsed: [])
        guard case .folder(let folder) = drawn.first else {
            Issue.record("expected the looping collection as a folder"); return
        }
        #expect(folder.entries == [.root("file:///x")])
    }

    /// A reference to a collection that no longer exists is kept as what it is,
    /// rather than silently vanishing from the sidebar.
    @Test func aCollectionThatIsGoneIsNotSilentlyDropped() {
        let ghost = CollectionRef.uri(for: UUID())
        let records = [CollectionRecord(id: workspace, name: "Main", members: [ghost])]
        #expect(GroupFold.layout(workspace: workspace, records: index(records), collapsed: [])
                == [.root(ghost)])
    }

    /// With membership a root can be reached twice; the graph still sees it
    /// once.
    @Test func aRootReachedTwiceIsMountedOnce() {
        let a = UUID(), b = UUID()
        let records = [
            CollectionRecord(id: workspace, name: "Main",
                             members: [CollectionRef.uri(for: a), CollectionRef.uri(for: b)]),
            CollectionRecord(id: a, name: "A", members: ["file:///shared"]),
            CollectionRecord(id: b, name: "B", members: ["file:///shared"]),
        ]
        #expect(GroupFold.roots(workspace: workspace, records: index(records)) == ["file:///shared"])
    }
}

/// The workspace store with its groups in collections: migration from a real
/// file, and the ways a change could be lost on the way through.
@MainActor
@Suite struct WorkspaceCollectionTests {
    private func directory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A library written by a build from before collections: nested folders,
    /// a closed one, an empty one, loose roots — and no `collapsedGroups` key,
    /// because it had never heard of it.
    private func writeOldLibrary(in dir: URL) throws -> (layout: [RootEntry], workspace: UUID) {
        let inner = RootFolder(id: UUID(), name: "Inner",
                               entries: [.root("file:///work/b")], isExpanded: false)
        let outer = RootFolder(id: UUID(), name: "Outer",
                               entries: [.root("file:///work/a"), .folder(inner)], isExpanded: true)
        let empty = RootFolder(id: UUID(), name: "Empty", entries: [], isExpanded: true)
        let entries: [RootEntry] = [.root("file:///top"), .folder(outer), .folder(empty)]
        var layout = RootLayout()
        layout.entries = entries
        let workspace = Workspace(name: "Main", layout: layout)
        let library = WorkspaceLibrary(workspaces: [workspace], activeID: workspace.id)

        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as! [String: Any]
        var workspaces = json["workspaces"] as! [[String: Any]]
        for i in workspaces.indices { workspaces[i].removeValue(forKey: "collapsedGroups") }
        json["workspaces"] = workspaces
        try JSONSerialization.data(withJSONObject: json)
            .write(to: dir.appendingPathComponent("workspaces.json"))
        return (entries, workspace.id)
    }

    // MARK: Migration

    /// The sidebar someone had is the sidebar they get.
    @Test func anOldLibraryOpensAsTheSameSidebar() throws {
        let dir = try directory()
        let (layout, workspace) = try writeOldLibrary(in: dir)

        let store = WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))

        #expect(store.active.layout.entries == layout)
        #expect(store.collections.record(workspace) != nil, "the top level did not become a collection")
    }

    /// And the file it came from is kept, untouched, before anything is written.
    @Test func theOriginalLibraryIsBackedUp() throws {
        let dir = try directory()
        _ = try writeOldLibrary(in: dir)
        let original = try Data(contentsOf: dir.appendingPathComponent("workspaces.json"))

        _ = WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))

        let backup = dir.appendingPathComponent("workspaces.pre-collections.json")
        #expect(try Data(contentsOf: backup) == original)
    }

    /// Opening it again migrates nothing and backs up nothing a second time.
    @Test func reopeningMigratesNothingAgain() throws {
        let dir = try directory()
        let (layout, _) = try writeOldLibrary(in: dir)
        let file = dir.appendingPathComponent("workspaces.json")
        let first = WorkspaceStore(fileURL: file)
        let collectionsAfterFirst = first.collections.all
        let backup = try Data(contentsOf: dir.appendingPathComponent("workspaces.pre-collections.json"))

        let second = WorkspaceStore(fileURL: file)

        #expect(second.collections.all == collectionsAfterFirst)
        #expect(second.active.layout.entries == layout)
        #expect(try Data(contentsOf: dir.appendingPathComponent("workspaces.pre-collections.json")) == backup)
    }

    /// If the collections are ever lost, the layout written beside them builds
    /// them again — rather than an empty sidebar.
    @Test func lostCollectionsAreRebuiltFromTheLayout() throws {
        let dir = try directory()
        let (layout, _) = try writeOldLibrary(in: dir)
        let file = dir.appendingPathComponent("workspaces.json")
        _ = WorkspaceStore(fileURL: file)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("collections.json"))

        let reopened = WorkspaceStore(fileURL: file)

        #expect(reopened.active.layout.entries == layout)
    }

    // MARK: Changes on the way through

    /// The hazard the store is built around.
    ///
    /// The layout in memory is only as fresh as the last redraw. A file renamed
    /// inside a group changes the collections directly; if the next group
    /// operation worked on the copy it had, it would write the old name back
    /// and undo the rename without a sound.
    @Test func aGroupOperationDoesNotUndoAChangeMadeUnderneathIt() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(fileURL: file)
        let folder = store.createFolder(named: "Drafts")
        store.reconcileRoots([NodeID("file:///docs/draft.typ")!], placingNewInto: folder)

        // What a rename does, from outside the workspace store, in the same turn.
        store.collections.remap(from: "file:///docs/draft.typ", to: "file:///docs/final.typ")
        // Any group operation that rewrites the layout.
        store.setFolderExpanded(folder, false)

        #expect(store.collections.record(folder)?.members == ["file:///docs/final.typ"],
                "the stale layout was written back over the rename")
    }

    /// A deleted folder's collection goes — its contents spilled, as always.
    @Test func deletingAFolderDeletesItsCollection() throws {
        let store = WorkspaceStore(fileURL: try directory().appendingPathComponent("workspaces.json"))
        let folder = store.createFolder(named: "Doomed")
        store.reconcileRoots([NodeID("file:///x")!], placingNewInto: folder)

        store.deleteFolder(folder)

        #expect(store.collections.record(folder) == nil)
        #expect(store.active.layout.entries == [.root("file:///x")])
    }

    /// A workspace passing through leaves nothing on disk — and keeping it
    /// writes its groups down with it.
    @Test func anEphemeralWorkspacesGroupsAreWrittenOnlyOnceKept() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("workspaces.json")
        let store = WorkspaceStore(fileURL: file)
        let stray = store.createEphemeral(named: "notes", rootURIs: ["file:///tmp/notes.typ"])

        #expect(CollectionStore(url: dir.appendingPathComponent("collections.json"))
                    .record(stray.id) == nil, "a workspace passing through was written down")

        store.keep(stray.id)
        #expect(CollectionStore(url: dir.appendingPathComponent("collections.json"))
                    .record(stray.id) != nil)
    }

    /// Deleting a workspace takes its groups — but not one another workspace
    /// still shows, since collections are shared.
    @Test func deletingAWorkspaceKeepsGroupsOthersStillShow() throws {
        let store = WorkspaceStore(fileURL: try directory().appendingPathComponent("workspaces.json"))
        let first = store.active
        let own = store.createFolder(named: "Only mine")
        let shared = store.createFolder(named: "Shared")
        let second = store.create(named: "Second")
        // The second workspace shows the shared group too.
        store.collections.adopt([CollectionRef.uri(for: shared)], into: second.id, at: nil)

        store.delete(first.id)

        #expect(store.collections.record(own) == nil, "a group only it showed survived it")
        #expect(store.collections.record(shared) != nil, "a group another workspace shows was deleted")
    }

    @Test func renamingAWorkspaceRenamesItsTopLevel() throws {
        let store = WorkspaceStore(fileURL: try directory().appendingPathComponent("workspaces.json"))
        store.rename(store.active.id, to: "Research")
        #expect(store.collections.record(store.active.id)?.name == "Research")
    }
}
