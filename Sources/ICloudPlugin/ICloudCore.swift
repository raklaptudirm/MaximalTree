import Foundation
import MaximalTreeKit

// iCloud Drive, as a place in the tree.
//
// An iCloud item *is* a file on this Mac — iCloud Drive is mounted locally —
// so this plugin does no file work of its own. It asks whoever serves
// `file://` for listings, and dresses each item as what it also is: the file
// on disk is its identity, so every file action and the file inspector apply
// to it, and opening it opens the file. What it adds is the one thing only
// iCloud knows: whether the bytes are on this Mac at all.

// MARK: - Where the bytes are

/// Where an item's contents are right now.
enum DownloadState: String, Sendable, Equatable {
    /// On this Mac, and the newest version there is.
    case current
    /// On this Mac, but iCloud has a newer one.
    case behind
    /// Only in iCloud. Opening it fetches it first, which can take a while.
    case inCloud
}

// MARK: - The drive

/// iCloud Drive as Finder shows it: its own folder, and beside it the folder
/// of every app that keeps documents in iCloud — Pages, Numbers, Shortcuts,
/// Obsidian — each of which is a container of its own on disk.
///
/// Everything here is injectable, and under the test runner the location is a
/// temporary directory: a test never lists, downloads or evicts anything in
/// the reader's own iCloud.
struct ICloudDrive: Sendable {
    /// Where iCloud keeps every container: iCloud Drive's own, and each app's.
    let containers: URL
    /// Where an item's contents are, or nil for something iCloud doesn't track.
    let state: @Sendable (URL) -> DownloadState?
    /// Start fetching an item's contents to this Mac.
    let download: @Sendable (URL) throws -> Void
    /// Drop an item's local copy, keeping it in iCloud.
    let evict: @Sendable (URL) throws -> Void
    /// What an app's folder is called — or nil for a container Finder keeps
    /// out of sight, which most are: Mail's, Safari's history, Wallet's. Only
    /// the ones an app declares public are documents you'd recognise.
    let appFolder: @Sendable (URL) -> String?

    static let driveContainer = "com~apple~CloudDocs"
    static let rootURI = "icloud://drive"
    static var rootID: NodeID { NodeID(canonical: rootURI) }

    /// iCloud Drive's own folder.
    var root: URL { containers.appendingPathComponent(Self.driveContainer, isDirectory: true) }

    static let live = ICloudDrive(
        containers: liveContainers,
        state: readState,
        download: { try FileManager.default.startDownloadingUbiquitousItem(at: $0) },
        evict: { try FileManager.default.evictUbiquitousItem(at: $0) },
        appFolder: readAppFolder)

    private static var liveContainers: URL {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("maximaltree-icloud-test-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: dir.appendingPathComponent(driveContainer), withIntermediateDirectories: true)
            return dir
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents", isDirectory: true)
    }

    static func readState(_ url: URL) -> DownloadState? {
        guard let values = try? url.resourceValues(
                forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true,
              let status = values.ubiquitousItemDownloadingStatus else { return nil }
        switch status {
        case .current: return .current
        case .downloaded: return .behind
        case .notDownloaded: return .inCloud
        default: return nil
        }
    }

    /// Whether Finder shows a container, and as what.
    ///
    /// The sync daemon marks a public container visible and a private one
    /// hidden, and names each after its app — so this asks the same two
    /// questions Finder does, through the file system rather than through any
    /// database of iCloud's own.
    static func readAppFolder(_ container: URL) -> String? {
        let documents = container.appendingPathComponent("Documents", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard (try? container.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == false,
              FileManager.default.fileExists(atPath: documents.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        let name = (try? documents.resourceValues(forKeys: [.ubiquitousItemContainerDisplayNameKey]))?
            .ubiquitousItemContainerDisplayName
        // Some arrive wrapped in direction marks, which draw as nothing and
        // sort as something.
        let cleaned = name?.filter { !["\u{200E}", "\u{200F}"].contains($0) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned?.isEmpty == false ? cleaned : container.lastPathComponent
    }

    /// The app folders Finder would show, by container, with their names.
    func appFolders() -> [(container: String, name: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: containers.path)) ?? []
        return names.sorted().compactMap { container in
            guard container != Self.driveContainer, !container.hasPrefix(".") else { return nil }
            return appFolder(containers.appendingPathComponent(container, isDirectory: true))
                .map { (container, $0) }
        }
    }

    // MARK: Addresses
    //
    // `icloud://drive/…` is iCloud Drive's own folder, and `icloud://app/<c>/…`
    // is inside the documents of the app whose container is `<c>`.

    /// Where an `icloud://` node lives on disk — or nil, for anything that
    /// isn't one of ours or that would land outside the place it names.
    ///
    /// A URI can arrive from a keymap or a script now, not only from a
    /// listing we produced, so `icloud://drive/../../etc` has to be turned
    /// away rather than trusted to mean somewhere inside iCloud.
    func url(for id: NodeID) -> URL? {
        guard id.scheme == "icloud", let parts = URLComponents(string: id.uri) else { return nil }
        var components = parts.path.split(separator: "/").map(String.init)
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        let base: URL
        switch parts.host {
        case "drive":
            base = root
        case "app":
            guard let container = components.first, container != Self.driveContainer else { return nil }
            components.removeFirst()
            base = containers.appendingPathComponent(container, isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        default:
            return nil
        }
        let url = components.reduce(base) { $0.appendingPathComponent($1) }
        guard Self.contains(url, in: base) else { return nil }
        return url
    }

    /// The `icloud://` node a location on disk is, if it is in iCloud Drive
    /// or in an app's documents.
    func id(for url: URL) -> NodeID? {
        let path = url.standardizedFileURL.path
        if Self.contains(url, in: root) {
            return Self.address("drive", String(path.dropFirst(root.standardizedFileURL.path.count)))
        }
        let base = containers.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return nil }
        let rest = path.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        guard rest.count >= 2, rest[1] == "Documents", rest[0] != Self.driveContainer,
              !rest[0].hasPrefix(".") else { return nil }
        return Self.address("app", "/" + ([rest[0]] + rest.dropFirst(2)).joined(separator: "/"))
    }

    /// The `file://` node the same item is.
    func fileID(for id: NodeID) -> NodeID? {
        url(for: id).flatMap { NodeID($0.standardizedFileURL.absoluteString) }
    }

    /// The container an app folder's node belongs to, when it is the top of
    /// one — `icloud://app/com~apple~Pages`, and nothing deeper.
    func appContainer(of id: NodeID) -> String? {
        guard id.scheme == "icloud", let parts = URLComponents(string: id.uri),
              parts.host == "app" else { return nil }
        let components = parts.path.split(separator: "/").map(String.init)
        return components.count == 1 ? components[0] : nil
    }

    /// What an app folder's node is called: the app's name, not "Documents".
    func appName(for id: NodeID) -> String? {
        appContainer(of: id).flatMap {
            appFolder(containers.appendingPathComponent($0, isDirectory: true))
        }
    }

    /// Whether Finder would show where this node is. Anything in iCloud
    /// Drive's own folder is; something in an app's container is only if the
    /// app made it public.
    func isShown(_ id: NodeID) -> Bool {
        guard let parts = URLComponents(string: id.uri) else { return false }
        if parts.host == "drive" { return true }
        guard let container = parts.path.split(separator: "/").first.map(String.init) else { return false }
        return appFolder(containers.appendingPathComponent(container, isDirectory: true)) != nil
    }

    private static func address(_ host: String, _ path: String) -> NodeID? {
        var parts = URLComponents()
        parts.scheme = "icloud"
        parts.host = host
        parts.path = path
        return parts.string.flatMap(NodeID.init)
    }

    private static func contains(_ url: URL, in base: URL) -> Bool {
        let base = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}

// MARK: - The provider

/// `icloud://` nodes: iCloud Drive's items, each one the file it also is.
struct ICloudProvider: NodeProvider {
    let schemes: Set<String> = ["icloud"]
    let drive: ICloudDrive
    let broker: NodeBroker

    static let fileType = TypeID("icloud.file")
    static let directoryType = TypeID("icloud.directory")

    func resolve(_ uri: String) -> NodeID? {
        guard let id = NodeID(uri), let url = drive.url(for: id),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return id
    }

    func node(for id: NodeID) async -> Node? {
        guard let fileID = drive.fileID(for: id),
              let file = await broker.node(for: fileID.uri) else { return nil }
        return dress(file, as: id)
    }

    func children(of id: NodeID, page cursor: Cursor?) async -> Page<Node> {
        guard let fileID = drive.fileID(for: id) else { return Page(items: []) }
        let page = await broker.children(of: fileID.uri, page: cursor)
        var items = page.items.compactMap { file -> Node? in
            guard let url = URL(string: file.id.uri), let child = drive.id(for: url) else { return nil }
            return dress(file, as: child)
        }
        // The top of the drive is also every app folder, as it is in Finder —
        // each one a container of its own on disk, beside iCloud Drive's.
        if id == ICloudDrive.rootID, cursor == nil {
            items += await appFolderNodes()
            items.sort(by: Self.inFinderOrder)
        }
        return Page(items: items, next: page.next)
    }

    private func appFolderNodes() async -> [Node] {
        var nodes: [Node] = []
        for (container, _) in drive.appFolders() {
            guard let id = NodeID("icloud://app/\(container)"),
                  let fileID = drive.fileID(for: id),
                  let file = await broker.node(for: fileID.uri) else { continue }
            nodes.append(dress(file, as: id))
        }
        return nodes
    }

    /// Folders first, then by name — the file plugin's order, kept once the
    /// app folders have joined the listing.
    static func inFinderOrder(_ a: Node, _ b: Node) -> Bool {
        let aFolder = a.type == directoryType, bFolder = b.type == directoryType
        if aFolder != bFolder { return aFolder }
        return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
    }

    /// A file's record, worn by the iCloud item it is.
    ///
    /// Its label, icon, size and dates are the file's, because they are the
    /// same thing. Its identity is the file, which is what hands it every file
    /// action and the file inspector; its anchor is the file, which is what
    /// makes opening it open the file. The download state is the only part
    /// that is iCloud's own.
    func dress(_ file: Node, as id: NodeID) -> Node {
        let isDirectory = file.type == .directory
        var node = Node(
            id: id,
            type: isDirectory ? Self.directoryType : Self.fileType,
            label: drive.appName(for: id) ?? (id == ICloudDrive.rootID ? "iCloud Drive" : file.label),
            icon: id == ICloudDrive.rootID ? NodeIcon("icloud", tint: .blue) : file.icon,
            attributes: file.attributes,
            subtitle: file.subtitle,
            hasChildren: file.hasChildren,
            childStyle: file.childStyle,
            anchor: NodeAnchor(node: file.id),
            identities: [file.id])
        if let url = URL(string: file.id.uri), let state = drive.state(url) {
            node.attributes["icloud"] = .string(state.rawValue)
            // Worth seeing at a glance: this one will take a moment to open.
            if state == .inCloud, !isDirectory {
                node.icon = NodeIcon("icloud.and.arrow.down", tint: .secondary)
            }
        }
        return node
    }

    /// Where a node's contents are, as its record says.
    static func state(of node: Node) -> DownloadState? {
        guard case .string(let raw)? = node.attributes["icloud"] else { return nil }
        return DownloadState(rawValue: raw)
    }
}

// MARK: - Keeping up with iCloud

/// Downloads finish and evictions happen without the app asking, so the drive
/// is watched like any other folder and its rows refreshed when iCloud moves
/// something in or out.
///
/// Conservative, as the funnel asks: a changed item is `.modified` and its
/// folder `.childrenChanged`. File events rarely say "renamed" reliably, and a
/// wrong one tears down a tab.
extension ICloudProvider: ChangeStreamingProvider {
    func changes(under root: NodeID) -> AsyncStream<[NodeChange]>? {
        let drive = drive
        // The whole drive is its app folders too, so it is watched where all
        // the containers are; a folder mounted on its own, where it is.
        guard let path = root == ICloudDrive.rootID ? drive.containers.path : drive.url(for: root)?.path
        else { return nil }
        return AsyncStream { continuation in
            let watcher = FileTreeWatcher(path: path) { events in
                let changes = Self.changes(for: events, in: drive)
                if !changes.isEmpty { continuation.yield(changes) }
            }
            continuation.onTermination = { _ in watcher?.stop() }
        }
    }

    static func changes(for events: [FileTreeWatcher.Event], in drive: ICloudDrive) -> [NodeChange] {
        var changes: [NodeChange] = []
        for event in events {
            let url = URL(fileURLWithPath: event.path)
            // A container appearing or going is the top of the drive changing.
            if url.deletingLastPathComponent().standardizedFileURL.path
                == drive.containers.standardizedFileURL.path {
                changes.append(.childrenChanged(ICloudDrive.rootID))
                continue
            }
            if event.mustRescanSubtree, let id = drive.id(for: url) {
                changes.append(.childrenChanged(id))
                continue
            }
            if let id = drive.id(for: url) { changes.append(.modified(id)) }
            if let parent = drive.id(for: url.deletingLastPathComponent()) {
                changes.append(.childrenChanged(parent))
            }
        }
        // Nothing from a container Finder keeps out of sight: Safari's history
        // and Mail's state change constantly, and none of it is in the tree.
        changes = changes.filter { change in
            switch change {
            case .modified(let id), .childrenChanged(let id), .removed(let id): return drive.isShown(id)
            case .renamed(_, let to): return drive.isShown(to)
            @unknown default: return true
            }
        }
        // One of each, in order: a burst of events about one folder is one
        // relisting, not twenty.
        return changes.reduce(into: []) { kept, change in
            if !kept.contains(change) { kept.append(change) }
        }
    }
}
