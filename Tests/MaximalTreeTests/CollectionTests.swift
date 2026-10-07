import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

@MainActor private func temporaryStore() throws -> WorkspaceStore {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("collections-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return WorkspaceStore(fileURL: dir.appendingPathComponent("workspaces.json"))
}

/// Collections as the tree sees them: nodes made of a workspace's placements.
@MainActor
@Suite struct CollectionProviderTests {
    private func provider(over store: WorkspaceStore) -> CollectionProvider {
        CollectionProvider(
            exists: { uri in await MainActor.run { store.members(of: uri) != nil } },
            change: { mutation in await MainActor.run { store.applyToCollections(mutation) } })
    }

    private func group(_ store: WorkspaceStore, _ id: UUID) throws -> NodeID {
        NodeID(canonical: try #require(store.uri(of: id)))
    }

    /// Order is the user's, so it has to survive being written down.
    @Test func orderSurvivesARestart() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("collections-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("workspaces.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let first = WorkspaceStore(fileURL: file)
        let channels = first.createGroup(named: "Channels")
        first.add(["yt://c", "yt://a", "yt://b"], to: channels, at: nil)
        first.add(["yt://b"], to: channels, at: 0)

        let reopened = WorkspaceStore(fileURL: file)
        let uri = try #require(reopened.uri(of: channels))
        #expect(reopened.members(of: uri) == ["yt://b", "yt://c", "yt://a"])
        #expect(CollectionRef.name(from: uri) == "Channels")
    }

    /// The name is in the URI, so a rename is a rename in the graph's sense —
    /// the old identity to the new one — and the old one stops resolving.
    @Test func renamingReportsTheNewIdentity() async throws {
        let store = try temporaryStore()
        let made = store.createGroup(named: "Old")
        let old = try group(store, made)
        let provider = provider(over: store)

        let changes = try await provider.apply(.rename(old, to: "New"))

        let new = try group(store, made)
        #expect(CollectionRef.name(from: new.uri) == "New")
        #expect(changes.first == .renamed(from: old, to: new))
        #expect(await provider.node(for: old) == nil, "the old name still resolves")
        #expect(await provider.node(for: new)?.label == "New")
    }

    /// Everything that held a deleted collection is told, since what it held
    /// just arrived there.
    @Test func deletingTellsEveryHolder() async throws {
        let store = try temporaryStore()
        let outer = store.createGroup(named: "Outer")
        let inner = store.createGroup(named: "Inner", in: outer)
        store.add(["file:///x"], to: inner, at: nil)
        let (outerNode, innerNode) = (try group(store, outer), try group(store, inner))

        let changes = try await provider(over: store).apply(.delete([innerNode]))

        #expect(changes.contains(.removed(innerNode)))
        #expect(changes.contains(.childrenChanged(outerNode)))
        #expect(store.members(of: outerNode.uri) == ["file:///x"])
    }

    /// A collection takes anything, and says so — which is what makes it a
    /// drop target at all.
    @Test func aCollectionAcceptsAnything() async throws {
        let store = try temporaryStore()
        let made = store.createGroup(named: "Anything")
        let node = try #require(await provider(over: store).node(for: try group(store, made)))
        #expect(node.accepts == .any)
    }

    /// What a collection is and the changes only a collection has. Placing is
    /// the host's, for every node, and so is listing what was placed.
    @Test func itLeavesPlacingToTheHost() async throws {
        let store = try temporaryStore()
        let made = store.createGroup(named: "C")
        store.add(["file:///x"], to: made, at: nil)
        let provider = provider(over: store)
        let id = try group(store, made)
        let other = NodeID("file:///x")!

        #expect(provider.supports(.rename(id, to: "D")))
        #expect(provider.supports(.delete([id])))
        #expect(!provider.supports(.adopt([other], into: id, at: nil)))
        #expect(!provider.supports(.release([other], from: id)))
        #expect(!provider.supports(.move([other], into: id)))
        #expect(!provider.supports(.rename(other, to: "y")))
        #expect(await provider.children(of: id, page: nil).items.isEmpty)
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

    private func members(_ model: AppModel, _ group: UUID) -> [String]? {
        model.workspaceStore.uri(of: group).flatMap(model.workspaceStore.members(of:))
    }

    /// A file renamed by the filesystem provider is followed into every
    /// collection that holds it — the whole point of writing references down
    /// is that they keep pointing at the thing.
    @Test func aRenameReportedElsewhereReachesTheCollections() throws {
        let model = try makeModel()
        let reading = model.workspaceStore.createGroup(named: "Reading")
        model.workspaceStore.add(["file:///docs/draft.typ"], to: reading, at: nil)

        model.store?.notify([.renamed(from: NodeID("file:///docs/draft.typ")!,
                                      to: NodeID("file:///docs/final.typ")!)])

        #expect(members(model, reading) == ["file:///docs/final.typ"])
    }

    /// Something actually deleted leaves the collections holding it.
    @Test func aRemovalReportedElsewhereReachesTheCollections() throws {
        let model = try makeModel()
        let reading = model.workspaceStore.createGroup(named: "Reading")
        model.workspaceStore.add(["file:///a.typ", "file:///b.typ"], to: reading, at: nil)

        model.store?.notify([.removed(NodeID("file:///a.typ")!)])

        #expect(members(model, reading) == ["file:///b.typ"])
    }

    /// A rename in one workspace stays there. A group migrated from a shared
    /// collection is its own in each, and nothing else is ever shared.
    @Test func aModelWithATemporaryWorkspaceHasItsOwnCollections() throws {
        let one = try makeModel()
        let two = try makeModel()
        let made = one.workspaceStore.createGroup(named: "Only here")
        #expect(two.workspaceStore.uri(of: made) == nil, "two models wrote to the same library")
    }

    /// Only the parents whose placed children changed are reported, so only
    /// their listings are fetched again.
    @Test func aChangeReportsTheParentsItChanged() throws {
        let store = try temporaryStore()
        let left = store.createGroup(named: "Left")
        let right = store.createGroup(named: "Right")
        store.add(["file:///a"], to: left, at: nil)
        var reported: [Set<String>] = []
        store.onActiveTreeChanged = { reported.append($0) }

        store.move(["file:///a"], from: left, to: right, at: nil)
        store.place(["yt://channel"], into: "yt://aggregator", at: nil)

        #expect(reported == [[try #require(store.uri(of: left)), try #require(store.uri(of: right))],
                             ["yt://aggregator"]])
    }

    /// A plugin's node holds what was placed in it in this workspace, so
    /// switching workspaces has to replace a listing cached from the last.
    @Test func switchingWorkspacesRelistsWhatWasPlaced() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("collections-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(),
                             workspaceFile: dir.appendingPathComponent("workspaces.json"))
        model.pluginHost.registry.register(provider: AggregatorProvider())
        model.start()
        let aggregator = NodeID("agg://feed")!
        model.workspaceStore.place(["file:///a"], into: aggregator.uri, at: nil)
        model.store?.ensureNodes([aggregator])
        await waitUntil("never held: model.host.node(aggregator) != nil") { model.host.node(aggregator) != nil }
        model.store?.requestChildren(of: aggregator)
        await waitUntil("never held: model.host.cachedChildren(of: aggregator)?.map(\\.uri) == [\"file:///a\"]") { model.host.cachedChildren(of: aggregator)?.map(\.uri) == ["file:///a"] }

        let other = model.workspaceStore.create(named: "Other")
        model.switchWorkspace(to: other.id)

        await waitUntil("never held: model.host.cachedChildren(of: aggregator) == []") { model.host.cachedChildren(of: aggregator) == [] }
    }

    @Test func aNewCollectionIsAGroupInTheSidebar() throws {
        let model = try makeModel()
        model.newCollection()
        let group = try #require(model.placements.children(of: model.sidebarRoot).first)
        #expect(CollectionRef.name(from: group) == "New Collection")
    }

    /// "Delete Collection" is offered for collections and nothing else — on a
    /// file it would be a second, differently worded way to trash something.
    @Test func deleteCollectionOnlyAppliesToCollections() throws {
        let model = try makeModel()
        let made = model.workspaceStore.createGroup(named: "C")
        let uri = try #require(model.workspaceStore.uri(of: made))
        let action = try #require(model.action("collection.delete"))
        #expect(model.canRun(action, targets: [NodeID(canonical: uri)]))
        #expect(!model.canRun(action, targets: [NodeID("file:///a.typ")!]))
    }
}

/// A plugin's node that takes anything, and lists nothing of its own.
private struct AggregatorProvider: NodeProvider {
    let schemes: Set<String> = ["agg"]
    func resolve(_ uri: String) -> NodeID? { NodeID(uri) }
    func node(for id: NodeID) async -> Node? { Node(id: id, type: "agg", accepts: .any) }
    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> { Page(items: []) }
}

/// A row reached through a collection knows which one, so "remove" can mean
/// that collection rather than every one the node is in.
@Suite struct CollectionRowTests {
    @Test func aChildRowKnowsWhatItWasReachedThrough() {
        let parent = NodeID("collection://parent")!
        let child = NodeID("file:///x")!
        let rows = SidebarRows.flatten(
            roots: [parent.uri], expandedNodes: [parent],
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

