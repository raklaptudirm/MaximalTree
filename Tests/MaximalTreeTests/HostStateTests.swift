import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

@MainActor
@Suite struct HostContextCacheTests {
    private func id(_ s: String) -> NodeID { NodeID(s)! }

    private func populated() -> (HostContext, NodeID, NodeID) {
        let host = HostContext()
        let parent = id("file:///dir")
        let child = id("file:///dir/a.txt")
        host._ingest(Node(id: parent, type: "file.directory", hasChildren: true))
        host._ingest(Node(id: child, type: "file.file"))
        host._setChildren([child], of: parent)
        host._setRoots([parent])
        host._setFocus(child)
        host._setSelection([child])
        return (host, parent, child)
    }

    @Test func remapRewritesEveryCache() {
        let (host, parent, child) = populated()
        let renamed = id("file:///dir/b.txt")

        host._remap(from: child, to: renamed)

        #expect(host.node(child) == nil)
        #expect(host.node(renamed) != nil)
        #expect(host.cachedChildren(of: parent) == [renamed])   // membership rewritten
        #expect(host.focusedNode == renamed)
        #expect(host.selection == [renamed])
    }

    @Test func remapRewritesRootsAndOwnChildren() {
        let (host, parent, child) = populated()
        let renamedDir = id("file:///dir2")

        host._remap(from: parent, to: renamedDir)

        #expect(host.roots == [renamedDir])
        // The renamed node keeps its (stale) child list; the store separately
        // invalidates it because descendant URIs changed.
        #expect(host.cachedChildren(of: renamedDir) == [child])
        #expect(host.cachedChildren(of: parent) == nil)
    }

    @Test func removeDropsNodeEverywhere() {
        let (host, parent, child) = populated()

        host._remove(child)

        #expect(host.node(child) == nil)
        #expect(host.cachedChildren(of: parent) == [])
        #expect(host.focusedNode == nil)
        #expect(host.selection.isEmpty)
        #expect(host.roots == [parent])
    }

    @Test func invalidateChildrenGoesStaleWithoutBlanking() {
        let (host, parent, child) = populated()
        host._invalidateChildren(of: parent)
        // Stale-while-revalidate: the listing is marked outdated (the backend
        // refetches on next read) but keeps being served — dropping it blanked
        // expanded subtrees for a frame.
        #expect(host._isChildrenStale(parent))
        #expect(host.cachedChildren(of: parent) == [child])

        // The refetch landing clears the flag and swaps the data in place.
        host._setChildren([child], of: parent)
        #expect(!host._isChildrenStale(parent))
    }
}

@MainActor
@Suite struct ZenModeTests {
    @Test func zenFlagRoundTrips() {
        let host = HostContext()
        #expect(!host.isZenMode)
        host._setZenMode(true)
        #expect(host.isZenMode)
        host._setZenMode(false)
        #expect(!host.isZenMode)
    }
}

/// Switching workspaces the way alt-tab switches apps.
@MainActor
@Suite struct WorkspaceCyclingTests {
    private func makeModel() throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppModel(host: HostContext(),
                        workspaceFile: dir.appendingPathComponent("workspaces.json"))
    }

    /// The whole point. Whatever else is open, the workspace you were last in
    /// is one step away, and taking that step again is the way back — so the
    /// key can be held down without walking off into workspaces you have not
    /// touched in a week.
    @Test func steppingForwardTwiceComesBack() throws {
        let model = try makeModel()
        model.createWorkspace(named: "B")
        model.createWorkspace(named: "C")
        let start = model.activeWorkspaceName
        #expect(start == "C")

        model.cycleWorkspace(by: 1)
        #expect(model.activeWorkspaceName == "B", "one step is the one you left")
        model.cycleWorkspace(by: 1)
        #expect(model.activeWorkspaceName == start, "and the next step is back")
        model.cycleWorkspace(by: 1)
        #expect(model.activeWorkspaceName == "B", "which makes it a toggle")
    }

    /// The other direction wraps to the far end of the same order, which is
    /// the workspace you have gone longest without.
    @Test func steppingBackReachesTheOldest() throws {
        let model = try makeModel()
        model.createWorkspace(named: "B")
        model.createWorkspace(named: "C")
        // Order is now C, B, Main.
        model.cycleWorkspace(by: -1)
        #expect(model.activeWorkspaceName == "Main")
    }

    /// A count is a step count, so `3 SPC w n` is the third most recent — the
    /// deeper reach alt-tab gives you for holding the key down.
    @Test func aCountStepsFurtherDownTheOrder() throws {
        let model = try makeModel()
        model.createWorkspace(named: "B")
        model.createWorkspace(named: "C")
        model.cycleWorkspace(by: 2)
        #expect(model.activeWorkspaceName == "Main")
    }

    /// Nowhere to go: one workspace is not a cycle of one, it is a no-op.
    @Test func oneWorkspaceGoesNowhere() throws {
        let model = try makeModel()
        model.cycleWorkspace(by: 1)
        #expect(model.workspaces.count == 1)
        #expect(model.activeWorkspaceName == "Main")
    }

    /// The menu numbers the arranged order, not this one: ⌘⌥2 has to mean the
    /// same workspace tomorrow, and it would not if visiting one moved it.
    @Test func theArrangedOrderDoesNotMove() throws {
        let model = try makeModel()
        model.createWorkspace(named: "B")
        model.createWorkspace(named: "C")
        let arranged = model.workspaces.map(\.name)
        model.cycleWorkspace(by: 1)
        model.cycleWorkspace(by: 1)
        #expect(model.workspaces.map(\.name) == arranged)
        #expect(arranged == ["Main", "B", "C"])
    }
}

@MainActor
@Suite struct WorkspaceStoreTests {
    /// Fresh directory per test so libraries and legacy files can't collide.
    private func tempLibraryURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspaces.json")
    }

    @Test func roundTripsActiveRoots() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let root = try #require(NodeID(fileURL: FileManager.default.temporaryDirectory))

        WorkspaceStore(fileURL: file).reconcileRoots([root])

        let restored = WorkspaceStore(fileURL: file)
            .resolvedRoots(using: [FileSystemProvider()])
        #expect(restored == [root])
    }

    @Test func unresolvableRootsAreDropped() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let gone = try #require(NodeID("file:///does/not/exist/zzz-\(UUID())"))

        WorkspaceStore(fileURL: file).reconcileRoots([gone])

        // The stale root is dropped; no silent reseeding — an emptied workspace
        // stays empty (seeding is first-launch-only, gated by wasFreshlyCreated).
        let restored = WorkspaceStore(fileURL: file)
            .resolvedRoots(using: [FileSystemProvider()])
        #expect(restored.isEmpty)
    }

    @Test func revealedNodesSurviveARelaunch() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let a = try #require(NodeID("file:///tmp/a"))
        let b = try #require(NodeID("file:///tmp/b"))

        WorkspaceStore(fileURL: file).setRevealedNodes([b.uri, a.uri])

        // Reopening the library is the relaunch: the tree comes back disclosed.
        let restored = WorkspaceStore(fileURL: file)
        #expect(restored.active.revealedNodes == [a.uri, b.uri].sorted())
    }

    @Test func revealedNodesAreScopedToTheirWorkspace() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WorkspaceStore(fileURL: file)
        let first = store.library.activeID
        store.setRevealedNodes(["file:///tmp/a"])

        let second = store.create(named: "Other")
        store.setActive(second.id)
        store.setRevealedNodes(["file:///tmp/b"])

        let restored = WorkspaceStore(fileURL: file)
        #expect(restored.library.workspaces.first { $0.id == first }?.revealedNodes
                == ["file:///tmp/a"])
        #expect(restored.library.workspaces.first { $0.id == second.id }?.revealedNodes
                == ["file:///tmp/b"])
    }

    /// A library written before the sidebar persisted disclosure must still load.
    @Test func aLibraryWithoutRevealedNodesLoadsEmpty() throws {
        let legacy = Workspace(name: "Old")
        let data = try JSONEncoder().encode(legacy)
        var object = try #require(try JSONSerialization.jsonObject(with: data)
                                  as? [String: Any])
        object.removeValue(forKey: "revealedNodes")
        let trimmed = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Workspace.self, from: trimmed)
        #expect(decoded.revealedNodes.isEmpty)
    }

    @Test func freshLibraryIsFlaggedOnce() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(WorkspaceStore(fileURL: file).wasFreshlyCreated)
        #expect(!WorkspaceStore(fileURL: file).wasFreshlyCreated)   // second launch
    }

    @Test func createSwitchAndPersistPerWorkspaceRoots() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rootA = try #require(NodeID(fileURL: FileManager.default.temporaryDirectory))

        let store = WorkspaceStore(fileURL: file)
        store.reconcileRoots([rootA])                       // into "Main"
        let b = store.create(named: "B")
        store.setActive(b.id)
        store.reconcileRoots([])                            // B is empty

        // Relaunch: B is still active and empty; switching back to Main restores A.
        let relaunched = WorkspaceStore(fileURL: file)
        #expect(relaunched.active.name == "B")
        #expect(relaunched.resolvedRoots(using: [FileSystemProvider()]).isEmpty)
        let main = try #require(relaunched.library.workspaces.first { $0.name == "Main" })
        relaunched.setActive(main.id)
        #expect(relaunched.resolvedRoots(using: [FileSystemProvider()]) == [rootA])
    }

    @Test func deleteActiveActivatesRemainingAndKeepsAtLeastOne() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WorkspaceStore(fileURL: file)
        let b = store.create(named: "B")
        store.setActive(b.id)

        store.delete(b.id)
        #expect(store.active.name == "Main")

        store.delete(store.active.id)                  // refused: last one
        #expect(store.library.workspaces.count == 1)
    }

    // MARK: Last-use order

    /// The order cycling walks: most recently used first, and the one you
    /// just left second — which is what makes stepping forward twice a
    /// round trip.
    @Test func recencyPutsTheOneYouLeftSecond() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WorkspaceStore(fileURL: file)
        let b = store.create(named: "B")
        let c = store.create(named: "C")

        store.setActive(b.id)
        store.setActive(c.id)
        #expect(store.byRecency.map(\.name) == ["C", "B", "Main"])

        store.setActive(b.id)
        #expect(store.byRecency.map(\.name) == ["B", "C", "Main"])
    }

    /// A library from before recency existed, or one whose workspaces were
    /// edited elsewhere: the order says exactly what exists, active first,
    /// rather than trusting the file.
    @Test func recencyHealsToWhatActuallyExists() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WorkspaceStore(fileURL: file)
        let b = store.create(named: "B")
        store.setActive(b.id)

        let relaunched = WorkspaceStore(fileURL: file)
        #expect(relaunched.byRecency.map(\.name) == ["B", "Main"])
        #expect(relaunched.byRecency.count == relaunched.library.workspaces.count)
    }

    /// Deleting the one you are in lands on the one you were in before it,
    /// not on whichever happens to be first in the arranged list.
    @Test func deletingTheActiveOneLandsOnTheMostRecent() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WorkspaceStore(fileURL: file)
        let b = store.create(named: "B")
        let c = store.create(named: "C")
        store.setActive(b.id)
        store.setActive(c.id)

        store.delete(c.id)
        #expect(store.active.name == "B")
        #expect(!store.library.recentIDs.contains(c.id))
    }

    /// An ephemeral workspace is never written down, and neither is its place
    /// in the order — a recency list naming a workspace that won't exist next
    /// launch is the same dangling reference `activeID` already avoids.
    @Test func ephemeralWorkspacesStayOutOfThePersistedOrder() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WorkspaceStore(fileURL: file)
        let passing = store.createEphemeral(named: "note.typ", rootURIs: [])
        store.setActive(passing.id)
        #expect(store.byRecency.first?.id == passing.id)

        let relaunched = WorkspaceStore(fileURL: file)
        #expect(relaunched.library.recentIDs == [relaunched.active.id])
        #expect(relaunched.library.workspaces.count == 1)
    }

    @Test func renamePersists() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = WorkspaceStore(fileURL: file)
        store.rename(store.active.id, to: "Projects")
        #expect(WorkspaceStore(fileURL: file).active.name == "Projects")
    }

    @Test func migratesLegacySingleWorkspaceFile() throws {
        let file = try tempLibraryURL()
        let dir = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = #"{"name":"Untitled","rootURIs":["file:///tmp"]}"#
        try legacy.write(to: dir.appendingPathComponent("workspace.json"),
                         atomically: true, encoding: .utf8)

        let store = WorkspaceStore(fileURL: file)
        #expect(!store.wasFreshlyCreated, "migration is not a fresh start — don't reseed")
        #expect(store.active.rootURIs == ["file:///tmp"])   // becomes loose roots
        #expect(store.active.name == "Main")           // legacy placeholder upgraded
    }

    @Test func preFoldersLibraryDecodesAsLooseRoots() throws {
        let file = try tempLibraryURL()
        let dir = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A workspaces.json written before folders existed (rootURIs, no layout).
        let id = UUID().uuidString
        let json = """
        {"activeID":"\(id)","workspaces":[{"id":"\(id)","name":"Main",
        "rootURIs":["file:///a","file:///b"]}]}
        """
        try json.write(to: file, atomically: true, encoding: .utf8)

        let store = WorkspaceStore(fileURL: file)
        #expect(store.active.rootURIs == ["file:///a", "file:///b"])
        #expect(store.active.placements.children(of: store.active.root) == ["file:///a", "file:///b"],
                "loose, at the top level")
    }
}

@MainActor
@Suite struct RootFolderTests {
    private func store() throws -> WorkspaceStore {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wsf-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("workspaces.json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return WorkspaceStore(fileURL: file)
    }

    private func ids(_ uris: String...) -> [NodeID] { uris.compactMap(NodeID.init) }

    /// What a group of the active sidebar holds.
    private func members(_ store: WorkspaceStore, _ group: UUID?) -> [String]? {
        store.uri(of: group).map(store.active.placements.children(of:))
    }

    private func group(_ store: WorkspaceStore, _ id: UUID) throws -> String {
        try #require(store.uri(of: id))
    }

    @Test func reconcilePlacesNewRootsIntoTheTargetGroup() throws {
        let store = try store()
        store.reconcileRoots(ids("file:///a"))
        let group = store.createGroup(named: "Work")

        store.reconcileRoots(ids("file:///a", "file:///b"), placingNewInto: group)
        #expect(store.groupContaining("file:///b") == group)
        #expect(store.groupContaining("file:///a") == nil, "existing roots aren't moved")
    }

    @Test func deletingAGroupKeepsItsRootsAsLoose() throws {
        let store = try store()
        store.reconcileRoots(ids("file:///a"))
        let group = store.createGroup(named: "Work")
        store.move(["file:///a"], from: nil, to: group, at: nil)
        #expect(store.groupContaining("file:///a") == group)

        store.deleteGroup(group)
        #expect(store.groupContaining("file:///a") == nil)
        #expect(store.active.rootURIs.contains("file:///a"), "the root survives its group")
    }

    @Test func reconcilePrunesVanishedRootsFromGroupsButKeepsTheGroup() throws {
        let store = try store()
        store.reconcileRoots(ids("file:///a", "file:///b"))
        let group = store.createGroup(named: "Work")
        store.move(["file:///a", "file:///b"], from: nil, to: group, at: nil)

        store.reconcileRoots(ids("file:///a"))   // b unmounted
        #expect(store.groupContaining("file:///a") == group)
        #expect(store.active.rootURIs == ["file:///a"])
        // Empty or not, the group is intentional — it stays.
        #expect(store.uri(of: group) != nil)
    }

    @Test func groupsNestAndMoveByIndex() throws {
        let store = try store()
        store.reconcileRoots(ids("file:///a", "file:///b", "file:///c"))
        let outer = store.createGroup(named: "Outer")
        let inner = store.createGroup(named: "Inner", in: outer)

        // Nesting: Inner sits inside Outer.
        #expect(members(store, outer)?.contains(try group(store, inner)) == true)

        // Position: put c first at the top level.
        store.move(["file:///c"], from: nil, to: nil, at: 0)
        #expect(store.active.rootURIs.first == "file:///c")

        // Move a root into the nested Inner group.
        store.move(["file:///a"], from: nil, to: inner, at: nil)
        #expect(store.groupContaining("file:///a") == inner)
    }

    @Test func aGroupCannotBeMovedIntoItsOwnDescendant() throws {
        let store = try store()
        let outer = store.createGroup(named: "Outer")
        let inner = store.createGroup(named: "Inner", in: outer)

        // Refused: Outer into Inner would make a cycle. Nothing changes.
        let before = store.active.placements
        store.move([try group(store, outer)], from: nil, to: inner, at: nil)
        #expect(store.active.placements == before)
    }

    @Test func deletingANestedGroupSpillsItsContentsInPlace() throws {
        let store = try store()
        store.reconcileRoots(ids("file:///a"))
        let outer = store.createGroup(named: "Outer")
        let inner = store.createGroup(named: "Inner", in: outer)
        store.move(["file:///a"], from: nil, to: inner, at: nil)

        store.deleteGroup(inner)
        // a survives, now directly inside Outer (Inner's old home).
        #expect(store.groupContaining("file:///a") == outer)
        #expect(store.active.rootURIs == ["file:///a"])
    }

    /// Regression: restoring must *rewrite* a root whose canonical spelling
    /// differs, not treat it as "old one vanished, new one appeared". Providers
    /// build ids with `NodeID(canonical:)` but resolve through the normalizing
    /// initializer, so the two can disagree — and the old prune-and-append lost
    /// the root's group and position, which reads as the root disappearing.
    @Test func restoringRewritesRootsInPlaceInsideTheirGroup() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Same directory, different spelling (a dot segment the provider folds away).
        let canonical = try #require(NodeID(fileURL: dir)).uri
        let stored = canonical.replacingOccurrences(
            of: dir.lastPathComponent, with: "./\(dir.lastPathComponent)")
        #expect(stored != canonical)

        let store = try store()
        let work = store.createGroup(named: "Work")
        store.add([stored], to: work, at: nil)

        let restored = store.restoreRoots(using: [FileSystemProvider()])

        #expect(restored.map(\.uri) == [canonical], "resolves to the live root")
        #expect(members(store, work) == [canonical], "rewritten in place — still in its group")
        #expect(members(store, nil) == [try group(store, work)],
                "no duplicate re-appended at the top level")
    }

    @Test func restorePreservesGroupMembershipAcrossLaunches() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try store()
        let root = try #require(NodeID(fileURL: dir))
        store.reconcileRoots([root])
        let group = store.createGroup(named: "Work")
        store.move([root.uri], from: nil, to: group, at: nil)

        let restored = store.restoreRoots(using: [FileSystemProvider()])
        #expect(restored == [root])
        #expect(store.groupContaining(root.uri) == group)
    }

    /// A root whose provider isn't loaded (plugin missing this launch) must not
    /// be silently deleted — it can't be judged, so it's kept.
    @Test func rootsWithNoProviderSurviveRestore() throws {
        let store = try store()
        store.reconcileRoots([NodeID("stub://thing")!])
        _ = store.restoreRoots(using: [FileSystemProvider()])   // no stub provider
        #expect(store.active.rootURIs == ["stub://thing"])
    }

    /// And stays kept when something else is mounted afterwards. It never was:
    /// it is missing from the live roots because nothing can load it, and the
    /// old reconcile pruned everything missing from them — silently, the next
    /// time anything was mounted.
    @Test func rootsWithNoProviderSurviveTheNextMount() throws {
        let store = try store()
        store.reconcileRoots([NodeID("file:///a")!, NodeID("nope://x")!])
        let live = store.restoreRoots(using: [])          // nothing is loadable
        store.reconcileRoots(live + [NodeID("file:///new")!])
        #expect(store.active.rootURIs.contains("nope://x"),
                "a root was dropped because its plugin was not loaded")
    }

    /// Dropping on the strip above C means before C. The old layout removed
    /// the row first and then inserted at the index measured before removal,
    /// so anything moved downward landed one place past where it was aimed.
    @Test func reorderingDownwardLandsBeforeTheTarget() throws {
        let store = try store()
        store.reconcileRoots(ids("file:///a", "file:///b", "file:///c"))
        // The strip above C sits at index 2.
        store.move(["file:///a"], from: nil, to: nil, at: 2)
        #expect(store.active.rootURIs == ["file:///b", "file:///a", "file:///c"])
    }

    /// Membership: the same root in two groups, taken out of one, is still in
    /// the other — and still mounted.
    @Test func removingFromOneGroupLeavesTheOther() throws {
        let store = try store()
        store.reconcileRoots(ids("file:///a"))
        let left = store.createGroup(named: "Left")
        let right = store.createGroup(named: "Right")
        store.move(["file:///a"], from: nil, to: left, at: nil)
        store.add(["file:///a"], to: right, at: nil)

        store.remove(["file:///a"], from: left)

        #expect(members(store, left) == [])
        #expect(members(store, right) == ["file:///a"])
        #expect(store.active.rootURIs == ["file:///a"], "no longer mounted")
    }

    /// A collection lives only in the sidebar, so removing it from the last
    /// place it is shown deletes it — along with any group inside it that
    /// nothing else holds.
    @Test func removingACollectionFromItsOnlyPlaceDeletesIt() throws {
        let store = try store()
        let outer = store.createGroup(named: "Outer")
        let inner = store.createGroup(named: "Inner", in: outer)
        store.add(["file:///a"], to: inner, at: nil)
        let innerURI = try group(store, inner)

        store.remove([try group(store, outer)], from: nil)

        #expect(store.uri(of: outer) == nil)
        #expect(store.active.placements.children[innerURI] == nil, "a group inside it was left behind")
        #expect(store.active.placements.children.isEmpty)
    }

    /// Not when another group still holds it: that is only taking it out of
    /// one place.
    @Test func aNestedGroupHeldElsewhereSurvivesItsParentsRemoval() throws {
        let store = try store()
        let doomed = store.createGroup(named: "Doomed")
        let kept = store.createGroup(named: "Kept")
        let both = store.createGroup(named: "Both", in: doomed)
        store.add([try group(store, both)], to: kept, at: nil)

        store.remove([try group(store, doomed)], from: nil)

        #expect(store.uri(of: doomed) == nil)
        #expect(store.uri(of: both) != nil, "deleted while another group held it")
    }

    /// Renaming a group gives it a new URI; the sidebar follows, open state
    /// included, and it keeps its id — so a drag begun before still lands.
    @Test func renamingAGroupKeepsItsPlaceAndItsOpenState() throws {
        let store = try store()
        let work = store.createGroup(named: "Work")
        store.add(["file:///a"], to: work, at: nil)
        let old = try group(store, work)
        store.setRevealedNodes([old])

        let renamed = try #require(store.renameGroup(work, to: "Job"))

        #expect(renamed.from == old)
        #expect(try group(store, work) == renamed.to)
        #expect(CollectionRef.name(from: renamed.to) == "Job")
        #expect(members(store, work) == ["file:///a"])
        #expect(store.active.revealedNodes == [renamed.to])
    }

    /// Placements belong to their workspace: the other workspaces are not
    /// arranged by this one.
    @Test func workspacesDoNotShareTheirArrangement() throws {
        let store = try store()
        let first = store.active.id
        let group = store.createGroup(named: "Mine")
        let second = store.create(named: "Second")
        store.setActive(second.id)
        #expect(store.uri(of: group) == nil)
        #expect(store.active.placements.children.isEmpty)
        store.setActive(first)
        #expect(store.uri(of: group) != nil)
    }

    @Test func groupsAndMembershipPersist() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wsf-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("workspaces.json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let store = WorkspaceStore(fileURL: file)
        store.reconcileRoots([NodeID("file:///a")!])
        let group = store.createGroup(named: "Work")
        store.move(["file:///a"], from: nil, to: group, at: nil)

        let reloaded = WorkspaceStore(fileURL: file)
        #expect(reloaded.groupContaining("file:///a") == group)
        #expect(reloaded.uri(of: group).flatMap(CollectionRef.name(from:)) == "Work")
    }
}
