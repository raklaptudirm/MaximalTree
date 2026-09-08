import Testing
import AppKit
import Foundation
@testable import MaximalTreeKit
@testable import MaximalTree

/// The contents column: what is inside the thing the sidebar has selected.
///
/// One column rather than one per pane, because what it lists is decided by
/// the sidebar and there is one of those. Everything here is the wiring that
/// follows from that — which container it takes, which pane its highlight
/// reaches, and what an action run from it acts on.
@MainActor
@Suite struct ContentsTests {
    private func makeModel() throws -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("contents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(host: HostContext(),
                             workspaceFile: dir.appendingPathComponent("workspaces.json"))
        // The real store, so selecting and opening go the way they go in the
        // app rather than through a setter no caller uses.
        model.start()
        return model
    }

    private func id(_ uri: String) -> NodeID { NodeID(uri)! }

    /// A library holding three items, selected in the sidebar.
    @discardableResult
    private func library(in model: AppModel, style: ChildStyle = .contents) -> NodeID {
        let container = id("stub://library")
        model.host._ingest(Node(id: container, type: "stub.dir",
                                hasChildren: true, childStyle: style))
        let items = ["alpha", "beta", "gamma"].map { id("stub://library/\($0)") }
        for item in items { model.host._ingest(Node(id: item, type: "stub.file")) }
        model.host._setChildren(items, of: container)
        model.host.select([container])
        return container
    }

    // MARK: Which container

    @Test func theSidebarSelectionDecidesWhatIsListed() throws {
        let model = try makeModel()
        let container = library(in: model)
        #expect(model.contentsContainer == container)
        #expect(model.contentsVisible)
    }

    /// A place is expanded in the tree, so there is nothing for the column to
    /// do and it stays out of the way.
    @Test func aPlaceGetsNoColumn() throws {
        let model = try makeModel()
        library(in: model, style: .places)
        #expect(model.contentsContainer == nil)
        #expect(!model.contentsVisible)
    }

    /// Several things selected is a question about all of them, which is not
    /// something one list can show.
    @Test func aMultipleSelectionGetsNoColumn() throws {
        let model = try makeModel()
        let container = library(in: model)
        model.host.select([container, id("stub://library/alpha")])
        #expect(model.contentsContainer == nil)
    }

    /// The column never writes the sidebar's selection, and this is why: the
    /// container is derived from it, so a row publishing itself there would
    /// find that a file has no contents and close the column showing it.
    @Test func highlightingARowDoesNotDisturbTheSidebar() throws {
        let model = try makeModel()
        let container = library(in: model)
        model.highlightContentsRow(id("stub://library/beta"))
        #expect(model.host.selection == [container])
        #expect(model.contentsContainer == container, "the column closed under its own row")
    }

    // MARK: Which pane

    @Test func theHighlightedRowIsWhatTheActivePaneDraws() throws {
        let model = try makeModel()
        library(in: model)
        let pane = try #require(model.navigation.activePane)
        model.highlightContentsRow(id("stub://library/beta"))
        #expect(model.displayedNode(in: pane) == id("stub://library/beta"))
    }

    /// Standing in front of the history, not rewriting it: a list of two
    /// hundred must not cost two hundred entries to walk back out of.
    @Test func highlightingLeavesTheHistoryAlone() throws {
        let model = try makeModel()
        library(in: model)
        let before = try #require(model.navigation.activePane).history
        model.highlightContentsRow(id("stub://library/beta"))
        #expect(try #require(model.navigation.activePane).history == before)
    }

    /// Enter commits, and then the pane is showing it for real.
    @Test func openingARowNavigatesToIt() throws {
        let model = try makeModel()
        library(in: model)
        model.openContentsRow(id("stub://library/gamma"))
        #expect(model.navigation.activePane?.current == id("stub://library/gamma"))
    }

    // MARK: Moving

    /// Nowhere to move from yet: the first press lands on the first row rather
    /// than doing nothing, which is what a list with no highlight needs.
    @Test func theFirstMoveLandsOnTheFirstRow() throws {
        let model = try makeModel()
        library(in: model)
        model.moveContentsRow(by: 1)
        #expect(model.contentsRow == id("stub://library/alpha"))
    }

    /// And the first `k` lands on the last row, which is the same rule seen
    /// from the other end.
    @Test func theFirstMoveUpwardLandsOnTheLastRow() throws {
        let model = try makeModel()
        library(in: model)
        model.moveContentsRow(by: -1)
        #expect(model.contentsRow == id("stub://library/gamma"))
    }

    /// A list you have put away stops deciding what you are looking at — and
    /// still remembers where you were when it comes back.
    @Test func hidingTheColumnHandsThePaneBackItsOwnHistory() throws {
        let model = try makeModel()
        library(in: model)
        let pane = try #require(model.navigation.activePane)
        model.highlightContentsRow(id("stub://library/beta"))

        model.contents.isHidden = true
        #expect(model.contentsRow == nil)
        #expect(model.displayedNode(in: pane) == pane.current)

        model.contents.isHidden = false
        #expect(model.contentsRow == id("stub://library/beta"))
    }

    @Test func movingClampsAtBothEnds() throws {
        let model = try makeModel()
        library(in: model)
        model.moveContentsRow(by: 99)
        #expect(model.contentsRow == id("stub://library/gamma"))
        model.moveContentsRow(by: -99)
        #expect(model.contentsRow == id("stub://library/alpha"))
    }

    /// The motions walk what is on screen. Stepping onto a row a filter has
    /// hidden would move the pane to something the reader cannot see.
    @Test func movingWalksTheFilteredRows() throws {
        let model = try makeModel()
        library(in: model)
        model.contents.filter = "mm"         // gamma alone
        model.moveContentsRow(by: 1)
        #expect(model.contentsRow == id("stub://library/gamma"))
        model.moveContentsRow(by: 1)
        #expect(model.contentsRow == id("stub://library/gamma"), "walked past the filter")
    }

    /// Per container, so stepping out to another library and back puts you
    /// where you were.
    @Test func eachContainerRemembersItsOwnRow() throws {
        let model = try makeModel()
        let library = library(in: model)
        model.highlightContentsRow(id("stub://library/beta"))

        let other = id("stub://other")
        model.host._ingest(Node(id: other, type: "stub.dir",
                                hasChildren: true, childStyle: .contents))
        model.host.select([other])
        #expect(model.contentsRow == nil, "the new container inherited a row")

        model.host.select([library])
        #expect(model.contentsRow == id("stub://library/beta"))
    }

    // MARK: Keys

    @Test func itClaimsKeysOfItsOwn() throws {
        let model = try makeModel()
        let map = model.surfaceKeymap(for: .contents, showing: nil)
        #expect(map.lookup([KeyChord("j")]) == .command("contents.down"))
        #expect(map.lookup([KeyChord("RET")]) == .command("contents.open"))
        #expect(map.lookup([KeyChord("/")]) == .command("contents.filter"))
    }

    /// Its `j` is not the sidebar's and not the inspector's.
    @Test func itsKeysAreItsOwn() throws {
        let model = try makeModel()
        #expect(model.surfaceKeymap(for: .contents, showing: nil).lookup([KeyChord("j")])
                == .command("contents.down"))
        #expect(model.surfaceKeymap(for: .sidebar, showing: nil).lookup([KeyChord("j")])
                == .command("explorer.down"))
    }

    @Test func everyKeyNamesARegisteredAction() throws {
        let model = try makeModel()
        let ids = Set(model.pluginHost.registry.actions.map(\.id))
        for key in AppModel.contentsKeys {
            #expect(ids.contains(key.action),
                    "\(key.sequence) names \(key.action), which is not registered")
        }
    }

    /// And the leader reaches it, both to go there and to put it away.
    @Test func theKeymapBindsItsFocusAndToggle() {
        let map = DefaultKeymap.make()
        #expect(map.lookup([KeyChord("SPC"), KeyChord("s"), KeyChord("b")])
                == .command("contents.focus"))
        #expect(map.lookup([KeyChord("SPC"), KeyChord("s"), KeyChord("b", shift: true)])
                == .command("toggle.contents"))
    }
}
