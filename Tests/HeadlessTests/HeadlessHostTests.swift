import Testing
import Foundation
@_spi(Host) import MaximalTreeKit
@testable import MaximalTreeHost
@testable import FileSystem
@testable import Git

/// The engine with no window, driven the way `mtree` drives it — through
/// HeadlessHost, with the real file-system plugin — on every platform CI runs.
@MainActor
@Suite struct HeadlessHostTests {
    /// A folder of its own, with a file and a folder in it, and a library
    /// beside it.
    struct Place {
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

    func host(_ place: Place) -> HeadlessHost {
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

extension HeadlessHostTests {
    /// The sidebar's rename, with no sidebar: by id, with an argument, and the
    /// file has its new name on disk when it answers.
    @Test func aFileIsRenamedThroughTheEngine() async throws {
        let place = try Place()
        let host = host(place)
        let file = place.root.appendingPathComponent("a.txt").absoluteString
        _ = try await host.node(file)

        try await host.host.perform(RenameNode.self, .init(node: try #require(NodeID(file)), name: "b.txt"))
        await host.settle()

        #expect(FileManager.default.fileExists(atPath: place.root.appendingPathComponent("b.txt").path))
        #expect(!FileManager.default.fileExists(atPath: place.root.appendingPathComponent("a.txt").path))
    }
}

/// Git's writes with no window: they wait for git, and a refusal comes back
/// to whoever asked — the reason they could move out of the repository canvas.
@MainActor
@Suite struct HeadlessGitTests {
    private func git(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", dir.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output
    }

    /// A repository with one new file, and a host over it.
    private func repository() throws -> (dir: URL, host: HeadlessHost, uri: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("headless-git-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try git(["init", "-q"], in: dir)
        try Data("hello".utf8).write(to: dir.appendingPathComponent("new.txt"))
        let host = HeadlessHost(library: dir.appendingPathExtension("json")) { GitCore.register(with: $0) }
        let uri = try #require(GitRef(repo: dir.path, kind: .repo).nodeID).uri
        return (dir, host, uri)
    }

    @Test func stagingWaitsForGit() async throws {
        let (dir, host, uri) = try repository()
        try await host.run("git.stageAll", on: uri)
        #expect(try git(["status", "--porcelain"], in: dir).hasPrefix("A  new.txt"))
    }

    /// No remote to pull from: git refuses, and the refusal is the answer.
    @Test func whatGitRefusesIsSaid() async throws {
        let (_, host, uri) = try repository()
        do {
            try await host.run("git.pull", on: uri)
            Issue.record("a pull with no remote succeeded")
        } catch let failure as HeadlessHost.Failure {
            #expect(failure.description.hasPrefix("Pull failed: "), "\(failure)")
        }
    }
}
