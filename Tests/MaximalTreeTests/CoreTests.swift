import Testing
import Foundation
import AppKit
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

    @Test func symlinksArePhonyPointersToTheirDestination() async throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("a.txt")
        let link = base.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let id = try #require(NodeID(fileURL: base))
        let page = await FileSystemProvider().children(of: id, page: nil)
        let linkNode = try #require(page.items.first { $0.label == "link.txt" })
        let anchor = try #require(linkNode.anchor, "a symlink is a pointer, not a file")
        // The destination resolves fully (temp dirs live behind /var → /private/var).
        #expect(anchor.node == NodeID(fileURL: target.resolvingSymlinksInPath()))
        #expect(anchor.fragment == nil)
        // Regular files stay real.
        #expect(page.items.first { $0.label == "a.txt" }?.anchor == nil)
    }

    @Test func moveReparentsAndReportsRenames() throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = try #require(NodeID(fileURL: base.appendingPathComponent("a.txt")))
        let sub = try #require(NodeID(fileURL: base.appendingPathComponent("sub")))

        let provider = FileSystemProvider()
        #expect(provider.supports(.move([file], into: sub)))

        let changes = try FileSystemProvider.perform(.move([file], into: sub))
        let moved = base.appendingPathComponent("sub/a.txt")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(changes.contains(.renamed(from: file, to: NodeID(fileURL: moved)!)),
                "a move is a rename — the host remaps open state from it")
        #expect(changes.contains(.childrenChanged(NodeID(fileURL: base)!)))
        #expect(changes.contains(.childrenChanged(sub)))
    }

    @Test func degenerateMovesAreRefused() throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try #require(NodeID(fileURL: base))
        let sub = try #require(NodeID(fileURL: base.appendingPathComponent("sub")))
        let file = try #require(NodeID(fileURL: base.appendingPathComponent("a.txt")))

        let provider = FileSystemProvider()
        #expect(!provider.supports(.move([sub], into: sub)), "into itself")
        #expect(!provider.supports(.move([root], into: sub)), "into own descendant")
        #expect(!provider.supports(.move([file], into: root)), "no-op: already there")
        #expect(!provider.supports(.move([file], into: file)), "destination not a directory")
    }

    @Test func createMakesUniquedFilesAndFolders() throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try #require(NodeID(fileURL: base))

        _ = try FileSystemProvider.perform(.create(in: root, name: "notes", asContainer: true))
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: base.appendingPathComponent("notes").path, isDirectory: &isDir))
        #expect(isDir.boolValue)

        // Colliding names unique Finder-style, extension preserved.
        let changes = try FileSystemProvider.perform(.create(in: root, name: "a.txt",
                                                             asContainer: false))
        #expect(changes == [.childrenChanged(root)])
        #expect(FileManager.default.fileExists(
            atPath: base.appendingPathComponent("a 2.txt").path))
    }

    @Test func fileEventsMapToConservativeChanges() throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let existing = base.appendingPathComponent("a.txt").path
        let vanished = base.appendingPathComponent("gone.txt").path

        let changes = FileSystemProvider.nodeChanges(
            for: [.init(path: existing, mustRescanSubtree: false),
                  .init(path: vanished, mustRescanSubtree: false)],
            rootPath: base.path)

        let parent = NodeID(fileURL: base)
        // One deduped childrenChanged for the shared parent…
        #expect(changes.filter {
            if case .childrenChanged(let id) = $0 { return id == parent } else { return false }
        }.count == 1)
        // …modified only for the path that still exists (never .removed).
        #expect(changes.contains {
            if case .modified(let id) = $0 { return id == NodeID(fileURL: URL(fileURLWithPath: existing)) }
            return false
        })
        #expect(!changes.contains { if case .removed = $0 { return true } else { return false } })
    }

    @Test func hiddenDirectoryChurnIsFiltered() throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let gitChurn = base.appendingPathComponent(".git/objects/ab/cdef").path
        #expect(FileSystemProvider.nodeChanges(
            for: [.init(path: gitChurn, mustRescanSubtree: false)],
            rootPath: base.path).isEmpty)
    }

    @Test func rescanEventsInvalidateTheDirectoryItself() throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let changes = FileSystemProvider.nodeChanges(
            for: [.init(path: base.path, mustRescanSubtree: true)],
            rootPath: base.path)
        #expect(changes == [.childrenChanged(NodeID(fileURL: base)!)])
    }

    @Test func liveWatcherReportsExternalWrites() async throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }

        let hit = expectationBox()
        let watcher = try #require(FileTreeWatcher(path: base.path, latency: 0.1) { events in
            if events.contains(where: { $0.path.hasSuffix("external.txt") }) {
                hit.fulfill()
            }
        })
        defer { watcher.stop() }

        // Let the stream settle, then simulate another app writing a file.
        try await Task.sleep(nanoseconds: 300_000_000)
        try "outside edit".write(to: base.appendingPathComponent("external.txt"),
                                 atomically: true, encoding: .utf8)

        for _ in 0..<100 where !hit.isFulfilled {   // FSEvents latency: allow ~5s
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(hit.isFulfilled, "expected an FSEvents callback for the written file")
    }

    private final class ExpectationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var fulfilled = false
        func fulfill() { lock.lock(); fulfilled = true; lock.unlock() }
        var isFulfilled: Bool { lock.lock(); defer { lock.unlock() }; return fulfilled }
    }
    private func expectationBox() -> ExpectationBox { ExpectationBox() }

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

    /// The rename UI feeds arbitrary text into the mutation; nothing resembling
    /// a path may pass through as a name.
    @Test func renameRejectsUnsafeNames() throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = try #require(NodeID(fileURL: base.appendingPathComponent("a.txt")))

        for name in ["", "evil/name", ".", ".."] {
            #expect(throws: FileSystemError.self) {
                try FileSystemProvider.perform(.rename(id, to: name))
            }
        }
        // The file is untouched after every refusal.
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("a.txt").path))
    }

    @Test func duplicateCopiesBesideTheOriginalUnderAUniquedName() throws {
        let base = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = try #require(NodeID(fileURL: base.appendingPathComponent("a.txt")))

        let changes = try FileSystemProvider.duplicate([id])

        let copy = base.appendingPathComponent("a 2.txt")
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(try String(contentsOf: copy, encoding: .utf8) == "hello",
                "a duplicate carries the content, not just the name")
        let parent = try #require(NodeID(fileURL: base))
        #expect(changes.contains {
            if case .childrenChanged(let p) = $0 { return p == parent } else { return false }
        })

        // Again: the uniquing must keep stepping, not overwrite the first copy.
        _ = try FileSystemProvider.duplicate([id])
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("a 3.txt").path))
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

/// Icons for source and config files.
///
/// These can't come from content types: macOS registers no UTI for most source
/// files, so they'd all share the generic document icon.
@Suite struct FileIconTests {
    private func icon(_ path: String) -> NodeIcon? {
        FileSystemProvider.languageIcon(for: URL(fileURLWithPath: path))
    }

    /// A missing SF Symbol renders as nothing — validate every name we ship.
    @MainActor
    @Test func everySymbolExists() {
        let icons = Array(FileSystemProvider.iconsByExtension.values)
            + Array(FileSystemProvider.iconsByFileName.values)
        for name in Set(icons.map(\.systemName)).sorted() {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "unknown SF Symbol: \(name)")
        }
    }

    @Test func sourceFilesGetLanguageIcons() {
        // The ones content types can't see (dynamic/absent UTIs).
        #expect(icon("/p/main.rs") != nil)
        #expect(icon("/p/flake.nix") != nil)
        #expect(icon("/p/app.ex") != nil)
        #expect(icon("/p/Main.kt") != nil)
        // Distinct languages read as distinct: same symbol family, own colour.
        #expect(icon("/p/a.rs")?.tint != icon("/p/a.go")?.tint)
        #expect(icon("/p/a.py")?.tint != icon("/p/a.rb")?.tint)
    }

    @Test func kindShowsInTheSymbol() {
        #expect(icon("/p/run.sh")?.systemName == "terminal")
        #expect(icon("/p/data.json")?.systemName == "curlybraces")
        #expect(icon("/p/schema.sql")?.systemName == "cylinder")
        #expect(icon("/p/style.css")?.systemName == "paintbrush")
        #expect(icon("/p/Dockerfile")?.systemName == "cube")
        #expect(icon("/p/Makefile")?.systemName == "hammer")
        #expect(icon("/p/LICENSE")?.systemName == "checkmark.seal")
        #expect(icon("/p/.gitignore")?.systemName == "arrow.triangle.branch")
        #expect(icon("/p/main.swift")?.systemName == "swift")
    }

    @Test func unknownFilesDeferToContentTypes() {
        // nil means "fall back to the UTI rules" — images, media, archives.
        #expect(icon("/p/photo.jpeg") == nil)
        #expect(icon("/p/mystery.zzz") == nil)
        #expect(icon("/p/noextension") == nil)
    }

    @Test func nodesCarryTheLanguageIconEndToEnd() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("icons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("main.rs")
        try "fn main() {}".write(to: url, atomically: true, encoding: .utf8)

        let id = try #require(NodeID(fileURL: url))
        let node = try #require(FileSystemProvider.makeNode(url: url, id: id))
        #expect(node.icon?.systemName == "chevron.left.forwardslash.chevron.right")
        #expect(node.icon?.tint != nil, "a Rust file should not use the generic doc icon")
    }
}
