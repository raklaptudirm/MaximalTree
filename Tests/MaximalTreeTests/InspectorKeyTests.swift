import Testing
import AppKit
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// The inspector's keys.
///
/// The last surface without any. Every other one declares keys, which is what
/// made "any surface can" true rather than "any canvas can" — and the
/// inspector was the one place you could read but not move.
@MainActor
@Suite struct InspectorKeyTests {
    private func makeModel() throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(),
                             workspaceFile: dir.appendingPathComponent("workspaces.json"))
        model.registerCoreActions(with: model.pluginHost.registry)
        return model
    }

    @Test func itClaimsKeysOfItsOwn() throws {
        let model = try makeModel()
        let map = model.surfaceKeymap(for: .inspector, showing: nil)

        #expect(map.lookup([KeyChord("j")]) == .command("inspector.scrollDown"))
        #expect(map.lookup([KeyChord("k")]) == .command("inspector.scrollUp"))
        #expect(map.lookup([KeyChord("g"), KeyChord("g")]) == .command("inspector.top"))
        #expect(map.lookup([KeyChord("g", shift: true)]) == .command("inspector.bottom"))
    }

    /// Its keys are the inspector's, not the sidebar's: `j` in one must not
    /// run the other's motion.
    @Test func itsKeysAreNotTheSidebars() throws {
        let model = try makeModel()
        let inspector = model.surfaceKeymap(for: .inspector, showing: nil)
        let sidebar = model.surfaceKeymap(for: .sidebar, showing: nil)

        #expect(inspector.lookup([KeyChord("j")]) == .command("inspector.scrollDown"))
        #expect(sidebar.lookup([KeyChord("j")]) == .command("explorer.down"))
    }

    @Test func everyKeyNamesARegisteredAction() throws {
        let model = try makeModel()
        let ids = Set(model.pluginHost.registry.actions.map(\.id))
        for key in AppModel.inspectorKeys {
            #expect(ids.contains(key.action),
                    "\(key.sequence) names \(key.action), which is not registered")
        }
    }

    /// With no inspector on screen the actions are harmless rather than a
    /// crash — which is the ordinary case, since the inspector can be hidden.
    @Test func scrollingWithNoInspectorDoesNothing() {
        InspectorScroll.report(nil)
        InspectorScroll.by(lines: 5)
        InspectorScroll.byHalfPage(1)
        InspectorScroll.toTop()
        InspectorScroll.toBottom()
    }

    /// It scrolls, and stops at the ends rather than running into blank space.
    @Test func scrollingMovesAndClamps() {
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.documentView = document
        scrollView.contentView.scroll(to: .zero)
        InspectorScroll.report(scrollView)
        defer { InspectorScroll.report(nil) }

        InspectorScroll.by(lines: 2)
        #expect(scrollView.contentView.bounds.origin.y > 0, "it did not move")

        InspectorScroll.toTop()
        #expect(scrollView.contentView.bounds.origin.y == 0)

        // Past the top is still the top.
        InspectorScroll.by(lines: -10)
        #expect(scrollView.contentView.bounds.origin.y == 0, "it scrolled above the start")

        InspectorScroll.toBottom()
        let bottom = scrollView.contentView.bounds.origin.y
        #expect(bottom == 900, "the bottom is the document less one screen")
        InspectorScroll.by(lines: 10)
        #expect(scrollView.contentView.bounds.origin.y == bottom, "it scrolled past the end")
    }
}
