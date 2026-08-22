import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// How the flat action registry becomes a menu.
@MainActor
@Suite struct ActionOrganizerTests {
    private func action(_ id: String, scope: ActionScope = .node,
                        owner: String? = nil,
                        surfaces: ActionSurfaces? = nil) -> Action {
        var action = Action(id: id, title: id, scope: scope, surfaces: surfaces) { _ in }
        action.owner = owner
        return action
    }

    private func ids(_ groups: [ActionGroup]) -> [String] {
        groups.flatMap { $0.actions.map(\.id) }
    }

    /// The clutter this exists to fix: a right-click on one file used to list
    /// every command in the app, including ones about other documents and the
    /// app as a whole.
    @Test func aContextMenuOnlyShowsActionsAboutTheNode() {
        let actions = [
            action("rename", scope: .node),
            action("newFile", scope: .container, owner: "FileSystem"),
            action("export", scope: .document, owner: "Typst"),
            action("newWebPage", scope: .workspace, owner: "Web"),
        ]
        #expect(ids(ActionOrganizer.groups(actions, for: .contextMenu))
                == ["rename", "newFile"])
    }

    /// The menu bar is the surface that *should* carry everything.
    @Test func theMenuBarShowsEveryScope() {
        let actions = [
            action("rename", scope: .node),
            action("export", scope: .document, owner: "Typst"),
            action("newWebPage", scope: .workspace, owner: "Web"),
        ]
        #expect(ids(ActionOrganizer.groups(actions, for: .menuBar)).count == 3)
    }

    @Test func anActionCanOverrideWhereItAppears() {
        // A workspace action that insists on the context menu gets it.
        let pinned = action("refresh", scope: .workspace, owner: "Typst",
                            surfaces: .everywhere)
        #expect(ids(ActionOrganizer.groups([pinned], for: .contextMenu)) == ["refresh"])
    }

    @Test func actionsAreGroupedByTheirPlugin() {
        let groups = ActionOrganizer.groups([
            action("file.trash", owner: "FileSystem"),
            action("git.open", owner: "Git"),
            action("file.copy", owner: "FileSystem"),
        ], for: .contextMenu)

        #expect(groups.count == 2)
        #expect(groups.first { $0.title == "FileSystem" }?.actions.map(\.id)
                == ["file.trash", "file.copy"], "one section per plugin, in order")
    }

    /// Closest to what you're pointing at, first.
    @Test func sectionsRunFromNodeScopedOutwards() {
        let groups = ActionOrganizer.groups([
            action("newPage", scope: .workspace, owner: "Web"),
            action("newFile", scope: .container, owner: "FileSystem"),
            action("trash", scope: .node, owner: "Trash"),
        ], for: .menuBar)
        #expect(groups.map(\.title) == ["Trash", "FileSystem", "Web"])
    }

    @Test func actionsWithinASectionRunFromNodeScopedOutwards() {
        let groups = ActionOrganizer.groups([
            action("newFile", scope: .container, owner: "FileSystem"),
            action("trash", scope: .node, owner: "FileSystem"),
        ], for: .menuBar)
        #expect(ids(groups) == ["trash", "newFile"])
    }

    /// Registration order is deliberate — New File before New Folder — so
    /// equal-scope actions must not be reshuffled.
    @Test func equalScopeActionsKeepTheirRegistrationOrder() {
        let groups = ActionOrganizer.groups([
            action("zebra", owner: "FileSystem"),
            action("apple", owner: "FileSystem"),
        ], for: .menuBar)
        #expect(ids(groups) == ["zebra", "apple"])
    }

    /// The app's own vocabulary leads, then the plugin owning the node in
    /// front of the reader, then everyone else.
    @Test func theNodesOwnPluginLeadsTheOtherPlugins() {
        let actions = [
            action("web.something", owner: "Web"),
            action("git.open", owner: "Git"),
            action("rename", owner: nil),
        ]
        let groups = ActionOrganizer.groups(actions, for: .contextMenu,
                                            preferredOwner: "Git")
        #expect(groups.map(\.title) == [nil, "Git", "Web"])
    }

    @Test func unrelatedPluginsAreOrderedPredictably() {
        let groups = ActionOrganizer.groups([
            action("w", owner: "Web"),
            action("f", owner: "FileSystem"),
            action("g", owner: "Git"),
        ], for: .contextMenu, preferredOwner: "Typst")
        #expect(groups.map(\.title) == ["FileSystem", "Git", "Web"])
    }

    @Test func nothingApplicableIsNoSections() {
        #expect(ActionOrganizer.groups([], for: .contextMenu).isEmpty)
        #expect(ActionOrganizer.groups([action("x", scope: .workspace)],
                                       for: .contextMenu).isEmpty)
    }
}

/// The defaults that make the decluttering automatic rather than something
/// every plugin has to remember to ask for.
@Suite struct ActionScopeDefaultsTests {
    @Test func nodeAndContainerActionsAppearEverywhere() {
        #expect(ActionScope.node.defaultSurfaces == .everywhere)
        #expect(ActionScope.container.defaultSurfaces == .everywhere)
    }

    @Test func documentAndWorkspaceActionsStayOffTheContextMenu() {
        #expect(!ActionScope.document.defaultSurfaces.contains(.contextMenu))
        #expect(!ActionScope.workspace.defaultSurfaces.contains(.contextMenu))
        #expect(ActionScope.document.defaultSurfaces.contains(.menuBar))
        #expect(ActionScope.workspace.defaultSurfaces.contains(.palette))
    }

    /// An action that says nothing about itself is about the node — the safe
    /// reading, and what every action meant before scopes existed.
    @Test func anActionDefaultsToNodeScope() {
        let action = Action(id: "x", title: "x") { _ in }
        #expect(action.scope == .node)
        #expect(action.surfaces == .everywhere)
    }
}
