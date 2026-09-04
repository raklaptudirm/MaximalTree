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
        let bound = DefaultKeymap.make().commandIDs.filter { !isUnavailableHere($0) }
        #expect(bound.count > 40, "the keymap should be checking most of the app")

        let missing = bound.subtracting(known).sorted()
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
}
