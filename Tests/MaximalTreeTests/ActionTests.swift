import Testing
import Foundation
@_spi(Host) @testable import MaximalTreeKit
@testable import MaximalTree

@MainActor
@Suite struct ActionTargetingTests {
    private func id(_ s: String) -> NodeID { NodeID(s)! }

    @Test func defaultsToHostSelection() {
        let host = HostContext()
        host._setSelection([id("file:///b.txt")])
        #expect(ActionContext(host: host).selection == [id("file:///b.txt")])
    }

    /// The context-menu case: the rows you right-clicked win over whatever happens
    /// to be selected, so a menu can never act on the wrong nodes.
    @Test func explicitTargetsOverrideSelection() {
        let host = HostContext()
        host._setSelection([id("file:///selected.txt")])
        let ctx = ActionContext(host: host, targets: [id("file:///clicked.txt")])
        #expect(ctx.targets == [id("file:///clicked.txt")])
        #expect(ctx.selection == [id("file:///clicked.txt")])
    }

    @Test func predicateEvaluatesAgainstTargets() {
        let host = HostContext()
        let file = id("file:///a.txt")
        host._ingest(Node(id: file, type: "file.file"))
        host._setSelection([])                       // selection is empty…

        let predicate = ActionPredicate.type(TypeID("file.file"))
        #expect(predicate.matches(ActionContext(host: host, targets: [file])))  // …targets still match
        #expect(!predicate.matches(ActionContext(host: host)))                  // and selection doesn't
    }

    @Test func predicateRejectsMixedTargets() {
        let host = HostContext()
        let file = id("file:///a.txt")
        let dir = id("file:///sub")
        host._ingest(Node(id: file, type: "file.file"))
        host._ingest(Node(id: dir, type: "file.directory"))

        let predicate = ActionPredicate.type(TypeID("file.file"))
        #expect(!predicate.matches(ActionContext(host: host, targets: [file, dir])))
    }
}
