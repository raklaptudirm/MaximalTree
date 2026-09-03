import Testing
import Foundation
@testable import MaximalTree
@testable import MaximalTreeKit

/// Fuzzy matching. The ranking is the part that matters — with a hundred
/// matches, being *a* match is worthless if the right one isn't first.
@Suite struct FuzzyTests {
    private func score(_ query: String, _ text: String) -> Int? {
        Fuzzy.match(query, text)?.score
    }

    @Test func matchesCharactersInOrderWithGapsBetween() {
        #expect(score("mtk", "MaximalTreeKit") != nil)
        #expect(score("keyc", "KeyCapture.swift") != nil)
        #expect(score("abc", "cba") == nil, "order has to hold")
        #expect(score("xyz", "MaximalTree") == nil)
    }

    @Test func anEmptyQueryMatchesEverything() {
        #expect(Fuzzy.match("", "anything") == Fuzzy.Match(score: 0, matched: []))
    }

    /// The reason a fuzzy finder feels sharp: an abbreviation of the word
    /// starts beats the same letters buried mid-word.
    @Test func wordStartsBeatCharactersInTheMiddle() {
        let initials = try! #require(score("gp", "GitPlugin"))
        let buried = try! #require(score("gp", "aggregate purple"))
        #expect(initials > buried, "GitPlugin should win for gp")
    }

    @Test func adjacentCharactersBeatScatteredOnes() {
        let together = try! #require(score("find", "Finder.swift"))
        let scattered = try! #require(score("find", "flag inspector node data"))
        #expect(together > scattered)
    }

    @Test func aPrefixBeatsAMatchFurtherIn() {
        let prefix = try! #require(score("term", "Terminal"))
        let inside = try! #require(score("term", "The determiner"))
        #expect(prefix > inside)
    }

    /// Between two things that both match tightly, the shorter is likelier to
    /// be the one meant.
    @Test func shorterNamesWinTies() {
        let short = try! #require(score("git", "Git"))
        let long = try! #require(score("git", "GitHubIntegrationSettingsPanel"))
        #expect(short > long)
    }

    /// The view highlights what matched, so the positions have to be right.
    @Test func itSaysWhereItMatched() {
        let hit = try! #require(Fuzzy.match("kc", "KeyCapture"))
        #expect(hit.matched == [0, 3], "K at 0, C at 3")
    }

    /// One greedy pass takes the first place each character will go, which is
    /// often the worst: "we" in "New Web Page" anchors on the `w` of "New" and
    /// reaches across for an `e`. The match belongs on "**We**b" — both for
    /// the score and for what gets highlighted.
    @Test func theMatchLandsWhereAReaderWouldPutIt() throws {
        let hit = try #require(Fuzzy.match("we", "New Web Page"))
        #expect(hit.matched == [4, 5], "the We of Web, not the w of New")
    }

    /// Which is what lets a named command out-rank the files that merely
    /// happen to start with the same letters.
    @Test func aTightWordStartBeatsALooseNamePrefix() throws {
        let command = try #require(score("we", "New Web Page"))
        let file = try #require(score("we", "weakref_finalize.py"))
        #expect(command > file - 18, "close enough that a little weighting settles it")
    }

    @Test func matchingIgnoresCase() {
        #expect(score("GIT", "git.swift") != nil)
        #expect(score("git", "GIT.swift") != nil)
    }
}

/// The picker: what it gathers, what it ranks, and where the selection goes.
/// Observation callbacks run outside the actor, so the flag they set has to
/// be a reference the test can read afterwards.
private final class Flag: @unchecked Sendable {
    var value = false
}

private func item(_ title: String, subtitle: String? = nil) -> FinderItem {
    FinderItem(id: title, title: title, subtitle: subtitle, effect: .run("noop"))
}

@MainActor
@Suite struct FinderModelTests {
    private func model(_ titles: [String], id: String = "test",
                       byDefault: Bool = true) -> (FinderModel, FinderSource) {
        let items = titles.map { item($0) }
        let source = FinderSource(id: id, title: "Test", prompt: "Find…",
                                  searchedByDefault: byDefault) { items }
        return (FinderModel(), source)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test func gathersItemsFromTheSourcesItWasOpenedOver() async {
        let (finder, source) = model(["alpha", "beta"])
        finder.open(scope: nil, sources: [source])
        await settle()
        #expect(finder.results().count == 2)
    }

    /// A source can stay out of the everything-search and still have a key.
    @Test func aSourceCanOptOutOfSearchingEverything() async {
        let (finder, source) = model(["alpha"], id: "workspaces", byDefault: false)
        finder.open(scope: nil, sources: [source])
        await settle()
        #expect(finder.results().isEmpty, "opted out of the general search")

        finder.open(scope: "workspaces", sources: [source])
        await settle()
        #expect(finder.results().count == 1, "but its own key still reaches it")
    }

    @Test func rankingPutsTheBestMatchFirst() async {
        let (finder, source) = model(["aggregate purple", "GitPlugin", "digitize"])
        finder.open(scope: nil, sources: [source])
        await settle()
        finder.query = "gp"
        #expect(finder.results().first?.item.title == "GitPlugin")
    }

    /// Ranked across sources together, so searching everything gives one list
    /// rather than several to read in turn.
    @Test func resultsFromEverySourceAreRankedTogether() async {
        let files = FinderSource(id: "files", title: "Files", prompt: "") {
            [item("notes.txt")]
        }
        let actions = FinderSource(id: "actions", title: "Actions", prompt: "") {
            [item("New Note")]
        }
        let finder = FinderModel()
        finder.open(scope: nil, sources: [files, actions])
        await settle()
        finder.query = "note"
        #expect(finder.results().count == 2, "both sources are in one ranked list")
    }

    /// A path or a host counts, but a name match is what you usually meant.
    @Test func subtitlesMatchButRankBelowTitles() async {
        let finder = FinderModel()
        let source = FinderSource(id: "s", title: "", prompt: "") {
            [item("unrelated", subtitle: "Sources/Widgets/thing.swift"),
             item("widgets.swift")]
        }
        finder.open(scope: nil, sources: [source])
        await settle()
        finder.query = "widgets"
        let titles = finder.results().map(\.item.title)
        #expect(titles.count == 2)
        #expect(titles.first == "widgets.swift", "a title match should lead")
    }

    @Test func movingWrapsAtBothEnds() async {
        let (finder, source) = model(["a", "b", "c"])
        finder.open(scope: nil, sources: [source])
        await settle()
        #expect(finder.index == 0)
        finder.move(-1)
        #expect(finder.index == 2, "up from the first goes to the last")
        finder.move(1)
        #expect(finder.index == 0)
    }

    @Test func typingReturnsToTheTopOfTheList() async {
        let (finder, source) = model(["alpha", "beta", "gamma"])
        finder.open(scope: nil, sources: [source])
        await settle()
        finder.move(2)
        #expect(finder.index == 2)
        finder.query = "a"
        #expect(finder.index == 0, "the old row is meaningless against a new list")
    }

    /// Opening again while a slow source is still walking must not have the
    /// first search's results arrive into the second's list.
    @Test func aSecondOpenAbandonsTheFirst() async {
        let slow = FinderSource(id: "slow", title: "", prompt: "") {
            try? await Task.sleep(for: .milliseconds(80))
            return [item("from the slow one")]
        }
        let quick = FinderSource(id: "quick", title: "", prompt: "") {
            [item("from the quick one")]
        }
        let finder = FinderModel()
        finder.open(scope: "slow", sources: [slow, quick])
        finder.open(scope: "quick", sources: [slow, quick])
        try? await Task.sleep(for: .milliseconds(150))
        #expect(finder.results().map(\.item.title) == ["from the quick one"])
    }

    /// A broad query keeps every match, not just the winner. The list is what
    /// you scroll; narrowing to one row would make the ranking the only thing
    /// that ever mattered.
    @Test func abroadQueryKeepsEveryMatch() async {
        let titles = ["alpha", "beta", "gamma", "delta", "sigma", "omega"]
        let (finder, source) = model(titles)
        finder.open(scope: nil, sources: [source])
        await settle()
        finder.query = "a"
        #expect(finder.results().count == titles.count, "every one of these has an a")
    }

    /// Rows are identified by item id, and SwiftUI silently draws one row for
    /// a repeated id — so a collision would look exactly like a list that
    /// refuses to grow.
    @Test func itemsFromEverySourceHaveDistinctIdentities() async {
        let files = FinderSource(id: "files", title: "", prompt: "") {
            [item("notes.txt"), item("todo.txt")]
        }
        let actions = FinderSource(id: "actions", title: "", prompt: "") {
            [item("New Note"), item("New Todo")]
        }
        let finder = FinderModel()
        finder.open(scope: nil, sources: [files, actions])
        await settle()
        let ids = finder.results().map(\.item.id)
        #expect(Set(ids).count == ids.count, "a repeated id draws one row for both")
    }

    /// Typing has to *tell* the view, not merely record itself: a list that
    /// holds the last render's results while the field fills up is the shape
    /// of every "it won't filter" complaint.
    @Test func typingInvalidatesWhateverIsShowingTheResults() {
        let finder = FinderModel()
        let told = Flag()
        withObservationTracking {
            _ = finder.query
        } onChange: {
            told.value = true
        }
        finder.query = "git"
        #expect(told.value, "a view reading the query was never told it changed")
    }

    /// The same for the results themselves, which is what the list reads.
    @Test func loadedItemsInvalidateTheResults() async {
        let (finder, source) = model(["alpha"])
        let told = Flag()
        withObservationTracking {
            _ = finder.results()
        } onChange: {
            told.value = true
        }
        finder.open(scope: nil, sources: [source])
        await settle()
        #expect(told.value)
    }

    /// The case that made the finder feel broken: thousands of incidental
    /// files against a handful of deliberately named commands. On equal terms
    /// "we" offered `weakref_finalize.py` before "New Web Page", because a
    /// prefix match on a filename genuinely scores well — there are simply
    /// three orders of magnitude more of them.
    @Test func aNamedCommandBeatsTheFilesThatHappenToMatch() async {
        let files = FinderSource(id: "files", title: "File", prompt: "") {
            ["weakref_finalize.py", "ruby.webp", "w32.exe", "webpack.config.js"]
                .map { item($0) }
        }
        let actions = FinderSource(id: "actions", title: "Action", prompt: "",
                                   weight: 18) {
            [item("New Web Page")]
        }
        let finder = FinderModel()
        finder.open(scope: nil, sources: [files, actions])
        await settle()
        finder.query = "we"
        #expect(finder.results().first?.item.title == "New Web Page")
    }

    /// Weighting tips the balance; it doesn't pin anything. A file whose name
    /// is what you typed still wins.
    @Test func weightingDoesNotOverrideAGoodMatch() async {
        let files = FinderSource(id: "files", title: "File", prompt: "") {
            [item("webpack.config.js")]
        }
        let actions = FinderSource(id: "actions", title: "Action", prompt: "",
                                   weight: 18) {
            [item("New Web Page")]
        }
        let finder = FinderModel()
        finder.open(scope: nil, sources: [files, actions])
        await settle()
        finder.query = "webpack"
        #expect(finder.results().first?.item.title == "webpack.config.js")
    }

    /// Rows say which list they came from, since one ranked list mixes files,
    /// actions and tabs and is otherwise hard to read.
    @Test func everyRowKnowsWhichListItCameFrom() async {
        let files = FinderSource(id: "files", title: "File", prompt: "") {
            [item("notes.txt")]
        }
        let finder = FinderModel()
        finder.open(scope: nil, sources: [files])
        await settle()
        #expect(finder.results().first?.source == "File")
    }

    /// Two mounted roots can reach the same file, and SwiftUI draws a single
    /// row for a repeated identity — so a duplicate is a row that silently
    /// goes missing rather than an error.
    @Test func aThingReachableTwiceIsListedOnce() async {
        let first = FinderSource(id: "a", title: "A", prompt: "") {
            [FinderItem(id: "file:///x/notes.txt", title: "notes.txt",
                        effect: .open("file:///x/notes.txt"))]
        }
        let second = FinderSource(id: "b", title: "B", prompt: "") {
            [FinderItem(id: "file:///x/notes.txt", title: "notes.txt",
                        effect: .open("file:///x/notes.txt"))]
        }
        let finder = FinderModel()
        finder.open(scope: nil, sources: [first, second])
        await settle()
        finder.query = "notes"
        #expect(finder.results().count == 1)
    }

    /// Rows are identified by what they are, so the view can tell one query's
    /// results from another's. Identifying them by position made SwiftUI reuse
    /// the views it had already drawn.
    @Test func rowsAreIdentifiedByTheirItem() async {
        let (finder, source) = model(["alpha", "beta"])
        finder.open(scope: nil, sources: [source])
        await settle()
        let before = finder.results().map(\.id)
        finder.query = "beta"
        let after = finder.results().map(\.id)
        #expect(before != after, "a different result set must carry different identities")
        #expect(after == ["beta"])
    }

    @Test func closingForgetsEverything() async {
        let (finder, source) = model(["alpha"])
        finder.open(scope: nil, sources: [source])
        await settle()
        finder.close()
        #expect(finder.results().isEmpty)
        #expect(finder.query.isEmpty)
    }
}


/// The finder is a text field, and in this app a text field means insert mode.
///
/// Without that the keymap ate the query before it could be typed: `g`, `o`,
/// `w`, `d`, `x`, the digits and SPC are all bound, so "git" fired the goto
/// prefix and then insert mode, and the list never narrowed past whatever
/// happened to be first.
@MainActor
@Suite struct FinderModeTests {
    private func app() -> AppModel {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("finder-mode-\(UUID().uuidString).json")
        return AppModel(host: HostContext(), workspaceFile: file)
    }

    @Test func openingTheFinderHandsItTheKeyboard() {
        let model = app()
        #expect(model.keys.mode == .normal)
        model.openFinder()
        #expect(model.keys.mode == .insert, "the query field has to receive what is typed")
    }

    @Test func closingGivesTheKeysBackToTheApp() {
        let model = app()
        model.openFinder()
        model.closeFinder()
        #expect(model.keys.mode == .normal)
        #expect(!model.finderVisible)
    }

    /// The letters an ordinary query is made of are commands in the mode the
    /// finder used to open in, which is the whole reason it opens in another.
    /// "git" alone is three of them.
    @Test func theQueryIsMadeOfKeysTheKeymapWouldHaveTaken() {
        let map = DefaultKeymap.make()
        for letter in ["g", "i", "o", "j", "k", "l", "h", "G"] {
            guard let chord = KeyChord(parsing: letter) else { continue }
            #expect(map.lookup([chord]) != .unbound,
                    "\(letter) is bound, so typing it needs insert mode")
        }
        // And the leader, which would otherwise start a sequence mid-word.
        #expect(map.lookup([KeyChord("SPC")]) != .unbound)
    }

    /// The picker's own keys have to be taken by the monitor.
    ///
    /// While the finder is open the first responder is the text field's field
    /// editor, so a SwiftUI key handler on the field never runs: the arrows
    /// moved the insertion point instead of the selection, and the only result
    /// you could reach was whichever was on top.
    @Test func theArrowsMoveTheSelectionRatherThanTheCaret() async {
        let model = app()
        let source = FinderSource(id: "s", title: "", prompt: "") {
            [item("one"), item("two"), item("three")]
        }
        model.finder.open(scope: nil, sources: [source])
        model.finderVisible = true
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.handleFinderKey(KeyChord("down")), "the finder has to claim it")
        #expect(model.finder.index == 1)
        #expect(model.handleFinderKey(KeyChord("up")))
        #expect(model.finder.index == 0)
    }

    /// The same, for the keys every terminal picker uses.
    @Test func controlNAndPMoveTooAndOrdinaryLettersDoNot() async {
        let model = app()
        let source = FinderSource(id: "s", title: "", prompt: "") {
            [item("one"), item("two")]
        }
        model.finder.open(scope: nil, sources: [source])
        model.finderVisible = true
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.handleFinderKey(KeyChord("n", control: true)))
        #expect(model.finder.index == 1)
        #expect(model.handleFinderKey(KeyChord("p", control: true)))
        #expect(model.finder.index == 0)
        // A bare letter is query text and must reach the field.
        #expect(!model.handleFinderKey(KeyChord("n")), "plain letters are typing")
    }

    @Test func escapeAndReturnBelongToTheFinderWhileItIsOpen() async {
        let model = app()
        model.openFinder()
        #expect(model.handleFinderKey(KeyChord("ESC")))
        #expect(!model.finderVisible)
        // Closed, it claims nothing — the app's keys are the app's again.
        #expect(!model.handleFinderKey(KeyChord("down")))
        #expect(!model.handleFinderKey(KeyChord("ESC")))
    }

    @Test func closingWhenAlreadyClosedLeavesTheModeAlone() {
        let model = app()
        model.keys.setMode(.insert)
        model.closeFinder()
        #expect(model.keys.mode == .insert, "nothing was open, so nothing was taken back")
    }
}


/// The file walk. This is what "nothing filters down" turned out to be: it
/// went through the graph's *cache*, which is empty for anything the sidebar
/// hasn't expanded, so it stopped at the first unvisited directory and offered
/// a handful of files.
@Suite struct FinderFilesTests {
    /// A small tree: nested files, a dependency directory, a hidden one.
    private func tree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("finder-walk-\(UUID().uuidString)")
        let manager = FileManager.default
        for directory in ["src/deep/deeper", "docs", "node_modules/pkg", ".git"] {
            try manager.createDirectory(at: root.appendingPathComponent(directory),
                                        withIntermediateDirectories: true)
        }
        for file in ["top.swift", "src/one.swift", "src/deep/two.swift",
                     "src/deep/deeper/three.swift", "docs/readme.md",
                     "node_modules/pkg/ignored.js", ".git/config"] {
            try "x".write(to: root.appendingPathComponent(file), atomically: true,
                          encoding: .utf8)
        }
        return root
    }

    @Test func reachesFilesAtEveryDepth() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = Set(FinderFiles.items(under: [root]).map(\.title))

        #expect(names.contains("top.swift"))
        #expect(names.contains("one.swift"))
        #expect(names.contains("two.swift"))
        #expect(names.contains("three.swift"), "the walk has to go all the way down")
        #expect(names.contains("readme.md"))
    }

    @Test func skipsDependencyAndHiddenTrees() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = Set(FinderFiles.items(under: [root]).map(\.title))

        #expect(!names.contains("ignored.js"), "node_modules is never what you want")
        #expect(!names.contains("config"), "nor anything hidden")
    }

    /// The path is what tells two files of the same name apart, and what a
    /// second word in the query can match against.
    @Test func eachFileCarriesWhereItLives() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let items = FinderFiles.items(under: [root])
        let deep = try #require(items.first { $0.title == "three.swift" })
        #expect(deep.subtitle == "src/deep/deeper")
    }

    @Test func opensTheFileItFound() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(FinderFiles.items(under: [root])
            .first { $0.title == "top.swift" })
        guard case .open(let uri) = item.effect else {
            Issue.record("a file should open"); return
        }
        #expect(uri.hasSuffix("top.swift"))
        #expect(NodeID(uri) != nil, "the uri has to be one the graph can resolve")
    }

    @Test func theCapIsHonoured() throws {
        let root = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FinderFiles.items(under: [root], limit: 2).count == 2)
    }

    @Test func aRootThatIsNotThereIsNotAFailure() {
        let missing = URL(fileURLWithPath: "/nowhere/at/all/\(UUID().uuidString)")
        #expect(FinderFiles.items(under: [missing]).isEmpty)
    }
}
