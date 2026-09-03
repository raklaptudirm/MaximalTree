import Foundation

/// One thing a finder can offer.
///
/// An item says what it *is*, not what to do about it: opening a node or
/// running an action, both named the way the rest of the app names them — a
/// uri and an action id. A plugin can therefore list its notes or its
/// bookmarks without reaching into the host, and the finder needs to know
/// nothing about what it is listing.
public struct FinderItem: Identifiable, Sendable {
    public enum Effect: Sendable {
        /// Open this node, as clicking it in the sidebar would.
        case open(String)
        /// Run this action id, as a key bound to it would.
        case run(String)
    }

    public let id: String
    /// What is matched against, and shown.
    public let title: String
    /// Shown after the title, and matched with a lighter weight — a path, a
    /// host, a folder.
    public let subtitle: String?
    public let systemImage: String?
    public let effect: Effect

    public init(id: String, title: String, subtitle: String? = nil,
                systemImage: String? = nil, effect: Effect) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.effect = effect
    }
}

/// A list the finder can search.
///
/// Files, open tabs, actions, notes, bookmarks: each is a source, and each is
/// reachable on its own or through the one that searches everything. Plugins
/// register these the way they register anything else, so "find a note" and
/// "find a bookmark" arrive with the plugins that own notes and bookmarks
/// rather than being wired into the host.
public struct FinderSource: Identifiable, Sendable {
    public let id: String
    /// Named in the picker's title and beside its results.
    public let title: String
    /// What the query field says before anything is typed.
    public let prompt: String
    public let systemImage: String?
    /// Whether searching *everything* includes this. A source that is slow or
    /// enormous can stay opt-in and still have a key of its own.
    public let searchedByDefault: Bool
    /// How strongly this source's items compete when everything is searched
    /// at once.
    ///
    /// Not all lists are alike. A workspace holds thousands of files that
    /// happen to be there and a handful of commands that were deliberately
    /// named, so on equal terms the files bury the commands: searching "we"
    /// offered `weakref_finalize.py` before "New Web Page". A few points of
    /// preference restores the balance without pinning anything.
    public let weight: Int
    /// Gathered when the picker opens. Async because a file tree is a disk
    /// walk and a bookmark list is a read.
    public let items: @Sendable () async -> [FinderItem]

    public init(id: String, title: String, prompt: String,
                systemImage: String? = nil, searchedByDefault: Bool = true,
                weight: Int = 0,
                items: @escaping @Sendable () async -> [FinderItem]) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.systemImage = systemImage
        self.searchedByDefault = searchedByDefault
        self.weight = weight
        self.items = items
    }
}
