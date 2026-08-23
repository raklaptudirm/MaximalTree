import Testing
import AppKit
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// Which nodes an action is handed when the thing it was invoked on is
/// several things at once.
@Suite struct ActionTargetVariantTests {
    private func id(_ uri: String) throws -> NodeID { try #require(NodeID(uri)) }

    @Test func aNodeIsOfferedAsItselfFirst() throws {
        let repo = try id("git://repo?repo=/work/p")
        let directory = try id("file:///work/p")
        let variants = ActionTargets.variants(for: [repo]) { _ in [directory] }

        #expect(variants.first == [repo], "the literal target has to come first")
        #expect(variants.contains([directory]))
    }

    @Test func nodesWithoutIdentitiesAreOfferedOnce() throws {
        let file = try id("file:///work/a.txt")
        #expect(ActionTargets.variants(for: [file]) { _ in [] } == [[file]])
    }

    /// A selection of several repos should reach the file actions as several
    /// directories in one go, not one invocation per node.
    @Test func aSelectionIsMappedTogether() throws {
        let first = try id("git://repo?repo=/work/a")
        let second = try id("git://repo?repo=/work/b")
        let directories = [try id("file:///work/a"), try id("file:///work/b")]
        let variants = ActionTargets.variants(for: [first, second]) { target in
            target == first ? [directories[0]] : [directories[1]]
        }
        #expect(variants.contains(directories))
    }

    /// A mixed selection where only some nodes can be seen as a directory must
    /// not produce a list that is half repos and half folders.
    @Test func aMixedSelectionIsNotHalfTranslated() throws {
        let repo = try id("git://repo?repo=/work/a")
        let page = try id("https://example.com")
        let directory = try id("file:///work/a")
        let variants = ActionTargets.variants(for: [repo, page]) { target in
            target == repo ? [directory] : []
        }
        #expect(variants == [[repo, page]], "\(variants)")
    }

    @Test func severalIdentitiesEachGetATurn() throws {
        let node = try id("git://repo?repo=/work/p")
        let directory = try id("file:///work/p")
        let page = try id("https://example.com/p")
        let variants = ActionTargets.variants(for: [node]) { _ in [directory, page] }
        #expect(variants == [[node], [directory], [page]])
    }

    @Test func anEmptySelectionIsStillOneVariant() {
        #expect(ActionTargets.variants(for: []) { _ in [] } == [[]])
    }
}

/// The point of it all: a repository is a directory, and gets to act like one.
@MainActor
@Suite struct NodeIdentityTests {
    /// The real model and the real plugins — registered by hand, since under
    /// XCTest the bundles are compiled in rather than loaded.
    private func makeApp() -> (AppModel, HostContext) {
        let host = HostContext()
        // Its own workspace file: mounting anything here must not land in the
        // user's real one.
        let model = AppModel(host: host, workspaceFile: FileManager.default
            .temporaryDirectory
            .appendingPathComponent("mt-workspace-\(UUID().uuidString).json"))
        FileSystemPlugin().register(with: model.pluginHost.registry)
        GitPlugin().register(with: model.pluginHost.registry)
        model.start()
        return (model, host)
    }

    /// A repo node offers the FileSystem plugin's actions, which test for
    /// `file://` nodes and would otherwise refuse it outright.
    @Test func aGitRepositoryOffersTheActionsOfADirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", directory.path, "init", "-q"]
        try git.run()
        git.waitUntilExit()

        let (model, host) = makeApp()
        host.mount(GitRef(repo: directory.path, kind: .repo).uri)
        // *This* repo, not whichever git root happened to be mounted first.
        let repo = try #require(host.roots.first {
            $0.scheme == "git" && $0.uri.contains(directory.lastPathComponent)
        })
        // The node record, and the record of what it also is, both have to
        // land before anything can be asked about them.
        for _ in 0..<40 where host.node(repo)?.identities.isEmpty ?? true {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let identity = try #require(host.node(repo)?.identities.first)
        for _ in 0..<40 where host.node(identity) == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }

        let actions = model.applicableActions(for: [repo])
        let ids = actions.map(\.id)
        #expect(ids.contains("file.reveal"),
                "a repository can't be revealed in Finder: \(ids)")
        #expect(ids.contains("file.newFile"),
                "no new file can be made in a repository: \(ids)")
        #expect(ids.contains("core.rename"),
                "a repository can't be renamed: \(ids)")

        // And it must *act* on the directory, not on the repo node: the
        // handler is written for file nodes and would otherwise be handed a
        // git:// uri it can't read. Copy Path says out loud which one it got.
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            if let saved {
                NSPasteboard.general.declareTypes([.string], owner: nil)
                NSPasteboard.general.setString(saved, forType: .string)
            }
        }
        let copyPath = try #require(actions.first { $0.id == "file.copyPath" })
        model.run(copyPath, targets: [repo])
        #expect(NSPasteboard.general.string(forType: .string) == directory.path,
                "copied \(NSPasteboard.general.string(forType: .string) ?? "nothing")")

        // The inspector shows what it is from both sides: git's section and
        // the filesystem's, each rendered for its own identity.
        let node = try #require(host.node(repo))
        let sections = try #require(model.store?.inspectors(for: node))
        #expect(sections.contains { $0.id == repo }, "no git section")
        #expect(sections.contains { $0.id == identity }, "no filesystem section")
    }
}
