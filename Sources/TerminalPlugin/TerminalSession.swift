import AppKit
import Foundation
import MaximalTreeKit

/// A terminal's identity in the graph.
///
///   `terminal://sessions`                     — every live terminal
///   `terminal://session/<uuid>?cwd=<path>`    — one of them
///
/// The uuid, not the directory, is what makes a surface a *node*: two
/// terminals in the same folder are two different things, and each has to be
/// nameable, openable, and closable on its own. The directory rides in the
/// query so a row can be labelled before the store is consulted.
enum TerminalRef {
    static let sessionsURI = "terminal://sessions"
    static var sessionsID: NodeID { NodeID(canonical: sessionsURI) }

    static func sessionURI(id: UUID, directory: String) -> String {
        var components = URLComponents()
        components.scheme = "terminal"
        components.host = "session"
        components.path = "/" + id.uuidString
        components.queryItems = [URLQueryItem(name: "cwd", value: directory)]
        return components.string ?? "terminal://session/\(id.uuidString)"
    }

    /// The directory a session node was started in, if its uri says.
    static func directory(of id: NodeID) -> String? {
        URLComponents(string: id.uri)?
            .queryItems?.first { $0.name == "cwd" }?.value
    }

    static func isSession(_ id: NodeID) -> Bool {
        URLComponents(string: id.uri)?.host == "session"
    }
}

/// Where a new terminal should start.
///
/// A terminal opened from somewhere should begin *there*: from another
/// terminal, in whatever directory that shell has cd'd to — not the one it was
/// launched in — and from a file or folder, beside it. Falling back to home is
/// for when the question has no answer, not for when it's merely unasked.
@MainActor
enum TerminalSpawn {
    static func directory(targets: [NodeID], sessions: TerminalSessions,
                          isDirectory: (NodeID) -> Bool) -> String {
        for target in targets {
            // A terminal's *live* directory, which is what the reader can see
            // in it — the shell may have moved since it started.
            if let session = sessions.session(for: target) {
                return session.directory
            }
            guard target.scheme == "file", let url = URL(string: target.uri) else { continue }
            return isDirectory(target) ? url.path : url.deletingLastPathComponent().path
        }
        return NSHomeDirectory()
    }
}

/// One live terminal.
///
/// The session owns the view, and the view owns the surface — so the shell
/// survives everything the UI does to it. A canvas is only ever a window onto
/// a session: switching tabs, closing a pane, or reopening the node later
/// re-hosts the same view rather than starting a second shell.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id: NodeID
    let created = Date()
    /// Where the shell started, and where it is now — a shell that cd's
    /// somewhere reports it, and the node follows.
    private(set) var directory: String
    /// What the running program calls itself, when it says.
    private(set) var title: String?
    /// The colour the terminal is actually painting behind its text — the
    /// theme it resolved, reported by the terminal itself.
    private(set) var background: NSColor?

    /// Not observed: AppKit views change constantly and none of it is state
    /// the graph cares about.
    @ObservationIgnored let view: TerminalSurfaceView

    init(id: NodeID, directory: String, initialInput: String? = nil) {
        self.id = id
        self.directory = directory
        self.view = TerminalSurfaceView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.workingDirectory = directory
        view.initialInput = initialInput
        view.sessionID = id
    }

    var label: String {
        if let title, !title.isEmpty { return title }
        let name = URL(fileURLWithPath: directory).lastPathComponent
        return name.isEmpty ? "Terminal" : "Terminal — \(name)"
    }

    func setTitle(_ value: String?) { title = value }
    func setDirectory(_ value: String) { directory = value }
    func setBackground(_ value: NSColor) { background = value }
}

/// Every live terminal, and the only thing that creates or ends one.
@MainActor
@Observable
final class TerminalSessions {
    static let shared = TerminalSessions()

    private(set) var ordered: [NodeID] = []
    private var sessions: [NodeID: TerminalSession] = [:]

    /// The host, so a terminal appearing, vanishing, or renaming itself
    /// reaches the sidebar. Weak, and set by whoever touches the store first
    /// — a plugin has no host until the app hands it one.
    @ObservationIgnored weak var host: HostContext?

    func session(for id: NodeID) -> TerminalSession? { sessions[id] }

    @discardableResult
    func create(directory: String, initialInput: String? = nil) -> TerminalSession {
        let uuid = UUID()
        let uri = TerminalRef.sessionURI(id: uuid, directory: directory)
        // Canonicalizing, not `NodeID(canonical:)`: the provider resolves uris
        // through the same initializer, and canonicalization is not identity —
        // it drops a trailing slash, which every directory from
        // NSTemporaryDirectory() has. Minting a raw id would leave the session
        // filed under one id and reachable only by another.
        let id = NodeID(uri) ?? NodeID(canonical: uri)
        let session = TerminalSession(id: id, directory: directory,
                                      initialInput: initialInput)
        sessions[id] = session
        ordered.append(id)
        host?.notify([.childrenChanged(TerminalRef.sessionsID)])
        return session
    }

    /// End a terminal: the surface is freed, which is what kills the shell.
    func close(_ id: NodeID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        ordered.removeAll { $0 == id }
        session.view.teardown()
        host?.notify([.removed(id), .childrenChanged(TerminalRef.sessionsID)])
    }

    /// A surface told us about itself. Called from libghostty's action
    /// callback, which knows a surface pointer and nothing else — the view is
    /// the surface's userdata, and the view knows its node.
    func surfaceReported(view: TerminalSurfaceView, background: NSColor) {
        guard let id = view.sessionID, let session = sessions[id] else { return }
        session.setBackground(background)
    }

    func surfaceReported(view: TerminalSurfaceView, title: String?, directory: String?) {
        guard let id = view.sessionID, let session = sessions[id] else { return }
        if let title { session.setTitle(title) }
        if let directory { session.setDirectory(directory) }
        host?.notify([.modified(id)])
    }
}
