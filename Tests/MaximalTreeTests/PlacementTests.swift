import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// Placements: what was put inside what, in one workspace.
@Suite struct PlacementTests {
    private let workspace = UUID()
    private var root: String { Placements.root(of: workspace) }

    // MARK: Placing

    @Test func adoptingKeepsTheOrderItWasGiven() {
        var table = Placements()
        table.adopt(["a", "b", "c"], into: root)
        table.adopt(["x"], into: root, at: 1)
        #expect(table.children(of: root) == ["a", "x", "b", "c"])
    }

    /// Dropped at 2 means "before what was at 2": counted before `a` leaves.
    @Test func movingDownLandsWhereItWasAimed() {
        var table = Placements()
        table.adopt(["a", "b", "c"], into: root)
        table.adopt(["a"], into: root, at: 2)
        #expect(table.children(of: root) == ["b", "a", "c"])
    }

    @Test func nothingIsPlacedInsideItself() {
        var table = Placements()
        let placed = table.adopt([root], into: root)
        #expect(!placed)
        #expect(table.children(of: root).isEmpty)
    }

    /// Every placed edge is in the table, so a cycle through any number of
    /// collections is seen.
    @Test func nothingIsPlacedInsideWhatItHolds() {
        var table = Placements()
        let outer = table.createCollection(named: "Outer", in: root)
        let inner = table.createCollection(named: "Inner", in: outer)
        let before = table

        let cycled = table.adopt([outer], into: inner)
        #expect(!cycled)
        #expect(table == before)
        let sibling = table.adopt([inner], into: root)
        #expect(sibling, "a sibling is not an ancestor")
    }

    /// An empty list is never stored, so "has placements" is "has an entry".
    @Test func releasingTheLastChildLeavesNoEntry() {
        var table = Placements()
        table.adopt(["a", "b"], into: "yt://aggregator")
        table.release(["b"], from: "yt://aggregator")
        #expect(table.children(of: "yt://aggregator") == ["a"])
        table.release(["a"], from: "yt://aggregator")
        #expect(table.children["yt://aggregator"] == nil)
    }

    /// A member already there moves rather than appearing twice, and naming
    /// the same thing twice in one go places it once.
    @Test func placingWhatIsAlreadyThereMovesIt() {
        var table = Placements()
        table.adopt(["a", "b", "c"], into: root)
        table.adopt(["c", "c"], into: root, at: 0)
        #expect(table.children(of: root) == ["c", "a", "b"])
        table.adopt(["x"], into: root, at: 99)
        #expect(table.children(of: root) == ["c", "a", "b", "x"], "past the end appends")
        table.release(["a"], from: root)
        #expect(table.children(of: root) == ["c", "b", "x"])
    }

    // MARK: Reading the sidebar

    /// What the sidebar mounts: through groups, not into a plugin's node, each
    /// once however many groups hold it.
    @Test func theMountedRootsAreTheLeavesThroughGroups() {
        var table = Placements()
        table.adopt(["file:///top"], into: root)
        let a = table.createCollection(named: "A", in: root)
        let b = table.createCollection(named: "B", in: root)
        table.adopt(["file:///shared", "yt://aggregator"], into: a)
        table.adopt(["file:///shared"], into: b)
        table.adopt(["yt://channel"], into: "yt://aggregator")

        #expect(table.leaves(from: root) == ["file:///top", "file:///shared", "yt://aggregator"])
    }

    /// Every group, in the order shown and how deep — for the Move to
    /// Collection menu, which leaves out what is being moved and what is in it.
    @Test func theGroupsAreListedInOrderWithTheirDepth() {
        var table = Placements()
        let outer = table.createCollection(named: "Outer", in: root)
        let inner = table.createCollection(named: "Inner", in: outer)
        let other = table.createCollection(named: "Other", in: root)

        #expect(table.collections(from: root).map(\.uri) == [outer, inner, other])
        #expect(table.collections(from: root).map(\.depth) == [0, 1, 0])
        #expect(table.collections(from: root, excluding: [CollectionRef.id(from: outer)!])
                    .map(\.uri) == [other])
    }

    /// A hand-edited cycle is listed once, not for ever.
    @Test func aCycleIsWalkedOnce() throws {
        let a = CollectionRef.uri(for: UUID(), named: "A")
        let records = try JSONDecoder().decode(Placements.self, from: JSONEncoder().encode(
            ["children": [root: [a], a: [a, "file:///x"]]]))
        #expect(records.collections(from: root).map(\.uri) == [a])
        #expect(records.leaves(from: root) == ["file:///x"])
    }

    @Test func aGroupIsFoundByIdUnderItsCurrentName() {
        var table = Placements()
        let group = table.createCollection(named: "Old", in: root)
        let renamed = table.rename(group, to: "New")
        #expect(table.collection(CollectionRef.id(from: group)!) == renamed)
        #expect(table.holders(of: renamed!) == [root])
    }

    // MARK: Collections

    @Test func aCollectionIsANameWhereItWasPut() {
        var table = Placements()
        table.adopt(["a", "b"], into: root)
        let group = table.createCollection(named: "Reading", in: root, at: 1)
        #expect(table.children(of: root) == ["a", group, "b"])
        #expect(CollectionRef.name(from: group) == "Reading")
        #expect(table.children(of: group).isEmpty)
    }

    /// The name is in the URI, so a rename reaches every reference to it —
    /// where it sits, and what it holds.
    @Test func renamingACollectionReachesEveryReference() {
        var table = Placements()
        let group = table.createCollection(named: "Reading", in: root)
        let other = table.createCollection(named: "Other", in: root)
        table.adopt([group], into: other)
        table.adopt(["a"], into: group)

        let renamed = table.rename(group, to: "Later")

        #expect(renamed.flatMap(CollectionRef.name(from:)) == "Later")
        #expect(renamed.flatMap(CollectionRef.id(from:)) == CollectionRef.id(from: group))
        #expect(table.children(of: root) == [renamed, other])
        #expect(table.children(of: other) == [renamed])
        #expect(table.children(of: renamed ?? "") == ["a"])
        #expect(table.children[group] == nil)
    }

    @Test func anyNameReadsBackExactly() {
        for name in ["Reading list", "A&B=c+d", "50% off / #tags?", "日本 é", ""] {
            var table = Placements()
            let uri = table.createCollection(named: name, in: root)
            #expect(CollectionRef.name(from: uri) == name)
            #expect(NodeID(uri)?.uri == uri, "already canonical")
        }
    }

    /// Only a collection has a name to change: not a plugin's node, and not
    /// the sidebar, which its workspace names.
    @Test func onlyCollectionsAreRenamed() {
        var table = Placements()
        table.adopt(["a"], into: "yt://aggregator")
        table.adopt(["b"], into: root)
        let before = table
        let plugin = table.rename("yt://aggregator", to: "Name")
        let sidebar = table.rename(root, to: "Name")
        #expect(plugin == nil && sidebar == nil)
        #expect(table == before)
    }

    @Test func theSidebarIsNeverDeleted() {
        var table = Placements()
        table.adopt(["b"], into: root)
        let before = table
        table.delete(root)
        #expect(table == before)
    }

    /// Every holder gets the contents where the collection sat, minus what it
    /// already has.
    @Test func deletingSpillsIntoEveryHolder() {
        var table = Placements()
        let doomed = table.createCollection(named: "Doomed", in: root)
        table.adopt(["x", "y"], into: doomed)
        table.adopt(["a"], into: root, at: 0)
        table.adopt(["b"], into: root)
        let other = table.createCollection(named: "Other", in: root)
        table.adopt(["y", doomed, "z"], into: other)

        table.delete(doomed)

        #expect(table.children(of: root) == ["a", "x", "y", "b", other])
        #expect(table.children(of: other) == ["y", "x", "z"])
        #expect(table.children[doomed] == nil)
    }

    @Test func aDeletedCollectionsGroupsMoveUpWithTheRest() {
        var table = Placements()
        let outer = table.createCollection(named: "Outer", in: root)
        let inner = table.createCollection(named: "Inner", in: outer)
        table.adopt(["a"], into: inner)

        table.delete(outer)

        #expect(table.children(of: root) == [inner])
        #expect(table.children(of: inner) == ["a"])
    }

    // MARK: Renames and removals

    @Test func aRenameIsFollowedAsChildAndAsParent() {
        var table = Placements()
        table.adopt(["file:///work", "file:///workshop"], into: root)
        table.adopt(["file:///work/notes/a.typ"], into: "yt://aggregator")
        table.adopt(["yt://channel"], into: "file:///work/feeds")

        table.remap(from: "file:///work", to: "file:///job")

        #expect(table.children(of: root) == ["file:///job", "file:///workshop"])
        #expect(table.children(of: "yt://aggregator") == ["file:///job/notes/a.typ"])
        #expect(table.children(of: "file:///job/feeds") == ["yt://channel"])
        #expect(table.children["file:///work/feeds"] == nil)
    }

    @Test func renamingOntoANodeWithPlacementsKeepsBoth() {
        var table = Placements()
        table.adopt(["a", "b"], into: "yt://old")
        table.adopt(["b", "c"], into: "yt://new")
        table.remap(from: "yt://old", to: "yt://new")
        #expect(Set(table.children(of: "yt://new")) == ["a", "b", "c"])
        #expect(table.children(of: "yt://new").count == 3)
    }

    /// Gone means gone from every list, and whatever was placed inside it —
    /// or inside anything under it — goes too.
    @Test func aRemovalTakesItsPlacementsWithIt() {
        var table = Placements()
        table.adopt(["file:///work", "file:///workshop"], into: root)
        table.adopt(["yt://channel"], into: "file:///work/feeds")
        let group = table.createCollection(named: "G", in: root)
        table.adopt(["file:///work/a"], into: group)

        table.remove("file:///work")

        #expect(table.children(of: root) == ["file:///workshop", group])
        #expect(table.children["file:///work/feeds"] == nil)
        #expect(table.children(of: group).isEmpty)
    }

    // MARK: Garbage

    @Test func aCollectionNothingShowsIsDroppedWithWhatItHeld() {
        var table = Placements()
        let outer = table.createCollection(named: "Outer", in: root)
        let inner = table.createCollection(named: "Inner", in: outer)
        table.adopt(["a"], into: inner)
        table.release([outer], from: root)

        table.collectGarbage(root: root)

        #expect(table.children.isEmpty)
    }

    @Test func aCollectionStillHeldSomewhereShownSurvives() {
        var table = Placements()
        let outer = table.createCollection(named: "Outer", in: root)
        let inner = table.createCollection(named: "Inner", in: outer)
        table.adopt(["a"], into: inner)
        table.adopt(["b"], into: outer)
        let keeper = table.createCollection(named: "Keeper", in: root)
        table.adopt([inner], into: keeper)
        table.release([outer], from: root)

        table.collectGarbage(root: root)

        #expect(table.children[outer] == nil)
        #expect(table.children(of: inner) == ["a"])
        #expect(table.children(of: keeper) == [inner])
    }

    /// An aggregator can sit inside a plugin's own tree, which this table
    /// cannot see — so what was put in it is not garbage.
    @Test func aCollectionInsideAPluginsNodeSurvives() {
        var table = Placements()
        let group = table.createCollection(named: "Picks", in: "yt://account/aggregator")
        table.adopt(["yt://channel"], into: group)
        table.collectGarbage(root: root)
        #expect(table.children(of: "yt://account/aggregator") == [group])
        #expect(table.children(of: group) == ["yt://channel"])
    }

    // MARK: Migration

    private func record(_ name: String, _ members: [String], id: UUID = UUID()) -> CollectionRecord {
        CollectionRecord(id: id, name: name, members: members)
    }

    @Test func aWorkspaceTakesWhatItsSidebarReaches() {
        let other = UUID()
        let inner = record("Inner", ["file:///b"])
        let empty = record("Empty", [])
        let outer = record("Outer", ["file:///a", inner.uri])
        let top = record("Main", ["file:///top", outer.uri, empty.uri, "git:///repo"], id: workspace)
        let elsewhere = record("Elsewhere", ["file:///z"])
        let otherTop = record("Other", [elsewhere.uri], id: other)
        let records = Dictionary(uniqueKeysWithValues:
            [top, outer, inner, empty, elsewhere, otherTop].map { ($0.id, $0) })

        let table = Placements.migrating(records, workspace: workspace)

        let named = { (r: CollectionRecord) in CollectionRef.uri(for: r.id, named: r.name) }
        #expect(table.children == [
            root: ["file:///top", named(outer), named(empty), "git:///repo"],
            named(outer): ["file:///a", named(inner)],
            named(inner): ["file:///b"],
        ], "each group named where it is referred to; the top level is the workspace, named by it")
    }

    @Test func aCollectionTwoWorkspacesReachedIsCopiedIntoEach() {
        let other = UUID()
        let shared = record("Shared", ["file:///s"])
        let records = Dictionary(uniqueKeysWithValues: [
            record("Main", [shared.uri], id: workspace), record("Other", [shared.uri], id: other), shared,
        ].map { ($0.id, $0) })

        var mine = Placements.migrating(records, workspace: workspace)
        let theirs = Placements.migrating(records, workspace: other)
        let sharedURI = CollectionRef.uri(for: shared.id, named: "Shared")
        mine.delete(sharedURI)

        #expect(mine.children(of: root) == ["file:///s"])
        #expect(theirs.children(of: Placements.root(of: other)) == [sharedURI])
    }

    /// A member pointing at a collection whose record is missing is kept, as
    /// the sidebar kept it: shown inert rather than silently dropped.
    @Test func aDanglingMemberIsKept() {
        let lost = CollectionRef.uri(for: UUID())
        let records = [workspace: record("Main", [lost], id: workspace)]
        let table = Placements.migrating(records, workspace: workspace)
        #expect(table.children(of: root) == [lost])
    }

    /// A hand-edited file can hold a cycle; migration still ends.
    @Test func aCycleInTheOldFileEnds() {
        let a = UUID(), b = UUID()
        let records = [
            workspace: record("Main", [CollectionRef.uri(for: a)], id: workspace),
            a: record("A", [CollectionRef.uri(for: b)], id: a),
            b: record("B", [CollectionRef.uri(for: a), CollectionRef.uri(for: workspace)], id: b),
        ]
        let table = Placements.migrating(records, workspace: workspace)
        let namedA = CollectionRef.uri(for: a, named: "A"), namedB = CollectionRef.uri(for: b, named: "B")
        #expect(table.children == [root: [namedA], namedA: [namedB], namedB: [namedA, root]])
    }

    // MARK: On disk

    /// An older workspace is read as the layout it was written with, to be
    /// migrated, and written back as placements only.
    @Test func anOlderWorkspaceIsReadForMigrationAndWrittenAsPlacements() throws {
        let json = #"{"id":"\#(workspace.uuidString)","name":"Main","layout":{"entries":[{"type":"root","uri":"file:///a"}]},"revealedNodes":[]}"#
        let decoded = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(decoded.legacyLayout?.entries == [.root("file:///a")])
        let written = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(written.contains("placements"))
        #expect(!written.contains("layout"))
    }

    @Test func placementsSurviveARoundTrip() throws {
        var workspace = Workspace(id: workspace, name: "Main")
        var table = Placements()
        table.adopt(["file:///a"], into: root)
        table.adopt(["file:///b"], into: table.createCollection(named: "G", in: root))
        workspace.placements = table

        let back = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace))
        #expect(back.placements == table)
    }
}

/// The store opening a library written before placements, from real files.
@MainActor
@Suite struct PlacementMigrationTests {
    private func directory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("placements-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ json: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: json).write(to: url)
    }

    private func named(_ id: UUID, _ name: String) -> String { CollectionRef.uri(for: id, named: name) }

    /// A library from the builds that kept groups in collections.json: a
    /// nested group, an empty one, a loose root, and a group opened in the
    /// sidebar — named by id alone, as expansion then did.
    @Test func aCollectionsLibraryOpensAsTheSameSidebar() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("workspaces.json")
        let main = UUID(), outer = UUID(), inner = UUID(), empty = UUID()
        try write(["activeID": main.uuidString, "workspaces": [[
            "id": main.uuidString, "name": "Main", "layout": ["entries": []],
            "revealedNodes": ["file:///top", CollectionRef.uri(for: outer)],
        ]]], to: file)
        try write([
            ["id": main.uuidString, "name": "Main",
             "members": ["file:///top", CollectionRef.uri(for: outer), CollectionRef.uri(for: empty)]],
            ["id": outer.uuidString, "name": "Outer", "members": ["file:///a", CollectionRef.uri(for: inner)]],
            ["id": inner.uuidString, "name": "Inner", "members": ["file:///b"]],
            ["id": empty.uuidString, "name": "Empty", "members": []],
        ], to: dir.appendingPathComponent("collections.json"))
        let original = try Data(contentsOf: file)
        let originalCollections = try Data(contentsOf: dir.appendingPathComponent("collections.json"))

        let store = WorkspaceStore(fileURL: file)

        let root = store.active.root
        #expect(store.active.placements.children == [
            root: ["file:///top", named(outer, "Outer"), named(empty, "Empty")],
            named(outer, "Outer"): ["file:///a", named(inner, "Inner")],
            named(inner, "Inner"): ["file:///b"],
        ])
        #expect(store.active.rootURIs == ["file:///top", "file:///a", "file:///b"])
        #expect(store.active.revealedNodes == ["collection://\(outer.uuidString.lowercased())?name=Outer",
                                               "file:///top"].sorted(),
                "the open group was lost, or kept under the name it no longer has")
        // Backed up as they were, and collections.json left where it is.
        #expect(try Data(contentsOf: dir.appendingPathComponent("workspaces.pre-placements.json")) == original)
        #expect(try Data(contentsOf: dir.appendingPathComponent("collections.pre-placements.json"))
                    == originalCollections)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("collections.json").path))

        // Written in the new shape: opening it again finds the same, and
        // migrates nothing.
        let written = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!written.contains("\"layout\""))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("collections.json"))
        let reopened = WorkspaceStore(fileURL: file)
        #expect(reopened.active.placements == store.active.placements)
        #expect(reopened.active.revealedNodes == store.active.revealedNodes)
    }

    /// From just before that, with the closed groups listed: the rest were open.
    @Test func groupsThatWereOpenStayOpen() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("workspaces.json")
        let main = UUID(), open = UUID(), closed = UUID()
        try write(["activeID": main.uuidString, "workspaces": [[
            "id": main.uuidString, "name": "Main", "layout": ["entries": []],
            "collapsedGroups": [CollectionRef.uri(for: closed)],
        ]]], to: file)
        try write([
            ["id": main.uuidString, "name": "Main",
             "members": [CollectionRef.uri(for: open), CollectionRef.uri(for: closed)]],
            ["id": open.uuidString, "name": "Open", "members": []],
            ["id": closed.uuidString, "name": "Closed", "members": []],
        ], to: dir.appendingPathComponent("collections.json"))

        let store = WorkspaceStore(fileURL: file)

        #expect(store.active.revealedNodes == [named(open, "Open")])
    }

    /// From before collections: folders in the layout, with their open state.
    @Test func aFoldersLibraryOpensAsTheSameSidebar() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("workspaces.json")
        let main = UUID(), outer = UUID(), inner = UUID()
        let innerFolder: [String: Any] = ["id": inner.uuidString, "name": "Inner", "isExpanded": false,
                                          "entries": [["type": "root", "uri": "file:///b"]]]
        let outerFolder: [String: Any] = ["id": outer.uuidString, "name": "Outer", "isExpanded": true,
                                          "entries": [["type": "root", "uri": "file:///a"],
                                                      ["type": "folder", "folder": innerFolder]]]
        try write(["activeID": main.uuidString, "workspaces": [[
            "id": main.uuidString, "name": "Main",
            "layout": ["entries": [["type": "root", "uri": "file:///top"],
                                   ["type": "folder", "folder": outerFolder]]],
        ]]], to: file)

        let store = WorkspaceStore(fileURL: file)

        #expect(store.active.placements.children == [
            store.active.root: ["file:///top", named(outer, "Outer")],
            named(outer, "Outer"): ["file:///a", named(inner, "Inner")],
            named(inner, "Inner"): ["file:///b"],
        ])
        #expect(store.active.revealedNodes == [named(outer, "Outer")])
    }

    /// A group two workspaces both showed becomes one in each — and the second
    /// is its own, so renaming it in one does not rename the other.
    @Test func aSharedGroupBecomesOneOfEachWorkspacesOwn() throws {
        let dir = try directory()
        let file = dir.appendingPathComponent("workspaces.json")
        let one = UUID(), two = UUID(), shared = UUID()
        try write(["activeID": one.uuidString, "workspaces": [
            ["id": one.uuidString, "name": "One", "layout": ["entries": []],
             "revealedNodes": [CollectionRef.uri(for: shared)]],
            ["id": two.uuidString, "name": "Two", "layout": ["entries": []],
             "revealedNodes": [CollectionRef.uri(for: shared)]],
        ]], to: file)
        try write([
            ["id": one.uuidString, "name": "One", "members": [CollectionRef.uri(for: shared)]],
            ["id": two.uuidString, "name": "Two", "members": [CollectionRef.uri(for: shared)]],
            ["id": shared.uuidString, "name": "Shared", "members": ["file:///s"]],
        ], to: dir.appendingPathComponent("collections.json"))

        let store = WorkspaceStore(fileURL: file)

        let first = store.library.workspaces[0], second = store.library.workspaces[1]
        let firstGroup = try #require(first.placements.children(of: first.root).first)
        let secondGroup = try #require(second.placements.children(of: second.root).first)
        #expect(firstGroup == named(shared, "Shared"))
        #expect(secondGroup != firstGroup)
        #expect(CollectionRef.name(from: secondGroup) == "Shared")
        #expect(second.placements.children(of: secondGroup) == ["file:///s"])
        #expect(second.revealedNodes == [secondGroup], "its open state did not follow the new identity")

        store.renameGroup(try #require(CollectionRef.id(from: firstGroup)), to: "Renamed")
        #expect(store.library.workspaces[1].placements.children(of: second.root) == [secondGroup])
    }
}
