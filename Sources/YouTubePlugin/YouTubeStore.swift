import Foundation
import MaximalTreeKit

// What the plugin keeps between runs: what a video was called, what it looked
// like, and what you searched for. Nothing about you goes to YouTube — this is
// the opposite direction, so that a video you put in a collection is still a
// title and a thumbnail when you are offline, or when YouTube has stopped
// answering in a shape we can read.

/// Where those things live — and, under the test runner, somewhere else, so a
/// test never writes the reader's own.
enum YouTubeStorage {
    static func directory() -> URL {
        let base: URL
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("maximaltree-youtube-test-\(UUID().uuidString)", isDirectory: true)
        } else {
            base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MaximalTree/youtube", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

/// What a listing said about a video, kept.
struct VideoRecord: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var line: String?
    var channel: String?
    var channelID: String?
    /// When it was last seen in a listing — which is what gets dropped first
    /// when the store is full.
    var seen: Date
}

/// What a listing said about a playlist, kept.
struct PlaylistRecord: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var line: String?
    var seen: Date
}

/// Titles, thumbnails and recent searches, on disk.
///
/// Bounded on purpose: a reader who browses for a year should not find a
/// megabyte of forgotten titles and ten thousand thumbnails. The oldest go
/// first, and nothing here is ever the only copy of anything — it is all
/// re-fetchable, which is what makes dropping it safe.
final class YouTubeStore: @unchecked Sendable {
    nonisolated(unsafe) static let shared = YouTubeStore()

    /// Roughly a year of browsing, and a few megabytes of thumbnails.
    static let videoLimit = 4000, playlistLimit = 500, thumbnailLimit = 800, searchLimit = 20

    /// Smaller in a test, which should not write four thousand records to
    /// prove that the four thousand and first drops one.
    let videoLimit: Int, playlistLimit: Int, thumbnailLimit: Int

    private let lock = NSLock()
    private let directory: URL
    private var videos: [String: VideoRecord] = [:]
    private var playlists: [String: PlaylistRecord] = [:]
    private var searches: [String] = []
    /// What each feed is called. Here rather than in its URI, so renaming one
    /// is not a change of identity — see `YouTubeRef`.
    ///
    /// Kept in a file of its own, apart from everything else here. The rest is a
    /// cache, safe to drop because all of it can be fetched again; a name the
    /// reader chose can't be, so it lives under `UserDataFile`'s rule instead.
    private var feedNames: [String: String] = [:]
    private let feedsURL: URL
    /// False when the feeds file couldn't be read or moved aside.
    private var feedsWritable = true
    /// The last time the names didn't save, until they do.
    private var lastFeedsSaveError: (any Error)?
    var feedsSaveError: (any Error)? { lock.withLock { lastFeedsSaveError } }
    /// Thumbnails read (or written) this run, so drawing a row is not a disk
    /// read each time. `nil` records one we have no image for.
    private var icons: [String: Data?] = [:]

    init(directory: URL? = nil, videoLimit: Int = YouTubeStore.videoLimit,
         playlistLimit: Int = YouTubeStore.playlistLimit,
         thumbnailLimit: Int = YouTubeStore.thumbnailLimit) {
        self.directory = directory ?? YouTubeStorage.directory()
        self.videoLimit = videoLimit
        self.playlistLimit = playlistLimit
        self.thumbnailLimit = thumbnailLimit
        let known = Self.read(Known.self, at: self.directory.appendingPathComponent("known.json"))
        videos = Dictionary(uniqueKeysWithValues: (known?.videos ?? []).map { ($0.id, $0) })
        playlists = Dictionary(uniqueKeysWithValues: (known?.playlists ?? []).map { ($0.id, $0) })
        searches = known?.searches ?? []
        feedsURL = self.directory.appendingPathComponent("feeds.json")
        switch UserDataFile.read([String: String].self, from: feedsURL) {
        case .read(let names):
            feedNames = names
        case .missing:
            // Builds before this kept the names in the cache file. Take them
            // across once, and from then on they are only here.
            feedNames = known?.feedNames ?? [:]
            if !feedNames.isEmpty { writeFeeds() }
        case .unreadable(let keptAt, let reason):
            feedsWritable = keptAt != nil
            NSLog("[YouTubePlugin] feed names unreadable (\(reason)); "
                  + (keptAt.map { "kept at \($0.path)" } ?? "left in place, not saving over it"))
        }
    }

    // MARK: What things are called

    func video(_ id: String) -> VideoRecord? { lock.withLock { videos[id] } }
    func playlist(_ id: String) -> PlaylistRecord? { lock.withLock { playlists[id] } }

    func remember(videos items: [VideoItem], line: (VideoItem) -> String?) {
        guard !items.isEmpty else { return }
        let now = Date()
        lock.withLock {
            for item in items {
                videos[item.id] = VideoRecord(id: item.id, title: item.title, line: line(item),
                                              channel: item.channel, channelID: item.channelID,
                                              seen: now)
            }
            trim()
        }
        write()
    }

    func remember(playlists items: [PlaylistItem]) {
        guard !items.isEmpty else { return }
        let now = Date()
        lock.withLock {
            for item in items {
                playlists[item.id] = PlaylistRecord(id: item.id, title: item.title,
                                                    line: item.line, seen: now)
            }
            trim()
        }
        write()
    }

    /// What a feed is called, or what a new one is called until it is renamed.
    func feedName(_ id: UUID) -> String {
        lock.withLock { feedNames[id.uuidString.lowercased()] } ?? "YouTube Feed"
    }

    func remember(feedName name: String, for id: UUID) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            if name.isEmpty { feedNames[id.uuidString.lowercased()] = nil }
            else { feedNames[id.uuidString.lowercased()] = name }
        }
        writeFeeds()
    }

    // MARK: What you looked for

    func remember(search query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        lock.withLock {
            searches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
            searches.insert(query, at: 0)
            searches = Array(searches.prefix(Self.searchLimit))
        }
        write()
    }

    func recentSearches() -> [String] { lock.withLock { searches } }

    func forgetSearches() {
        lock.withLock { searches = [] }
        write()
    }

    // MARK: What things look like

    /// The thumbnail for a video, if one has been fetched. Never fetches:
    /// this is called while drawing rows.
    func icon(for id: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let known = icons[id] { return known }
        let data = try? Data(contentsOf: thumbnail(id))
        icons[id] = data
        return data
    }

    func store(icon data: Data, for id: String) {
        guard !data.isEmpty, Self.isVideoID(id) else { return }
        lock.withLock { icons[id] = data }
        try? data.write(to: thumbnail(id), options: .atomic)
        pruneThumbnails()
    }

    private func thumbnail(_ id: String) -> URL {
        directory.appendingPathComponent("thumb-\(id).jpg")
    }

    /// Ids are YouTube's, but a file name is ours to be careful with.
    static func isVideoID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32
            && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    // MARK: Keeping it bounded

    private func trim() {
        if videos.count > videoLimit {
            for record in videos.values.sorted(by: { $0.seen < $1.seen })
                .prefix(videos.count - videoLimit) {
                videos[record.id] = nil
            }
        }
        if playlists.count > playlistLimit {
            for record in playlists.values.sorted(by: { $0.seen < $1.seen })
                .prefix(playlists.count - playlistLimit) {
                playlists[record.id] = nil
            }
        }
    }

    private func pruneThumbnails() {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.lastPathComponent.hasPrefix("thumb-") }),
              names.count > thumbnailLimit else { return }
        let oldest = names.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in oldest.prefix(names.count - thumbnailLimit) {
            try? files.removeItem(at: file)
            lock.withLock {
                let id = file.deletingPathExtension().lastPathComponent.dropFirst("thumb-".count)
                icons[String(id)] = nil
            }
        }
    }

    // MARK: On disk

    private struct Known: Codable {
        var videos: [VideoRecord]
        var playlists: [PlaylistRecord]
        var searches: [String]
        /// Read from caches written before feed names had a file of their own,
        /// to carry them across; never written any more.
        var feedNames: [String: String]?
    }

    private static func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func write() {
        let known = lock.withLock {
            Known(videos: Array(videos.values), playlists: Array(playlists.values),
                  searches: searches, feedNames: nil)
        }
        // A cache: a write that fails costs a refetch, so it isn't worth more
        // than trying.
        guard let data = try? JSONEncoder().encode(known) else { return }
        try? data.write(to: directory.appendingPathComponent("known.json"), options: .atomic)
    }

    private func writeFeeds() {
        guard feedsWritable else { return }
        let names = lock.withLock { feedNames }
        do {
            try UserDataFile.write(names, to: feedsURL)
            lock.withLock { lastFeedsSaveError = nil }
        } catch {
            lock.withLock { lastFeedsSaveError = error }
            NSLog("[YouTubePlugin] feed names not saved: \(error.localizedDescription)")
        }
    }
}
