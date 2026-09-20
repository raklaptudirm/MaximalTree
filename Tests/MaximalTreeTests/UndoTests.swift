import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// Undo, over the one thing the host owns outright: how the sidebar is
/// arranged. Snapshots rather than inverses — see `UndoHistory` for why, and
/// for why it stops where it does.
@MainActor
@Suite struct UndoTests {
    private func makeModel() throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("undo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(),
                             workspaceFile: dir.appendingPathComponent("workspaces.json"))
        model.start()
        return model
    }

    private func store(_ model: AppModel) -> WorkspaceStore { model.workspaceStore }

    /// What the sidebar's top level holds, in order.
    private func top(_ model: AppModel) -> [String] {
        model.placements.children(of: model.sidebarRoot)
    }

    // MARK: One change, both ways

    @Test func aPlacementGoesBackAndForwardAgain() throws {
        let model = try makeModel()
        let root = model.sidebarRoot
        #expect(store(model).canUndo == false, "a fresh workspace has nothing to put back")

        _ = store(model).place(["file:///a"], into: root, at: nil)
        #expect(top(model) == ["file:///a"])
        #expect(store(model).canUndo)

        store(model).undo()
        #expect(top(model) == [], "the placement was not put back")
        #expect(store(model).canUndo == false)
        #expect(store(model).canRedo)

        store(model).redo()
        #expect(top(model) == ["file:///a"])
    }

    /// Undoing is not itself a change to undo. Two undos walk back two
    /// changes rather than flipping between the same pair.
    @Test func undoWalksBackRatherThanFlipping() throws {
        let model = try makeModel()
        let root = model.sidebarRoot
        _ = store(model).place(["file:///a"], into: root, at: nil)
        _ = store(model).place(["file:///b"], into: root, at: nil)
        #expect(top(model) == ["file:///a", "file:///b"])

        store(model).undo()
        store(model).undo()
        #expect(top(model) == [], "the second undo undid the first")
    }

    /// A new change is a new branch: what was undone is no longer ahead.
    @Test func aFreshChangeDropsWhatWasAhead() throws {
        let model = try makeModel()
        let root = model.sidebarRoot
        _ = store(model).place(["file:///a"], into: root, at: nil)
        store(model).undo()
        #expect(store(model).canRedo)

        _ = store(model).place(["file:///b"], into: root, at: nil)
        #expect(store(model).canRedo == false)
        #expect(top(model) == ["file:///b"])
    }

    // MARK: The case an inverse would get wrong

    /// Deleting a group spills what it held into every holder it had. The
    /// inverse of that is not one `adopt`, which is the argument for keeping
    /// the state rather than describing the change.
    @Test func aDeletedGroupComesBackWithWhatItHeld() throws {
        let model = try makeModel()
        let group = store(model).createGroup(named: "Reading")
        let uri = try #require(store(model).uri(of: group))
        _ = store(model).place(["file:///a", "file:///b"], into: uri, at: nil)

        store(model).deleteGroup(group)
        #expect(store(model).uri(of: group) == nil)
        #expect(top(model) == ["file:///a", "file:///b"], "it did not spill")

        store(model).undo()
        #expect(store(model).uri(of: group) == uri, "the group did not come back")
        #expect(model.placements.children(of: uri) == ["file:///a", "file:///b"])
        #expect(top(model) == [uri])
    }

    @Test func aRenamedGroupGoesBackToItsName() throws {
        let model = try makeModel()
        let group = store(model).createGroup(named: "Reading")
        _ = store(model).renameGroup(group, to: "Later")
        #expect(CollectionRef.name(from: try #require(store(model).uri(of: group))) == "Later")

        store(model).undo()
        #expect(CollectionRef.name(from: try #require(store(model).uri(of: group))) == "Reading")
    }

    // MARK: What isn't the reader's to undo

    /// Following what the graph has mounted is the app keeping up, not a change
    /// anyone made — so it leaves nothing to put back.
    @Test func followingWhatIsMountedIsNotSomethingToUndo() throws {
        let model = try makeModel()
        store(model).reconcileRoots([try #require(NodeID("file:///a"))])

        #expect(top(model) == ["file:///a"], "it did not follow the mount")
        #expect(store(model).canUndo == false, "following the graph became undoable")
    }

    /// And a node that vanished from the world leaves every workspace without
    /// that becoming the last thing you can put back.
    @Test func aNodeLeavingTheWorldIsNotSomethingToUndo() throws {
        let model = try makeModel()
        _ = store(model).place(["file:///a"], into: model.sidebarRoot, at: nil)

        store(model).removeEverywhere("file:///a")
        #expect(top(model) == [])

        // Undo goes back past it, to before the placement — not to a sidebar
        // still holding a node that no longer exists.
        store(model).undo()
        #expect(top(model) == [], "a node leaving the world became undoable")
    }

    // MARK: Whose history it is

    /// Undoing is about the thing in front of you: an entry made in one
    /// workspace cannot reach across into another.
    @Test func historyBelongsToTheWorkspaceItWasMadeIn() throws {
        let model = try makeModel()
        _ = store(model).place(["file:///a"], into: model.sidebarRoot, at: nil)
        #expect(store(model).canUndo)

        let other = store(model).create(named: "Other")
        store(model).setActive(other.id)
        #expect(store(model).canUndo == false, "another workspace's history was offered")

        store(model).setActive(model.workspaceStore.library.workspaces[0].id)
        #expect(store(model).canUndo, "its own history was lost")
    }

    // MARK: Reached the way everything else is

    @Test func undoAndRedoAreActionsLikeAnythingElse() throws {
        let model = try makeModel()
        model.registerCoreActions(with: model.pluginHost.registry)
        let root = model.sidebarRoot
        _ = store(model).place(["file:///a"], into: root, at: nil)

        model.runCommand("edit.undo")
        #expect(top(model) == [])
        model.runCommand("edit.redo")
        #expect(top(model) == ["file:///a"])
    }

    /// Greyed out when there is nothing to put back, which is what keeps a key
    /// bound to it from doing something surprising.
    @Test func undoIsOfferedOnlyWhenThereIsSomethingToPutBack() throws {
        let model = try makeModel()
        model.registerCoreActions(with: model.pluginHost.registry)
        let undo = try #require(model.action("edit.undo"))
        #expect(model.canRun(undo) == false)

        _ = store(model).place(["file:///a"], into: model.sidebarRoot, at: nil)
        #expect(model.canRun(undo))
    }

    // MARK: Bounded

    @Test func theHistoryDoesNotGrowForever() throws {
        let model = try makeModel()
        let root = model.sidebarRoot
        for index in 0...(UndoHistory.limit + 5) {
            _ = store(model).place(["file:///\(index)"], into: root, at: nil)
        }
        for _ in 0..<(UndoHistory.limit + 10) where store(model).canUndo {
            store(model).undo()
        }
        // The oldest were dropped, so walking all the way back does not reach
        // the empty sidebar it started from.
        #expect(top(model).isEmpty == false, "every entry was kept")
    }
}
