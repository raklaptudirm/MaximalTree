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
        #expect(store.active.layout.entries.allSatisfy {
            if case .root = $0 { return true } else { return false }
        })
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

    @Test func reconcilePlacesNewRootsIntoTheTargetFolder() throws {
        let store = try store()
        store.reconcileRoots(ids("file:///a"))
        let folder = store.createFolder(named: "Work")

        store.reconcileRoots(ids("file:///a", "file:///b"), placingNewInto: folder)
        #expect(store.folderID(containing: "file:///b") == folder)
        #expect(store.folderID(containing: "file:///a") == nil, "existing roots aren't moved")
    }

    @Test func deletingAFolderKeepsItsRootsAsLoose() throws {
        let store = try store()
        store.reconcileRoots(ids("file:///a"))
        let folder = store.createFolder(named: "Work")
        store.moveRoots(["file:///a"], toFolder: folder)
        #expect(store.folderID(containing: "file:///a") == folder)

        store.deleteFolder(folder)
        #expect(store.folderID(containing: "file:///a") == nil)
        #expect(store.active.rootURIs.contains("file:///a"), "the root survives its folder")
    }

    @Test func reconcilePrunesVanishedRootsFromFoldersButKeepsTheFolder() throws {
        let store = try store()
        store.reconcileRoots(ids("file:///a", "file:///b"))
        let folder = store.createFolder(named: "Work")
        store.moveRoots(["file:///a", "file:///b"], toFolder: folder)

        store.reconcileRoots(ids("file:///a"))   // b unmounted
        #expect(store.folderID(containing: "file:///a") == folder)
        #expect(store.active.rootURIs == ["file:///a"])
        // Empty or not, the folder is intentional — it stays.
        #expect(store.active.layout.entries.contains {
            if case .folder(let f) = $0 { return f.id == folder } else { return false }
        })
    }

    @Test func foldersNestAndMoveByIndex() throws {
        let store = try store()
        store.reconcileRoots(ids("file:///a", "file:///b", "file:///c"))
        let outer = store.createFolder(named: "Outer")
        let inner = store.createFolder(named: "Inner", in: outer)

        // Nesting: Inner sits inside Outer.
        #expect(RootLayout.folder(outer, contains: inner, in: store.active.layout.entries))

        // Position: put c first at the top level.
        store.moveEntries([.root("file:///c")], toFolder: nil, at: 0)
        #expect(store.active.layout.rootURIs.first == "file:///c")

        // Move a root into the nested Inner folder.
        store.moveEntries([.root("file:///a")], toFolder: inner, at: nil)
        #expect(store.folderID(containing: "file:///a") == inner)
    }

    @Test func aFolderCannotBeMovedIntoItsOwnDescendant() throws {
        let store = try store()
        let outer = store.createFolder(named: "Outer")
        let inner = store.createFolder(named: "Inner", in: outer)

        // Refused: Outer into Inner would make a cycle. Layout is unchanged.
        let before = store.active.layout
        store.moveEntries([.folder(outer)], toFolder: inner, at: nil)
        #expect(store.active.layout == before)
        #expect(RootLayout.folder(outer, contains: inner, in: store.active.layout.entries))
    }

    @Test func deletingANestedFolderSpillsItsContentsInPlace() throws {
        let store = try store()
        store.reconcileRoots(ids("file:///a"))
        let outer = store.createFolder(named: "Outer")
        let inner = store.createFolder(named: "Inner", in: outer)
        store.moveEntries([.root("file:///a")], toFolder: inner, at: nil)

        store.deleteFolder(inner)
        // a survives, now directly inside Outer (Inner's old home).
        #expect(store.folderID(containing: "file:///a") == outer)
        #expect(store.active.rootURIs == ["file:///a"])
    }

    /// Regression: restoring must *rewrite* a root whose canonical spelling
    /// differs, not treat it as "old one vanished, new one appeared". Providers
    /// build ids with `NodeID(canonical:)` but resolve through the normalizing
    /// initializer, so the two can disagree — and the old prune-and-append lost
    /// the root's folder and position, which reads as the root disappearing.
    @Test func resolvingRewritesRootsInPlaceInsideTheirFolder() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Same directory, different spelling (a dot segment the provider folds away).
        let canonical = try #require(NodeID(fileURL: dir)).uri
        let stored = canonical.replacingOccurrences(
            of: dir.lastPathComponent, with: "./\(dir.lastPathComponent)")
        #expect(stored != canonical)

        var entries: [RootEntry] = [
            .folder(RootFolder(name: "Work", entries: [.root(stored)])),
        ]
        var ids: [NodeID] = []
        RootLayout.resolveInPlace(&entries, using: [FileSystemProvider()], into: &ids)

        #expect(ids.map(\.uri) == [canonical], "resolves to the live root")
        #expect(entries.count == 1, "no duplicate re-appended at the top level")
        guard case .folder(let folder) = entries[0] else {
            Issue.record("the folder vanished"); return
        }
        #expect(folder.entries == [.root(canonical)],
                "rewritten in place — still in its folder")
    }

    @Test func restorePreservesFolderMembershipAcrossLaunches() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("restore2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try store()
        let root = try #require(NodeID(fileURL: dir))
        store.reconcileRoots([root])
        let folder = store.createFolder(named: "Work")
        store.moveRoots([root.uri], toFolder: folder)

        let restored = store.restoreRoots(using: [FileSystemProvider()])
        #expect(restored == [root])
        #expect(store.folderID(containing: root.uri) == folder)
    }

    /// A root whose provider isn't loaded (plugin missing this launch) must not
    /// be silently deleted — it can't be judged, so it's kept.
    @Test func rootsWithNoProviderSurviveRestore() throws {
        let store = try store()
        store.reconcileRoots([NodeID("stub://thing")!])
        _ = store.restoreRoots(using: [FileSystemProvider()])   // no stub provider
        #expect(store.active.rootURIs == ["stub://thing"])
    }

    @Test func entryRefTokensRoundTrip() {
        let id = UUID()
        #expect(EntryRef(token: EntryRef.root("file:///x").token) == .root("file:///x"))
        #expect(EntryRef(token: EntryRef.folder(id).token) == .folder(id))
        #expect(EntryRef(token: "garbage") == nil)
    }

    @Test func foldersAndMembershipPersist() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wsf-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("workspaces.json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let store = WorkspaceStore(fileURL: file)
        store.reconcileRoots([NodeID("file:///a")!])
        let folder = store.createFolder(named: "Work")
        store.moveRoots(["file:///a"], toFolder: folder)

        let reloaded = WorkspaceStore(fileURL: file)
        #expect(reloaded.folderID(containing: "file:///a") == folder)
        if case .folder(let f)? = reloaded.active.layout.entries.first(where: {
            if case .folder = $0 { return true } else { return false }
        }) {
            #expect(f.name == "Work")
        } else {
            Issue.record("folder did not persist")
        }
    }
}
