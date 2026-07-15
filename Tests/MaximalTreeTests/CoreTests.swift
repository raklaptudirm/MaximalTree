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
        #expect(page.items.map(\.displayName) == ["sub", "a.txt", "b.txt"])

        let sub = try #require(page.items.first { $0.displayName == "sub" })
        #expect(sub.type == TypeID("file.directory"))
        #expect(sub.hasChildren)

        let txt = try #require(page.items.first { $0.displayName == "a.txt" })
        #expect(txt.type == TypeID("file.file"))
        #expect(!txt.hasChildren)
    }

    @Test func resolveNonexistentReturnsNil() {
        #expect(FileSystemProvider().resolve("file:///definitely/does/not/exist/zzz-\(UUID())") == nil)
    }

    @Test func defaultRootIsHome() throws {
        let roots = FileSystemProvider().roots()
        let home = try #require(NodeID(fileURL: FileManager.default.homeDirectoryForCurrentUser))
        #expect(roots == [home])
    }
}
