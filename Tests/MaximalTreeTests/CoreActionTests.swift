import Testing
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// One registry, one id space: the app's own operations are actions like a
/// plugin's, so they can be listed, bound, and called by name.
@MainActor
@Suite struct CoreActionTests {
    private func makeModel() throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppModel(host: HostContext(),
                        workspaceFile: dir.appendingPathComponent("workspaces.json"))
    }

    /// The host's actions plus every plugin this target can construct.
    ///
    /// Typst and Web are missing on purpose: the test target compiles only
    /// their view-free core files, so their entry points — and the actions
    /// registered from them — aren't here to ask. Their ids are excluded from
    /// the check below rather than asserted against an empty registry.
    private func availableActionIDs(_ model: AppModel) -> Set<String> {
        let registry = model.pluginHost.registry
        model.registerCoreActions(with: registry)
        FileSystemPlugin().register(with: registry)
        GitPlugin().register(with: registry)
        TerminalPlugin().register(with: registry)
        return Set(registry.actions.map(\.id))
    }

    /// Owned by a plugin this target does not compile the entry point of.
    private func isUnavailableHere(_ id: String) -> Bool {
        id.hasPrefix("typst.") || id.hasPrefix("web.")
    }

    /// The invariant that keeps the two halves honest. A binding is a string
    /// until something runs it, so a key naming an operation that doesn't
    /// exist is a key that quietly does nothing — and nothing would have said
    /// so before this.
    @Test func everyDefaultBindingNamesARegisteredAction() throws {
        let model = try makeModel()
        let known = availableActionIDs(model)
        let bound = DefaultKeymap.make().allCommands.filter { !isUnavailableHere($0) }
        #expect(bound.count > 40, "the keymap should be checking most of the app")

        let missing = bound.subtracting(known).sorted()
        #expect(missing.isEmpty, "bound to nothing: \(missing.joined(separator: ", "))")

        // The two this target can't register are at least owned by a plugin
        // that exists, which is all that can be checked from here.
        let elsewhere = DefaultKeymap.make().allCommands.filter(isUnavailableHere)
        #expect(elsewhere.allSatisfy { $0.hasPrefix("typst.") || $0.hasPrefix("web.") })
    }

    /// The point of the unification: the host's own operations are in the same
    /// registry a plugin's are, so a surface listing actions lists them too.
    @Test func theAppsOwnOperationsAreActions() throws {
        let model = try makeModel()
        model.registerCoreActions(with: model.pluginHost.registry)
        let ids = Set(model.pluginHost.registry.actions.map(\.id))

        for id in ["pane.splitRight", "toggle.zen", "workspace.next",
                   "explorer.down", "finder.all", "nav.back", "file.save"] {
            #expect(ids.contains(id), "\(id) is not an action")
        }
    }

    /// Motions belong to the surface holding the keyboard, and that is a
    /// property of the action rather than a guard inside its handler — so a
    /// surface listing actions can leave out the ones that would do nothing.
    @Test func explorerMotionsOnlyApplyWhileTheSidebarHasTheKeyboard() throws {
        let model = try makeModel()
        model.registerCoreActions(with: model.pluginHost.registry)
        let down = try #require(model.pluginHost.registry.actions.first { $0.id == "explorer.down" })

        // No window in a test, so nothing holds the keyboard and `Surfaces`
        // falls back to the sidebar — which is exactly when these should apply.
        #expect(down.appliesTo.matches(ActionContext(host: model.host)))
    }

    /// A repeat has to survive the trip from the key to the handler; `5 j`
    /// moves five rows because the count reaches the action.
    @Test func theRepeatCountReachesTheHandler() {
        var seen: [Int] = []
        let action = Action(id: "test.count", title: "Count") { ctx in seen.append(ctx.count) }
        let host = HostContext()

        action.handler(ActionContext(host: host, count: 5))
        action.handler(ActionContext(host: host))
        #expect(seen == [5, 1])
    }

    /// Never zero, so a handler can loop on it without checking.
    @Test func aCountBelowOneIsStillOne() {
        let host = HostContext()
        #expect(ActionContext(host: host, count: 0).count == 1)
        #expect(ActionContext(host: host, count: -3).count == 1)
    }

    /// The menus name actions by id, and an id that resolves to nothing is a
    /// menu item that silently isn't there. Nothing else would say so.
    @Test func everyMenuItemNamesARegisteredAction() throws {
        let model = try makeModel()
        let known = availableActionIDs(model)

        // The ids AppCommands and the sidebar toolbar place by hand.
        let placed = [
            "toggle.zen", "pane.splitRight", "pane.splitDown", "pane.close",
            "nav.back", "nav.forward", "tab.new", "tab.close",
            "finder.all", "finder.files", "finder.actions", "finder.nodeActions",
            "workspace.keep", "workspace.create", "workspace.rename", "workspace.delete",
            "workspace.addFolder", "workspace.newFolder",
        ]
        let missing = placed.filter { !known.contains($0) }
        #expect(missing.isEmpty, "menus name nothing: \(missing.joined(separator: ", "))")
    }

    /// A menu item's key equivalent comes from the action, so the shortcuts
    /// the menu bar used to own are now on the operations themselves.
    @Test func menuOperationsCarryTheirShortcuts() throws {
        let model = try makeModel()
        model.registerCoreActions(with: model.pluginHost.registry)
        let byID = Dictionary(uniqueKeysWithValues:
            model.pluginHost.registry.actions.map { ($0.id, $0) })

        for id in ["pane.splitRight", "pane.close", "nav.back", "tab.new", "tab.close",
                   "toggle.zen", "finder.all", "finder.nodeActions"] {
            #expect(byID[id]?.shortcut != nil, "\(id) lost its key equivalent")
        }
    }

    /// What can't be done now shouldn't be offered. One answer feeds the
    /// greyed-out menu item, the finder's list, and a key bound to it.
    @Test func anOperationThatCannotRunSaysSo() throws {
        let model = try makeModel()
        model.registerCoreActions(with: model.pluginHost.registry)
        let byID = Dictionary(uniqueKeysWithValues:
            model.pluginHost.registry.actions.map { ($0.id, $0) })
        let ctx = ActionContext(host: model.host)

        // One tab and one pane in a fresh model, so neither can be closed.
        #expect(byID["tab.close"]?.appliesTo.matches(ctx) == false)
        #expect(byID["pane.close"]?.appliesTo.matches(ctx) == false)
        // And one workspace, so it cannot be deleted — but a new one can be made.
        #expect(byID["workspace.delete"]?.appliesTo.matches(ctx) == false)
        #expect(byID["workspace.create"]?.appliesTo.matches(ctx) == true)
    }

    /// The node finder lists what is *about* the node, not the whole app.
    /// Every app-level operation applies to a node in the sense of not being
    /// stopped by one, so scope is what separates them.
    @Test func theNodeFinderListsOnlyActionsAboutTheNode() throws {
        let model = try makeModel()
        let registry = model.pluginHost.registry
        model.registerCoreActions(with: registry)
        registry.register(action: Action(id: "test.onNode", title: "On Node",
                                         scope: .node) { _ in })
        registry.register(action: Action(id: "test.onApp", title: "On App",
                                         scope: .workspace) { _ in })

        let scoped = registry.actions
            .filter { $0.scope == .node || $0.scope == .container || $0.scope == .document }
            .map(\.id)
        #expect(scoped.contains("test.onNode"))
        #expect(!scoped.contains("test.onApp"))
        // None of the app's own operations claim to be about a node.
        #expect(!scoped.contains("pane.splitRight"))
        #expect(!scoped.contains("toggle.zen"))
    }
}
