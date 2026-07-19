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

    @Test func invalidateChildrenForcesRefetch() {
        let (host, parent, _) = populated()
        host._invalidateChildren(of: parent)
        #expect(host.cachedChildren(of: parent) == nil)
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

        WorkspaceStore(fileURL: file).saveRoots([root])

        let restored = WorkspaceStore(fileURL: file)
            .resolvedRoots(using: [FileSystemProvider()])
        #expect(restored == [root])
    }

    @Test func unresolvableRootsAreDropped() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let gone = try #require(NodeID("file:///does/not/exist/zzz-\(UUID())"))

        WorkspaceStore(fileURL: file).saveRoots([gone])

        // The stale root is dropped; no silent reseeding — an emptied workspace
        // stays empty (seeding is first-launch-only, gated by wasFreshlyCreated).
        let restored = WorkspaceStore(fileURL: file)
            .resolvedRoots(using: [FileSystemProvider()])
        #expect(restored.isEmpty)
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
        store.saveRoots([rootA])                       // into "Main"
        let b = store.create(named: "B")
        store.setActive(b.id)
        store.saveRoots([])                            // B is empty

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
        #expect(store.active.rootURIs == ["file:///tmp"])
        #expect(store.active.name == "Main")           // legacy placeholder upgraded
    }
}
