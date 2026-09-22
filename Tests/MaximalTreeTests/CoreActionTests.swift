import Testing
import Foundation
import AppKit
import SwiftUI
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
    /// Typst is missing on purpose: the test target compiles only its
    /// view-free core files, so its entry point — and the actions registered
    /// from it — aren't here to ask. Its ids are excluded from the check below
    /// rather than asserted against an empty registry.
    private func availableActionIDs(_ model: AppModel) -> Set<String> {
        let registry = model.pluginHost.registry
        model.registerCoreActions(with: registry)
        FileSystemPlugin().register(with: registry)
        GitPlugin().register(with: registry)
        TerminalPlugin().register(with: registry)
        WebPlugin().register(with: registry)
        return Set(registry.actions.map(\.id))
    }

    /// Owned by a plugin this target does not compile the entry point of.
    private func isUnavailableHere(_ id: String) -> Bool {
        id.hasPrefix("typst.")
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

        // The ones this target can't register are at least owned by a plugin
        // that exists, which is all that can be checked from here.
        let elsewhere = DefaultKeymap.make().allCommands.filter(isUnavailableHere)
        #expect(elsewhere.allSatisfy { $0.hasPrefix("typst.") })
    }

    /// The same invariant on the other half of the keymap.
    ///
    /// A surface's keys are the natural home for a command that only that
    /// surface can run, so they carry the ones a leader group has no business
    /// holding — and they need the same check, or moving a binding out of
    /// `DefaultKeymap` would quietly move it out of coverage. Both sides come
    /// from one registry here, so a plugin this target can't construct
    /// contributes neither keys nor actions and can't fail this by absence.
    @Test func everySurfaceKeyNamesARegisteredAction() throws {
        let model = try makeModel()
        let known = availableActionIDs(model)
        let registry = model.pluginHost.registry
        let declared = registry.canvases.flatMap(\.keys)
            + registry.surfaceKeys.flatMap(\.keys)
        #expect(declared.count > 20, "surfaces should be declaring keys")

        let missing = Set(declared.map(\.action)).subtracting(known).sorted()
        #expect(missing.isEmpty, "bound to nothing: \(missing.joined(separator: ", "))")
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

    /// A repeat has to survive the trip from the key to the body; `5 j` moves
    /// five rows because the count reaches the action — as part of its
    /// argument, so a keymap can carry it as data.
    @Test func theRepeatCountReachesTheHandler() async throws {
        final class Seen: @unchecked Sendable {
            var counts: [Int] = []
        }
        let seen = Seen()
        let action = Action(id: "test.count", title: "Count") { ctx in
            seen.counts.append(ctx.count)
        }
        let host = HostContext()

        _ = try await action.command.run(NodeTargets(nodes: [], count: 5),
                                         in: ActionContext(host: host))
        _ = try await action.command.run(NodeTargets(nodes: []),
                                         in: ActionContext(host: host))
        #expect(seen.counts == [5, 1])
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
            "workspace.addFolder", "collection.new",
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

/// A surface's keys belong to that surface.
///
/// The explorer's motions are the sidebar's own. Dispatch has always known it —
/// `runCommand` checks before running — but the overlay read the keymap
/// directly, and a keymap is a static trie that cannot know the caret is in a
/// document. So it listed keys that could not fire, which is what made the
/// sidebar look like it was taking part in a surface it has nothing to do with.
@MainActor
@Suite struct SurfaceScopedKeyTests {
    private func map() -> Keymap {
        var map = Keymap()
        map.describe("SPC g", as: "git")
        map.bind("SPC g s", to: "git.stage")
        map.bind("SPC g c", to: "git.commit")
        map.bind("j", to: "explorer.down")
        map.bind("/", to: "finder.all")
        return map
    }

    private func top(_ map: Keymap) -> [(chord: KeyChord, binding: KeyBinding)] {
        guard case .prefix(_, let continuations) = map.lookup([]) else { return [] }
        return continuations
    }

    @Test func abindingThatCannotFireIsNotListed() {
        let map = map()
        // The sidebar hasn't got the keyboard, so its motions cannot run.
        let rows = KeyWhichKey.live(top(map), under: [], keymap: map) { $0 != "explorer.down" }
        #expect(!rows.contains { $0.chord == KeyChord("j") }, "a dead binding was offered")
        #expect(rows.contains { $0.chord == KeyChord("/") })
    }

    /// A group is worth showing only while something under it is.
    @Test func aGroupIsAsLiveAsWhatItLeadsTo() {
        let map = map()
        let all = KeyWhichKey.live(top(map), under: [], keymap: map) { _ in true }
        #expect(all.contains { $0.chord == KeyChord("SPC") })

        let none = KeyWhichKey.live(top(map), under: [], keymap: map) {
            !$0.hasPrefix("git.")
        }
        #expect(!none.contains { $0.chord == KeyChord("SPC") },
                "a group leading only to dead ends was offered")

        // One live command under it is enough to keep the group.
        let some = KeyWhichKey.live(top(map), under: [], keymap: map) { $0 == "git.commit" }
        #expect(some.contains { $0.chord == KeyChord("SPC") })
    }

    @Test func theKeymapCanSayWhatAGroupLeadsTo() {
        let map = map()
        #expect(Set(map.commands(under: [KeyChord("SPC"), KeyChord("g")])
                    ) == ["git.stage", "git.commit"])
        #expect(map.commands(under: [KeyChord("j")]) == ["explorer.down"])
        #expect(map.commands(under: [KeyChord("z")]).isEmpty)
    }
}
