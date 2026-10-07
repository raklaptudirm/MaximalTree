import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// What an open document does when its file moves underneath it.
@Suite struct ExternalEditOutcomeTests {
    private func outcome(disk: String?, buffer: String, saved: String) -> ExternalEdit.Outcome {
        ExternalEdit.outcome(onDisk: disk, buffer: buffer, saved: saved)
    }

    @Test func aChangedFileIsFollowedWhenNothingIsUnsaved() {
        #expect(outcome(disk: "new", buffer: "old", saved: "old") == .reload("new"))
    }

    @Test func aChangedFileUnderUnsavedEditsIsAConflict() {
        #expect(outcome(disk: "theirs", buffer: "mine", saved: "original")
                == .conflict("theirs"))
    }

    /// The case that makes timing-based detection wrong. Saving produces a
    /// file-system event a moment later; by the time it lands the reader may
    /// have typed more, which looks exactly like someone else's edit unless
    /// the file is compared against what we last wrote.
    @Test func theEchoOfOurOwnSaveIsNotAConflict() {
        // Saved "v2", kept typing to "v3", then our own write event arrives.
        #expect(outcome(disk: "v2", buffer: "v3", saved: "v2") == .unchanged)
    }

    /// Someone saved exactly what we already had — the text is right, it just
    /// isn't unsaved any more.
    @Test func aFileThatCatchesUpToTheBufferClearsTheDirtyState() {
        #expect(outcome(disk: "same", buffer: "same", saved: "older")
                == .adoptAsSaved("same"))
    }

    @Test func anUnreadableFileChangesNothing() {
        #expect(outcome(disk: nil, buffer: "mine", saved: "original") == .unchanged)
    }
}

/// A provider that exists only to own the `stub://` scheme.
private struct StubProvider: NodeProvider {
    let schemes: Set<String> = ["stub"]
    func resolve(_ uri: String) -> NodeID? { NodeID(uri) }
    func node(for id: NodeID) async -> Node? { Node(id: id, type: "stub.doc") }
    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        Page(items: [])
    }
}

/// The host's side: only edits from *outside* wake a canvas.
@MainActor
@Suite struct ExternalEditNoticeTests {
    private func makeStore() -> (GraphStore, HostContext) {
        let host = HostContext()
        let registry = Registry()
        registry.register(provider: StubProvider())
        let store = GraphStore(context: host, registry: registry, nav: NavigationModel())
        return (store, host)
    }

    @Test func anExternalModificationPostsANotice() throws {
        let (store, host) = makeStore()
        let id = try #require(NodeID("stub://doc"))

        store.notifyExternal([.modified(id)])

        #expect(host.externalEdit?.node == id)
    }

    /// Our own save reports `.modified` too — the inspector needs the new size
    /// and date — but nothing should go re-read the file because of it.
    @Test func ourOwnNotificationDoesNotPostANotice() throws {
        let (store, host) = makeStore()
        let id = try #require(NodeID("stub://doc"))

        store.notify([.modified(id)])

        #expect(host.externalEdit == nil)
    }

    @Test func repeatedChangesToOneNodeAreEachObservable() throws {
        let (store, host) = makeStore()
        let id = try #require(NodeID("stub://doc"))

        store.notifyExternal([.modified(id)])
        let first = host.externalEdit
        store.notifyExternal([.modified(id)])

        #expect(first != host.externalEdit, "a second change to the same file was swallowed")
    }
}

/// The watcher end to end: a file appearing, changing, and vanishing on disk,
/// through real FSEvents and the real provider.
@MainActor
@Suite struct FileSystemWatchTests {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolve symlinks: /var is /private/var, and FSEvents reports the real
        // path — the ids would otherwise never match what we're watching.
        return URL(fileURLWithPath: dir.resolvingSymlinksInPath().path)
    }

    /// Watch `root`, make a change on disk, and report whether the expected
    /// changes ever arrived. FSEvents is coalesced and asynchronous, so this
    /// waits for them rather than for a while — and gives up rather than
    /// hanging a test run if the watcher never fires.
    ///
    /// FSEvents also takes a moment to start listening, and a change made
    /// before it does is simply missed. So it is poked first, in a folder of
    /// its own that none of these tests are about, until it answers; only then
    /// is the change under test made.
    private func watching(_ root: NodeID, with provider: FileSystemProvider,
                          until matches: @escaping @Sendable ([NodeChange]) -> Bool,
                          perform: () throws -> Void) async throws -> Bool {
        let probe = try #require(root.fileURL).appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        let probeID = try #require(NodeID(fileURL: probe))

        let stream = try #require(provider.changes(under: root))
        let seen = Seen()
        let consumer = Task { for await batch in stream { seen.add(batch) } }
        defer { consumer.cancel() }

        let armed = await waitUntil("the watcher never started listening") {
            try? UUID().uuidString.write(to: probe.appendingPathComponent("poke"),
                                         atomically: true, encoding: .utf8)
            return seen.changes.contains(.childrenChanged(probeID))
        }
        guard armed else { return false }

        seen.clear()
        try perform()
        return await waitUntil("the change never arrived", within: .seconds(5)) {
            matches(seen.changes)
        }
    }

    /// What the watcher has reported, as it arrives.
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [NodeChange] = []
        var changes: [NodeChange] { lock.withLock { all } }
        func add(_ batch: [NodeChange]) { lock.withLock { all += batch } }
        func clear() { lock.withLock { all = [] } }
    }

    @Test func creatingAFileOutsideTheAppRefreshesItsFolder() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = try #require(NodeID(fileURL: dir))
        let provider = FileSystemProvider()

        let saw = try await watching(root, with: provider,
                                     until: { $0.contains(.childrenChanged(root)) }) {
            try "hello".write(to: dir.appendingPathComponent("new.txt"),
                              atomically: true, encoding: .utf8)
        }
        #expect(saw, "the folder's listing was never invalidated")
    }

    @Test func editingAFileOutsideTheAppReportsItModified() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)
        let root = try #require(NodeID(fileURL: dir))
        let fileID = try #require(NodeID(fileURL: file))
        let provider = FileSystemProvider()

        let saw = try await watching(root, with: provider,
                                     until: { $0.contains(.modified(fileID)) }) {
            try "after".write(to: file, atomically: true, encoding: .utf8)
        }
        #expect(saw, "an outside edit never reached the app")
    }

    /// A deletion is reported as the folder's listing changing, never as
    /// `.removed`: FSEvents can't pair renames, and a wrong removal would tear
    /// down open tabs for a file that was only moved.
    @Test func deletingAFileOutsideTheAppRefreshesItsFolder() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doomed.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let root = try #require(NodeID(fileURL: dir))
        let provider = FileSystemProvider()

        let saw = try await watching(root, with: provider,
                                     until: { $0.contains(.childrenChanged(root)) }) {
            try FileManager.default.removeItem(at: file)
        }
        #expect(saw)
        let listing = await provider.children(of: root, page: nil).items
        #expect(!listing.contains { $0.id.uri.hasSuffix("doomed.txt") },
                "the deleted file is still in the listing")
    }
}
