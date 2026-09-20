import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// A watch list is a collection, and nothing else: made when first needed,
/// added to rather than moved into, and yours to rearrange.
@MainActor
@Suite struct WatchLaterTests {
    private func makeModel() throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watch-later-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(),
                             workspaceFile: dir.appendingPathComponent("workspaces.json"))
        model.start()
        return model
    }

    private func collection(_ model: AppModel, named name: String) -> String? {
        model.placements.collections(from: model.sidebarRoot)
            .first { CollectionRef.name(from: $0.uri) == name }?.uri
    }

    private func id(_ uri: String) throws -> NodeID { try #require(NodeID(uri)) }

    /// The first thing added makes the list; the second joins it, in order.
    @Test func addingMakesTheListOnceAndKeepsTheOrder() throws {
        let model = try makeModel()
        #expect(collection(model, named: AppModel.watchLaterName) == nil)

        model.addToCollection([try id("youtube://video/a")], named: AppModel.watchLaterName)
        let list = try #require(collection(model, named: AppModel.watchLaterName))
        model.addToCollection([try id("youtube://video/b")], named: AppModel.watchLaterName)

        #expect(collection(model, named: AppModel.watchLaterName) == list, "a second list was made")
        #expect(model.placements.children(of: list)
                == ["youtube://video/a", "youtube://video/b"])
    }

    /// Adding the same thing twice is not two rows — it moves to the end,
    /// which is what a list of things to come back to should do.
    @Test func addingSomethingTwiceKeepsOneOfIt() throws {
        let model = try makeModel()
        model.addToCollection([try id("youtube://video/a"), try id("youtube://video/b")],
                              named: AppModel.watchLaterName)
        model.addToCollection([try id("youtube://video/a")], named: AppModel.watchLaterName)
        let list = try #require(collection(model, named: AppModel.watchLaterName))
        #expect(model.placements.children(of: list) == ["youtube://video/b", "youtube://video/a"])
    }

    /// Added, not moved: what you were looking at keeps holding it.
    @Test func addingLeavesItWhereItAlreadyWas() throws {
        let model = try makeModel()
        let channel = try id("youtube://channel/UCaaaaaaaaaaaaaaaaaaaaaa")
        let video = try id("youtube://video/a")
        model.workspaceStore.place([channel.uri], into: model.sidebarRoot, at: nil)
        model.workspaceStore.place([video.uri], into: channel.uri, at: nil)

        model.addToCollection([video], named: AppModel.watchLaterName)

        #expect(model.placements.children(of: channel.uri) == [video.uri],
                "it was taken out of where it was listed")
        let list = try #require(collection(model, named: AppModel.watchLaterName))
        #expect(model.placements.children(of: list) == [video.uri])
    }

    /// It belongs to the workspace it was made in, like every collection.
    @Test func eachWorkspaceHasItsOwn() throws {
        let model = try makeModel()
        model.addToCollection([try id("youtube://video/a")], named: AppModel.watchLaterName)
        let other = model.workspaceStore.create(named: "Other")
        model.switchWorkspace(to: other.id)

        #expect(collection(model, named: AppModel.watchLaterName) == nil)
        model.addToCollection([try id("youtube://video/b")], named: AppModel.watchLaterName)
        let list = try #require(collection(model, named: AppModel.watchLaterName))
        #expect(model.placements.children(of: list) == ["youtube://video/b"])
    }

    /// A collection made for what is being added holds it, ready to be named.
    @Test func aNewCollectionIsMadeAroundWhatWasAdded() throws {
        let model = try makeModel()
        let video = try id("youtube://video/a")
        model.addToNewCollection([video])

        let made = try #require(model.placements.collections(from: model.sidebarRoot).first)
        #expect(CollectionRef.name(from: made.uri) == "New Collection")
        #expect(model.placements.children(of: made.uri) == [video.uri])
        #expect(model.host.selection == [NodeID(canonical: made.uri)])
    }

    /// The action is offered for anything with a row, and puts it in the list.
    @Test func theActionAddsWhateverIsTargeted() throws {
        let model = try makeModel()
        let action = try #require(model.action("collection.watchLater"))
        let video = try id("youtube://video/a")
        #expect(model.canRun(action, targets: [video]))
        #expect(!model.canRun(action, targets: []))

        model.run(action, targets: [video])
        let list = try #require(collection(model, named: AppModel.watchLaterName))
        #expect(model.placements.children(of: list) == [video.uri])
    }

    /// Dragging a row out of a listing into a collection adds it: the listing
    /// is not the sidebar's to rearrange, so nothing moves out of it.
    @Test func aRowDraggedFromAListingIsAdded() throws {
        let model = try makeModel()
        let video = try id("youtube://video/a")
        model.addToCollection([try id("youtube://video/b")], named: AppModel.watchLaterName)
        let list = try #require(collection(model, named: AppModel.watchLaterName))

        // No drag was recorded by the sidebar, which is what a row from the
        // contents column looks like when it lands.
        #expect(model.drop([video.uri], onto: CollectionRef.id(from: list)))

        #expect(model.placements.children(of: list) == ["youtube://video/b", video.uri])
    }
}
