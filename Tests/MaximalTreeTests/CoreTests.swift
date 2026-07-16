import Testing
import Foundation
@testable import MaximalTreeKit
// FileSystemProvider + NodeID(fileURL:) are compiled into this test target directly
// (see project.yml), so no app import is needed for them.

@Suite struct NodeIDTests {
    @Test func trailingSlashCollapses() {
        #expect(NodeID("file:///Users/x/foo/")?.uri == NodeID("file:///Users/x/foo")?.uri)
    }

    @Test func authorityRootNotCollapsed() {
        // scheme://host/ must not be stripped into "scheme://host:"
        #expect(NodeID("git://repo/")?.uri == "git://repo")
        #expect(NodeID("file:///") != nil)
    }

    @Test func schemeLowercased() {
        #expect(NodeID("HTTPS://Example.com/a")?.scheme == "https")
    }

    @Test func fileStandardization() {
        #expect(NodeID("file:///Users/x/./foo/../bar")?.uri == NodeID("file:///Users/x/bar")?.uri)
    }

    @Test func schemeExtraction() {
        #expect(NodeID("file:///a/b")?.scheme == "file")
    }

    @Test func rejectsEmpty() {
        #expect(NodeID("   ") == nil)
    }
}

@Suite struct FileSystemProviderTests {
    private func makeTempTree() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "hello".write(to: base.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "world".write(to: base.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        return base
    }

    @Test func resolveAndChildren() async throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let provider = FileSystemProvider()

        let id = try #require(NodeID(fileURL: base))
        #expect(provider.resolve(id.uri) != nil)

        let page = await provider.children(of: id, page: nil)
        #expect(page.items.map(\.label) == ["sub", "a.txt", "b.txt"])

        let sub = try #require(page.items.first { $0.label == "sub" })
        #expect(sub.type == TypeID("file.directory"))
        #expect(sub.hasChildren)

        let txt = try #require(page.items.first { $0.label == "a.txt" })
        #expect(txt.type == TypeID("file.file"))
        #expect(!txt.hasChildren)
    }

    @Test func nodesCarryProviderSuppliedIcons() async throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = try #require(NodeID(fileURL: base))
        let page = await FileSystemProvider().children(of: id, page: nil)

        let dir = try #require(page.items.first { $0.label == "sub" })
        #expect(dir.icon?.systemName == "folder.fill")
        #expect(dir.icon?.tint == .blue)

        // Icon is content-type aware, not extension-guessed by the host.
        let text = try #require(page.items.first { $0.label == "a.txt" })
        #expect(text.icon?.systemName == "doc.text")
    }

    @Test func resolveNonexistentReturnsNil() {
        #expect(FileSystemProvider().resolve("file:///definitely/does/not/exist/zzz-\(UUID())") == nil)
    }

    @Test func defaultRootIsHome() throws {
        let roots = FileSystemProvider().roots()
        let home = try #require(NodeID(fileURL: FileManager.default.homeDirectoryForCurrentUser))
        #expect(roots == [home])
    }

    @Test func supportsRenameAndDelete() throws {
        let provider = FileSystemProvider()
        let id = try #require(NodeID("file:///tmp/x"))
        #expect(provider.supports(.rename(id, to: "y")))
        #expect(provider.supports(.delete([id])))
    }

    @Test func renameMovesFileAndReportsNewIdentity() async throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let provider = FileSystemProvider()
        let src = base.appendingPathComponent("a.txt")
        let id = try #require(NodeID(fileURL: src))

        let changes = try await provider.apply(.rename(id, to: "renamed.txt"))

        let dst = base.appendingPathComponent("renamed.txt")
        #expect(!FileManager.default.fileExists(atPath: src.path))
        #expect(FileManager.default.fileExists(atPath: dst.path))
        let newID = try #require(NodeID(fileURL: dst))
        #expect(changes.contains {
            if case .renamed(let from, let to) = $0 { return from == id && to == newID }
            return false
        })
    }

    @Test func deleteTrashesFileAndReportsRemoval() async throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let provider = FileSystemProvider()
        let target = base.appendingPathComponent("b.txt")
        let id = try #require(NodeID(fileURL: target))

        let changes = try await provider.apply(.delete([id]))

        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(changes.contains { if case .removed(let r) = $0 { return r == id } else { return false } })
    }
}
