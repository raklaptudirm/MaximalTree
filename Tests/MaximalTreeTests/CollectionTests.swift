import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// Collections: a name and an ordered list of references.
///
/// The rules first, because they are where the judgement is — where a deleted
/// collection's members go, what dragging an existing member means, and which
/// references a rename has to reach.
@Suite struct CollectionRulesTests {

    // MARK: Order

    @Test func adoptingAppendsByDefault() {
        #expect(CollectionRules.adopt(["c"], into: ["a", "b"], at: nil) == ["a", "b", "c"])
    }

    @Test func adoptingAtAPositionInsertsThere() {
        #expect(CollectionRules.adopt(["x"], into: ["a", "b", "c"], at: 1) == ["a", "x", "b", "c"])
    }

    /// Dragging something already there reorders it rather than duplicating.
    @Test func adoptingAMemberMovesIt() {
        #expect(CollectionRules.adopt(["c"], into: ["a", "b", "c"], at: 0) == ["c", "a", "b"])
    }

    /// Downward, the insertion point is counted before the member leaves it —
    /// so "put a after b" means after b, not one further along.
    @Test func movingAMemberDownLandsWhereItWasAimed() {
        // Dropped at index 2 means "before what was at 2", which was c.
        #expect(CollectionRules.adopt(["a"], into: ["a", "b", "c"], at: 2) == ["b", "a", "c"])
    }

    @Test func adoptingTheSameThingTwiceInOneGoKeepsOne() {
        #expect(CollectionRules.adopt(["x", "x"], into: ["a"], at: nil) == ["a", "x"])
    }

    @Test func aPositionPastTheEndAppends() {
        #expect(CollectionRules.adopt(["x"], into: ["a"], at: 99) == ["a", "x"])
    }

    @Test func releasingRemovesOnlyWhatWasNamed() {
        #expect(CollectionRules.release(["b"], from: ["a", "b", "c"]) == ["a", "c"])
    }

    // MARK: Deleting a collection

    private func record(_ name: String, _ members: [String]) -> CollectionRecord {
        CollectionRecord(id: UUID(), name: name, members: members)
    }

    /// What a group has always done: the contents are not thrown away, they
    /// take the deleted collection's place.
    @Test func deletingSpillsTheMembersInPlace() {
        let inner = record("Inner", ["x", "y"])
        let outer = record("Outer", ["a", inner.uri, "b"])
        let after = CollectionRules.delete(inner.id, from: [outer, inner])

        #expect(after.count == 1, "the deleted collection is still there")
        #expect(after.first?.members == ["a", "x", "y", "b"])
    }

    /// A collection is not a list of duplicates.
    @Test func spillingSkipsWhatTheHolderAlreadyHas() {
        let inner = record("Inner", ["x", "a"])
        let outer = record("Outer", ["a", inner.uri])
        let after = CollectionRules.delete(inner.id, from: [outer, inner])
        #expect(after.first?.members == ["a", "x"])
    }

    /// Several holders is what membership means, and each gets the members.
    @Test func everyHolderReceivesTheMembers() {
        let inner = record("Inner", ["x"])
        let left = record("Left", [inner.uri])
        let right = record("Right", ["r", inner.uri])
        let after = CollectionRules.delete(inner.id, from: [left, right, inner])

        #expect(after.first { $0.id == left.id }?.members == ["x"])
        #expect(after.first { $0.id == right.id }?.members == ["r", "x"])
    }

    /// Nothing held it: it simply goes, and nothing else changes.
    @Test func deletingAnUnheldCollectionTouchesNothingElse() {
        let loose = record("Loose", ["x"])
        let other = record("Other", ["y"])
        #expect(CollectionRules.delete(loose.id, from: [loose, other]) == [other])
    }

    // MARK: Renames

    @Test func aRenameIsFollowed() {
        let records = [record("C", ["file:///a/old.txt", "file:///b"])]
        let after = CollectionRules.remap(from: "file:///a/old.txt", to: "file:///a/new.txt",
                                          in: records)
        #expect(after.first?.members == ["file:///a/new.txt", "file:///b"])
    }

    /// The provider reports only the folder; everything inside moved with it.
    @Test func aRenamedFolderTakesItsContentsAlong() {
        let records = [record("C", ["file:///docs/notes/today.typ"])]
        let after = CollectionRules.remap(from: "file:///docs/notes", to: "file:///docs/journal",
                                          in: records)
        #expect(after.first?.members == ["file:///docs/journal/today.typ"])
    }

    /// A prefix is not a parent: `notes` renamed must not touch `notes-old`.
    @Test func aSiblingSharingThePrefixIsLeftAlone() {
        let records = [record("C", ["file:///docs/notes-old/x.typ"])]
        let after = CollectionRules.remap(from: "file:///docs/notes", to: "file:///docs/journal",
                                          in: records)
        #expect(after.first?.members == ["file:///docs/notes-old/x.typ"])
    }

    // MARK: Removal

    @Test func aMemberReportedGoneIsDropped() {
        let records = [record("C", ["file:///a", "file:///b"])]
        #expect(CollectionRules.remove("file:///a", from: records).first?.members == ["file:///b"])
    }

    @Test func aRemovedFolderTakesItsContentsWithIt() {
        let records = [record("C", ["file:///a/inside.txt", "file:///ab"])]
        #expect(CollectionRules.remove("file:///a", from: records).first?.members == ["file:///ab"])
    }
}

/// The store and the provider: what is written down, and what the tree sees.
@MainActor
@Suite struct CollectionProviderTests {
    private func temporaryStore() -> CollectionStore {
        CollectionStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("collections-\(UUID().uuidString).json"))
    }

    /// Order is the user's, so it has to survive being written down.
    @Test func orderSurvivesARestart() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("collections-\(UUID().uuidString).json")
        let first = CollectionStore(url: url)
        let record = first.create(named: "Channels")
        first.adopt(["yt://c", "yt://a", "yt://b"], into: record.id, at: nil)
        first.adopt(["yt://b"], into: record.id, at: 0)

        let reopened = CollectionStore(url: url)
        #expect(reopened.record(record.id)?.members == ["yt://b", "yt://c", "yt://a"])
        #expect(reopened.record(record.id)?.name == "Channels")
    }

    /// A member no provider can resolve is shown, not lost. Its plugin may
    /// simply not be loaded, and a sidebar entry silently deleted for that is
    /// far worse than one that is briefly inert.
    @Test func aMemberThatDoesNotResolveIsKept() async {
        let store = temporaryStore()
        let record = store.create(named: "Mixed")
        store.adopt(["file:///real", "jellyfin://item/abc"], into: record.id, at: nil)
        let provider = CollectionProvider(store: store) { uri in
            uri.hasPrefix("file://") ? Node(id: NodeID(uri)!, type: "file") : nil
        }

        let page = await provider.children(of: NodeID(canonical: record.uri), page: nil)
        #expect(page.items.map(\.id.uri) == ["file:///real", "jellyfin://item/abc"])
        #expect(page.items.last?.type == TypeID("collection.unavailable"))
        // And it is still written down.
        #expect(store.record(record.id)?.members.count == 2)
    }

    /// A collection's identity is its id, not its name.
    @Test func renamingKeepsTheIdentity() async throws {
        let store = temporaryStore()
        let record = store.create(named: "Old")
        let provider = CollectionProvider(store: store) { _ in nil }
        let id = NodeID(canonical: record.uri)

        let changes = try await provider.apply(.rename(id, to: "New"))
        #expect(changes == [.modified(id)], "a rename was reported as a change of identity")
        #expect(store.record(record.id)?.name == "New")
    }

    /// Everything that held a deleted collection is told, since its members
    /// just arrived there.
    @Test func deletingTellsEveryHolder() async throws {
        let store = temporaryStore()
        let outer = store.create(named: "Outer")
        let inner = store.create(named: "Inner", in: outer.id)
        store.adopt(["file:///x"], into: inner.id, at: nil)
        let provider = CollectionProvider(store: store) { _ in nil }

        let changes = try await provider.apply(.delete([NodeID(canonical: inner.uri)]))
        #expect(changes.contains(.removed(NodeID(canonical: inner.uri))))
        #expect(changes.contains(.childrenChanged(NodeID(canonical: outer.uri))))
        #expect(store.record(outer.id)?.members == ["file:///x"])
    }

    /// A collection takes anything, and says so — which is what makes it a
    /// drop target at all.
    @Test func aCollectionAcceptsAnything() async throws {
        let store = temporaryStore()
        let record = store.create(named: "Anything")
        let provider = CollectionProvider(store: store) { _ in nil }
        let node = try #require(await provider.node(for: NodeID(canonical: record.uri)))
        #expect(node.accepts == .any)
    }

    /// It adopts and releases its own members, and refuses to move — a move is
    /// containment, which is not what a collection does.
    @Test func itSupportsMembershipAndNotMoves() {
        let store = temporaryStore()
        let record = store.create(named: "C")
        let provider = CollectionProvider(store: store) { _ in nil }
        let id = NodeID(canonical: record.uri)
        let other = NodeID("file:///x")!

        #expect(provider.supports(.adopt([other], into: id, at: nil)))
        #expect(provider.supports(.release([other], from: id)))
        #expect(!provider.supports(.move([other], into: id)))
        // And nothing about a collection that does not exist.
        #expect(!provider.supports(.adopt([other], into: NodeID(canonical: CollectionRef.uri(for: UUID())), at: nil)))
    }
}

/// Collections inside the running app: what reaches them from the rest of the
/// graph, and what the reader can do to them.
@MainActor
@Suite struct CollectionHostTests {
    private func makeModel() throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("collections-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(),
                             workspaceFile: dir.appendingPathComponent("workspaces.json"))
        model.start()
        return model
    }

    /// A file renamed by the filesystem provider is followed into every
    /// collection that holds it — the whole point of writing references down
    /// is that they keep pointing at the thing.
    @Test func aRenameReportedElsewhereReachesTheCollections() throws {
        let model = try makeModel()
        let record = model.collections.create(named: "Reading")
        model.collections.adopt(["file:///docs/draft.typ"], into: record.id, at: nil)

        model.store?.notify([.renamed(from: NodeID("file:///docs/draft.typ")!,
                                      to: NodeID("file:///docs/final.typ")!)])

        #expect(model.collections.record(record.id)?.members == ["file:///docs/final.typ"])
    }

    /// Something actually deleted leaves the collections holding it.
    @Test func aRemovalReportedElsewhereReachesTheCollections() throws {
        let model = try makeModel()
        let record = model.collections.create(named: "Reading")
        model.collections.adopt(["file:///a.typ", "file:///b.typ"], into: record.id, at: nil)

        model.store?.notify([.removed(NodeID("file:///a.typ")!)])

        #expect(model.collections.record(record.id)?.members == ["file:///b.typ"])
    }

    /// The model does not share the reader's own collections file.
    ///
    /// Not "starts empty": every workspace owns a collection for its top level,
    /// so a fresh store never is.
    @Test func aModelWithATemporaryWorkspaceHasItsOwnCollections() throws {
        let one = try makeModel()
        let two = try makeModel()
        let made = one.collections.create(named: "Only here")
        #expect(two.collections.record(made.id) == nil, "two models wrote to the same collections")
    }

    /// A new folder is a collection now — which is why there is no longer a
    /// separate New Collection that did the same thing another way.
    @Test func aNewFolderIsACollection() throws {
        let model = try makeModel()
        model.createRootFolder(named: "Reading")
        let folder = try #require(model.rootLayout.entries.compactMap { entry -> RootFolder? in
            if case .folder(let folder) = entry { return folder } else { return nil }
        }.first)
        #expect(model.collections.record(folder.id)?.name == "Reading")
    }

    /// "Delete Collection" is offered for collections and nothing else — on a
    /// file it would be a second, differently worded way to trash something.
    @Test func deleteCollectionOnlyAppliesToCollections() throws {
        let model = try makeModel()
        let record = model.collections.create(named: "C")
        let action = try #require(model.action("collection.delete"))
        #expect(model.canRun(action, targets: [NodeID(canonical: record.uri)]))
        #expect(!model.canRun(action, targets: [NodeID("file:///a.typ")!]))
    }
}

/// A row reached through a collection knows which one, so "remove" can mean
/// that collection rather than every one the node is in.
@Suite struct CollectionRowTests {
    @Test func aChildRowKnowsWhatItWasReachedThrough() {
        let parent = NodeID("collection://parent")!
        let child = NodeID("file:///x")!
        let rows = SidebarRows.flatten(
            entries: [.root(parent.uri)], expandedNodes: [parent],
            graph: SidebarGraph(children: { $0 == parent ? [child] : [] },
                                isExpandable: { $0 == parent },
                                hasMore: { _ in false }))

        guard case .node(_, _, _, _, _, _, let rootParent) = rows[0],
              case .node(let id, _, _, _, _, _, let childParent) = rows[1]
        else { Issue.record("unexpected rows: \(rows.map(\.id))"); return }
        #expect(rootParent == nil, "a root was given a parent")
        #expect(id == child && childParent == parent)
    }
}

