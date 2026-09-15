import Testing
import Foundation
@testable import MaximalTree

/// Which workspace a file opened from the Finder belongs to.
@Suite struct FileOpeningTests {
    private func workspace(_ name: String, roots: [String]) -> Workspace {
        Workspace(name: name, rootURIs: roots.map { URL(fileURLWithPath: $0).absoluteString })
    }

    /// A workspace whose roots are given as URIs rather than paths, for the
    /// providers that mount a directory without being the filesystem.
    private func uris(_ name: String, _ uris: [String]) -> Workspace {
        Workspace(name: name, rootURIs: uris)
    }

    private func file(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func aFileInsideAMountedRootBelongsToThatWorkspace() {
        let work = workspace("Work", roots: ["/Users/me/work"])
        let notes = workspace("Notes", roots: ["/Users/me/notes"])
        #expect(FileOpening.owner(of: file("/Users/me/work/app/main.swift"),
                                  in: [work, notes])?.name == "Work")
        #expect(FileOpening.owner(of: file("/Users/me/notes/today.typ"),
                                  in: [work, notes])?.name == "Notes")
    }

    /// A stray has no project to open in, which is what the loose window is for.
    @Test func aFileNoWorkspaceMountsBelongsToNone() {
        let work = workspace("Work", roots: ["/Users/me/work"])
        #expect(FileOpening.owner(of: file("/tmp/scratch.txt"), in: [work]) == nil)
        #expect(FileOpening.owner(of: file("/Users/me/other/x.swift"), in: [work]) == nil)
    }

    /// Roots nest — a repository inside a mounted home directory — and the
    /// nearer root is the more specific answer.
    @Test func theInnermostRootWins() {
        let home = workspace("Home", roots: ["/Users/me"])
        let project = workspace("Project", roots: ["/Users/me/work/app"])
        #expect(FileOpening.owner(of: file("/Users/me/work/app/main.swift"),
                                  in: [home, project])?.name == "Project")
        // Outside the inner root, the outer one still claims it.
        #expect(FileOpening.owner(of: file("/Users/me/notes.txt"),
                                  in: [home, project])?.name == "Home")
    }

    /// Compared on path boundaries: a root must not claim a sibling whose name
    /// merely starts the same way.
    @Test func aRootDoesNotClaimItsNeighbours() {
        let app = workspace("App", roots: ["/src/app"])
        #expect(FileOpening.owner(of: file("/src/apple/main.swift"), in: [app]) == nil)
        #expect(FileOpening.owner(of: file("/src/app/main.swift"), in: [app])?.name == "App")
    }

    /// The root itself, dropped on the app, is in its own workspace.
    @Test func aRootIsInsideItself() {
        let work = workspace("Work", roots: ["/Users/me/work"])
        #expect(FileOpening.owner(of: file("/Users/me/work"), in: [work])?.name == "Work")
    }

    @Test func trailingSlashesAndDotsDoNotConfuseIt() {
        let work = workspace("Work", roots: ["/Users/me/work/"])
        #expect(FileOpening.owner(of: file("/Users/me/work/./app/main.swift"),
                                  in: [work])?.name == "Work")
    }

    /// A root that names no place on disk claims nothing.
    @Test func rootsWithoutADirectoryClaimNothing() {
        let web = uris("Web", ["https://example.com", "terminal:///1"])
        #expect(FileOpening.owner(of: file("/Users/me/x.txt"), in: [web]) == nil)
    }

    /// The case that sent every file in this repository to a loose window: a
    /// project mounted through a provider that isn't the filesystem still
    /// mounts a directory, and the files under it are still its own.
    @Test func aRootMountedThroughAnotherProviderStillClaimsItsFiles() {
        let main = uris("Main", ["git://repo?repo=/Users/me/dev/Tree"])
        #expect(FileOpening.owner(of: file("/Users/me/dev/Tree/App.swift"),
                                  in: [main])?.name == "Main")
        #expect(FileOpening.owner(of: file("/Users/me/dev/Other/App.swift"),
                                  in: [main]) == nil)
    }

    @Test func aPathWithSpacesSurvivesBeingInAQuery() {
        let notes = uris("Notes", ["git://repo?repo=/Users/me/My%20Notes"])
        #expect(FileOpening.owner(of: file("/Users/me/My Notes/today.typ"),
                                  in: [notes])?.name == "Notes")
    }

    /// Depth still decides across providers: the repository mounted inside a
    /// mounted home directory is the more specific answer.
    @Test func theInnermostRootWinsWhicheverProviderMountedIt() {
        let home = uris("Home", [URL(fileURLWithPath: "/Users/me").absoluteString])
        let dev = uris("Dev", ["git://repo?repo=/Users/me/dev/Tree"])
        #expect(FileOpening.owner(of: file("/Users/me/dev/Tree/App.swift"),
                                  in: [home, dev])?.name == "Dev")
    }
}

/// A stray file gets a workspace of its own, and that workspace is not one the
/// library remembers unless it is kept.
@Suite @MainActor struct EphemeralWorkspaceTests {
    private func tempLibraryURL() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspaces.json")
    }

    @Test func anEphemeralWorkspaceIsListedButNotWrittenDown() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let store = WorkspaceStore(fileURL: file)
        let stray = store.createEphemeral(named: "notes.typ", rootURIs: ["file:///tmp/notes.typ"])
        store.setActive(stray.id)

        // Present in the session: it is switchable, and it is what is active.
        #expect(store.library.workspaces.contains { $0.id == stray.id })
        #expect(store.active.id == stray.id)

        // Gone from the next launch, without anything having deleted it.
        let reloaded = WorkspaceStore(fileURL: file)
        #expect(!reloaded.library.workspaces.contains { $0.id == stray.id })
    }

    /// The stored library must not be left pointing at a workspace that won't
    /// be there — it would come back with nothing active.
    @Test func theStoredActiveWorkspaceIsNeverAnEphemeralOne() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let store = WorkspaceStore(fileURL: file)
        let real = store.active.id
        let stray = store.createEphemeral(named: "stray.txt", rootURIs: ["file:///tmp/stray.txt"])
        store.setActive(stray.id)

        let reloaded = WorkspaceStore(fileURL: file)
        #expect(reloaded.active.id == real)
    }

    @Test func keepingOneMakesItSurvive() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let store = WorkspaceStore(fileURL: file)
        let stray = store.createEphemeral(named: "notes.typ", rootURIs: ["file:///tmp/notes.typ"])
        store.keep(stray.id)

        let reloaded = WorkspaceStore(fileURL: file)
        let kept = reloaded.library.workspaces.first { $0.id == stray.id }
        #expect(kept?.name == "notes.typ")
        #expect(kept?.rootURIs == ["file:///tmp/notes.typ"])
        // And it is an ordinary workspace now, not one waiting to vanish.
        #expect(kept?.isEphemeral == false)
    }

    @Test func keepingSomethingThatIsAlreadyKeptChangesNothing() throws {
        let file = try tempLibraryURL()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let store = WorkspaceStore(fileURL: file)
        let real = store.create(named: "Work")
        store.keep(real.id)
        #expect(store.library.workspaces.filter { $0.id == real.id }.count == 1)
        #expect(store.library.workspaces.first { $0.id == real.id }?.isEphemeral == false)
    }
}
