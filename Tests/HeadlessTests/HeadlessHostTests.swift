import Testing
import Foundation
import MaximalTreeKit
@testable import MaximalTreeHost
@testable import FileSystem

/// The engine with no window, driven the way `mtree` drives it — through
/// HeadlessHost, with the real file-system plugin — on every platform CI runs.
@MainActor
@Suite struct HeadlessHostTests {
    /// A folder of its own, with a file and a folder in it, and a library
    /// beside it.
    private struct Place {
        let root: URL
        var uri: String { root.absoluteString }
        var library: URL { root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".json") }

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("headless-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"),
                                                    withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: root.appendingPathComponent("a.txt"))
        }
    }

    private func host(_ place: Place) -> HeadlessHost {
        HeadlessHost(library: place.library) { FileSystemCore.register(with: $0) }
    }

    @Test func aFolderListsWhatIsInIt() async throws {
        let place = try Place()
        let children = try await host(place).children(of: place.uri)
        #expect(Set(children.map(\.label)) == ["a.txt", "sub"])
        #expect(children.first { $0.label == "sub" }?.hasChildren == true)
    }

    @Test func aNodeIsWhatItsProviderSaysItIs() async throws {
        let place = try Place()
        let node = try await host(place).node(place.root.appendingPathComponent("a.txt").absoluteString)
        #expect(node.label == "a.txt")
        #expect(node.type == .file)
    }

    @Test func whatCannotBeServedSaysSo() async throws {
        let place = try Place()
        await #expect(throws: HeadlessHost.Failure.self) {
            _ = try await host(place).node("nowhere://at/all")
        }
    }

    /// Actions are offered as a menu would offer them — including, where there
    /// is no Trash, not offering to move something there.
    @Test func whatCanBeDoneIsWhatAMenuWouldOffer() async throws {
        let place = try Place()
        let ids = try await host(place).actions(for: place.uri).map(\.id)
        #expect(ids.contains("file.newFolder"))
        #expect(ids.contains("file.trash") == FileSystemProvider.hasTrash)
    }

    /// And doing one is waited for: the folder is on disk when `run` returns.
    @Test func runningAnActionWaitsForIt() async throws {
        let place = try Place()
        let host = host(place)
        try await host.run("file.newFolder", on: place.uri)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: place.root.appendingPathComponent("untitled folder").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func anActionThatDoesNotApplyIsRefused() async throws {
        let place = try Place()
        let file = place.root.appendingPathComponent("a.txt").absoluteString
        await #expect(throws: HeadlessHost.Failure.self) {
            try await host(place).run("file.newFolder", on: file)
        }
    }

    /// A mount is kept: a second host over the same library has it.
    @Test func aMountIsWrittenDown() async throws {
        let place = try Place()
        try await host(place).mount(place.uri)
        let again = host(place)
        let mounted = try #require(NodeID(place.uri))
        #expect(again.roots.contains(mounted), "roots: \(again.roots.map(\.uri))")
    }
}
