import Testing
import Foundation
@_spi(Host) @testable import MaximalTreeKit
@testable import MaximalTree

// A file of the reader's own data that can't be read is never written over.
//
// It used to be: an unreadable workspace library fell through to a fresh one and
// was saved straight over, taking every workspace and collection with it, and
// bookmarks and feed names went the same way on their next change. These pin the
// rule for each of them.

/// A folder of its own, and a way to make it read-only and back.
private struct Folder {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("user-data-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    func contents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    /// Nothing can be created, moved or removed in it while `body` runs.
    func readOnly<T>(_ body: () throws -> T) rethrows -> T {
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return try body()
    }
}

/// What a newer build might write: a shape this one can't decode.
private let unreadable = Data(#"{"workspaces":[{"id":"not-a-uuid","name":"Research"}],"activeID":null}"#.utf8)

@Suite struct UserDataFileTests {
    @Test func aFileThatIsNotThereIsMissing() throws {
        let folder = try Folder()
        guard case .missing = UserDataFile.read([String].self, from: folder.file("a.json")) else {
            Issue.record("not reported missing"); return
        }
    }

    @Test func aReadableFileIsRead() throws {
        let folder = try Folder()
        try Data(#"["a","b"]"#.utf8).write(to: folder.file("a.json"))
        guard case .read(let value) = UserDataFile.read([String].self, from: folder.file("a.json")) else {
            Issue.record("not read"); return
        }
        #expect(value == ["a", "b"])
    }

    /// Moved aside beside itself, every byte as it was, under a name that says
    /// what it is.
    @Test func anUnreadableFileIsMovedAsideUntouched() throws {
        let folder = try Folder()
        try unreadable.write(to: folder.file("workspaces.json"))

        guard case .unreadable(let kept?, _) = UserDataFile.read([Int].self, from: folder.file("workspaces.json")) else {
            Issue.record("not set aside"); return
        }
        #expect(try Data(contentsOf: kept) == unreadable, "it was changed on the way")
        #expect(!FileManager.default.fileExists(atPath: folder.file("workspaces.json").path))
        #expect(kept.lastPathComponent.hasPrefix("workspaces.unreadable-"))
        #expect(kept.pathExtension == "json")
        #expect(kept.deletingLastPathComponent().standardizedFileURL == folder.url.standardizedFileURL)
    }

    /// The second of two bad launches keeps the first one's file too.
    @Test func aSecondUnreadableFileDoesNotReplaceTheFirst() throws {
        let folder = try Folder()
        let file = folder.file("workspaces.json")
        try unreadable.write(to: file)
        _ = UserDataFile.read([Int].self, from: file)
        try Data("second".utf8).write(to: file)
        _ = UserDataFile.read([Int].self, from: file)

        let kept = folder.contents().filter { $0.hasPrefix("workspaces.unreadable-") }
        #expect(kept.count == 2, "one set-aside file replaced the other: \(folder.contents())")
    }

    /// When it can't even be moved, it stays exactly where it was.
    @Test func aFileThatCannotBeMovedStaysPut() throws {
        let folder = try Folder()
        let file = folder.file("workspaces.json")
        try unreadable.write(to: file)

        let reading = folder.readOnly { UserDataFile.read([Int].self, from: file) }

        guard case .unreadable(nil, _) = reading else {
            Issue.record("claimed to have moved it"); return
        }
        #expect(try Data(contentsOf: file) == unreadable)
    }
}

@MainActor
@Suite struct WorkspaceLibraryKeepingTests {
    /// The bug itself: an unreadable library used to be replaced by a fresh
    /// one on launch, with nothing kept.
    @Test func anUnreadableLibraryIsKeptAndAFreshOneStarted() throws {
        let folder = try Folder()
        let file = folder.file("workspaces.json")
        try unreadable.write(to: file)

        let store = WorkspaceStore(fileURL: file)

        let kept = try #require(store.unreadable?.keptAt, "nothing was kept")
        #expect(try Data(contentsOf: kept) == unreadable, "what was kept is not what was there")
        #expect(store.library.workspaces.map(\.name) == ["Main"])
        #expect(FileManager.default.fileExists(atPath: file.path), "the fresh library wasn't saved")
    }

    /// And when it couldn't be moved, nothing is saved over it — not on
    /// launch, and not on the next change either.
    @Test func anUnreadableLibraryThatCannotBeMovedIsNeverWrittenOver() throws {
        let folder = try Folder()
        let file = folder.file("workspaces.json")
        try unreadable.write(to: file)

        let store = folder.readOnly { WorkspaceStore(fileURL: file) }
        #expect(store.unreadable != nil)
        #expect(store.unreadable?.keptAt == nil)

        _ = store.createGroup(named: "Something")
        #expect(try Data(contentsOf: file) == unreadable, "it was written over")
        // Not attempted at all, rather than attempted and failed: saving over
        // it is refused, not merely unlucky.
        #expect(store.saveError == nil, "it tried to save over the file")
    }

    @Test func aMissingLibraryStartsFreshWithNothingToReport() throws {
        let folder = try Folder()
        let store = WorkspaceStore(fileURL: folder.file("workspaces.json"))
        #expect(store.unreadable == nil)
        #expect(folder.contents() == ["workspaces.json"])
    }

    /// A save that fails is said once per run of failures, and forgotten
    /// once one succeeds.
    @Test func aFailedSaveIsReportedOnceUntilOneSucceeds() throws {
        let folder = try Folder()
        let store = WorkspaceStore(fileURL: folder.file("workspaces.json"))
        var reports = 0
        store.onSaveFailed = { _ in reports += 1 }

        folder.readOnly {
            _ = store.createGroup(named: "One")
            _ = store.createGroup(named: "Two")
        }
        #expect(reports == 1, "reported \(reports) times")
        #expect(store.saveError != nil)

        _ = store.createGroup(named: "Three")
        #expect(store.saveError == nil, "a save that worked didn't clear the failure")
    }
}

@MainActor
@Suite struct WorkspaceLibraryNoticeTests {
    @Test func theReaderIsToldWhereTheirWorkspacesWent() throws {
        let folder = try Folder()
        let file = folder.file("workspaces.json")
        try unreadable.write(to: file)

        let model = AppModel(host: HostContext(), workspaceFile: file)
        model.start()

        let kept = try #require(model.workspaceStore.unreadable?.keptAt)
        #expect(model.commandFailure?.title == "Your Workspaces Were Set Aside")
        #expect(model.commandFailure?.message.contains(kept.lastPathComponent) == true,
                "it didn't say where they went")
    }

    @Test func aLibraryThatReadsFineSaysNothing() throws {
        let folder = try Folder()
        let model = AppModel(host: HostContext(), workspaceFile: folder.file("workspaces.json"))
        model.start()
        #expect(model.commandFailure == nil)
    }
}

@Suite struct BookmarkKeepingTests {
    /// The first bookmark added after a bad launch used to be what erased the
    /// rest.
    @Test func addingABookmarkDoesNotEraseAnUnreadableFile() throws {
        let folder = try Folder()
        let file = folder.file("web-bookmarks.json")
        try unreadable.write(to: file)

        let store = BookmarkStore(fileURL: file)
        store.add(url: "https://example.com", title: "Example")

        let kept = try #require(store.unreadable?.keptAt)
        #expect(try Data(contentsOf: kept) == unreadable)
        #expect(store.all().map(\.title) == ["Example"])
    }
}

extension BookmarkKeepingTests {
    /// And one that can't even be moved is never saved over — refused, not
    /// attempted and failed.
    @Test func bookmarksThatCannotBeMovedAreNeverWrittenOver() throws {
        let folder = try Folder()
        let file = folder.file("web-bookmarks.json")
        try unreadable.write(to: file)

        let store = folder.readOnly { () -> BookmarkStore in
            let store = BookmarkStore(fileURL: file)
            store.add(url: "https://example.com", title: "Example")
            return store
        }
        #expect(store.unreadable?.keptAt == nil)
        #expect(try Data(contentsOf: file) == unreadable)
        #expect(store.saveError == nil, "it tried to save over the file")
    }
}

@Suite struct FeedNameKeepingTests {
    @Test func feedNamesThatCannotBeMovedAreNeverWrittenOver() throws {
        let folder = try Folder()
        let file = folder.file("feeds.json")
        try unreadable.write(to: file)

        let store = folder.readOnly { () -> YouTubeStore in
            let store = YouTubeStore(directory: folder.url)
            store.remember(feedName: "Music", for: UUID())
            return store
        }
        #expect(try Data(contentsOf: file) == unreadable)
        #expect(store.feedsSaveError == nil, "it tried to save over the file")
    }

    private func cache(_ folder: Folder) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.file("known.json")))) as? [String: Any] ?? [:]
    }

    /// Names a reader chose live apart from the cache now, so losing the cache
    /// loses nothing that can't be fetched again.
    @Test func aFeedNameSurvivesLosingTheCache() throws {
        let folder = try Folder()
        let feed = UUID()
        YouTubeStore(directory: folder.url).remember(feedName: "Music", for: feed)

        try Data("not json".utf8).write(to: folder.file("known.json"))

        #expect(YouTubeStore(directory: folder.url).feedName(feed) == "Music")
    }

    @Test func theCacheNoLongerHoldsFeedNames() throws {
        let folder = try Folder()
        let store = YouTubeStore(directory: folder.url)
        store.remember(feedName: "Music", for: UUID())
        store.remember(search: "something")
        #expect(cache(folder)["feedNames"] == nil, "a chosen name is in the cache again")
    }

    /// Names kept in the cache by an older build are carried across once.
    @Test func namesFromAnOlderCacheAreCarriedAcross() throws {
        let folder = try Folder()
        let feed = UUID()
        let old = #"{"videos":[],"playlists":[],"searches":[],"feedNames":{"\#(feed.uuidString.lowercased())":"Talks"}}"#
        try Data(old.utf8).write(to: folder.file("known.json"))

        #expect(YouTubeStore(directory: folder.url).feedName(feed) == "Talks")
        #expect(FileManager.default.fileExists(atPath: folder.file("feeds.json").path))
    }
}

// MARK: - Telling the reader

/// Everything posted to `notices`, held or live, in the order it arrived.
@MainActor
private final class Heard {
    private(set) var notices: [Notice] = []
    init(_ notices: Notices) { notices.listen { [unowned self] in self.notices.append($0) } }
}

@MainActor
@Suite struct NoticeTests {
    /// A store says its piece while it is being opened, which is before
    /// anyone is listening. Held, not dropped.
    @Test func whatIsSaidBeforeTheHostListensIsHeld() {
        let notices = Notices()
        notices.post(Notice(title: "One", message: "", source: "a"))
        notices.post(Notice(title: "Two", message: "", source: "b"))
        #expect(Heard(notices).notices.map(\.title) == ["One", "Two"])
    }

    @Test func whatIsSaidAfterwardsArrivesAtOnce() {
        let notices = Notices()
        let heard = Heard(notices)
        notices.post(Notice(title: "Later", message: "", source: "a"))
        #expect(heard.notices.map(\.title) == ["Later"])
    }

    /// Two at once, as on a launch where nothing can be read: the second
    /// waits its turn rather than replacing the first.
    @Test func aSecondNoticeWaitsForTheFirstToBeDismissed() async throws {
        let folder = try Folder()
        let file = folder.file("workspaces.json")
        try unreadable.write(to: file)
        let model = AppModel(host: HostContext(), workspaceFile: file)
        model.start()

        model.pluginHost.registry.notices.post(Notice(title: "Second", message: "", source: "test"))
        #expect(model.commandFailure?.title == "Your Workspaces Were Set Aside")

        model.dismissCommandFailure()
        for _ in 0..<200 where model.commandFailure == nil { await Task.yield() }
        #expect(model.commandFailure?.title == "Second", "the second notice was lost")

        model.dismissCommandFailure()
        for _ in 0..<20 { await Task.yield() }
        #expect(model.commandFailure == nil)
    }
}

@MainActor
@Suite struct UserDataNoticeTests {
    @Test func unreadableBookmarksAreToldWhereTheyWent() throws {
        let folder = try Folder()
        let file = folder.file("web-bookmarks.json")
        try unreadable.write(to: file)
        let store = BookmarkStore(fileURL: file)
        let notices = Notices()
        let heard = Heard(notices)

        store.report(to: notices)

        let kept = try #require(store.unreadable?.keptAt)
        #expect(heard.notices.map(\.title) == ["Your Bookmarks Were Set Aside"])
        #expect(heard.notices.first?.message.contains(kept.lastPathComponent) == true,
                "it didn't say where they went")
        #expect(heard.notices.first?.message.contains("“web-bookmarks.json”") == true,
                "it didn't say what to rename it back to")
    }

    @Test func bookmarksThatCouldNotBeMovedSaySo() throws {
        let folder = try Folder()
        let file = folder.file("web-bookmarks.json")
        try unreadable.write(to: file)
        let store = folder.readOnly { BookmarkStore(fileURL: file) }
        let notices = Notices()
        let heard = Heard(notices)

        store.report(to: notices)

        #expect(heard.notices.map(\.title) == ["Your Bookmarks Couldn't Be Read"])
    }

    @Test func bookmarksThatReadFineSayNothing() throws {
        let folder = try Folder()
        let notices = Notices()
        let heard = Heard(notices)
        BookmarkStore(fileURL: folder.file("web-bookmarks.json")).report(to: notices)
        #expect(heard.notices.isEmpty)
    }

    /// Once when saving starts to fail, not once for every bookmark after
    /// it; and again if it fails after having worked.
    @Test func aFailingBookmarkSaveIsToldOncePerRunOfFailures() throws {
        let folder = try Folder()
        let store = BookmarkStore(fileURL: folder.file("web-bookmarks.json"))
        let notices = Notices()
        let heard = Heard(notices)
        store.report(to: notices)

        folder.readOnly {
            store.add(url: "https://example.com/1", title: "One")
            store.add(url: "https://example.com/2", title: "Two")
        }
        #expect(heard.notices.map(\.title) == ["Your Bookmarks Weren't Saved"])

        store.add(url: "https://example.com/3", title: "Three")
        folder.readOnly { store.remove(url: "https://example.com/3") }
        #expect(heard.notices.count == 2, "a failure after a success went unsaid")
    }

    @Test func unreadableFeedNamesAreToldWhereTheyWent() throws {
        let folder = try Folder()
        try unreadable.write(to: folder.file("feeds.json"))
        let store = YouTubeStore(directory: folder.url)
        let notices = Notices()
        let heard = Heard(notices)

        store.report(to: notices)

        let kept = try #require(store.feedsUnreadable?.keptAt)
        #expect(heard.notices.map(\.title) == ["Your YouTube Feed Names Were Set Aside"])
        #expect(heard.notices.first?.message.contains(kept.lastPathComponent) == true)
    }

    @Test func aFailingFeedNameSaveIsToldOncePerRunOfFailures() throws {
        let folder = try Folder()
        let store = YouTubeStore(directory: folder.url)
        let notices = Notices()
        let heard = Heard(notices)
        store.report(to: notices)

        folder.readOnly {
            store.remember(feedName: "Music", for: UUID())
            store.remember(feedName: "Talks", for: UUID())
        }
        #expect(heard.notices.map(\.title) == ["Your YouTube Feed Names Weren't Saved"])
    }

    /// The plugins hand their stores the host's channel when they register —
    /// without it, everything above is said to nobody.
    @Test func thePluginsPassTheHostsChannelOn() {
        let registry = Registry()
        WebPlugin().register(with: registry)
        YouTubePlugin().register(with: registry)
        #expect(BookmarkStore.shared.notices === registry.notices)
        #expect(YouTubeStore.shared.notices === registry.notices)
    }
}
