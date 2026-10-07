import Foundation

// MARK: - Telling the reader

/// Something the reader needs to hear that no command failed to do: their
/// bookmarks couldn't be read, their feed names didn't save. A command that
/// fails says so by throwing, and the host reports it; this is for what goes
/// wrong on nobody's request — on launch, or in a save no one asked for by name.
public struct Notice: Sendable, Equatable {
    public var title: String
    public var message: String
    /// Who is saying it, the way a command's id says which command failed:
    /// `"web.bookmarks"`.
    public var source: String

    public init(title: String, message: String, source: String) {
        self.title = title
        self.message = message
        self.source = source
    }
}

/// Where a plugin says it — `CoreRegistry.notices`. Hand it to whatever holds
/// the reader's data.
///
/// It can be told from any thread, because the stores that have something to
/// say are called from providers off the main actor. And nothing said before
/// the host is listening is lost: it is held until the host is, since the first
/// thing a store has to say is usually said while it is being opened.
public final class Notices: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [Notice] = []
    private var listener: (@MainActor @Sendable (Notice) -> Void)?

    public init() {}

    public func post(_ notice: Notice) {
        let listener = lock.withLock { () -> (@MainActor @Sendable (Notice) -> Void)? in
            if listener == nil { held.append(notice) }
            return listener
        }
        guard let listener else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { listener(notice) }
        } else {
            Task { @MainActor in listener(notice) }
        }
    }

    /// The host, taking everything said so far and everything said from now on.
    @_spi(Host) @MainActor
    public func listen(_ listener: @escaping @MainActor @Sendable (Notice) -> Void) {
        let held = lock.withLock { () -> [Notice] in
            self.listener = listener
            defer { self.held = [] }
            return self.held
        }
        held.forEach(listener)
    }
}

// MARK: What a UserDataFile has to say

/// The three things the reader is told about a `UserDataFile`, said the same
/// way for every one of them. `title` and `text` name what the file holds, as
/// a title and in a sentence — "Bookmarks" and "bookmarks" — and are plural,
/// because every such file is a collection of something.
public extension Notice {
    /// What `UserDataFile.read` did with `file` when it couldn't read it:
    /// moved it to `keptAt`, or, with `keptAt` nil, left it where it was.
    static func unreadable(_ title: String, _ text: String, file: URL, keptAt: URL?,
                           source: String) -> Notice {
        guard let kept = keptAt else {
            return Notice(
                title: "Your \(title) Couldn't Be Read",
                message: "MaximalTree couldn't read your \(text) or move them aside, so it is "
                    + "leaving the file exactly as it is and won't save over it. Nothing you "
                    + "change in your \(text) this session will be kept.",
                source: source)
        }
        return Notice(
            title: "Your \(title) Were Set Aside",
            message: "MaximalTree couldn't read your \(text), so it moved them, untouched, "
                + "to “\(kept.lastPathComponent)” in \(kept.deletingLastPathComponent().path) "
                + "and started afresh. A newer build may be able to read them: to put "
                + "them back, quit and rename that file to “\(file.lastPathComponent)”.",
            source: source)
    }

    /// A save that failed. Say it once per run of failures, not once per
    /// change: it tries again with each one.
    static func notSaved(_ title: String, _ text: String, error: any Error,
                         source: String) -> Notice {
        Notice(
            title: "Your \(title) Weren't Saved",
            message: "MaximalTree couldn't save your \(text): \(error.localizedDescription) "
                + "It tries again with every change; until one succeeds, what you change won't "
                + "be there next time.",
            source: source)
    }
}
