import Testing
import Foundation
@_spi(Host) @testable import MaximalTreeKit
@testable import MaximalTree

/// What reaches a provider, in order — and only renames of what ends in
/// "/renamable", and moves into what ends in "/folder", are honoured.
private final class Recording: NodeProvider, MutatingNodeProvider, @unchecked Sendable {
    let schemes: Set<String> = ["rec"]
    @MainActor private(set) var applied: [GraphMutation] = []

    func resolve(_ uri: String) -> NodeID? { NodeID(uri) }
    func node(for id: NodeID) async -> Node? {
        // A feed-like node keeps members; the rest only contain.
        id.uri.hasSuffix("/feed")
            ? Node(id: id, type: "rec.feed", label: "Feed", accepts: .any)
            : Node(id: id, type: "rec.item", label: id.uri.components(separatedBy: "/").last ?? id.uri)
    }
    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> { Page(items: []) }

    func supports(_ mutation: GraphMutation) -> Bool {
        switch mutation {
        case .rename(let id, _): id.uri.hasSuffix("/renamable")
        case .move(_, let into): into.uri.hasSuffix("/folder")
        default: false
        }
    }
    func apply(_ mutation: GraphMutation) async throws -> [NodeChange] {
        await MainActor.run { applied.append(mutation) }
        return []
    }
}

/// The host's own views rename and drop through commands — reachable by id
/// with an argument, from anything that drives the engine.
@MainActor
@Suite struct NodeCommandTests {
    private func model(_ provider: Recording) throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("node-commands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(), workspaceFile: dir.appendingPathComponent("w.json"))
        model.pluginHost.registry.register(provider: provider)
        model.start()
        return model
    }

    private func id(_ uri: String) throws -> NodeID { try #require(NodeID(uri)) }

    private func known(_ ids: NodeID..., in model: AppModel) async throws {
        model.store?.ensureNodes(ids)
        await waitUntil("the nodes never arrived") { ids.allSatisfy { model.host.node($0) != nil } }
    }

    private func settle(_ model: AppModel) async {
        await waitUntil("it never finished") {
            model.commandsRunning == 0 && (model.store?.outstanding ?? 0) == 0
        }
    }

    @Test func theEngineRegistersThem() throws {
        let model = try model(Recording())
        #expect(model.dispatch.registry.command(RenameNode.id) != nil)
        #expect(model.dispatch.registry.command(DropNodes.id) != nil)
    }

    /// What a field commits arrives trimmed — and a name that says nothing
    /// new asks for nothing.
    @Test func aRenameArrivesAsAsked() async throws {
        let provider = Recording()
        let model = try model(provider)
        let node = try id("rec://x/renamable")
        try await known(node, in: model)

        model.invoke(RenameNode.self, .init(node: node, name: "  Notes  "))
        model.invoke(RenameNode.self, .init(node: node, name: "renamable"))
        model.invoke(RenameNode.self, .init(node: node, name: "   "))
        await settle(model)

        #expect(provider.applied == [.rename(node, to: "Notes")])
        #expect(model.commandFailure == nil)
    }

    /// A node its owner won't rename says so, rather than nothing happening.
    @Test func aRenameThatIsRefusedSaysSo() async throws {
        let provider = Recording()
        let model = try model(provider)
        let node = try id("rec://x/readonly")
        try await known(node, in: model)

        model.invoke(RenameNode.self, .init(node: node, name: "Other"))
        await settle(model)

        #expect(provider.applied.isEmpty)
        #expect(model.commandFailure?.command == RenameNode.id)
        #expect(model.commandFailure?.message == "“readonly” can't be renamed.")
    }

    /// Onto something that only contains, a drop is a move, and its owner
    /// does it.
    @Test func droppingOntoAFolderMovesIt() async throws {
        let provider = Recording()
        let model = try model(provider)
        let item = try id("rec://x/item"), folder = try id("rec://x/folder")
        try await known(item, folder, in: model)

        model.invoke(DropNodes.self, .init(nodes: [item], onto: folder))
        await settle(model)

        #expect(provider.applied == [.move([item], into: folder)])
    }

    /// Onto something that keeps members, it is kept there — by the host, in
    /// the workspace, and nothing is moved.
    @Test func droppingOntoAFeedKeepsItThere() async throws {
        let provider = Recording()
        let model = try model(provider)
        let item = try id("rec://x/item"), feed = try id("rec://x/feed")
        try await known(item, feed, in: model)

        model.invoke(DropNodes.self, .init(nodes: [item], onto: feed))
        await settle(model)

        #expect(model.workspaceStore.placedChildren(of: feed.uri) == [item.uri])
        #expect(provider.applied.isEmpty)
    }
}
