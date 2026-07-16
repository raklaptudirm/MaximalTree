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
@Suite struct WorkspaceStoreTests {
    private func tempFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-\(UUID().uuidString).json")
    }

    @Test func roundTripsRoots() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let dir = FileManager.default.temporaryDirectory
        let root = try #require(NodeID(fileURL: dir))

        WorkspaceStore(fileURL: file).save(roots: [root])

        // A brand-new store (fresh launch) restores the same root.
        let restored = WorkspaceStore(fileURL: file)
            .resolvedRoots(using: [FileSystemProvider()]) { [] }
        #expect(restored == [root])
    }

    @Test func unresolvableRootsDegradeToSeed() throws {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let gone = try #require(NodeID("file:///does/not/exist/zzz-\(UUID())"))
        let seed = try #require(NodeID(fileURL: FileManager.default.temporaryDirectory))

        WorkspaceStore(fileURL: file).save(roots: [gone])

        // The stale root is dropped (renamed/removed while the app was closed) and
        // the empty result falls back to the seed.
        let restored = WorkspaceStore(fileURL: file)
            .resolvedRoots(using: [FileSystemProvider()]) { [seed] }
        #expect(restored == [seed])
    }
}
