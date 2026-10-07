import Testing
import AppKit
import GhosttyKit
import Foundation
@_spi(Host) @testable import MaximalTreeKit
@testable import MaximalTree

/// Terminals as nodes: each surface is its own, and it lives exactly as long
/// as its shell.
@MainActor
@Suite struct TerminalSessionTests {
    private func makeStore() -> TerminalSessions { TerminalSessions() }

    /// The point of the change: a directory doesn't have *the* terminal, it
    /// has as many as you opened, and each is separately addressable.
    @Test func twoTerminalsInOneDirectoryAreTwoNodes() {
        let store = makeStore()
        let first = store.create(directory: "/tmp")
        let second = store.create(directory: "/tmp")

        #expect(first.id != second.id)
        #expect(store.session(for: first.id) === first)
        #expect(store.session(for: second.id) === second)
        #expect(store.ordered == [first.id, second.id], "opening order is the listing order")
    }

    /// A session's id has to be the id the provider resolves its uri to.
    /// Canonicalisation is not identity — it drops a trailing slash, and every
    /// directory from NSTemporaryDirectory() has one — so a raw id would file
    /// the session under something nothing else could look up.
    @Test func aSessionsIdMatchesWhatItsUriResolvesTo() throws {
        let store = makeStore()
        for directory in ["/tmp/", NSTemporaryDirectory(), "/Users/me/project"] {
            let session = store.create(directory: directory)
            let resolved = try #require(
                TerminalProvider().resolve(session.id.uri))
            #expect(resolved == session.id, "\(directory) round-trips to a different id")
            #expect(store.session(for: resolved) === session)
        }
    }

    @Test func aSessionNodeCarriesItsDirectory() {
        let store = makeStore()
        let session = store.create(directory: "/Users/me/project")
        #expect(TerminalRef.directory(of: session.id) == "/Users/me/project")
        #expect(TerminalRef.isSession(session.id))
        #expect(!TerminalRef.isSession(TerminalRef.sessionsID))
    }

    /// A terminal is named by what runs in it, falling back to where it runs.
    @Test func aSessionIsLabelledByItsProgramThenItsDirectory() {
        let store = makeStore()
        let session = store.create(directory: "/Users/me/project")
        #expect(session.label == "Terminal — project")

        session.setTitle("vim README.md")
        #expect(session.label == "vim README.md")
    }

    /// Closing is what ends a shell, and the node goes with it.
    @Test func closingRemovesTheNode() {
        let store = makeStore()
        let session = store.create(directory: "/tmp")
        store.close(session.id)

        #expect(store.session(for: session.id) == nil)
        #expect(store.ordered.isEmpty)
    }

    /// A terminal the workspace remembered from a previous run comes back.
    ///
    /// The shell itself cannot outlive the app, but the node can: its uri
    /// names a directory, which is all that is needed to put the same terminal
    /// back. It keeps its id, because the workspace remembers this node as one
    /// of its roots and a fresh id would leave that entry pointing at nothing.
    @Test func aTerminalFromAPreviousRunIsRestored() async throws {
        let id = try #require(NodeID(TerminalRef.sessionURI(id: UUID(),
                                                            directory: "/tmp")))
        let node = await TerminalProvider().node(for: id)

        #expect(node?.id == id, "the restored terminal changed identity")
        #expect(node?.type == TypeID("terminal.session"))
        let session = try #require(TerminalSessions.shared.session(for: id))
        #expect(session.directory == "/tmp")
        TerminalSessions.shared.close(id)
    }

    /// Restoring is cheap on purpose: a workspace full of terminals must not
    /// spawn a screenful of shells at launch. The shell starts when the
    /// terminal is first shown.
    @Test func restoringDoesNotStartAShell() throws {
        let store = makeStore()
        let id = try #require(NodeID(TerminalRef.sessionURI(id: UUID(),
                                                            directory: "/tmp")))
        let session = store.restore(id: id, directory: "/tmp")
        #expect(!session.view.hasLiveSurface, "restoring started a shell")
    }

    /// Restoring the same node twice is one terminal, not two — the provider
    /// is asked for a node far more often than once.
    @Test func restoringIsIdempotent() throws {
        let store = makeStore()
        let id = try #require(NodeID(TerminalRef.sessionURI(id: UUID(),
                                                            directory: "/tmp")))
        let first = store.restore(id: id, directory: "/tmp")
        let second = store.restore(id: id, directory: "/tmp")
        #expect(first === second)
        #expect(store.ordered == [id])
    }

    /// The terminal reports its own title and pwd as programs run and the
    /// shell moves; the node follows both.
    @Test func aSurfaceReportRenamesAndRelocatesItsNode() {
        let store = makeStore()
        let session = store.create(directory: "/tmp")

        store.surfaceReported(view: session.view, title: "htop", directory: "/var/log")

        #expect(session.title == "htop")
        #expect(session.directory == "/var/log")
        #expect(session.label == "htop")
    }

    /// What makes a session a session. A canvas is rebuilt whenever the node
    /// is closed and reopened, moved to another tab, or re-laid-out — and the
    /// shell has to be indifferent to all of it. Before sessions owned their
    /// views, leaving a window took the surface with it.
    @Test func theShellSurvivesLeavingAndRejoiningAWindow() async throws {
        try #require(GhosttyApp.shared.app != nil)
        let store = makeStore()
        let session = store.create(directory: NSTemporaryDirectory())

        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        window.contentView = container
        container.addSubview(session.view)
        window.orderFrontRegardless()
        defer { store.close(session.id); window.orderOut(nil) }
        try #require(await waitUntil("the surface never came up", in: window) {
            session.view.hasLiveSurface
        })

        // The tab switch: out of the view tree entirely, then back — each
        // given the turn anything deferred about it would take.
        session.view.removeFromSuperview()
        await mainQueueDrained()
        container.addSubview(session.view)
        await mainQueueDrained()

        #expect(session.view.hasLiveSurface, "the shell died when its canvas went away")
        #expect(store.session(for: session.id) === session)
    }

    /// And closing really does end it — the surface is what holds the shell.
    @Test func closingEndsTheSurface() async throws {
        try #require(GhosttyApp.shared.app != nil)
        let store = makeStore()
        let session = store.create(directory: NSTemporaryDirectory())

        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try #require(await waitUntil("the surface never came up", in: window) {
            session.view.hasLiveSurface
        })

        store.close(session.id)
        #expect(!session.view.hasLiveSurface)
    }

    // MARK: Spawning where the reader already is

    @Test func aNewTerminalInheritsAnotherTerminalsLiveDirectory() {
        let store = makeStore()
        let session = store.create(directory: "/Users/me/project")
        // The shell moved after it started; that is the directory to inherit,
        // not the one it was launched in.
        store.surfaceReported(view: session.view, title: nil, directory: "/var/log")

        #expect(TerminalSpawn.directory(targets: [session.id], sessions: store,
                                        isDirectory: { _ in false }) == "/var/log")
    }

    @Test func aNewTerminalOpensBesideTheSelectedFile() throws {
        let store = makeStore()
        let file = try #require(NodeID("file:///Users/me/project/README.md"))
        #expect(TerminalSpawn.directory(targets: [file], sessions: store,
                                        isDirectory: { _ in false })
                == "/Users/me/project")
    }

    @Test func aNewTerminalOpensInsideTheSelectedFolder() throws {
        let store = makeStore()
        let folder = try #require(NodeID("file:///Users/me/project"))
        #expect(TerminalSpawn.directory(targets: [folder], sessions: store,
                                        isDirectory: { _ in true })
                == "/Users/me/project")
    }

    /// Home is for when there is nothing to go on — not for when the question
    /// simply wasn't asked.
    @Test func withNothingToGoOnANewTerminalStartsAtHome() throws {
        let store = makeStore()
        let web = try #require(NodeID("https://example.com"))
        #expect(TerminalSpawn.directory(targets: [web], sessions: store,
                                        isDirectory: { _ in false })
                == NSHomeDirectory())
        #expect(TerminalSpawn.directory(targets: [], sessions: store,
                                        isDirectory: { _ in false })
                == NSHomeDirectory())
    }

    /// Whether a node follows a *real* shell's `cd` is the one thing here
    /// that isn't proven.
    ///
    /// Disabled because the harness can't drive the shell, not because the
    /// behaviour is known to be wrong: text written with `ghostty_surface_text`
    /// never reaches the pty from a test process — a probe that typed
    /// `touch <file>` produced no file, so nothing is being executed at all.
    /// The same call is what Ghostty's own app uses, and keystrokes in the app
    /// go through `ghostty_surface_key` instead, so this proves nothing about
    /// the running terminal either way. Left here because it is exactly the
    /// test to run once the surface can be driven headlessly.
    @Test(.disabled("input does not reach the pty from a test process"))
    func aRealShellsCdIsFollowedByItsNode() async throws {
        try #require(GhosttyApp.shared.app != nil)
        let store = makeStore()
        let start = NSTemporaryDirectory()
        let session = store.create(directory: start)

        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.view
        window.orderFrontRegardless()
        defer { store.close(session.id); window.orderOut(nil) }
        try #require(await waitUntil("the surface never came up", in: window) {
            session.view.hasLiveSurface
        })

        session.view.send(text: "cd /usr/local\n")

        // The shell has to run the command and report back through OSC 7.
        await waitUntil("the node never followed the shell to /usr/local",
                        every: .milliseconds(50)) {
            session.directory.hasSuffix("/usr/local")
        }
    }

    /// A terminal is somewhere you go back to, so it belongs in the sidebar
    /// rather than only in whichever tab happened to open it.
    @MainActor
    @Test func openingATerminalMountsItAsARoot() throws {
        let host = HostContext()
        let registry = Registry()
        registry.register(provider: TerminalProvider())
        let store = GraphStore(context: host, registry: registry, nav: NavigationModel())
        _ = store

        let session = TerminalSessions.shared.create(directory: NSTemporaryDirectory())
        defer { TerminalSessions.shared.close(session.id) }
        host.mount(session.id.uri)

        #expect(host.roots.contains(session.id), "the terminal never reached the sidebar")
    }

    /// And it is work from the moment it exists: opening something else must
    /// not reuse its tab, even though nothing has been typed into it.
    @MainActor
    @Test func aTerminalsTabIsNotAPreview() throws {
        let nav = NavigationModel()
        let terminal = try #require(NodeID(TerminalRef.sessionURI(id: UUID(),
                                                                 directory: "/tmp")))
        nav.openInPreview(terminal)
        #expect(!nav.activeTab.isPinned, "a fresh tab starts as a preview")

        nav.pinTabs(showing: terminal)      // what the canvas does on appear

        #expect(nav.activeTab.isPinned)
        let other = try #require(NodeID("file:///tmp/other.txt"))
        nav.openInPreview(other)
        #expect(nav.tabs.count == 2, "the terminal's tab was taken over")
        #expect(nav.tabs[0].current == terminal)
    }

    @Test func reportsForAnUnknownSurfaceAreIgnored() {
        let store = makeStore()
        let orphan = TerminalSurfaceView(frame: .zero)
        // No sessionID: a view the store never made. Must not crash or invent.
        store.surfaceReported(view: orphan, title: "nope", directory: nil)
        #expect(store.ordered.isEmpty)
    }
}

/// Does libghostty actually run inside this process?
///
/// The point of the whole exercise: not that the header parses or that the
/// static library links, but that the terminal *starts* — config loaded,
/// app created, and a surface with a live shell behind it attached to a view.
@MainActor
@Suite struct GhosttyEmbeddingTests {
    /// Ghostty resolves `theme = dark:…, light:…` against the scheme its host
    /// reports, and assumes light until told — which is why a terminal came up
    /// in the light theme on a dark desktop.
    @Test func appearanceIsTranslatedToAColourScheme() throws {
        #expect(GhosttyApp.scheme(for: try #require(NSAppearance(named: .darkAqua)))
                == GHOSTTY_COLOR_SCHEME_DARK)
        #expect(GhosttyApp.scheme(for: try #require(NSAppearance(named: .aqua)))
                == GHOSTTY_COLOR_SCHEME_LIGHT)
        // Vibrant and high-contrast appearances are neither .aqua nor
        // .darkAqua, and must still land on the right side.
        #expect(GhosttyApp.scheme(for: try #require(NSAppearance(named: .vibrantDark)))
                == GHOSTTY_COLOR_SCHEME_DARK)
        #expect(GhosttyApp.scheme(for: try #require(
            NSAppearance(named: .accessibilityHighContrastDarkAqua)))
                == GHOSTTY_COLOR_SCHEME_DARK)
        #expect(GhosttyApp.scheme(for: try #require(
            NSAppearance(named: .accessibilityHighContrastAqua)))
                == GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    /// The link that was missing.
    ///
    /// Telling libghostty the colour scheme doesn't re-theme anything by
    /// itself: it records the scheme and asks the *host* to reload the
    /// configuration, and the conditional theme (`theme = dark:…, light:…`) is
    /// resolved when that reload is applied. This host ignored the request, so
    /// the scheme was set and nothing acted on it — a light theme on a dark
    /// desktop. Anything downstream of this is libghostty's own business; what
    /// has to be true here is that the request arrives and is answered.
    @Test func changingTheSchemeReappliesTheConfiguration() async throws {
        let ghostty = GhosttyApp.shared
        let app = try #require(ghostty.app)

        // Away from wherever it currently is, so the change is a real one:
        // libghostty ignores a scheme that matches what it already has.
        let current = GhosttyApp.scheme(for: NSApp.effectiveAppearance)
        let other = current == GHOSTTY_COLOR_SCHEME_DARK
            ? GHOSTTY_COLOR_SCHEME_LIGHT : GHOSTTY_COLOR_SCHEME_DARK

        let before = ghostty.configReloads
        ghostty_app_set_color_scheme(app, other)
        await waitUntil("the scheme changed and the config was never re-applied") {
            ghostty.configReloads > before
        }

        ghostty_app_set_color_scheme(app, current)
    }

    /// Which keys carry text, and which speak for themselves.
    ///
    /// This is what made arrow keys type garbage: AppKit reports an arrow's
    /// `characters` as a private-use codepoint (0xF700 and up), and passing
    /// that through as text inserts it instead of moving the cursor. Control
    /// combinations are the mirror image — their `characters` is already the
    /// control byte, which libghostty derives from the keycode itself, so
    /// sending it too encodes it twice.
    @Test func onlyRealTextIsSentAsText() throws {
        func event(_ characters: String, _ type: NSEvent.EventType = .keyDown) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
        }

        #expect(TerminalSurfaceView.textToSend(for: try event("a")) == "a")
        #expect(TerminalSurfaceView.textToSend(for: try event("é")) == "é")
        #expect(TerminalSurfaceView.textToSend(for: try event("👋")) == "👋")

        // Arrows, function keys, Home/End: private use area.
        for arrow in [NSUpArrowFunctionKey, NSDownArrowFunctionKey,
                      NSLeftArrowFunctionKey, NSRightArrowFunctionKey,
                      NSHomeFunctionKey, NSF1FunctionKey] {
            let key = String(UnicodeScalar(UInt32(arrow))!)
            #expect(TerminalSurfaceView.textToSend(for: try event(key)) == nil,
                    "0x\(String(arrow, radix: 16)) would be typed into the terminal")
        }

        // Control characters: ctrl-c, tab, return, escape, delete.
        for control in ["\u{03}", "\u{09}", "\u{0D}", "\u{1B}", "\u{7F}"] {
            #expect(TerminalSurfaceView.textToSend(for: try event(control)) == nil)
        }

        // A key going *up* carries no text at all.
        #expect(TerminalSurfaceView.textToSend(for: try event("a", .keyUp)) == nil)
    }

    /// Copy and paste go through the host: libghostty has no clipboard of its
    /// own, it asks. Both directions are checked against the real pasteboard.
    @Test func theTerminalCanReadAndWriteTheClipboard() {
        let marker = "mt-clipboard-\(UUID().uuidString)"
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            if let saved {
                NSPasteboard.general.declareTypes([.string], owner: nil)
                NSPasteboard.general.setString(saved, forType: .string)
            }
        }

        GhosttyApp.writeClipboard(marker, to: GHOSTTY_CLIPBOARD_STANDARD)
        #expect(GhosttyApp.readClipboard(GHOSTTY_CLIPBOARD_STANDARD) == marker)
        #expect(NSPasteboard.general.string(forType: .string) == marker,
                "the terminal's copy never reached the system pasteboard")

        // The selection clipboard is an X11 idea macOS lacks; it must still
        // answer rather than come back empty.
        #expect(GhosttyApp.readClipboard(GHOSTTY_CLIPBOARD_SELECTION) == marker)

        // Writing nothing must not wipe what's there.
        GhosttyApp.writeClipboard("", to: GHOSTTY_CLIPBOARD_STANDARD)
        #expect(GhosttyApp.readClipboard(GHOSTTY_CLIPBOARD_STANDARD) == marker)
    }

    /// End to end: what the shell prints, copied out of the terminal, lands on
    /// the pasteboard the way a person would expect ⌘C to leave it.
    @Test func copyingFromTheTerminalReachesThePasteboard() async throws {
        try #require(GhosttyApp.shared.app != nil)
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            if let saved {
                NSPasteboard.general.declareTypes([.string], owner: nil)
                NSPasteboard.general.setString(saved, forType: .string)
            }
        }
        let marker = "mt-copy-\(UUID().uuidString.prefix(8))"

        let store = TerminalSessions()
        let session = store.create(directory: NSTemporaryDirectory(),
                                   initialInput: "echo \(marker)\n")
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.view
        window.orderFrontRegardless()
        defer { store.close(session.id); window.orderOut(nil) }

        try #require(await waitUntil("the shell never echoed it", every: .milliseconds(50)) {
            session.view.visibleText()?.contains(marker) ?? false
        })

        // select_all then copy_to_clipboard, the same bindings ⌘A/⌘C invoke.
        session.view.perform(binding: "select_all")
        session.view.perform(binding: "copy_to_clipboard")
        await waitUntil("copying out of the terminal put nothing on the pasteboard") {
            NSPasteboard.general.string(forType: .string)?.contains(marker) ?? false
        }
    }

    /// A shell that exits takes its terminal with it. Left alone, the node
    /// stays in the sidebar looking alive while answering nothing.
    @Test func exitingTheShellClosesTheTerminal() async throws {
        try #require(GhosttyApp.shared.app != nil)
        // Not an immediate exit: a command that dies within
        // `abnormal-command-exit-runtime-ms` is reported as a failure and the
        // surface deliberately stays open to show why. This is the ordinary
        // case — a shell someone finished with.
        let session = TerminalSessions.shared.create(directory: NSTemporaryDirectory(),
                                                     initialInput: "sleep 1; exit\n")
        let id = session.id
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.view
        window.orderFrontRegardless()
        defer { TerminalSessions.shared.close(id); window.orderOut(nil) }

        // Generous: the first `login` in a process can take several seconds
        // before the shell is even up to run `exit`.
        let closed = await waitUntil("the shell exited and its terminal stayed behind",
                                     within: .seconds(20), every: .milliseconds(50)) {
            TerminalSessions.shared.session(for: id) == nil
        }
        if !closed {
            Issue.record("the screen said: \(session.view.visibleText()?.suffix(200) ?? "<no screen>")")
        }
    }

    /// The host's environment is not the user's.
    ///
    /// Whatever launches the app — an IDE, a build tool, an agent — may set
    /// GIT_EDITOR so that git never blocks on an editor. A terminal that
    /// inherits it runs `/usr/bin/true` for `git commit`, which writes nothing
    /// and returns, so git aborts on an empty message and no editor is ever
    /// seen. Checked in the shell itself, since that is who is lied to.
    @Test func aShellDoesNotInheritTheHostsEditorOverride() async throws {
        try #require(GhosttyApp.shared.app != nil)
        setenv("GIT_EDITOR", "true", 1)
        defer { unsetenv("GIT_EDITOR") }
        GhosttyApp.scrubHostEnvironment()

        // The terminal echoes what is typed, and that echo contains the
        // literal `$GIT_EDITOR`. Marking the *output* differently is what lets
        // the answer be told apart from the question.
        let store = TerminalSessions()
        let session = store.create(directory: NSTemporaryDirectory(),
                                   initialInput: "echo \"seen<$GIT_EDITOR>end\"\n")
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.view
        window.orderFrontRegardless()
        defer { store.close(session.id); window.orderOut(nil) }

        var answers: [String] = []
        await waitUntil("the shell never answered", within: .seconds(15), every: .milliseconds(50)) {
            let screen = session.view.visibleText() ?? ""
            answers = screen.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                // The command as typed still mentions the variable; the shell's
                // answer never does.
                .filter { $0.contains("seen<") && !$0.contains("$") }
            return !answers.isEmpty
        }
        let answer = try #require(answers.first, "the shell never answered")
        #expect(answer.contains("seen<>end"), "the shell inherited it: \(answer)")
    }

    /// A real terminal has to run full-screen programs, not just echo text:
    /// the pty, the terminfo database we ship, and the alternate screen all
    /// have to work together. `git commit` exercises all three — it hands off
    /// to $EDITOR, which fails outright if TERM names a terminfo entry that
    /// can't be found.
    @Test func gitCommitOpensAnEditorInTheTerminal() async throws {
        try #require(GhosttyApp.shared.app != nil)
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("mt-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try "hello".write(to: repo.appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        for arguments in [["init", "-q"], ["add", "-A"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", repo.path] + arguments
            try git.run()
            git.waitUntilExit()
        }

        // initial_input runs it as though it were typed — which is the only
        // way to drive the shell from here, since synthetic key events don't
        // reach the pty.
        let store = TerminalSessions()
        let session = store.create(
            directory: repo.path,
            initialInput: "git -c user.email=t@e.com -c user.name=T commit\n")
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = session.view
        window.orderFrontRegardless()
        defer { store.close(session.id); window.orderOut(nil) }

        var screen = ""
        let editing = await waitUntil("no editor came up", every: .milliseconds(50)) {
            screen = session.view.visibleText() ?? ""
            return screen.contains("COMMIT_EDITMSG") || screen.contains("commit message")
        }
        if !editing { Issue.record("the terminal showed:\n\(screen.suffix(600))") }
        // The tell-tale of a missing terminfo entry, in case it ever regresses
        // into the fallback rather than failing outright.
        #expect(!screen.contains("Terminal entry not found"), "\(screen.suffix(400))")
    }

    @Test func libghosttyStartsInProcess() {
        let app = GhosttyApp.shared
        #expect(app.failure == nil, "\(app.failure ?? "")")
        #expect(app.app != nil, "libghostty produced no app")
    }

    /// A surface needs a window: it takes the view's backing scale at
    /// creation, and renders through a layer that a windowless view lacks.
    @Test func aSurfaceAttachesToAViewAndSpawnsAShell() async throws {
        try #require(GhosttyApp.shared.app != nil)

        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.workingDirectory = NSTemporaryDirectory()
        window.contentView = view
        window.orderFrontRegardless()
        defer {
            window.contentView = nil     // frees the surface, ending the shell
            window.orderOut(nil)
        }

        #expect(view.hasLiveSurface, "no surface — libghostty refused the view")

        // A terminal that renders but runs nothing is not a terminal: the
        // surface should have forked a shell under this very process. The
        // renderer and IO threads start behind the surface, so it is waited for.
        func children() -> [String] {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-A", "-o", "ppid=,comm="]
            let pipe = Pipe()
            ps.standardOutput = pipe
            guard (try? ps.run()) != nil else { return [] }
            let listing = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            ps.waitUntilExit()
            let mine = String(ProcessInfo.processInfo.processIdentifier)
            return listing.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix(mine + " ") }
        }
        // macOS starts a login shell through `login -fp`, so that — not a
        // bare zsh — is what a working terminal forks here.
        var forked: [String] = []
        let spawned = await waitUntil("nothing was forked by this process", every: .milliseconds(100)) {
            forked = children()
            return forked.contains { $0.hasSuffix("login") || $0.hasSuffix("sh") }
        }
        if !spawned { Issue.record("its children were:\n\(forked.joined(separator: "\n"))") }
    }
}
