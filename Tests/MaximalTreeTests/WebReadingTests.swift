import Testing
import AppKit
import WebKit
import Foundation
@_spi(Host) @testable import MaximalTreeKit
@testable import MaximalTree

/// Reading a page: what you do to it that isn't going somewhere else.
@MainActor
@Suite struct WebReadingTests {
    private func registry() -> Registry {
        let registry = Registry()
        WebPlugin().register(with: registry)
        return registry
    }

    @Test func theReadingVocabularyIsRegistered() {
        let ids = Set(registry().actions.map(\.id))
        for id in ["web.findNext", "web.findPrevious", "web.zoomIn", "web.zoomOut",
                   "web.zoomReset", "web.copyURL"] {
            #expect(ids.contains(id), "\(id) is not registered")
        }
    }

    /// All of them need a live page, so none clutters a list while you are
    /// looking at something else.
    @Test func noneOfThemApplyWithoutAPage() throws {
        let host = HostContext()
        let file = try #require(NodeID("file:///tmp/a.txt"))
        host._ingest(Node(id: file, type: "file.file"))
        let ctx = ActionContext(host: host, targets: [file])

        for id in ["web.findNext", "web.zoomIn", "web.zoomReset", "web.copyURL"] {
            let action = try #require(registry().actions.first { $0.id == id })
            #expect(!action.appliesTo.matches(ctx), "\(id) offered itself for a text file")
        }
    }

    /// Zoom stops at the ends: past these the page stops being readable in
    /// either direction, and a held key would otherwise run away.
    @Test func zoomIsClamped() {
        let session = WebSession(homeURL: nil)
        for _ in 0..<50 { session.zoom(by: 0.1) }
        #expect(session.webView.pageZoom == 3.0, "zoomed past legible")

        for _ in 0..<100 { session.zoom(by: -0.1) }
        #expect(session.webView.pageZoom == 0.5, "zoomed past legible the other way")

        session.resetZoom()
        #expect(session.webView.pageZoom == 1)
        #expect(session.zoomPercent == 100)
    }

    @Test func zoomReadsAsAPercentage() {
        let session = WebSession(homeURL: nil)
        session.zoom(by: 0.5)
        #expect(session.zoomPercent == 150)
    }

    /// The search text lives on the session because it outlives the inspector
    /// that typed it — and because the next/previous actions have to reach it,
    /// which a view's state cannot offer them.
    @Test func theSearchIsRememberedOnTheSession() {
        let session = WebSession(homeURL: nil)
        #expect(session.searchText.isEmpty)

        session.find("needle")
        #expect(session.searchText == "needle")

        // Searching for nothing clears the "not found" notice rather than
        // leaving it standing over an empty field.
        session.searchFoundNothing = true
        session.find("")
        #expect(!session.searchFoundNothing)
    }

    /// Repeating a search is only offered once there is one to repeat.
    @Test func findNextNeedsSomethingToFind() throws {
        let host = HostContext()
        let page = try #require(NodeID("https://example.com/"))
        host._ingest(Node(id: page, type: "web.page"))
        let ctx = ActionContext(host: host, targets: [page])
        let action = try #require(registry().actions.first { $0.id == "web.findNext" })

        // No session yet, so nothing to search either.
        #expect(!action.appliesTo.matches(ctx))
    }

    /// Asking whether an action applies must not start a browser session: the
    /// finder asks about every action every time it opens.
    @Test func askingDoesNotStartASession() throws {
        let page = try #require(NodeID("https://example.com/never-opened"))
        #expect(WebSessionStore.shared.existingSession(for: page) == nil)

        let host = HostContext()
        host._ingest(Node(id: page, type: "web.page"))
        let ctx = ActionContext(host: host, targets: [page])
        for action in registry().actions where action.id.hasPrefix("web.") {
            _ = action.appliesTo.matches(ctx)
        }
        #expect(WebSessionStore.shared.existingSession(for: page) == nil,
                "asking about an action opened a web view")
    }
}

/// What a page *is* while it is open.
///
/// The live session holds the title, so the provider is where that is read —
/// a canvas showing the page reports that the record changed, and everything
/// listing the node gets the answer from one place, whether or not the canvas
/// is on screen.
@MainActor
@Suite struct WebRecordTests {
    private func page(_ uri: String) throws -> NodeID { try #require(NodeID(uri)) }

    @Test func aPageWithNoSessionIsNamedAfterItsURL() async throws {
        let id = try page("https://example.com/things")
        let node = try #require(await WebProvider().node(for: id))
        #expect(node.label == WebProvider.label(for: try #require(URL(string: id.uri))))
    }

    @Test func anOpenPageIsCalledWhateverItCallsItself() async throws {
        let id = try page("https://example.com/things")
        WebSessionStore.shared.session(for: id).title = "Things — Example"

        let node = try #require(await WebProvider().node(for: id))
        #expect(node.label == "Things — Example")
    }

    /// A page that hasn't said what it is called yet falls back rather than
    /// showing an empty row.
    @Test func aPageThatHasNotSaidItsNameKeepsTheURLOne() async throws {
        let id = try page("https://example.com/quiet")
        WebSessionStore.shared.session(for: id).title = ""

        let node = try #require(await WebProvider().node(for: id))
        #expect(node.label == WebProvider.label(for: try #require(URL(string: id.uri))))
    }

    /// Asking what a page is must not start a browser session for it — the
    /// same rule the action predicates follow.
    @Test func askingWhatAPageIsDoesNotStartASession() async throws {
        let id = try page("https://example.com/untouched")
        _ = await WebProvider().node(for: id)
        #expect(WebSessionStore.shared.existingSession(for: id) == nil)
    }

    @Test func theSitesIconIsOnTheRecord() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("favicons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = FaviconStore.shared
        FaviconStore.shared = FaviconStore(directory: directory)
        defer { FaviconStore.shared = previous }

        let png = try #require(NSImage(systemSymbolName: "star", accessibilityDescription: nil)?
            .tiffRepresentation)
        FaviconStore.shared.store(png, for: "example.com")

        let node = try #require(await WebProvider().node(for: try page("https://example.com/a")))
        #expect(node.icon?.imageData == png)
    }
}
